# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2023-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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

# Common flags and cmake commands for all Isaac ROS packages.
message(STATUS "Loading isaac_ros_common extras")

# The FindCUDA module is removed
if(POLICY CMP0146)
  cmake_policy(SET CMP0146 OLD)
endif()

# Default to C++17
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()

# Default to Release build
if(NOT CMAKE_BUILD_TYPE OR CMAKE_BUILD_TYPE STREQUAL "")
  set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()
message( STATUS "CMAKE_BUILD_TYPE: ${CMAKE_BUILD_TYPE}" )

# for #include <cuda_runtime.h>
set(CUDA_MIN_VERSION "11.4")
find_package(CUDA REQUIRED)
include_directories("${CUDA_INCLUDE_DIRS}")

# CUDA 13 CCCL migration: ensure host compiler can find <cuda/std/...>, <thrust/...>, <cub/...>
# Prefer linking the CCCL CMake target when available; otherwise add CTK's cccl include path.
find_package(CCCL CONFIG QUIET)
if(TARGET CCCL::CCCL)
  link_libraries(CCCL::CCCL)
else()
  include_directories("${CUDA_INCLUDE_DIRS}/cccl")
endif()

# Setup cuda architectures
# Target Ada is CUDA 11.8 or greater
# Target is blackwell for CUDA 13.0 or greater, and volta is deprecated
# SM_120 added for DGX Spark and future Blackwell-based aarch64 platforms
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  if(${CMAKE_SYSTEM_PROCESSOR} STREQUAL "aarch64")
    set(CMAKE_CUDA_ARCHITECTURES "87;110;120")
  elseif(${CUDA_VERSION} GREATER_EQUAL 13.0)
    set(CMAKE_CUDA_ARCHITECTURES "120;100;89;86;80;75")
  elseif(${CUDA_VERSION} GREATER_EQUAL 11.8)
    set(CMAKE_CUDA_ARCHITECTURES "89;86;80;75;70")
  else()
    set(CMAKE_CUDA_ARCHITECTURES "86;80;75;70")
  endif()
endif()
message(STATUS "CUDA architectures: ${CMAKE_CUDA_ARCHITECTURES}")

# FindCUDAToolkit only defines the header-only CUDA::nvtx3 target from CMake 3.25;
# replicate its definition on older CMake (Ubuntu 22.04 ships 3.22).
if(NOT TARGET CUDA::nvtx3)
  find_path(NVTX3_INCLUDE_DIR nvtx3/nvToolsExt.h HINTS ${CUDA_INCLUDE_DIRS})
  if(NVTX3_INCLUDE_DIR)
    add_library(CUDA::nvtx3 INTERFACE IMPORTED)
    set_target_properties(CUDA::nvtx3 PROPERTIES
      INTERFACE_INCLUDE_DIRECTORIES "${NVTX3_INCLUDE_DIR}"
      INTERFACE_LINK_LIBRARIES "${CMAKE_DL_LIBS}")
  endif()
endif()

# VPI debs install under /opt/nvidia/vpi<N> without registering with CMake's default
# search paths; pick the newest installed version unless the caller already set vpi_DIR.
if(NOT vpi_DIR)
  file(GLOB vpi_config_dirs "/opt/nvidia/vpi*/lib/*/cmake/vpi")
  if(vpi_config_dirs)
    list(SORT vpi_config_dirs)
    list(GET vpi_config_dirs -1 vpi_DIR)
    message(STATUS "Using VPI from: ${vpi_DIR}")
  endif()
endif()

# Set the DEVICE for cmake
# This is used to determine the architecture and the library path
if(${CMAKE_SYSTEM_PROCESSOR} STREQUAL "x86_64")
  set(CMAKE_DEVICE "x86_64")
elseif(${CMAKE_SYSTEM_PROCESSOR} STREQUAL "aarch64")
  # aarch64 deprecated: default to sbsa device layout
  set(CMAKE_DEVICE "sbsa")
else()
  message(FATAL_ERROR "Unsupported CMAKE_SYSTEM_PROCESSOR (${CMAKE_SYSTEM_PROCESSOR}). Supported: x86_64, aarch64")
endif()
message(NOTICE "CMAKE_DEVICE: ${CMAKE_DEVICE}")