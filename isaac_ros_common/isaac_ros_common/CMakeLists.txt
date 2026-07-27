# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2021-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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

cmake_minimum_required(VERSION 3.22.1)
project(isaac_ros_common LANGUAGES C CXX)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()
# Must precede enable_language(CUDA): this package enables CUDA before loading its own
# extras, so the toolkit has to be chosen first or nvcc-on-PATH wins.
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/isaac_ros_cuda_flavour.cmake)
enable_language(CUDA)

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

find_package(CUDAToolkit)

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/isaac_ros_common-extras.cmake)

# Dependencies
find_package(vpi REQUIRED)

# NVTX
option(USE_NVTX "Enable NVTX markers for improved profiling (if available)" ON)
# "if available" has to actually mean that. CUDA::nvtx3 only exists when the nvtx3 headers are
# present in the selected toolkit, and they are not part of the minimal cudart/cublas/npp/cusolver
# set -- so a toolkit without cuda-nvtx-<ver> installed made this fail at generate time with
# 'links to target "CUDA::nvtx3" but the target was not found'. Profiling markers are optional;
# a missing profiler must not break the build.
if(USE_NVTX AND TARGET CUDA::nvtx3)
    add_definitions(-DUSE_NVTX)
    link_directories("${CUDA_TOOLKIT_ROOT_DIR}/lib64")
    link_libraries("CUDA::nvtx3")
elseif(USE_NVTX)
    message(WARNING
      "NVTX markers disabled: the nvtx3 headers are not in ${CUDA_TOOLKIT_ROOT_DIR}. "
      "Install cuda-nvtx-<ver> (tools/scripts/install_isaac_deps.sh does this) to re-enable "
      "profiling markers.")
endif()

# vpi utilities
ament_auto_add_library(${PROJECT_NAME} SHARED
  src/cuda_stream.cpp
  src/qos.cpp
)
target_link_libraries(${PROJECT_NAME} vpi CUDA::cudart)

# Register cmake in install.
ament_index_register_resource(isaac_ros_common_cmake_path CONTENT
    "${CMAKE_INSTALL_PREFIX}/share/${PROJECT_NAME}/cmake")
list(APPEND ${PROJECT_NAME}_CONFIG_EXTRAS
  cmake/isaac_ros_common-version-info.cmake
  cmake/isaac_ros_common-extras.cmake
  cmake/isaac_ros_common-extras-modules.cmake
  cmake/isaac_ros_common-extras-assets.cmake
)

ament_python_install_package(${PROJECT_NAME})

ament_index_register_resource(isaac_ros_common_scripts_path CONTENT
    "${CMAKE_INSTALL_PREFIX}/bin")
install(
  DIRECTORY scripts/
  DESTINATION bin
  USE_SOURCE_PERMISSIONS
)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)

  # Ignore copyright notices since we use custom NVIDIA Isaac ROS Software License
  set(ament_cmake_copyright_FOUND TRUE)
  ament_lint_auto_find_test_dependencies()
endif()


# Embed versioning information into installed files
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/isaac_ros_common-version-info.cmake)
generate_version_info(${PROJECT_NAME})

ament_auto_package(INSTALL_TO_SHARE cmake)
