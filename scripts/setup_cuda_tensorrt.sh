#!/usr/bin/env bash
#
# setup_cuda_tensorrt.sh
#   Install the CUDA + TensorRT host stack that the airacingtech isaac_ros packages
#   (and the isaac_launch pipeline in race_common) compile against:
#
#       CUDA 12.8  +  TensorRT 10.15.1 (cuda12)   [ + optional ZED SDK 5.4 ]
#
#   Why these versions:
#     * The Isaac ROS DNN/codec stack targets the TensorRT 10.x API. TensorRT 11
#       removed nvinfer1::BuilderFlag::kFP16 and NetworkDefinitionCreationFlag::
#       kEXPLICIT_BATCH, so gxf_isaac_tensor_rt fails to build against it.
#     * The Stereolabs ZED SDK ships only CUDA 12.x builds (no CUDA 13).
#     * The custom NVENC/NVDEC codec is CUDA 12/13 portable (CUDA_VERSION-guarded),
#       but 12.8 + TRT 10.15 is the combination this stack is validated on.
#
#   Target : Ubuntu 24.04 (noble), x86_64, NVIDIA driver >= 570 (for CUDA 12.8).
#   Notes  : Does NOT touch the NVIDIA driver. Installs CUDA 12.8 ALONGSIDE any existing
#            CUDA (makes 12.8 the default via update-alternatives). Requires sudo/root.
#            ROS 2 / rosdep dependencies (zed_msgs, nitros deps, ...) are NOT handled
#            here -- get those with `rosdep install` + your .repos, as usual.
#
#   Usage:
#     ./setup_cuda_tensorrt.sh              # CUDA 12.8 + TensorRT 10.15
#     ./setup_cuda_tensorrt.sh --with-zed   # also install the ZED SDK (for the ZED wrapper)
#
set -euo pipefail

CUDA_PKG="cuda-toolkit-12-8"
CUDA_DIR="/usr/local/cuda-12.8"
TRT="10.15.1.29-1+cuda12.9"
TRT_PKGS=(libnvinfer-headers-dev libnvinfer10 libnvinfer-dev
          libnvinfer-headers-plugin-dev libnvinfer-plugin10 libnvinfer-plugin-dev
          libnvonnxparsers10 libnvonnxparsers-dev)
ZED_URL="https://download.stereolabs.com/zedsdk/5.4/cu12/ubuntu24"

WITH_ZED=0
[ "${1:-}" = "--with-zed" ] && WITH_ZED=1

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
export DEBIAN_FRONTEND=noninteractive

# --- sanity checks ---
. /etc/os-release 2>/dev/null || true
[ "${VERSION_ID:-}" = "24.04" ] || echo "WARNING: validated on Ubuntu 24.04; found '${VERSION_ID:-unknown}'."
[ "$(uname -m)" = "x86_64" ] || { echo "ERROR: x86_64 only." >&2; exit 1; }
command -v wget >/dev/null || $SUDO apt-get install -y wget
command -v curl >/dev/null || $SUDO apt-get install -y curl

echo "== [1/4] NVIDIA CUDA apt repository =="
if ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi "cuda-ubuntu2404"; then
  tmp="$(mktemp -d)"
  wget -qO "$tmp/cuda-keyring.deb" \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  $SUDO dpkg -i "$tmp/cuda-keyring.deb"
  rm -rf "$tmp"
fi
$SUDO apt-get update

echo "== [2/4] CUDA 12.8 toolkit (kept alongside existing CUDA; driver untouched) =="
$SUDO apt-get install -y "$CUDA_PKG"
if update-alternatives --list cuda 2>/dev/null | grep -q "$CUDA_DIR"; then
  $SUDO update-alternatives --set cuda "$CUDA_DIR"
else
  $SUDO ln -sfn "$CUDA_DIR" /etc/alternatives/cuda
fi

echo "== [3/4] TensorRT $TRT (replaces any TensorRT 11) =="
$SUDO apt-get remove -y "tensorrt" "libnvinfer*" "libnvonnxparsers*" "python3-libnvinfer*" || true
pins=(); for p in "${TRT_PKGS[@]}"; do pins+=("${p}=${TRT}"); done
$SUDO apt-get install -y --allow-downgrades --allow-change-held-packages "${pins[@]}"
$SUDO apt-mark hold "${TRT_PKGS[@]}"   # keep apt upgrade from pulling TRT 11 back

if [ "$WITH_ZED" -eq 1 ]; then
  echo "== [4/4] ZED SDK 5.4 (cuda12.8), silent =="
  run="$(mktemp --suffix=.zed.run)"
  curl -fSL -o "$run" "$ZED_URL"
  chmod +x "$run"
  $SUDO bash "$run" -- silent skip_cuda skip_drivers skip_python skip_hub \
    || $SUDO bash "$run" -- silent
  $SUDO chmod -R a+rX /usr/local/zed   # let non-root colcon builds read the SDK
  rm -f "$run"
else
  echo "== [4/4] ZED SDK skipped (pass --with-zed to install it) =="
fi

echo "== verify =="
"$CUDA_DIR/bin/nvcc" --version | tail -2 || true
dpkg -l 'libnvinfer-dev' 2>/dev/null | awk '/^ii/{print "TensorRT:", $2, $3}'
[ "$WITH_ZED" -eq 1 ] && { ls -d /usr/local/zed >/dev/null 2>&1 && echo "ZED SDK: installed at /usr/local/zed"; }
echo "DONE. Host ready to compile isaac_ros / isaac_launch (CUDA 12.8 + TensorRT $TRT)."
