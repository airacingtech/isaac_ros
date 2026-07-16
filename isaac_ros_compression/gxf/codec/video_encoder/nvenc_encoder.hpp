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

#ifndef NVIDIA_GXF_MULTIMEDIA_EXTENSIONS_NVENC_ENCODER_HPP_
#define NVIDIA_GXF_MULTIMEDIA_EXTENSIONS_NVENC_ENCODER_HPP_

#include <cuda.h>
#include <cuda_runtime.h>
#include <nvEncodeAPI.h>
#include <vector>
#include <queue>
#include <memory>

#include "gxf/core/gxf.h"
#include "gxf/std/scheduling_terms.hpp"

namespace nvidia {
namespace gxf {

// Structure to hold NVENC encoder state
struct NvencContext {
  // NVENC API function pointers
  void* nvenc_lib;
  NV_ENCODE_API_FUNCTION_LIST nvenc_api;
  void* encoder;
  bool initialized = false;  // deferred-init guard (resolution auto-detect)
  
  // CUDA context
  CUcontext cu_context;
  CUdevice cu_device;
  int device_id;
  
  // Encoder configuration
  uint32_t width;
  uint32_t height;
  uint32_t bitrate;
  uint32_t framerate;
  uint32_t gop_length;
  uint32_t profile;
  uint32_t level;
  uint32_t qp;
  uint32_t rate_control_mode;
  uint32_t intra_refresh;
  uint32_t vbv_buffer_frames;
  uint32_t max_bitrate;
  
  // Input/output buffers
  std::vector<NV_ENC_REGISTERED_PTR> registered_resources;
  std::vector<NV_ENC_INPUT_PTR> input_buffers;
  std::vector<NV_ENC_OUTPUT_PTR> output_buffers;
  
  // Buffer management
  uint32_t buffer_count;
  uint32_t current_buffer_idx;
  
  // Async operation
  nvidia::gxf::Handle<nvidia::gxf::AsynchronousSchedulingTerm> scheduling_term;
  pthread_t encode_thread;
  volatile bool eos;
  volatile bool encoding_in_progress;
  
  // Output bitstream
  std::vector<uint8_t> output_bitstream;
  uint32_t bitstream_size;
  volatile int32_t dqbuf_index;
  
  // Request/response counting
  volatile uint64_t request_count;
  volatile uint64_t response_count;
  
  gxf_context_t gxf_context;
  std::queue<gxf::Entity> output_entity_queue;
};

class NvencEncoder {
 public:
  NvencEncoder();
  ~NvencEncoder();
  
  // Initialize NVENC encoder with given parameters
  int initialize(NvencContext* ctx);
  
  // Encode a frame (input is CUDA device pointer in NV12 format)
  int encodeFrame(NvencContext* ctx, void* cuda_input_ptr, uint32_t pitch);
  
  // Finalize encoding and cleanup
  int finalize(NvencContext* ctx);
  
  // Get encoded bitstream
  int getBitstream(NvencContext* ctx, uint8_t** data, uint32_t* size);
  
 private:
  // Load NVENC API
  int loadNvencAPI(NvencContext* ctx);
  
  // Create NVENC encoder session
  int createEncoder(NvencContext* ctx);
  
  // Configure encoder parameters
  int configureEncoder(NvencContext* ctx);
  
  // Allocate input/output buffers
  int allocateBuffers(NvencContext* ctx);
  
  // Free resources
  void freeResources(NvencContext* ctx);
};

}  // namespace gxf
}  // namespace nvidia

#endif  // NVIDIA_GXF_MULTIMEDIA_EXTENSIONS_NVENC_ENCODER_HPP_
