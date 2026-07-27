# Pin the CUDA toolkit to the CUDA major of the prebuilt NITROS/GXF payload.
#
# Included by isaac_ros_common-extras.cmake, so every Isaac ROS package -- and anything else that
# depends on isaac_ros_common -- inherits it with no build-system flags and nothing to remember.
#
# Why this is needed: the GXF payload is a prebuilt binary tied to a CUDA major
# (gxf_x86_64_cuda_12_6 links libcudart.so.12). Source-built packages otherwise compile against
# whichever nvcc is first on PATH, so a host with the CUDA 13 toolkit and a cuda_12_6 payload ends up
# loading two CUDA runtimes -- two context and memory pools -- inside one NITROS container, and a
# device buffer produced by a GXF codelet is consumed by a TensorRT engine on the other runtime.
# That is not a configuration NVIDIA tests.
#
# The toolkit is deliberately NOT taken from `nvcc` on PATH, and never from the /usr/local/cuda
# symlink: that tracks the newest toolkit installed, which is exactly the wrong answer on a host
# whose payload is older. The AV24 has the CUDA 13 toolkit and must build GPU code with CUDA 12.6.
#
# Precedence:
#   1. an explicit CUDA_TOOLKIT_ROOT_DIR / CMAKE_CUDA_COMPILER from the caller -- never overridden
#   2. the flavour isaac_ros_gxf recorded, when it is already installed
#   3. the ABI link probe against the payloads in this checkout, when gxf has not been built yet
#      (isaac_ros_common builds before isaac_ros_gxf, so this is the bootstrap path)

if(DEFINED _ISAAC_ROS_CUDA_FLAVOUR_DONE)
  return()
endif()
set(_ISAAC_ROS_CUDA_FLAVOUR_DONE TRUE)

# Opt out with -DISAAC_ROS_CUDA_PIN=OFF. Deliberately NOT "bail if CUDA_TOOLKIT_ROOT_DIR is already
# set": ament_auto_find_build_dependencies() pulls in sibling packages whose extras call
# find_package(CUDA) first, which populates CUDA_TOOLKIT_ROOT_DIR with whatever nvcc is on PATH. That
# made this return early and silently leave packages on CUDA 13 (gxf_isaac_tensorops,
# gxf_isaac_ros_unet) while everything else moved to 12.6 -- exactly the mixed-runtime split this
# file exists to prevent. The flavour is derived from the payload, so it must win unconditionally.
option(ISAAC_ROS_CUDA_PIN "Pin the CUDA toolkit to the GXF payload's CUDA major" ON)
if(NOT ISAAC_ROS_CUDA_PIN)
  message(STATUS "isaac_ros: CUDA pinning disabled (ISAAC_ROS_CUDA_PIN=OFF)")
  return()
endif()

set(_flavour "")

# (2) isaac_ros_gxf already installed -- reuse its recorded decision rather than forming a second
# opinion that could drift from the payload that was actually installed.
#
# Read the value out of the installed extras textually instead of via find_package(isaac_ros_gxf):
# isaac_ros_gxf DEPENDS on isaac_ros_common, so calling find_package here is a dependency cycle, and
# loading gxf's config mid-configure of common fails in ament_index_get_resource.
# Search every prefix list that might hold the sibling package. CMAKE_PREFIX_PATH alone was not
# enough: under colcon's isolated install each package has its own prefix and the reliable source of
# those is AMENT_PREFIX_PATH in the environment. Missing it made the lookup fail silently, so the
# module fell through to "no payload" and left packages on whatever nvcc was on PATH -- which is how
# gxf_isaac_tensorops stayed on CUDA 13 while isaac_ros_common moved to 12.6.
set(_isaac_prefixes ${CMAKE_PREFIX_PATH} ${ament_index_build_path})
if(DEFINED ENV{AMENT_PREFIX_PATH})
  string(REPLACE ":" ";" _ament_env "$ENV{AMENT_PREFIX_PATH}")
  list(APPEND _isaac_prefixes ${_ament_env})
endif()
if(DEFINED ENV{CMAKE_PREFIX_PATH})
  string(REPLACE ":" ";" _cmake_env "$ENV{CMAKE_PREFIX_PATH}")
  list(APPEND _isaac_prefixes ${_cmake_env})
