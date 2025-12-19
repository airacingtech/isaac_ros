# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2022-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

project(gxf_codec_extension LANGUAGES C CXX)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-fPIC -w)
endif()
find_package(yaml-cpp)

ament_auto_add_library(gxf_video_encoder_extension SHARED
  video_encoder/videoencoder_ext.cpp
  video_encoder/videoencoder_request.cpp
  video_encoder/videoencoder_request.hpp
  video_encoder/videoencoder_response.cpp
  video_encoder/videoencoder_response.hpp
  video_encoder/videoencoder_context.cpp
  video_encoder/videoencoder_context.hpp
  video_encoder/videoencoder_utils.cpp
  video_encoder/videoencoder_utils.hpp
  video_encoder/nvenc_encoder.cpp
  video_encoder/nvenc_encoder.hpp
)

ament_auto_add_library(gxf_video_decoder_extension SHARED
  video_decoder/videodecoder_ext.cpp
  video_decoder/videodecoder_request.cpp
  video_decoder/videodecoder_request.hpp
  video_decoder/videodecoder_response.cpp
  video_decoder/videodecoder_response.hpp
  video_decoder/videodecoder_context.cpp
  video_decoder/videodecoder_context.hpp
  video_decoder/videodecoder_utils.cpp
  video_decoder/videodecoder_utils.hpp
)

find_package(CUDAToolkit)

# https://developer.nvidia.com/video_codec_sdk/downloads/v11-1-5
set(CMAKE_INCLUDE_CURRENT_DIR TRUE)

target_include_directories(gxf_video_encoder_extension PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/nvbuf_utils
  ${CMAKE_CURRENT_SOURCE_DIR}/libv4l2/include
  /usr/local/include
)

target_include_directories(gxf_video_decoder_extension PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/nvbuf_utils
  ${CMAKE_CURRENT_SOURCE_DIR}/libv4l2/include
)

execute_process(COMMAND uname -m COMMAND tr -d '\n' OUTPUT_VARIABLE ARCHITECTURE)
message( STATUS "Architecture: ${ARCHITECTURE}" )

if( ${ARCHITECTURE} STREQUAL "x86_64" )
  # On x86_64, use standard NVIDIA video codec libraries instead of Jetson-specific v4l2 wrappers
  add_library(nvcuvid SHARED IMPORTED)
  add_library(nvidia_encode SHARED IMPORTED)
  
  set_property(TARGET nvcuvid PROPERTY IMPORTED_LOCATION /usr/lib/x86_64-linux-gnu/libnvcuvid.so)
  set_property(TARGET nvidia_encode PROPERTY IMPORTED_LOCATION /usr/lib/x86_64-linux-gnu/libnvidia-encode.so)
  
  message(STATUS "Building for x86_64 - using standard NVIDIA video codec libraries")
elseif( ${ARCHITECTURE} STREQUAL "aarch64" )
  # On aarch64 (Jetson), use the v4l2 wrapper libraries
  add_library(nvbuf_fdmap SHARED IMPORTED)
  add_library(nvbufsurface SHARED IMPORTED)
  add_library(nvbufsurftransform SHARED IMPORTED)
  add_library(nvv4l2 SHARED IMPORTED)
  add_library(cuvidv4l2 SHARED IMPORTED)
  
  set_property(TARGET nvbuf_fdmap PROPERTY IMPORTED_LOCATION /usr/lib/aarch64-linux-gnu/nvidia/libnvbuf_fdmap.so.1.0.0)
  set_property(TARGET nvbufsurface PROPERTY IMPORTED_LOCATION /usr/lib/aarch64-linux-gnu/nvidia/libnvbufsurface.so)
  set_property(TARGET nvbufsurftransform PROPERTY IMPORTED_LOCATION /usr/lib/aarch64-linux-gnu/nvidia/libnvbufsurftransform.so)
  set_property(TARGET nvv4l2 PROPERTY IMPORTED_LOCATION /usr/lib/aarch64-linux-gnu/nvidia/libnvv4l2.so)
  set_property(TARGET cuvidv4l2 PROPERTY IMPORTED_LOCATION /usr/lib/aarch64-linux-gnu/nvidia/libnvcuvidv4l2.so)
endif()

if( ${ARCHITECTURE} STREQUAL "x86_64" )
  find_library(V4L2_LIB v4l2 REQUIRED)
  message(STATUS "Found libv4l2: ${V4L2_LIB}")
endif()

target_link_libraries(gxf_video_encoder_extension
  CUDA::cuda_driver
  CUDA::cudart
  yaml-cpp
  isaac_ros_gxf::Core
  isaac_ros_gxf::Cuda
  isaac_ros_gxf::Std
  isaac_ros_gxf::Multimedia
)

target_link_libraries(gxf_video_decoder_extension
  CUDA::cuda_driver
  CUDA::cudart
  yaml-cpp
  isaac_ros_gxf::Core
  isaac_ros_gxf::Std
  isaac_ros_gxf::Cuda
  isaac_ros_gxf::Multimedia
)

# Link architecture-specific libraries
if( ${ARCHITECTURE} STREQUAL "x86_64" )
  target_link_libraries(gxf_video_encoder_extension
    nvcuvid
    nvidia_encode
    ${V4L2_LIB}
    ${CMAKE_DL_LIBS}
    CUDA::cuda_driver
  )

  target_link_libraries(gxf_video_decoder_extension
    nvcuvid
    nvidia_encode
    ${V4L2_LIB}
  )
elseif( ${ARCHITECTURE} STREQUAL "aarch64" )
  target_link_libraries(gxf_video_encoder_extension
    cuvidv4l2
    nvv4l2
    nvbufsurface
    nvbuf_fdmap
    nvbufsurftransform
  )
  
  target_link_libraries(gxf_video_decoder_extension
    cuvidv4l2
    nvv4l2
    nvbufsurface
    nvbuf_fdmap
    nvbufsurftransform
  )
endif()
