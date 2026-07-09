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

#include "nvenc_encoder.hpp"
#include <cuda.h>
#include <dlfcn.h>
#include <cstring>
#include <iostream>

#define NVENC_LOG_ERROR(msg) std::cerr << "[NVENC ERROR] " << msg << std::endl
#define NVENC_LOG_INFO(msg) std::cout << "[NVENC INFO] " << msg << std::endl
#define NVENC_LOG_DEBUG(msg) std::cout << "[NVENC DEBUG] " << msg << std::endl

#define CHECK_CUDA_ERROR(call, msg) \
  do { \
    CUresult err = call; \
    if (err != CUDA_SUCCESS) { \
      const char* err_str; \
      cuGetErrorString(err, &err_str); \
      NVENC_LOG_ERROR(msg << ": " << err_str); \
      return -1; \
    } \
  } while(0)

#define CHECK_NVENC_ERROR(call, msg) \
  do { \
    NVENCSTATUS err = call; \
    if (err != NV_ENC_SUCCESS) { \
      NVENC_LOG_ERROR(msg << " (NVENC error: " << err << ")"); \
      return -1; \
    } \
  } while(0)

namespace nvidia {
namespace gxf {

NvencEncoder::NvencEncoder() {}

NvencEncoder::~NvencEncoder() {}

int NvencEncoder::loadNvencAPI(NvencContext* ctx) {
  // Load NVENC library
  ctx->nvenc_lib = dlopen("libnvidia-encode.so.1", RTLD_LAZY);
  if (!ctx->nvenc_lib) {
    NVENC_LOG_ERROR("Failed to load libnvidia-encode.so.1: " << dlerror());
    return -1;
  }
  
  // Get API function list creator
  typedef NVENCSTATUS (*NvEncodeAPICreateInstanceFunc)(NV_ENCODE_API_FUNCTION_LIST*);
  NvEncodeAPICreateInstanceFunc nvEncodeAPICreateInstance = 
      (NvEncodeAPICreateInstanceFunc)dlsym(ctx->nvenc_lib, "NvEncodeAPICreateInstance");
  
  if (!nvEncodeAPICreateInstance) {
    NVENC_LOG_ERROR("Failed to get NvEncodeAPICreateInstance");
    return -1;
  }
  
  // Initialize function list
  ctx->nvenc_api.version = NV_ENCODE_API_FUNCTION_LIST_VER;
  NVENCSTATUS status = nvEncodeAPICreateInstance(&ctx->nvenc_api);
  if (status != NV_ENC_SUCCESS) {
    NVENC_LOG_ERROR("Failed to create NVENC API instance");
    return -1;
  }
  
  NVENC_LOG_INFO("NVENC API loaded successfully");
  return 0;
}

int NvencEncoder::createEncoder(NvencContext* ctx) {
  // Initialize CUDA
  CHECK_CUDA_ERROR(cuInit(0), "Failed to initialize CUDA");
  
  // Get CUDA device
  CHECK_CUDA_ERROR(cuDeviceGet(&ctx->cu_device, ctx->device_id), 
                   "Failed to get CUDA device");
  
  // Create CUDA context (or use existing one)
  CUcontext current_ctx;
  cuCtxGetCurrent(&current_ctx);
  if (current_ctx == nullptr) {
#if CUDA_VERSION >= 13000
    CUctxCreateParams create_params{};
    CHECK_CUDA_ERROR(cuCtxCreate(&ctx->cu_context, &create_params, 0u, ctx->cu_device),
                    "Failed to create CUDA context");
#else
    CHECK_CUDA_ERROR(cuCtxCreate(&ctx->cu_context, 0u, ctx->cu_device),
                    "Failed to create CUDA context");
#endif
  } else {
    ctx->cu_context = current_ctx;
  }

  
  // Open encode session
  NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS session_params = {};
  session_params.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
  session_params.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
  session_params.device = ctx->cu_context;
  session_params.apiVersion = NVENCAPI_VERSION;
  
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncOpenEncodeSessionEx(&session_params, &ctx->encoder),
      "Failed to open NVENC encode session");
  
  NVENC_LOG_INFO("NVENC encoder session created");
  return 0;
}

int NvencEncoder::configureEncoder(NvencContext* ctx) {
  // Get preset config
  NV_ENC_PRESET_CONFIG preset_config = {};
  preset_config.version = NV_ENC_PRESET_CONFIG_VER;
  preset_config.presetCfg.version = NV_ENC_CONFIG_VER;
  
  GUID codec_guid = NV_ENC_CODEC_H264_GUID;
  GUID preset_guid = NV_ENC_PRESET_P4_GUID;  // Low latency preset
  
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncGetEncodePresetConfigEx(
          ctx->encoder, codec_guid, preset_guid, 
          NV_ENC_TUNING_INFO_LOW_LATENCY, &preset_config),
      "Failed to get preset config");
  
