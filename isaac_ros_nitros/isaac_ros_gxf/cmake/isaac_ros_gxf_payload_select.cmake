# Copyright 2026 AI Racing Tech
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0

# Host-aware selection of the prebuilt GXF payload.
#
# NVIDIA ships GXF as prebuilt binaries in per-(arch, CUDA major) flavours. Each flavour is
# also built against a specific Ubuntu, so it carries a hard glibc/libstdc++ floor:
#
#   gxf_x86_64_cuda_13_0  GXF 5.1.0  Ubuntu 24.04  glibc >= 2.38, GLIBCXX >= 3.4.32, CUDA 13
#   gxf_x86_64_cuda_12_6  GXF 4.1.0  Ubuntu 22.04  glibc >= 2.35, GLIBCXX >= 3.4.30, CUDA 12
#
# Picking the wrong flavour does not fail at configure time -- it fails much later, when some
# unrelated package links a GXF .so and ld reports undefined references coming out of the .so
# itself (`libgxf_multimedia.so: undefined reference to __isoc23_strtol@GLIBC_2.38'). That is
# the failure this module exists to prevent.
#
# CUDA major is NOT a sufficient discriminator on its own. The AV24 is the counter-example: it
# has the CUDA 13 toolkit installed but is Ubuntu 22.04 (glibc 2.35), so it can only ever use
# the cuda_12_6 payload. The glibc/libstdc++ ABI floor is the binding constraint; the CUDA
# runtime is a second, independent one. Both must hold.
#
# Rather than hardcode that table and hope it stays true, this module *link-probes* each
# candidate: it tries to link a trivial executable against the candidate's libgxf_core.so and
# libgxf_multimedia.so. That reproduces the exact ld invocation that would fail later, so it
# catches both the glibc/libstdc++ floor and a missing libcudart.so.<major> in one shot, and
# stays correct for payload flavours that do not exist yet.
#
# Sets in the caller's scope:
#   ISAAC_ROS_GXF_PAYLOAD_FOUND    TRUE if a usable payload was found
#   ISAAC_ROS_GXF_PAYLOAD_VARIANT  e.g. gxf_x86_64_cuda_12_6
#   ISAAC_ROS_GXF_PAYLOAD_INCLUDE  include subdir matching the variant's GXF core version
#   ISAAC_ROS_GXF_PAYLOAD_REASON   human-readable explanation of the choice

if(DEFINED _ISAAC_ROS_GXF_PAYLOAD_SELECT_INCLUDED)
  return()
endif()
set(_ISAAC_ROS_GXF_PAYLOAD_SELECT_INCLUDED TRUE)

# Escape hatch: pin a flavour explicitly and skip all probing.
set(ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE "" CACHE STRING
    "Pin the GXF payload flavour (e.g. gxf_x86_64_cuda_12_6) instead of auto-detecting it.")

# Extra directories to search for the CUDA runtime during the link probe, for hosts that keep
# it outside /usr/local/cuda*.
set(ISAAC_ROS_GXF_EXTRA_CUDA_LIB_DIRS "" CACHE STRING
    "Additional CUDA runtime library directories to consider when probing GXF payloads.")

