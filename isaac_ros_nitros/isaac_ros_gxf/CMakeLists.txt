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

cmake_minimum_required(VERSION 3.22.1)
project(isaac_ros_gxf)

# Add option for overriding GXF core library directory
option(GXF_CORE_LIB_DIR_OVERRIDE "Override path for GXF core library directory" "")

execute_process(COMMAND uname -m COMMAND tr -d '\n' OUTPUT_VARIABLE ARCHITECTURE)
message( STATUS "Architecture: ${ARCHITECTURE}" )

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

add_library(${PROJECT_NAME} STATIC src/isaac_ros_gxf.cpp)

# GXF core headers
install(
  DIRECTORY gxf/core/include/
  DESTINATION share/${PROJECT_NAME}/gxf/include/
)

# Install extensions directory
if( ${ARCHITECTURE} STREQUAL "x86_64" )
  # The vendored payload is prebuilt on Ubuntu 24.04 (glibc 2.38). Refuse to
  # install a payload the host cannot link: otherwise this package builds fine
  # and every downstream consumer fails at link or launch.
  set(_gxf_payload ${CMAKE_CURRENT_SOURCE_DIR}/gxf/core/lib/gxf_x86_64_cuda_13_0)

  set(_gxf_compat_dir ${CMAKE_CURRENT_BINARY_DIR}/compat)
  file(MAKE_DIRECTORY ${_gxf_compat_dir})
  execute_process(
    COMMAND ${CMAKE_CXX_COMPILER} -shared -fPIC -O2
            ${CMAKE_CURRENT_SOURCE_DIR}/compat/compat_shim.cpp
            -o ${_gxf_compat_dir}/libisoc23_compat.so
    RESULT_VARIABLE _gxf_shim_rc OUTPUT_QUIET ERROR_VARIABLE _gxf_shim_err)
  if(NOT _gxf_shim_rc EQUAL 0)
    message(FATAL_ERROR "Failed to build compat/compat_shim.cpp, which the GXF "
      "payload needs as libisoc23_compat.so.\n${_gxf_shim_err}")
  endif()

  execute_process(
    COMMAND env -u LD_LIBRARY_PATH bash -c "echo 'int main(){return 0;}' | ${CMAKE_CXX_COMPILER} -x c++ - -x none -o /dev/null -Wl,--no-as-needed ${_gxf_payload}/core/libgxf_core.so ${_gxf_payload}/multimedia/libgxf_multimedia.so -Wl,-rpath-link,${_gxf_payload}/logger -Wl,-rpath-link,${_gxf_payload}/core -Wl,-rpath-link,${_gxf_compat_dir}"
    RESULT_VARIABLE _gxf_probe_rc OUTPUT_QUIET ERROR_VARIABLE _gxf_probe_err)
  if(NOT _gxf_probe_rc EQUAL 0)
    message(FATAL_ERROR "GXF cuda_13_0 payload cannot link on this host "
      "(too-new glibc/libstdc++ requirements in the prebuilt .so files). "
      "This drop's .so files still carry symbol-version requirements this host "
      "cannot satisfy; they must be patched to bind the unversioned definitions "
      "in compat/compat_shim.cpp, which lists them.\n${_gxf_probe_err}")
  endif()

  # Jammy compat: the payload references a few glibc-2.38 / libstdc++-13
  # symbols (see compat/compat_shim.cpp). patch_gxf_glibc.sh clears their
  # version requirements and adds libisoc23_compat.so as a NEEDED entry, so
  # build and install the shim here -- consumers then resolve it from this
  # package's lib dir with no environment setup.
  add_library(isoc23_compat SHARED compat/compat_shim.cpp)
  install(TARGETS isoc23_compat LIBRARY DESTINATION lib)

  # The payload links libcudart.so.13; expose the CUDA 13 runtime to every
  # workspace process via an ament env hook (applied by install/setup.bash).
  ament_environment_hooks("${CMAKE_CURRENT_SOURCE_DIR}/env-hooks/cuda13_runtime.dsv.in")

  install(DIRECTORY gxf/core/lib/gxf_x86_64_cuda_13_0/ DESTINATION share/${PROJECT_NAME}/gxf/lib)
  install(FILES gxf/core/lib/gxf_x86_64_cuda_13_0/core/libgxf_core.so DESTINATION lib)
  install(FILES gxf/core/lib/gxf_x86_64_cuda_13_0/logger/libgxf_logger.so DESTINATION lib)
  install(FILES gxf/core/lib/gxf_x86_64_cuda_13_0/multimedia/libgxf_multimedia.so DESTINATION lib)
  install(FILES gxf/core/lib/gxf_x86_64_cuda_13_0/cuda/libgxf_cuda.so DESTINATION lib)
