# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2022-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
project(isaac_ros_nitros LANGUAGES C CXX)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

install(PROGRAMS scripts/diagnostic_viewer.py DESTINATION lib/${PROJECT_NAME})

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

# Ensure CUDA imported targets (e.g., CUDA::nvtx3 / CUDA::nvToolsExt) are available
find_package(CUDAToolkit REQUIRED)

# NVTX
option(USE_NVTX "Enable NVTX markers for improved profiling (if available)" ON)
if(USE_NVTX)
    add_definitions(-DUSE_NVTX)
    link_directories("${CUDA_TOOLKIT_ROOT_DIR}/lib64")
    link_libraries("CUDA::nvtx3")
endif()

# cuVSLAM and cuApriltags (register paths and install)

# Determine the architecture
#
# cuVSLAM ships the same per-CUDA-major split as the GXF payload and carries the same glibc floor
# with it (lib_x86_64_cuda_13_0 needs glibc 2.38; lib_x86_64_cuda_12_6 needs only 2.34). Hardcoding
# 13_0 here makes isaac_ros_visual_slam unbuildable on Ubuntu 22.04 with exactly the undefined-
# reference failure the GXF payload selection exists to prevent, so follow the same decision.
#
# isaac_ros_gxf publishes the flavour it selected as e.g. "gxf_x86_64_cuda_12_6"; the CUDA suffix is
# the part these directory names share. Fall back to upstream's default when that is unavailable.
function(_nitros_cuda_suffix out_var)
    set(_suffix "")
    if(ISAAC_ROS_GXF_PAYLOAD_VARIANT MATCHES "cuda_([0-9]+_[0-9]+)$")
        set(_suffix "${CMAKE_MATCH_1}")
    endif()
    set(${out_var} "${_suffix}" PARENT_SCOPE)
endfunction()

# Pick lib_<arch>_cuda_<suffix> when that flavour exists on disk, else keep `fallback`.
function(_nitros_pick_lib_dir base arch fallback out_var)
    _nitros_cuda_suffix(_suffix)
    set(_chosen "${fallback}")
    if(_suffix)
        set(_candidate "${base}/lib_${arch}_cuda_${_suffix}")
        if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${_candidate}")
            set(_chosen "${_candidate}")
        endif()
    endif()
    set(${out_var} "${_chosen}" PARENT_SCOPE)
endfunction()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
    set(CUVSLAM_LIB_PATH "lib/cuvslam/lib_aarch64_jetpack70")
    set(CUAPRILTAGS_LIB_PATH "lib/cuapriltags/lib_aarch64_jetpack61")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64")
    _nitros_pick_lib_dir("lib/cuvslam" "x86_64" "lib/cuvslam/lib_x86_64_cuda_13_0" CUVSLAM_LIB_PATH)
    # cuApriltags only ships a 12_6 x86_64 build, so this stays pinned unless a match appears.
    _nitros_pick_lib_dir("lib/cuapriltags" "x86_64" "lib/cuapriltags/lib_x86_64_cuda_12_6"
                         CUAPRILTAGS_LIB_PATH)
else()
    message(FATAL_ERROR "Unsupported architecture: ${CMAKE_SYSTEM_PROCESSOR}")
endif()
message(STATUS "isaac_ros_nitros: cuVSLAM = ${CUVSLAM_LIB_PATH}")
message(STATUS "isaac_ros_nitros: cuApriltags = ${CUAPRILTAGS_LIB_PATH}")

# Install exported libraries
install(FILES ${CUAPRILTAGS_LIB_PATH}/libcuapriltags.a
    DESTINATION "${CMAKE_INSTALL_PREFIX}/share/${PROJECT_NAME}/cuapriltags/lib")
install(FILES
      ${CUVSLAM_LIB_PATH}/libcuvslam.so
      ${CUVSLAM_LIB_PATH}/cuvslam_api_launcher
    DESTINATION "${CMAKE_INSTALL_PREFIX}/share/${PROJECT_NAME}/cuvslam/lib")

