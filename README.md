# Installation
Please ensure that you are running [CUDA 12.9](https://developer.nvidia.com/cuda-12-9-0-download-archive?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=22.04&target_type=deb_network).

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

## libnvTools
Please install the legacy NVTX.
```bash
sudo apt install libnvtoolsext1
sudo ln -s \
  /usr/lib/x86_64-linux-gnu/libnvToolsExt.so.1 \
  /usr/lib/x86_64-linux-gnu/libnvToolsExt.so
```

## isaac_ros_gxf
Please run these commands inside of isaac_ros_gxf.
```bash
sudo apt install git-lfs
git lfs install
git lfs pull
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
