// SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

#include "cuvid_decoder.hpp"
#include "videodecoder_context.hpp"
#include <iostream>
#include <iomanip>
#include <cstring>

#define CUVID_LOG_ERROR(msg) std::cerr << "[CUVID ERROR] " << msg << std::endl
#define CUVID_LOG_WARN(msg) std::cerr << "[CUVID WARN] " << msg << std::endl
#define CUVID_LOG_INFO(msg) std::cout << "[CUVID INFO] " << msg << std::endl
#define CUVID_LOG_DEBUG(msg) std::cout << "[CUVID DEBUG] " << msg << std::endl

#define CHECK_CUDA_ERROR(call, msg) \
  do { \
    CUresult err = call; \
    if (err != CUDA_SUCCESS) { \
      const char* err_str; \
      cuGetErrorString(err, &err_str); \
      CUVID_LOG_ERROR(msg << ": " << err_str); \
      return -1; \
    } \
  } while(0)

namespace nvidia {
namespace gxf {

CuvidDecoder::CuvidDecoder() {}

CuvidDecoder::~CuvidDecoder() {}

int CUDAAPI CuvidDecoder::HandleVideoSequence(void* user_data, CUVIDEOFORMAT* format) {
  CuvidContext* ctx = static_cast<CuvidContext*>(user_data);
  
  CUVID_LOG_INFO("Video sequence: " << format->coded_width << "x" << format->coded_height);
  
  // Store video parameters
  ctx->coded_width = format->coded_width;
  ctx->coded_height = format->coded_height;
  ctx->width = format->display_area.right - format->display_area.left;
  ctx->height = format->display_area.bottom - format->display_area.top;
  
  // Propagate dimensions to parent context for response codelet
  if (ctx->parent_ctx) {
    ctx->parent_ctx->video_width = ctx->width;
    ctx->parent_ctx->video_height = ctx->height;
    ctx->parent_ctx->colorspace = V4L2_COLORSPACE_DEFAULT;
    ctx->parent_ctx->quantization = V4L2_QUANTIZATION_DEFAULT;
  }
  
  // Create decoder if not exists or format changed
  CuvidDecoder decoder;
  if (decoder.createDecoder(ctx, format) != 0) {
    CUVID_LOG_ERROR("Failed to create decoder");
    return 0;
  }
  
  return 1;
}

int CUDAAPI CuvidDecoder::HandlePictureDecode(void* user_data, CUVIDPICPARAMS* pic_params) {
  CuvidContext* ctx = static_cast<CuvidContext*>(user_data);
  
  std::lock_guard<std::mutex> lock(ctx->decoder_mutex);
  
  // Ensure CUDA context is active
  CUcontext current_ctx;
  cuCtxGetCurrent(&current_ctx);
  if (current_ctx != ctx->cu_context) {
    cuCtxPushCurrent(ctx->cu_context);
  }
  
  CUresult result = cuvidDecodePicture(ctx->decoder, pic_params);
  if (result != CUDA_SUCCESS) {
    CUVID_LOG_ERROR("Failed to decode picture");
    return 0;
  }
  
  return 1;
}

int CUDAAPI CuvidDecoder::HandlePictureDisplay(void* user_data, CUVIDPARSERDISPINFO* disp_info) {
  CuvidContext* ctx = static_cast<CuvidContext*>(user_data);
  
  std::lock_guard<std::mutex> lock(ctx->decoder_mutex);
  
  // If a frame is already mapped and not yet consumed, skip this one
  // This prevents mapping multiple frames which causes errors
  if (ctx->frame_available) {
    CUVID_LOG_WARN("Frame already available, skipping new frame");
    return 1;
  }
  
  // Ensure CUDA context is active
  CUcontext current_ctx;
  cuCtxGetCurrent(&current_ctx);
  if (current_ctx != ctx->cu_context) {
    cuCtxPushCurrent(ctx->cu_context);
  }
  
  CUVIDPROCPARAMS proc_params = {};
  proc_params.progressive_frame = disp_info->progressive_frame;
  proc_params.top_field_first = disp_info->top_field_first;
  proc_params.second_field = 0;
  
  unsigned int pitch = 0;
  CUresult result = cuvidMapVideoFrame(ctx->decoder, disp_info->picture_index,
                                       &ctx->decoded_frame, &pitch, &proc_params);
  if (result != CUDA_SUCCESS) {
    const char* err_str;
    cuGetErrorString(result, &err_str);
    CUVID_LOG_ERROR("Failed to map video frame: " << err_str);
    return 0;
  }
  
  ctx->decoded_pitch = pitch;
  ctx->picture_index = disp_info->picture_index;
  ctx->frame_available = true;
  
  // Trigger response codelet only if we have an entity waiting
  if (ctx->scheduling_term && ctx->output_entity_queue) {
    if (!ctx->output_entity_queue->empty()) {
      ctx->scheduling_term->setEventState(nvidia::gxf::AsynchronousEventState::EVENT_DONE);
    } else {
      CUVID_LOG_WARN("Frame ready but no entity in queue, skipping EVENT_DONE");
    }
  }
  
  return 1;
}

int CuvidDecoder::createDecoder(CuvidContext* ctx, CUVIDEOFORMAT* format) {
  // Ensure CUDA context is active
  CUcontext current_ctx;
  cuCtxGetCurrent(&current_ctx);
  if (current_ctx != ctx->cu_context) {
    CUresult result = cuCtxPushCurrent(ctx->cu_context);
    if (result != CUDA_SUCCESS) {
      const char* err_str;
      cuGetErrorString(result, &err_str);
      CUVID_LOG_ERROR("Failed to set CUDA context: " << err_str);
      return -1;
    }
  }
  
  // Destroy old decoder if exists
  if (ctx->decoder) {
    cuvidDestroyDecoder(ctx->decoder);
    ctx->decoder = nullptr;
  }
  
  CUVIDDECODECREATEINFO decode_info = {};
  decode_info.CodecType = format->codec;
  decode_info.ChromaFormat = format->chroma_format;
  decode_info.OutputFormat = cudaVideoSurfaceFormat_NV12;
  decode_info.bitDepthMinus8 = format->bit_depth_luma_minus8;
  decode_info.DeinterlaceMode = cudaVideoDeinterlaceMode_Adaptive;
  decode_info.ulNumOutputSurfaces = 2;
  decode_info.ulCreationFlags = cudaVideoCreate_PreferCUVID;
  decode_info.ulNumDecodeSurfaces = 8;
  decode_info.vidLock = nullptr;
  decode_info.ulWidth = format->coded_width;
  decode_info.ulHeight = format->coded_height;
  decode_info.ulMaxWidth = format->coded_width;
  decode_info.ulMaxHeight = format->coded_height;
  decode_info.ulTargetWidth = format->coded_width;
  decode_info.ulTargetHeight = format->coded_height;
  
  CUresult result = cuvidCreateDecoder(&ctx->decoder, &decode_info);
  if (result != CUDA_SUCCESS) {
    const char* err_str;
    cuGetErrorString(result, &err_str);
    CUVID_LOG_ERROR("Failed to create CUVID decoder: " << err_str);
    return -1;
  }
  
  // Verify hardware decoder was created
  CUVIDDECODECAPS decode_caps = {};
  decode_caps.eCodecType = format->codec;
  decode_caps.eChromaFormat = format->chroma_format;
  decode_caps.nBitDepthMinus8 = format->bit_depth_luma_minus8;
  
  result = cuvidGetDecoderCaps(&decode_caps);
  if (result == CUDA_SUCCESS && decode_caps.bIsSupported) {
    CUVID_LOG_INFO("CUVID hardware decoder created: " << format->coded_width << "x" << format->coded_height 
                   << " (HW accelerated: " << (decode_caps.bIsSupported ? "YES" : "NO") << ")");
  } else {
    CUVID_LOG_WARN("CUVID decoder created but hardware support unclear: " << format->coded_width << "x" << format->coded_height);
  }
  
  return 0;
}

int CuvidDecoder::initialize(CuvidContext* ctx) {
  // Initialize CUDA
  CHECK_CUDA_ERROR(cuInit(0), "Failed to initialize CUDA");
  
  // Get CUDA device
  CHECK_CUDA_ERROR(cuDeviceGet(&ctx->cu_device, ctx->device_id), 
                   "Failed to get CUDA device");
  
  // Create or get CUDA context
  CUcontext current_ctx;
  cuCtxGetCurrent(&current_ctx);
  if (current_ctx == nullptr) {
    CUctxCreateParams create_params{};
    CHECK_CUDA_ERROR(cuCtxCreate(&ctx->cu_context, &create_params, 0u, ctx->cu_device),
                    "Failed to create CUDA context");
  } else {
    ctx->cu_context = current_ctx;
  }

  
  // Create parser
  CUVIDPARSERPARAMS parser_params = {};
  parser_params.CodecType = cudaVideoCodec_H264;
  parser_params.ulMaxNumDecodeSurfaces = 8;
  parser_params.ulMaxDisplayDelay = 1;
  parser_params.pUserData = ctx;
  parser_params.pfnSequenceCallback = HandleVideoSequence;
  parser_params.pfnDecodePicture = HandlePictureDecode;
  parser_params.pfnDisplayPicture = HandlePictureDisplay;
  
  CUresult result = cuvidCreateVideoParser(&ctx->parser, &parser_params);
  if (result != CUDA_SUCCESS) {
    const char* err_str;
    cuGetErrorString(result, &err_str);
    CUVID_LOG_ERROR("Failed to create video parser: " << err_str);
    return -1;
  }
  
  ctx->frame_available = false;
  ctx->eos = false;
  ctx->decoder = nullptr;
  
  CUVID_LOG_INFO("CUVID decoder initialized successfully");
  return 0;
}

int CuvidDecoder::decode(CuvidContext* ctx, const uint8_t* bitstream, uint32_t size) {
  // Ensure CUDA context is active
  CUcontext current_ctx;
  cuCtxGetCurrent(&current_ctx);
  if (current_ctx != ctx->cu_context) {
    CUresult result = cuCtxPushCurrent(ctx->cu_context);
    if (result != CUDA_SUCCESS) {
      const char* err_str;
      cuGetErrorString(result, &err_str);
      CUVID_LOG_ERROR("Failed to set CUDA context for decode: " << err_str);
      return -1;
    }
  }
  
  CUVIDSOURCEDATAPACKET packet = {};
  packet.payload = bitstream;
  packet.payload_size = size;
  packet.flags = CUVID_PKT_TIMESTAMP;
  packet.timestamp = 0;
  
  CUresult result = cuvidParseVideoData(ctx->parser, &packet);
  if (result != CUDA_SUCCESS) {
    const char* err_str;
    cuGetErrorString(result, &err_str);
    CUVID_LOG_ERROR("Failed to parse video data: " << err_str);
    return -1;
  }
  
  return 0;
}

int CuvidDecoder::getDecodedFrame(CuvidContext* ctx, CUdeviceptr* frame_ptr, uint32_t* pitch) {
  std::lock_guard<std::mutex> lock(ctx->decoder_mutex);
  
  if (!ctx->frame_available) {
    return -1;
  }
  
  *frame_ptr = ctx->decoded_frame;
  *pitch = ctx->decoded_pitch;
  
  return 0;
}

void CuvidDecoder::freeResources(CuvidContext* ctx) {
  if (ctx->decoder) {
    // Unmap any mapped frames
    if (ctx->frame_available) {
      cuvidUnmapVideoFrame(ctx->decoder, ctx->decoded_frame);
      ctx->frame_available = false;
    }
    cuvidDestroyDecoder(ctx->decoder);
    ctx->decoder = nullptr;
  }
  
  if (ctx->parser) {
    cuvidDestroyVideoParser(ctx->parser);
    ctx->parser = nullptr;
  }
  
  CUVID_LOG_INFO("CUVID resources freed");
}

int CuvidDecoder::finalize(CuvidContext* ctx) {
  // Send EOS to parser
  if (ctx->parser) {
    CUVIDSOURCEDATAPACKET packet = {};
    packet.flags = CUVID_PKT_ENDOFSTREAM;
    cuvidParseVideoData(ctx->parser, &packet);
  }
  
  freeResources(ctx);
  return 0;
}

}  // namespace gxf
}  // namespace nvidia