# Install header files for cuvslam
install(FILES lib/cuvslam/include/cuvslam/cuvslam2.h
              lib/cuvslam/include/cuvslam/ground_constraint2.h
        DESTINATION "${CMAKE_INSTALL_PREFIX}/share/${PROJECT_NAME}/cuvslam/include/cuvslam")

# cuVSLAM (register path)
ament_index_register_resource(cuvslam CONTENT share/${PROJECT_NAME}/cuvslam)

# Install the header file for cuapriltags
install(FILES lib/cuapriltags/cuapriltags/cuAprilTags.h
        DESTINATION "${CMAKE_INSTALL_PREFIX}/share/${PROJECT_NAME}/cuapriltags/cuapriltags")

# cuApriltags (register path)
ament_index_register_resource(cuapriltags CONTENT share/${PROJECT_NAME}/cuapriltags)

# Dependencies
find_package(Eigen3 3.3 REQUIRED NO_MODULE)
find_package(vpi REQUIRED)
find_package(yaml-cpp)

# NitrosNode
ament_auto_add_library(${PROJECT_NAME} SHARED
  src/nitros_node.cpp
  src/nitros_context.cpp
  src/types/type_adapter_nitros_context.cpp
  src/types/nitros_type_base.cpp
  src/types/nitros_empty.cpp
  src/nitros_publisher.cpp
  src/nitros_subscriber.cpp
  src/nitros_publisher_subscriber_group.cpp
)
target_link_libraries(${PROJECT_NAME}
  Eigen3::Eigen
  vpi
  yaml-cpp
)
set_target_properties(${PROJECT_NAME} PROPERTIES
  BUILD_WITH_INSTALL_RPATH TRUE
  BUILD_RPATH_USE_ORIGIN TRUE
  INSTALL_RPATH_USE_LINK_PATH TRUE)

if(BUILD_TESTING)
  # Install test/config directory
  install(DIRECTORY test/config DESTINATION share/${PROJECT_NAME}/test)

  # NitrosEmptyForwardNode
  ament_auto_add_library(nitros_empty_forward_node SHARED test/src/nitros_empty_forward_node.cpp)
  target_link_libraries(nitros_empty_forward_node ${PROJECT_NAME})
  set_target_properties(nitros_empty_forward_node PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    BUILD_RPATH_USE_ORIGIN TRUE
    INSTALL_RPATH_USE_LINK_PATH TRUE)
  rclcpp_components_register_nodes(nitros_empty_forward_node "nvidia::isaac_ros::nitros::NitrosEmptyForwardNode")
  set(node_plugins "${node_plugins}nvidia::isaac_ros::nitros::NitrosEmpty;$<TARGET_FILE:nitros_empty_forward_node>\n")

find_package(ament_lint_auto REQUIRED)

  # Ignore copyright notices since we use custom NVIDIA Isaac ROS Software License
  set(ament_cmake_copyright_FOUND TRUE)
  ament_lint_auto_find_test_dependencies()

  # The FindPythonInterp and FindPythonLibs modules are removed
  if(POLICY CMP0148)
    cmake_policy(SET CMP0148 OLD)
  endif()

  find_package(launch_testing_ament_cmake REQUIRED)
  add_launch_test(test/isaac_ros_nitros_test_pol.py TIMEOUT "15")
  add_launch_test(test/isaac_ros_nitros_diagnostics_test_pol.py TIMEOUT "15")
endif()


# Embed versioning information into installed files
ament_index_get_resource(ISAAC_ROS_COMMON_CMAKE_PATH isaac_ros_common_cmake_path isaac_ros_common)
include("${ISAAC_ROS_COMMON_CMAKE_PATH}/isaac_ros_common-version-info.cmake")
generate_version_info(${PROJECT_NAME})

ament_auto_package(INSTALL_TO_SHARE config)