endif()
list(REMOVE_DUPLICATES _isaac_prefixes)

# find_file rather than iterating by hand: it handles the prefix/suffix combinations and any
# path-form differences between CMAKE_PREFIX_PATH and AMENT_PREFIX_PATH entries. Getting this wrong
# is not loud -- the module just reports "no payload" and every package silently keeps whatever nvcc
# is on PATH.
find_file(_gxf_extras
  NAMES isaac_ros_gxf-extras.cmake
  PATHS ${_isaac_prefixes}
  PATH_SUFFIXES share/isaac_ros_gxf/cmake
  NO_DEFAULT_PATH)

if(_gxf_extras AND EXISTS "${_gxf_extras}")
  file(STRINGS "${_gxf_extras}" _recorded
       REGEX "ISAAC_ROS_GXF_PAYLOAD_VARIANT[ \t]+\"[^\"]+\"")
  if(_recorded)
    list(GET _recorded 0 _recorded)
    string(REGEX REPLACE ".*\"([^\"]+)\".*" "\\1" _flavour "${_recorded}")
    set(_how "recorded by isaac_ros_gxf")
  endif()
endif()

# (3) Bootstrap: run the probe against the payloads in this checkout. isaac_ros_common is a
# dependency OF isaac_ros_gxf, so on a clean workspace it configures first and has nothing to read.
if(NOT _flavour)
  set(_gxf_pkg "${CMAKE_CURRENT_LIST_DIR}/../../../isaac_ros_nitros/isaac_ros_gxf")
  get_filename_component(_gxf_pkg "${_gxf_pkg}" ABSOLUTE)
  set(_probe "${_gxf_pkg}/cmake/isaac_ros_gxf_payload_select.cmake")
  if(EXISTS "${_probe}")
    include("${_probe}")
    isaac_ros_gxf_select_payload("${_gxf_pkg}/gxf")
    if(ISAAC_ROS_GXF_PAYLOAD_VARIANT)
      set(_flavour "${ISAAC_ROS_GXF_PAYLOAD_VARIANT}")
      set(_how "ABI link probe")
    endif()
  endif()
endif()

if(NOT _flavour)
  # No payload and no probe: leave CMake's normal discovery in place. A workspace with no NITROS
  # stack is a legitimate configuration -- it just builds the CPU path.
  message(STATUS "isaac_ros: no GXF payload found; leaving CUDA toolkit discovery to CMake")
  return()
endif()

if(NOT _flavour MATCHES "cuda_([0-9]+)_([0-9]+)$")
  message(STATUS "isaac_ros: cannot derive a CUDA version from payload '${_flavour}'")
  return()
endif()
set(_cuda_ver "${CMAKE_MATCH_1}.${CMAKE_MATCH_2}")
set(_cuda_root "/usr/local/cuda-${_cuda_ver}")

if(NOT EXISTS "${_cuda_root}/bin/nvcc")
  # Hard error rather than silently falling back to the wrong major: falling back is what produced
  # the mixed-runtime build this file exists to prevent.
  message(FATAL_ERROR
    "isaac_ros: the GXF payload (${_flavour}) requires CUDA ${_cuda_ver}, but "
    "${_cuda_root}/bin/nvcc is missing.\n"
    "Install the matching toolkit:\n"
    "  sudo tools/scripts/install_isaac_deps.sh -y")
endif()

set(CUDA_TOOLKIT_ROOT_DIR "${_cuda_root}" CACHE PATH "CUDA toolkit matching the GXF payload" FORCE)
set(CMAKE_CUDA_COMPILER "${_cuda_root}/bin/nvcc" CACHE FILEPATH
    "nvcc matching the GXF payload" FORCE)
# CUDAToolkit_ROOT is what the modern FindCUDAToolkit honours; the legacy FindCUDA uses
# CUDA_TOOLKIT_ROOT_DIR. Isaac packages use both, so set both.
set(CUDAToolkit_ROOT "${_cuda_root}" CACHE PATH "CUDA toolkit matching the GXF payload" FORCE)

message(STATUS
  "isaac_ros: CUDA ${_cuda_ver} pinned from GXF payload ${_flavour} (${_how}) -> ${_cuda_root}")
