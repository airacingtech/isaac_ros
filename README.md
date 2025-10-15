# Installation
Please ensure that you are running [CUDA 12.6](https://developer.nvidia.com/cuda-12-6-0-download-archive?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=22.04&target_type=deb_network).

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

## isaac_ros_gxf
Please run these commands inside of isaac_ros_gxf.
```bash
git lfs install
git lfs pull
```

## rclcpp_action conflicts with gcc
There is a function conflict which must be patched and can be done easily via:
```bash
sudo sed -i 's/#if !(defined(__GLIBCXX__) && __GLIBCXX__ >= 20220706)/#if !(defined(__GLIBCXX__))/' /opt/ros/iron/include/rclcpp_action/rclcpp_action/types.hpp
```
