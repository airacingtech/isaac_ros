# Installation

## CUDA 12.6.2
Please ensure that you are running [CUDA 12.6.2](https://developer.nvidia.com/cuda-12-6-2-download-archive?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=22.04&target_type=deb_network).

## CUDNN 9.7.1
Please install it [here](https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb).
```bash
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get -y install cudnn
```

## NVIDIA VPI
Please add this to your apt package manager.
```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://airacingtech.github.io/isaac_ros/isaac_ros.gpg \
  | gpg --dearmor | sudo tee /etc/apt/keyrings/isaac_ros.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/isaac_ros.gpg] https://airacingtech.github.io/isaac_ros ./" \
  | sudo tee /etc/apt/sources.list.d/isaac_ros.list

sudo apt update
sudo apt install libnvvpi3 vpi3-dev vpi3-samples
```

## TensorRT 10
You need TensorRT 10.5. Please install it [here](https://developer.nvidia.com/downloads/compute/machine-learning/tensorrt/10.5.0/local_repo/nv-tensorrt-local-repo-ubuntu2204-10.5.0-cuda-12.6_1.0-1_amd64.deb)
```bash
sudo apt install \
  tensorrt \
  tensorrt-dev \
  libnvinfer-plugin-dev \
  libnvonnxparsers-dev \
  python3-libnvinfer \
  python3-libnvinfer-dev \
  python3-libnvinfer-plugin \
  onnx-graphsurgeon \
  polygraphy
```
## libnvTools
Please install the legacy NVTX.
```bash
sudo apt install libnvtoolsext1
sudo ln -s \
  /usr/lib/x86_64-linux-gnu/libnvToolsExt.so.1 \
  /usr/lib/x86_64-linux-gnu/libnvToolsExt.so
```

## CVCUDA
Please install the [development](https://github.com/CVCUDA/CV-CUDA/releases/download/v0.16.0/cvcuda-dev-0.16.0-cuda12-x86_64-linux.deb) and [library](https://github.com/CVCUDA/CV-CUDA/releases/download/v0.16.0/cvcuda-lib-0.16.0-cuda12-x86_64-linux.deb) dependencies.

## isaac_ros_gxf
Please run these commands inside of isaac_ros_gxf.
```bash
sudo apt install git-lfs
git lfs install
git lfs pull
```
## datacenter-gpu-manager (3)
Please install libsdgcm.3 [here](https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/datacenter-gpu-manager_3.3.7_amd64.deb).

## Boost 1.84
Please install it [here](https://archives.boost.io/release/1.82.0/source/boost_1_82_0.tar.gz).
```bash
tar xzf boost_1_82_0.tar.gz && cd boost_1_82_0 && ./bootstrap.sh --prefix=/usr/local && sudo ./b2 install -j$(nproc)
```

## Tritonserver
Install these dependencies first (Re2 and b64).
```bash
sudo apt-get install -y libre2-dev
sudo apt-get install -y libb64-dev
```

## tensorrt cmake
Please run these commands.
```bash
git clone https://github.com/tier4/tensorrt_cmake_module.git
cd tensorrt_cmake_module
cmake -S . -B build
sudo cmake --install build
```

## cudnn cmake
```bash
git clone https://github.com/tier4/cudnn_cmake_module-release.git
cd cudnn_cmake_module-release
cmake -S . -B build
sudo cmake --install build
```

## Redundant type specialization
There is a redundant type specialization within iron that conflicts with GCC type specialization. This can be fixed easily by commenting out the generic type specialization.
```cpp
// /opt/ros/iron/rclcpp_action/rclcpp_action/types.hpp
template<>
struct less<rclcpp_action::GoalUUID>
{
  bool operator()(
    const rclcpp_action::GoalUUID & lhs,
    const rclcpp_action::GoalUUID & rhs) const
  {
    return lhs < rhs;
  }
};
```