  // Initialize encoder config
  NV_ENC_INITIALIZE_PARAMS init_params = {};
  init_params.version = NV_ENC_INITIALIZE_PARAMS_VER;
  init_params.encodeGUID = codec_guid;
  init_params.presetGUID = preset_guid;
  init_params.encodeWidth = ctx->width;
  init_params.encodeHeight = ctx->height;
  init_params.darWidth = ctx->width;
  init_params.darHeight = ctx->height;
  init_params.frameRateNum = ctx->framerate;
  init_params.frameRateDen = 1;
  init_params.enablePTD = 1;
  init_params.reportSliceOffsets = 0;
  init_params.enableSubFrameWrite = 0;
  init_params.maxEncodeWidth = ctx->width;
  init_params.maxEncodeHeight = ctx->height;
  init_params.tuningInfo = NV_ENC_TUNING_INFO_LOW_LATENCY;
  
  // Encoder config
  NV_ENC_CONFIG encode_config = preset_config.presetCfg;
  init_params.encodeConfig = &encode_config;
  
  // H.264 specific config
  encode_config.profileGUID = NV_ENC_H264_PROFILE_HIGH_GUID;
  encode_config.frameIntervalP = 1;  // No B-frames

  // GOP / intra-refresh. Rolling intra-refresh recovers from packet loss without
  // periodic IDR bitrate spikes -- preferred for a lossy cellular uplink.
  if (ctx->intra_refresh > 0) {
    encode_config.gopLength = NVENC_INFINITE_GOPLENGTH;
    encode_config.encodeCodecConfig.h264Config.enableIntraRefresh = 1;
    encode_config.encodeCodecConfig.h264Config.intraRefreshPeriod = ctx->intra_refresh;
    encode_config.encodeCodecConfig.h264Config.intraRefreshCnt = ctx->intra_refresh;
  } else {
    encode_config.gopLength = ctx->gop_length;
  }
  
  // Rate control
  encode_config.rcParams.rateControlMode = (ctx->rate_control_mode == 0) ? 
      NV_ENC_PARAMS_RC_CONSTQP : 
      (ctx->rate_control_mode == 1) ? NV_ENC_PARAMS_RC_CBR : NV_ENC_PARAMS_RC_VBR;
  
  encode_config.rcParams.averageBitRate = ctx->bitrate;
  encode_config.rcParams.maxBitRate = ctx->bitrate;
  encode_config.rcParams.vbvBufferSize =
    (ctx->bitrate / ctx->framerate) *
    ((ctx->vbv_buffer_frames > 0) ? ctx->vbv_buffer_frames : 1);
  encode_config.rcParams.vbvInitialDelay = encode_config.rcParams.vbvBufferSize;
  encode_config.rcParams.constQP = {ctx->qp, ctx->qp, ctx->qp};
  
  // H.264 config
  encode_config.encodeCodecConfig.h264Config.idrPeriod =
    (ctx->intra_refresh > 0) ? NVENC_INFINITE_GOPLENGTH : ctx->gop_length;
  encode_config.encodeCodecConfig.h264Config.sliceMode = 0;
  encode_config.encodeCodecConfig.h264Config.sliceModeData = 0;
  encode_config.encodeCodecConfig.h264Config.repeatSPSPPS = 1;
  // outputAnnexBFormat is enabled by default in newer NVENC versions
  
  // Initialize encoder
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncInitializeEncoder(ctx->encoder, &init_params),
      "Failed to initialize NVENC encoder");
  
  NVENC_LOG_INFO("NVENC encoder configured: " << ctx->width << "x" << ctx->height 
                 << " @ " << ctx->bitrate << " bps, " << ctx->framerate << " fps");
  return 0;
}

int NvencEncoder::allocateBuffers(NvencContext* ctx) {
  ctx->buffer_count = 5;  // Match the original buffer count
  
  // Allocate output bitstream buffers
  for (uint32_t i = 0; i < ctx->buffer_count; i++) {
    NV_ENC_CREATE_BITSTREAM_BUFFER create_bitstream = {};
    create_bitstream.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    
    NV_ENC_OUTPUT_PTR bitstream_buffer;
    CHECK_NVENC_ERROR(
        ctx->nvenc_api.nvEncCreateBitstreamBuffer(ctx->encoder, &create_bitstream),
        "Failed to create bitstream buffer");
    
    bitstream_buffer = create_bitstream.bitstreamBuffer;
    ctx->output_buffers.push_back(bitstream_buffer);
  }
  
  NVENC_LOG_INFO("Allocated " << ctx->buffer_count << " NVENC buffers");
  return 0;
}

int NvencEncoder::initialize(NvencContext* ctx) {
  if (loadNvencAPI(ctx) != 0) {
    return -1;
  }
  
  if (createEncoder(ctx) != 0) {
    return -1;
  }
  
  if (configureEncoder(ctx) != 0) {
    return -1;
  }
  
  if (allocateBuffers(ctx) != 0) {
    return -1;
  }
  
  ctx->current_buffer_idx = 0;
  ctx->eos = false;
  ctx->encoding_in_progress = false;
  
  NVENC_LOG_INFO("NVENC encoder initialized successfully");
  return 0;
}