elseif( ${ARCHITECTURE} STREQUAL "aarch64" )
  if(CMAKE_DEVICE STREQUAL "sbsa")
    set(GXF_CORE_LIB_DIR gxf/core/lib/gxf_aarch64_cuda_13_0/)
  elseif(CMAKE_DEVICE STREQUAL "arm64")
    set(GXF_CORE_LIB_DIR gxf/core/lib/gxf_jetpack70/)
  else()
    message(FATAL_ERROR "Device is not supported.")
  endif()
  install(DIRECTORY ${GXF_CORE_LIB_DIR} DESTINATION share/${PROJECT_NAME}/gxf/lib)
  install(FILES ${GXF_CORE_LIB_DIR}/core/libgxf_core.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/logger/libgxf_logger.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/multimedia/libgxf_multimedia.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/cuda/libgxf_cuda.so DESTINATION lib)
endif()

# Register cmake in install.
ament_index_register_resource(isaac_ros_gxf_cmake_path CONTENT
    "${CMAKE_INSTALL_PREFIX}/share/${PROJECT_NAME}/cmake")
list(APPEND ${PROJECT_NAME}_CONFIG_EXTRAS cmake/isaac_ros_gxf-extras.cmake)

# Core
add_library(Core INTERFACE)
set_target_properties(Core PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/include"
)
set_property(TARGET Core PROPERTY
  INTERFACE_LINK_LIBRARIES
    magic_enum::magic_enum
    "$<INSTALL_PREFIX>/lib/libgxf_core.so"
)

# Logger
add_library(Logger INTERFACE)
set_target_properties(Logger PROPERTIES
  INTERFACE_LINK_LIBRARIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/lib/logger/libgxf_logger.so"
  INTERFACE_INCLUDE_DIRECTORIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/include"
)

# Std
add_library(Std INTERFACE)
set_target_properties(Std PROPERTIES
  INTERFACE_LINK_LIBRARIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/lib/std/libgxf_std.so"
  INTERFACE_INCLUDE_DIRECTORIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/include"
)

# Multimedia
add_library(Multimedia INTERFACE)
set_target_properties(Multimedia PROPERTIES
  INTERFACE_LINK_LIBRARIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/lib/multimedia/libgxf_multimedia.so"
  INTERFACE_INCLUDE_DIRECTORIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/include"
)

# Serialization
add_library(Serialization INTERFACE)
set_target_properties(Serialization PROPERTIES
  INTERFACE_LINK_LIBRARIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/lib/serialization/libgxf_serialization.so"
  INTERFACE_INCLUDE_DIRECTORIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/include"
)

# Cuda
add_library(Cuda INTERFACE)
set_target_properties(Cuda PROPERTIES
  INTERFACE_LINK_LIBRARIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/lib/cuda/libgxf_cuda.so"
  INTERFACE_INCLUDE_DIRECTORIES
    "$<INSTALL_PREFIX>/share/${PROJECT_NAME}/gxf/include"
)

install(TARGETS Core Logger Std Multimedia Serialization Cuda
        EXPORT export_${PROJECT_NAME}
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib
        RUNTIME DESTINATION bin)
ament_export_targets(export_${PROJECT_NAME} HAS_LIBRARY_TARGET)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)

  # Ignore copyright notices since we use custom NVIDIA Isaac ROS Software License
  set(ament_cmake_copyright_FOUND TRUE)
  ament_lint_auto_find_test_dependencies()
endif()


# Embed versioning information into installed files
ament_index_get_resource(ISAAC_ROS_COMMON_CMAKE_PATH isaac_ros_common_cmake_path isaac_ros_common)
include("${ISAAC_ROS_COMMON_CMAKE_PATH}/isaac_ros_common-version-info.cmake")
generate_version_info(${PROJECT_NAME})

ament_auto_package(INSTALL_TO_SHARE cmake)
