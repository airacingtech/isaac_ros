# CI dependency image for compiling the airacingtech isaac_ros packages.
# Bakes the heavy, stable host stack so the workflow never reinstalls it on a source
# change -- the image layers are cached in the GitHub Actions cache and only rebuilt
# when THIS file changes. Per-repo ROS deps (rosdep) and the colcon build itself run in
# the workflow (with their own caches).
#
#   CUDA 12.8 + ROS 2 Jazzy + TensorRT 10.15 + nv-codec-headers + colcon/ccache
FROM nvidia/cuda:12.8.1-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG TRT_VERSION=10.15.1.29-1+cuda12.9
ARG NV_CODEC_HEADERS_REF=n13.0.19.0

# base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
      git wget curl gnupg2 lsb-release ca-certificates locales \
      build-essential cmake ninja-build ccache software-properties-common \
    && locale-gen en_US en_US.UTF-8 && update-locale LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ROS 2 Jazzy + colcon + rosdep
RUN add-apt-repository universe -y \
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
         -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu noble main" \
         > /etc/apt/sources.list.d/ros2.list \
    && apt-get update && apt-get install -y \
         ros-jazzy-ros-base ros-dev-tools python3-colcon-common-extensions python3-rosdep \
    && rosdep init && rosdep update \
    && rm -rf /var/lib/apt/lists/*

# TensorRT 10.x (NOT 11 -- 11 removes kFP16/kEXPLICIT_BATCH). The base image ships the CUDA repo.
RUN apt-get update && apt-get install -y --allow-downgrades --allow-change-held-packages \
      libnvinfer-headers-dev=${TRT_VERSION} libnvinfer10=${TRT_VERSION} libnvinfer-dev=${TRT_VERSION} \
      libnvinfer-headers-plugin-dev=${TRT_VERSION} libnvinfer-plugin10=${TRT_VERSION} \
      libnvinfer-plugin-dev=${TRT_VERSION} libnvonnxparsers10=${TRT_VERSION} libnvonnxparsers-dev=${TRT_VERSION} \
    && apt-mark hold libnvinfer-headers-dev libnvinfer10 libnvinfer-dev \
         libnvinfer-headers-plugin-dev libnvinfer-plugin10 libnvinfer-plugin-dev \
         libnvonnxparsers10 libnvonnxparsers-dev \
    && rm -rf /var/lib/apt/lists/*

# NVENC/NVDEC compile headers (driver libs are dlopen'd at runtime, so no GPU needed to build)
RUN git clone --depth 1 --branch ${NV_CODEC_HEADERS_REF} \
      https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers \
    && make -C /tmp/nv-codec-headers install PREFIX=/usr/local \
    && rm -rf /tmp/nv-codec-headers