int NvencEncoder::encodeFrame(NvencContext* ctx, void* cuda_input_ptr, uint32_t pitch) {
  // Register CUDA resource if not already registered
  NV_ENC_REGISTER_RESOURCE register_resource = {};
  register_resource.version = NV_ENC_REGISTER_RESOURCE_VER;
  register_resource.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR;
  register_resource.resourceToRegister = cuda_input_ptr;
  register_resource.width = ctx->width;
  register_resource.height = ctx->height;
  register_resource.pitch = pitch;
  register_resource.bufferFormat = NV_ENC_BUFFER_FORMAT_NV12;
  
  NV_ENC_REGISTERED_PTR registered_resource;
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncRegisterResource(ctx->encoder, &register_resource),
      "Failed to register CUDA resource");
  registered_resource = register_resource.registeredResource;
  
  // Map input resource
  NV_ENC_MAP_INPUT_RESOURCE map_input = {};
  map_input.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
  map_input.registeredResource = registered_resource;
  
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncMapInputResource(ctx->encoder, &map_input),
      "Failed to map input resource");
  
  // Encode picture
  NV_ENC_PIC_PARAMS pic_params = {};
  pic_params.version = NV_ENC_PIC_PARAMS_VER;
  pic_params.inputBuffer = map_input.mappedResource;
  pic_params.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12;
  pic_params.inputWidth = ctx->width;
  pic_params.inputHeight = ctx->height;
  pic_params.outputBitstream = ctx->output_buffers[ctx->current_buffer_idx];
  pic_params.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
  
  NVENCSTATUS encode_status = ctx->nvenc_api.nvEncEncodePicture(ctx->encoder, &pic_params);
  
  // Unmap input resource
  ctx->nvenc_api.nvEncUnmapInputResource(ctx->encoder, map_input.mappedResource);
  
  // Unregister resource
  ctx->nvenc_api.nvEncUnregisterResource(ctx->encoder, registered_resource);
  
  if (encode_status != NV_ENC_SUCCESS) {
    NVENC_LOG_ERROR("Failed to encode picture");
    return -1;
  }
  
  ctx->dqbuf_index = ctx->current_buffer_idx;
  ctx->current_buffer_idx = (ctx->current_buffer_idx + 1) % ctx->buffer_count;
  
  return 0;
}

int NvencEncoder::getBitstream(NvencContext* ctx, uint8_t** data, uint32_t* size) {
  // Lock bitstream
  NV_ENC_LOCK_BITSTREAM lock_bitstream = {};
  lock_bitstream.version = NV_ENC_LOCK_BITSTREAM_VER;
  lock_bitstream.outputBitstream = ctx->output_buffers[ctx->dqbuf_index];
  
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncLockBitstream(ctx->encoder, &lock_bitstream),
      "Failed to lock bitstream");
  
  // Copy bitstream data
  ctx->output_bitstream.resize(lock_bitstream.bitstreamSizeInBytes);
  memcpy(ctx->output_bitstream.data(), lock_bitstream.bitstreamBufferPtr, 
         lock_bitstream.bitstreamSizeInBytes);
  
  ctx->bitstream_size = lock_bitstream.bitstreamSizeInBytes;
  
  // Unlock bitstream
  CHECK_NVENC_ERROR(
      ctx->nvenc_api.nvEncUnlockBitstream(ctx->encoder, lock_bitstream.outputBitstream),
      "Failed to unlock bitstream");
  
  *data = ctx->output_bitstream.data();
  *size = ctx->bitstream_size;
  
  return 0;
}

void NvencEncoder::freeResources(NvencContext* ctx) {
  if (ctx->encoder && ctx->nvenc_api.nvEncDestroyEncoder) {
    // Destroy bitstream buffers
    for (auto buffer : ctx->output_buffers) {
      ctx->nvenc_api.nvEncDestroyBitstreamBuffer(ctx->encoder, buffer);
    }
    ctx->output_buffers.clear();
    
    // Destroy encoder
    ctx->nvenc_api.nvEncDestroyEncoder(ctx->encoder);
    ctx->encoder = nullptr;
  }
  
  if (ctx->nvenc_lib) {
    dlclose(ctx->nvenc_lib);
    ctx->nvenc_lib = nullptr;
  }
  
  NVENC_LOG_INFO("NVENC resources freed");
}

int NvencEncoder::finalize(NvencContext* ctx) {
  // Send EOS
  if (ctx->encoder) {
    NV_ENC_PIC_PARAMS pic_params = {};
    pic_params.version = NV_ENC_PIC_PARAMS_VER;
    pic_params.encodePicFlags = NV_ENC_PIC_FLAG_EOS;
    ctx->nvenc_api.nvEncEncodePicture(ctx->encoder, &pic_params);
  }
  
  freeResources(ctx);
  return 0;
}

}  // namespace gxf
}  // namespace nvidia
