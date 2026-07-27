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
set(GXF_CORE_LIB_DIR_OVERRIDE "" CACHE STRING "Override path for GXF core library directory")
set(GXF_CORE_INCLUDE_DIR_OVERRIDE "" CACHE STRING
    "Override path for GXF core headers. Must match GXF_CORE_LIB_DIR_OVERRIDE: extensions
     bake kGxfCoreVersion in at compile time and GXF refuses to load an extension built
     against a different core version (GXF_FACTORY_INCOMPATIBLE).")

execute_process(COMMAND uname -m COMMAND tr -d '\n' OUTPUT_VARIABLE ARCHITECTURE)
message( STATUS "Architecture: ${ARCHITECTURE}" )

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

add_library(${PROJECT_NAME} STATIC src/isaac_ros_gxf.cpp)

# Work out which prebuilt GXF payload this host can actually link and load, instead of
# defaulting to the newest one and failing later in an unrelated package. See the module for
# why the glibc/libstdc++ floor -- not the CUDA version -- is the binding constraint.
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/isaac_ros_gxf_payload_select.cmake")
isaac_ros_gxf_select_payload("${CMAKE_CURRENT_SOURCE_DIR}/gxf")

if(NOT ISAAC_ROS_GXF_PAYLOAD_FOUND
   AND NOT GXF_CORE_LIB_DIR_OVERRIDE
   AND NOT ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE)
  # Reaching here means the workspace asked for the NITROS stack on a host that cannot run any
  # vendored payload. Building it anyway would install a GXF that poisons the link of every
  # downstream package, so stop with an actionable message instead.
  message(FATAL_ERROR
    "isaac_ros_gxf: ${ISAAC_ROS_GXF_PAYLOAD_REASON}.\n"
    "The NITROS stack cannot be built on this host. Build without it (the CPU path) via\n"
    "  make <target> WITH_NITROS=0\n"
    "or install the runtime the payload needs -- see tools/scripts/nitros_probe.sh --explain.")
endif()

# GXF core headers. These must match the payload: extensions bake kGxfCoreVersion in at compile
# time and the core refuses to load an extension built against a different version
# (GXF_FACTORY_INCOMPATIBLE), so headers and libs are selected together, never independently.
if(GXF_CORE_INCLUDE_DIR_OVERRIDE)
  set(GXF_CORE_INCLUDE_DIR "${GXF_CORE_INCLUDE_DIR_OVERRIDE}")
elseif(ISAAC_ROS_GXF_PAYLOAD_INCLUDE)
  set(GXF_CORE_INCLUDE_DIR "gxf/${ISAAC_ROS_GXF_PAYLOAD_INCLUDE}")
else()
  set(GXF_CORE_INCLUDE_DIR gxf/core/include)
endif()
message(STATUS "isaac_ros_gxf: GXF headers = ${GXF_CORE_INCLUDE_DIR}")
install(
  DIRECTORY ${GXF_CORE_INCLUDE_DIR}/
  DESTINATION share/${PROJECT_NAME}/gxf/include/
)

# Install extensions directory
if( ${ARCHITECTURE} STREQUAL "x86_64" )
  if(GXF_CORE_LIB_DIR_OVERRIDE)
    set(GXF_CORE_LIB_DIR "${GXF_CORE_LIB_DIR_OVERRIDE}")
  else()
    set(GXF_CORE_LIB_DIR "gxf/core/lib/${ISAAC_ROS_GXF_PAYLOAD_VARIANT}")
  endif()
  message(STATUS "isaac_ros_gxf: x86_64 GXF payload = ${GXF_CORE_LIB_DIR}")
  install(DIRECTORY ${GXF_CORE_LIB_DIR}/ DESTINATION share/${PROJECT_NAME}/gxf/lib)
  install(FILES ${GXF_CORE_LIB_DIR}/core/libgxf_core.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/logger/libgxf_logger.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/multimedia/libgxf_multimedia.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/cuda/libgxf_cuda.so DESTINATION lib)
elseif( ${ARCHITECTURE} STREQUAL "aarch64" )
  if(GXF_CORE_LIB_DIR_OVERRIDE)
    set(GXF_CORE_LIB_DIR "${GXF_CORE_LIB_DIR_OVERRIDE}")
  elseif(ISAAC_ROS_GXF_PAYLOAD_VARIANT)
    set(GXF_CORE_LIB_DIR "gxf/core/lib/${ISAAC_ROS_GXF_PAYLOAD_VARIANT}")
  elseif(CMAKE_DEVICE STREQUAL "sbsa")
    set(GXF_CORE_LIB_DIR gxf/core/lib/gxf_aarch64_cuda_13_0/)
  elseif(CMAKE_DEVICE STREQUAL "arm64")
    set(GXF_CORE_LIB_DIR gxf/core/lib/gxf_jetpack70/)
  else()
    message(FATAL_ERROR "Device is not supported.")
  endif()
  message(STATUS "isaac_ros_gxf: aarch64 GXF payload = ${GXF_CORE_LIB_DIR}")
  install(DIRECTORY ${GXF_CORE_LIB_DIR} DESTINATION share/${PROJECT_NAME}/gxf/lib)
  install(FILES ${GXF_CORE_LIB_DIR}/core/libgxf_core.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/logger/libgxf_logger.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/multimedia/libgxf_multimedia.so DESTINATION lib)
  install(FILES ${GXF_CORE_LIB_DIR}/cuda/libgxf_cuda.so DESTINATION lib)
endif()

# Put the GXF extension libraries on the loader path via `source install/setup.bash`, so there is
# no hand-sourced env script and non-interactive launches behave like interactive ones.
#
# isaac_ros_gxf installs only core/logger/multimedia/cuda into lib/. The rest of the payload
# (libgxf_std.so and friends) lands under share/isaac_ros_gxf/gxf/lib/<subsystem>/, which is not a
# default loader path, yet those are DT_NEEDED by NITROS components -- avt_vimba_camera's
# mono_camera_exec among them. Without this, nodes die at dlopen with "libgxf_std.so: cannot open
# shared object file".
#
# This is emitted as a .dsv rather than a shell hook on purpose: the top-level install/setup.bash
# processes .dsv entries, and a .sh environment hook is NOT picked up through that path (it only
# applies when sourcing the package's own local_setup.bash). The subsystem list is enumerated here
# at configure time, so it always matches the payload flavour that was actually selected.
set(_gxf_dsv "${CMAKE_CURRENT_BINARY_DIR}/gxf_library_path.dsv")
set(_gxf_dsv_content "")
file(GLOB _gxf_payload_subdirs LIST_DIRECTORIES true "${GXF_CORE_LIB_DIR}/*")
foreach(_d IN LISTS _gxf_payload_subdirs)
  if(IS_DIRECTORY "${_d}")
    get_filename_component(_sub "${_d}" NAME)
    string(APPEND _gxf_dsv_content
      "prepend-non-duplicate;LD_LIBRARY_PATH;share/${PROJECT_NAME}/gxf/lib/${_sub}\n")
  endif()
endforeach()
# The cuda_12_6 payload needs libcudart/libcublas/libnpp .so.12. On a host whose default toolkit is
# a different CUDA major the 12.6 runtime is installed side by side, but /usr/local/cuda-12.6 is
# not on the default loader path. Absolute dsv paths are fine and this is skipped when absent.
file(GLOB _cuda126_dirs LIST_DIRECTORIES true
     "/usr/local/cuda-12.6/targets/*/lib" "/usr/local/cuda-12.6/lib64")
foreach(_d IN LISTS _cuda126_dirs)
  if(IS_DIRECTORY "${_d}")
    string(APPEND _gxf_dsv_content "prepend-non-duplicate;LD_LIBRARY_PATH;${_d}\n")
  endif()
endforeach()
file(WRITE "${_gxf_dsv}" "${_gxf_dsv_content}")
ament_environment_hooks("${_gxf_dsv}")

# Record the payload decision for downstream packages. The gxf_isaac_* extensions ship the same
# per-flavour split and MUST use the flavour that was actually installed here -- mixing GXF 4.1.0
# core with 5.1.0 extensions is a runtime GXF_FACTORY_INCOMPATIBLE. Publishing the decision (as
# opposed to letting each package re-probe) makes the choice consistent by construction and keeps
# ~20 extension packages from each paying for a link probe.
string(CONCAT _payload_cmake_content
  "# Generated by isaac_ros_gxf at configure time. Do not edit.\n"
  "# The GXF payload flavour selected for this host; extensions must match it.\n"
  "set(ISAAC_ROS_GXF_PAYLOAD_VARIANT \"${ISAAC_ROS_GXF_PAYLOAD_VARIANT}\")\n"
  "set(ISAAC_ROS_GXF_PAYLOAD_INCLUDE \"${ISAAC_ROS_GXF_PAYLOAD_INCLUDE}\")\n"
  "set(ISAAC_ROS_GXF_PAYLOAD_REASON \"${ISAAC_ROS_GXF_PAYLOAD_REASON}\")\n")
file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/isaac_ros_gxf-payload.cmake"
  CONTENT "${_payload_cmake_content}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/isaac_ros_gxf-payload.cmake"
        DESTINATION share/${PROJECT_NAME}/cmake)

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
