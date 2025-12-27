#!/usr/bin/env bash
#
# Fixed Isaac ROS run.sh for race_common workspace
#

set -e

# ----------------------------
# Resolve script root safely
# ----------------------------
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$ROOT/utils/print_color.sh"

# ----------------------------
# Usage
# ----------------------------
usage() {
    print_info "Usage: ./run.sh [-d <isaac_ros_dev_dir>] [-b] [-v]"
    exit 0
}

# ----------------------------
# Defaults
# ----------------------------
IMAGE_KEY=ros2_humble
SKIP_IMAGE_BUILD=0
VERBOSE=0
DOCKER_ARGS=()

# IMPORTANT: default workspace root is race_common
ISAAC_ROS_DEV_DIR="$(realpath "$ROOT/../../../../..")"

# ----------------------------
# Parse args
# ----------------------------
VALID_ARGS=$(getopt -o hvd:ba: --long help,verbose,isaac_ros_dev_dir:,skip_image_build,docker_arg: -- "$@")
eval set -- "$VALID_ARGS"

while true; do
  case "$1" in
    -d|--isaac_ros_dev_dir)
      ISAAC_ROS_DEV_DIR="$(realpath "$2")"
      shift 2 ;;
    -b|--skip_image_build)
      SKIP_IMAGE_BUILD=1
      shift ;;
    -a|--docker_arg)
      DOCKER_ARGS+=("$2")
      shift 2 ;;
    -v|--verbose)
      VERBOSE=1
      shift ;;
    -h|--help)
      usage ;;
    --)
      shift
      break ;;
  esac
done

# ----------------------------
# Sanity checks
# ----------------------------
print_info "Using ISAAC_ROS_DEV_DIR = $ISAAC_ROS_DEV_DIR"

if [[ $(id -u) -eq 0 ]]; then
    print_error "Do NOT run as root."
    exit 1
fi

# Docker group check (safe)
if ! groups "$USER" | grep -q docker; then
    print_error "User '$USER' is not in docker group."
    print_error "Run: sudo usermod -aG docker $USER && newgrp docker"
    exit 1
fi

# Docker usability check (safe under set -e)
if ! docker ps >/dev/null 2>&1; then
    print_error "Docker is not usable for this user."
    exit 1
fi

# ----------------------------
# Git LFS check (correct)
# ----------------------------
if git -C "$ISAAC_ROS_DEV_DIR" rev-parse >/dev/null 2>&1; then
    MISSING_LFS=$(git -C "$ISAAC_ROS_DEV_DIR" lfs ls-files | grep '^-' || true)
    if [[ -n "$MISSING_LFS" ]]; then
        print_error "Missing Git LFS files:"
        echo "$MISSING_LFS"
        exit 1
    fi
fi

# ----------------------------
# Docker image naming
# ----------------------------
PLATFORM="$(uname -m)"
BASE_IMAGE_KEY="$PLATFORM.$IMAGE_KEY.user"
BASE_NAME="isaac_ros_dev-$PLATFORM"
CONTAINER_NAME="$BASE_NAME-container"

# ----------------------------
# Remove old exited container
# ----------------------------
if docker ps -a --filter name="$CONTAINER_NAME" --filter status=exited -q | grep -q .; then
    docker rm "$CONTAINER_NAME" >/dev/null
fi

# ----------------------------
# Attach if already running
# ----------------------------
if docker ps --filter name="$CONTAINER_NAME" -q | grep -q .; then
    print_info "Attaching to running container $CONTAINER_NAME"
    docker exec -it --user admin --workdir /workspaces/isaac_ros-dev "$CONTAINER_NAME" /bin/bash
    exit 0
fi

# ----------------------------
# Build image if needed
# ----------------------------
print_info "Launching Isaac ROS Dev container"
print_info "Image key: $BASE_IMAGE_KEY"

if [[ $SKIP_IMAGE_BUILD -ne 1 ]]; then
    print_info "Building image $BASE_NAME"
    "$ROOT/build_image_layers.sh" \
        --image_key "$BASE_IMAGE_KEY" \
        --image_name "$BASE_NAME"
fi

if ! docker image ls "$BASE_NAME" -q | grep -q .; then
    print_error "Docker image $BASE_NAME not found."
    exit 1
fi

# ----------------------------
# Docker runtime args
# ----------------------------
DOCKER_ARGS+=(
  --privileged
  --network host
  -e DISPLAY
  -e NVIDIA_VISIBLE_DEVICES=all
  -e NVIDIA_DRIVER_CAPABILITIES=all
  -e ROS_DOMAIN_ID
  -e USER
  -e ISAAC_ROS_WS=/workspaces/isaac_ros-dev
  -v /tmp/.X11-unix:/tmp/.X11-unix
  -v "$HOME/.Xauthority:/home/admin/.Xauthority:rw"
  -v "$ISAAC_ROS_DEV_DIR:/workspaces/isaac_ros-dev"
  -v /etc/localtime:/etc/localtime:ro
)

# ----------------------------
# Run container
# ----------------------------
print_info "Running container $CONTAINER_NAME"

if [[ $VERBOSE -eq 1 ]]; then
    set -x
fi

docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --runtime nvidia \
    --user admin \
    --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
    --workdir /workspaces/isaac_ros-dev \
    "${DOCKER_ARGS[@]}" \
    "$BASE_NAME" \
    /bin/bash
