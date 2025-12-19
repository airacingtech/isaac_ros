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

#ifndef NVIDIA_GXF_MULTIMEDIA_EXTENSIONS_CUVID_DECODER_HPP_
#define NVIDIA_GXF_MULTIMEDIA_EXTENSIONS_CUVID_DECODER_HPP_

#include <cuda.h>
#include <cuda_runtime.h>
#include <nvcuvid.h>
#include <linux/videodev2.h>
#include <vector>
#include <memory>
#include <mutex>
#include <queue>

#include "gxf/core/gxf.h"
#include "gxf/std/scheduling_terms.hpp"

namespace nvidia {
namespace gxf {

// Forward declarations
struct nvmpictx;

// Structure to hold CUVID decoder state
struct CuvidContext {
  // CUVID decoder
  CUvideodecoder decoder;
  CUvideoparser parser;
  
  // CUDA context
  CUcontext cu_context;
  CUdevice cu_device;
  int device_id;
  
  // Video parameters
  uint32_t width;
  uint32_t height;
  uint32_t coded_width;
  uint32_t coded_height;
  cudaVideoCodec codec_type;
  
  // Output frame info
  CUdeviceptr decoded_frame;
  uint32_t decoded_pitch;
  int picture_index;  // For unmapping
  bool frame_available;
  
  // Synchronization
  std::mutex decoder_mutex;
  
  // Async operation
  nvidia::gxf::Handle<nvidia::gxf::AsynchronousSchedulingTerm> scheduling_term;
  volatile bool eos;
  
  // Timestamps
  uint64_t output_timestamp_sec;
  uint64_t output_timestamp_usec;
  
  gxf_context_t gxf_context;
  std::queue<gxf::Entity>* output_entity_queue;  // Pointer to parent's queue
  
  // Parent decoder context (to propagate video dimensions)
  struct nvmpictx* parent_ctx;
};

class CuvidDecoder {
 public:
  CuvidDecoder();
  ~CuvidDecoder();
  
  // Initialize CUVID decoder
  int initialize(CuvidContext* ctx);
  
  // Decode H264 bitstream
  int decode(CuvidContext* ctx, const uint8_t* bitstream, uint32_t size);
  
  // Get decoded frame
  int getDecodedFrame(CuvidContext* ctx, CUdeviceptr* frame_ptr, uint32_t* pitch);
  
  // Finalize and cleanup
  int finalize(CuvidContext* ctx);
  
 private:
  // Parser callbacks
  static int CUDAAPI HandleVideoSequence(void* user_data, CUVIDEOFORMAT* format);
  static int CUDAAPI HandlePictureDecode(void* user_data, CUVIDPICPARAMS* pic_params);
  static int CUDAAPI HandlePictureDisplay(void* user_data, CUVIDPARSERDISPINFO* disp_info);
  
  // Create decoder
  int createDecoder(CuvidContext* ctx, CUVIDEOFORMAT* format);
  
  // Free resources
  void freeResources(CuvidContext* ctx);
};

}  // namespace gxf
}  // namespace nvidia

#endif  // NVIDIA_GXF_MULTIMEDIA_EXTENSIONS_CUVID_DECODER_HPP_