# Report what the host can actually offer, for diagnostics.
function(_isaac_ros_gxf_host_abi out_glibc out_glibcxx)
  execute_process(COMMAND getconf GNU_LIBC_VERSION
                  OUTPUT_VARIABLE _libc OUTPUT_STRIP_TRAILING_WHITESPACE
                  ERROR_QUIET)
  string(REGEX MATCH "[0-9]+\\.[0-9]+" _libc "${_libc}")

  # libstdc++ as seen by the compiler that will actually build this workspace, not whatever
  # /usr/lib happens to hold -- they differ when a newer toolchain is installed side by side.
  execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=libstdc++.so.6
                  OUTPUT_VARIABLE _libstdcxx OUTPUT_STRIP_TRAILING_WHITESPACE
                  ERROR_QUIET)
  set(_glibcxx "")
  if(EXISTS "${_libstdcxx}")
    execute_process(
      COMMAND sh -c
        "objdump -p '${_libstdcxx}' 2>/dev/null | grep -oE 'GLIBCXX_3\\.4\\.[0-9]+' | sort -V | tail -1"
      OUTPUT_VARIABLE _glibcxx OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  endif()

  set(${out_glibc} "${_libc}" PARENT_SCOPE)
  set(${out_glibcxx} "${_glibcxx}" PARENT_SCOPE)
endfunction()

# Link a throwaway executable against the candidate payload. Returns TRUE only if ld resolves
# every symbol the payload's own .so files need -- i.e. only if this host could really use it.
function(_isaac_ros_gxf_probe_payload lib_dir probe_name out_ok out_log)
  set(_log "")

  set(_core "${lib_dir}/core/libgxf_core.so")
  set(_mm "${lib_dir}/multimedia/libgxf_multimedia.so")
  if(NOT EXISTS "${_core}")
    set(${out_ok} FALSE PARENT_SCOPE)
    set(${out_log} "no libgxf_core.so under ${lib_dir}" PARENT_SCOPE)
    return()
  endif()

  set(_probe_src "${CMAKE_CURRENT_BINARY_DIR}/gxf_payload_probe/probe.cpp")
  file(WRITE "${_probe_src}" "int main() { return 0; }\n")

  set(_link_libs "${_core}")
  if(EXISTS "${_mm}")
    list(APPEND _link_libs "${_mm}")
  endif()

  # The payload's .so files reference each other across sibling directories (libgxf_core.so
  # needs logger/libgxf_logger.so, multimedia/ needs cuda/, ...), and they reference the CUDA
  # runtime. ld must be able to *find* all of those or it reports the payload's symbols as
  # undefined and the probe rejects a perfectly good flavour for the wrong reason. -rpath-link
  # only affects this link-time search; it is not baked into the probe binary.
  set(_rpath_link "")
  file(GLOB _sibling_dirs LIST_DIRECTORIES true "${lib_dir}/*")
  foreach(_d IN LISTS _sibling_dirs)
    if(IS_DIRECTORY "${_d}")
      list(APPEND _rpath_link "-Wl,-rpath-link,${_d}")
    endif()
  endforeach()
  # Any CUDA runtime present on the host, so a genuinely missing major still fails the probe.
  # Covers the apt toolkit layout, plus LD_LIBRARY_PATH and an explicit override for hosts that
  # keep the runtime somewhere non-standard (pip wheels, vendored trees).
  file(GLOB _cuda_dirs LIST_DIRECTORIES true
       "/usr/local/cuda-*/targets/*/lib" "/usr/local/cuda/targets/*/lib"
       "/usr/local/cuda-*/lib64" "/usr/local/cuda/lib64")
  foreach(_extra IN LISTS ISAAC_ROS_GXF_EXTRA_CUDA_LIB_DIRS)
    list(APPEND _cuda_dirs "${_extra}")
  endforeach()
  if(DEFINED ENV{LD_LIBRARY_PATH})
    string(REPLACE ":" ";" _ldpath "$ENV{LD_LIBRARY_PATH}")
    list(APPEND _cuda_dirs ${_ldpath})
  endif()
  foreach(_d IN LISTS _cuda_dirs)
    if(IS_DIRECTORY "${_d}")
      list(APPEND _rpath_link "-Wl,-rpath-link,${_d}")
    endif()
  endforeach()

  # try_compile reuses an already-defined result variable and silently skips the check, so the
  # result variable must be unique per flavour and must never be pre-initialised. Sharing one
  # name across flavours would make every probe after the first inherit the first one's verdict.
  set(_res_var "_gxf_probe_result_${probe_name}")
  unset(${_res_var})
  unset(${_res_var} CACHE)

  # -Wl,--no-as-needed keeps the payload on the link line even though the probe references
  # nothing from it, so ld is forced to validate its symbols. Without this the probe would
  # link cleanly against an unusable payload and defeat the whole point.
  try_compile(${_res_var}
    "${CMAKE_CURRENT_BINARY_DIR}/gxf_payload_probe/${probe_name}"
    SOURCES "${_probe_src}"
    LINK_OPTIONS -Wl,--no-as-needed ${_rpath_link}
    LINK_LIBRARIES ${_link_libs}
    OUTPUT_VARIABLE _log
  )

  set(${out_ok} "${${_res_var}}" PARENT_SCOPE)
  set(${out_log} "${_log}" PARENT_SCOPE)
endfunction()

# Map a payload flavour to the core headers whose kGxfCoreVersion matches its libgxf_core.so.
# A mismatch here is not a link error -- it surfaces at runtime as GXF_FACTORY_INCOMPATIBLE,
# because extensions bake kGxfCoreVersion in at compile time and the core refuses to load an
# extension built against a different one. So headers and libs must move together.
function(_isaac_ros_gxf_include_for_variant gxf_root variant out_include)
  set(_candidates "")
  # cuda_12_6 -> include_cuda_12_6, and so on for any future flavour. Fall back to the
  # unsuffixed include dir, which tracks whichever payload upstream considers current.
  if("${variant}" MATCHES "cuda_([0-9]+_[0-9]+)$")
    list(APPEND _candidates "core/include_cuda_${CMAKE_MATCH_1}")
  endif()
  list(APPEND _candidates "core/include")

  foreach(_c IN LISTS _candidates)
    if(EXISTS "${gxf_root}/${_c}/gxf/core/gxf.h")
      set(${out_include} "${_c}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  set(${out_include} "core/include" PARENT_SCOPE)
endfunction()

# gxf_root: path to the isaac_ros_gxf package's `gxf` directory.
function(isaac_ros_gxf_select_payload gxf_root)
  set(_lib_root "${gxf_root}/core/lib")

  # Preference order: newest CUDA first, so a 24.04 host lands on 13_0 and a 22.04 host falls
  # through to 12_6. aarch64 has no 12_6 flavour, so its list is effectively fixed.
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
    if(CMAKE_DEVICE STREQUAL "arm64")
      set(_candidates gxf_jetpack70)
    else()
      set(_candidates gxf_aarch64_cuda_13_0)
    endif()
  else()
    set(_candidates gxf_x86_64_cuda_13_0 gxf_x86_64_cuda_12_6)
  endif()

  # Only consider flavours that are actually vendored in this checkout.
  set(_present "")
  foreach(_c IN LISTS _candidates)
    if(IS_DIRECTORY "${_lib_root}/${_c}")
      list(APPEND _present "${_c}")
    endif()
  endforeach()

  _isaac_ros_gxf_host_abi(_host_glibc _host_glibcxx)
  message(STATUS
    "isaac_ros_gxf: host ABI glibc ${_host_glibc}, ${_host_glibcxx}, "
    "candidates: ${_present}")

  if(ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE)
    set(_chosen "${ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE}")
    if(NOT IS_DIRECTORY "${_lib_root}/${_chosen}")
      message(FATAL_ERROR
        "ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE=${_chosen} is not vendored under ${_lib_root}")
    endif()
    set(_reason "pinned via ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE")
  else()
    set(_chosen "")
    foreach(_c IN LISTS _present)
      _isaac_ros_gxf_probe_payload("${_lib_root}/${_c}" "${_c}" _ok _log)
      if(_ok)
        set(_chosen "${_c}")
        set(_reason "link probe passed on glibc ${_host_glibc} / ${_host_glibcxx}")
        break()
      endif()
      # Pull the interesting line out of a very noisy compiler log. Prefer the ABI symbol that
      # actually explains the rejection; fall back to the tail of the log so a probe failure is
      # never reported without a reason.
      set(_why "")
      foreach(_pat "undefined reference to [^\n]*@GLIBC[^\n]*"
                   "undefined reference to [^\n]*"
                   "[^\n]*cannot find[^\n]*"
                   "[^\n]*not found[^\n]*")
        string(REGEX MATCH "${_pat}" _why "${_log}")
        if(_why)
          break()
        endif()
      endforeach()
      if(NOT _why)
        string(STRIP "${_log}" _why)
        string(LENGTH "${_why}" _len)
        if(_len GREATER 400)
          string(SUBSTRING "${_why}" 0 400 _why)
        endif()
        if(NOT _why)
          set(_why "link probe failed (no diagnostic captured)")
        endif()
      endif()
      message(STATUS "isaac_ros_gxf: ${_c} rejected -- ${_why}")
    endforeach()
  endif()

  if(_chosen)
    _isaac_ros_gxf_include_for_variant("${gxf_root}" "${_chosen}" _include)
    set(ISAAC_ROS_GXF_PAYLOAD_FOUND TRUE PARENT_SCOPE)
    set(ISAAC_ROS_GXF_PAYLOAD_VARIANT "${_chosen}" PARENT_SCOPE)
    set(ISAAC_ROS_GXF_PAYLOAD_INCLUDE "${_include}" PARENT_SCOPE)
    set(ISAAC_ROS_GXF_PAYLOAD_REASON "${_reason}" PARENT_SCOPE)
    message(STATUS "isaac_ros_gxf: selected ${_chosen} (${_reason}), headers ${_include}")
  else()
    set(ISAAC_ROS_GXF_PAYLOAD_FOUND FALSE PARENT_SCOPE)
    set(ISAAC_ROS_GXF_PAYLOAD_VARIANT "" PARENT_SCOPE)
    set(ISAAC_ROS_GXF_PAYLOAD_INCLUDE "" PARENT_SCOPE)
    set(ISAAC_ROS_GXF_PAYLOAD_REASON
        "no vendored GXF payload is loadable on this host (glibc ${_host_glibc}, ${_host_glibcxx})"
        PARENT_SCOPE)
  endif()
endfunction()
