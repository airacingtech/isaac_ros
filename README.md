# Isaac ROS / NITROS on the ART stack

This tree is ART's fork of the NVIDIA Isaac ROS repositories. It builds on **Ubuntu 22.04** and
**Ubuntu 24.04** from the same checkout, with no per-machine flags: the correct prebuilt GXF payload
is detected at configure time.

- Nothing to source by hand. `source install/setup.bash` is sufficient, including for
  non-interactive launches (ssh, systemd).
- Nothing lives in a home directory. All host dependencies are under `/opt` or the system prefix.
- If the stack cannot be built on a host, `isaac_launch` degrades to the CPU path and warns at
  compile time that the build is **not NITROS boosted**.

---

## Support matrix

NVIDIA ships GXF, cuVSLAM and cuApriltags as **prebuilt binaries**, in per-CUDA-major flavours. Each
flavour is also compiled against a specific Ubuntu, so it carries a hard glibc/libstdc++ floor.

| | Ubuntu 22.04 | Ubuntu 24.04 |
|---|---|---|
| GXF payload | `gxf_x86_64_cuda_12_6` | `gxf_x86_64_cuda_13_0` |
| GXF core version | 4.1.0 | 5.1.0 |
| GXF headers | `gxf/core/include_cuda_12_6` | `gxf/core/include` |
| cuVSLAM | `lib/cuvslam/lib_x86_64_cuda_12_6` | `lib/cuvslam/lib_x86_64_cuda_13_0` |
| CUDA runtime | 12.6 (`.so.12`) | 13.0 (`.so.13`) |
| Requires glibc | ≥ 2.35 | ≥ 2.38 |
| Requires GLIBCXX | ≥ 3.4.30 | ≥ 3.4.32 |

The AV24 (`art-iac-car`) is Ubuntu 22.04, glibc 2.35, GCC 11.4 → **`cuda_12_6`**.

### The CUDA version is not the deciding factor

This is the single most important thing to understand, and the most common way to get this wrong.

The AV24 has the **CUDA 13 toolkit installed** and still must use the **`cuda_12_6`** payload,
because `cuda_13_0` needs glibc 2.38 and 22.04 provides 2.35. Selecting on CUDA version would pick a
payload that cannot link. The binding constraint is the **glibc/libstdc++ ABI floor**; the CUDA
runtime is a second, independent requirement. Both must hold.

Choosing wrongly does not fail at configure time. It fails much later, while linking some unrelated
package, with undefined references coming out of the GXF binary itself:

```
/bin/ld: .../libgxf_multimedia.so: undefined reference to `std::ios_base_library_init()@GLIBCXX_3.4.32'
/bin/ld: .../libgxf_multimedia.so: undefined reference to `__isoc23_strtol@GLIBC_2.38'
```

If you see that, a 24.04 payload is installed on a 22.04 host.

---

## Quick start

```bash
# 1. Host dependencies (auto-detects the flavour this host can use)
sudo tools/scripts/install_isaac_deps.sh -y

# 2. Build
colcon build --packages-up-to isaac_launch

# 3. Use
source install/setup.bash
```

To confirm what will be selected, without building:

```bash
tools/scripts/nitros_probe.sh --explain
# NITROS: available via gxf_x86_64_cuda_12_6 -- link probe passed on glibc 2.35 / GLIBCXX_3.4.30
```

---

## How selection works

`isaac_ros_gxf/cmake/isaac_ros_gxf_payload_select.cmake` **link-probes** each vendored payload: it
tries to link a throwaway binary against that flavour's `libgxf_core.so` and `libgxf_multimedia.so`,
newest CUDA major first, and takes the first that succeeds.

This reproduces the exact `ld` invocation that would otherwise fail later, so one check covers both
the glibc/libstdc++ floor **and** a missing `libcudart.so.<major>` — and it stays correct for payload
flavours that do not exist yet, instead of encoding a table that goes stale.

The decision is made **once**, by `isaac_ros_gxf`, and carried to everything else:

| Consumer | Mechanism |
|---|---|
| `isaac_ros_gxf` core libs + headers | `GXF_CORE_LIB_DIR` / `GXF_CORE_INCLUDE_DIR` |
| ~20 `gxf_isaac_*` extensions | `GXF_EXT_LIB_SUBDIR`, set in `isaac_ros_gxf-extras.cmake` |
| cuVSLAM / cuApriltags | `CUVSLAM_LIB_PATH` / `CUAPRILTAGS_LIB_PATH` in `isaac_ros_nitros` |
| `isaac_launch` | `find_package(isaac_ros_gxf)` → NITROS boosted, or warn |

Headers and libraries **must** move together. Extensions bake `kGxfCoreVersion` in at compile time
and a GXF 4.1.0 core refuses to load a 5.1.0 extension — that failure is a runtime
`GXF_FACTORY_INCOMPATIBLE`, not a link error, so it is easy to ship by accident. Selection therefore
sets the lib dir and the include dir as a pair, never independently.

### The GXF flavour dictates CUDA for the whole GPU stack

The selected flavour is not just a GXF detail — **every GPU package follows it**: yolov8, TensorRT and
OpenCV-CUDA included.

The reason is that these all end up in one process. A NITROS container runs GXF codelets, hands
device buffers to a TensorRT engine, and calls OpenCV CUDA kernels. If GXF is `cuda_12_6` while
TensorRT and OpenCV are built against CUDA 13, that process loads **two CUDA runtimes** with two
context and memory pools — a combination NVIDIA does not test, and one where the ownership of a
device pointer crossing between them is not something you want to reason about on a race car.

So:

| Package | CUDA source of truth |
|---|---|
| `isaac_ros_gxf`, `gxf_isaac_*` | the link probe |
| `isaac_ros_nitros` (cuVSLAM, cuApriltags) | the recorded flavour |
| `yolov8` | the recorded flavour, via `cmake/nitros_cuda_flavour.cmake` |
| TensorRT (`libnvinfer*`) | installed as the `+cuda<major>` build matching the flavour |
| OpenCV-CUDA (`/opt/opencv-cuda`) | built against the matching toolkit |

`yolov8` deliberately does **not** derive its toolkit from `nvcc` on `PATH`, and never from the
`/usr/local/cuda` symlink — that tracks the newest toolkit, which is precisely the wrong answer on a
host whose GXF payload is older. The AV24 has the CUDA 13 toolkit installed and must build GPU code
with CUDA 12.6.

To see the version the stack requires:

```bash
tools/scripts/nitros_probe.sh --cuda    # 12.6
```

Two notes when changing flavour:

- **TensorRT is packaged per CUDA major** (`10.16.1.11-1+cuda12.9` vs `+cuda13.2`). The installer
  keeps the TensorRT **major** you already have and changes only the CUDA flavour — the TRT major is
  an API boundary (`nvparsers` was removed in 10), so crossing it would trade a CUDA mismatch for a
  compile break. If only a different major is available for your CUDA, the installer says so and
  stops rather than doing it silently.
- **Cached TensorRT `.engine` files are invalidated.** They are tied to the TensorRT version and the
  GPU arch, and rebuild on first launch. Expected, not an error.

### Overrides

Auto-detection should be right; these exist for bring-up and bisecting.

| Variable | Effect |
|---|---|
| `ISAAC_ROS_GXF_PAYLOAD_VARIANT_OVERRIDE` | Pin a flavour, skip probing |
| `ISAAC_ROS_GXF_EXTRA_CUDA_LIB_DIRS` | Extra CUDA runtime dirs for the probe |
| `GXF_CORE_LIB_DIR_OVERRIDE` / `GXF_CORE_INCLUDE_DIR_OVERRIDE` | Upstream knobs; must be set as a matching pair |
| `NITROS_PROBE_REFRESH=1` | Ignore the cached probe verdict |

---

## Dependencies

### CUDA runtime

Exactly what the prebuilt binaries link, derived by scanning `DT_NEEDED` across every vendored `.so`
— not a full toolkit.

| Soname needed | 22.04 package | 24.04 package |
|---|---|---|
| `libcudart.so.{12,13}` | `cuda-cudart-12-6` | `cuda-cudart-13-0` |
| `libcublas.so.*`, `libcublasLt.so.*` | `libcublas-12-6` | `libcublas-13-0` |
| `libnppc/nppial/nppidei/nppig.so.*` | `libnpp-12-6` | `libnpp-13-0` |
| `libcusolver.so.{11,12}` | `libcusolver-12-6` | `libcusolver-13-0` |

> **cuSOLVER's soname trails its toolkit version.** `libcusolver-12-6` ships `libcusolver.so.11`
> and `libcusolver-13-0` ships `libcusolver.so.12`. It is the easiest dependency to miss because
> nothing fails until `isaac_ros_visual_slam` links and reports undefined `cusolverDn*` symbols.

The CUDA packages normally register their own `/etc/ld.so.conf.d` entry via the
`/usr/local/cuda-<major>` symlink, so no extra loader configuration is usually needed.

### Other host dependencies

| Dependency | Location | Needed by |
|---|---|---|
| CUDA toolkit (nvcc) | `/usr/local/cuda-<ver>` | compiling `isaac_ros_common` and anything CUDA |
| TensorRT | system | `isaac_ros_tensor_rt`, `yolov8` |
| OpenCV **with CUDA modules** | `/opt/opencv-cuda` | `yolov8` (`opencv_cudaarithm`, `cudafilters`, `cudaimgproc`, `cudawarping`, `cudev`) |
| VimbaX / Vimba GigE TL | `/opt/VimbaX_*`, `/opt/Vimba_6_0` | `avt_vimba_camera` |

OpenCV-CUDA is auto-discovered under `/opt`; `OPENCV_CUDA_ROOT` overrides. Ubuntu's packaged OpenCV
does **not** include the CUDA modules, so a CUDA build is required — `install_isaac_deps.sh
--opencv-cuda` builds one.

---

## Install script

`tools/scripts/install_isaac_deps.sh`

| Invocation | Effect |
|---|---|
| (no args) | Runtime for the flavour this host can use, plus rosdep |
| `--cuda 12.6` / `--cuda 13.0` | Force one flavour |
| `--cuda all` | Both flavours — for an image serving 22.04 **and** 24.04 |
| `--opencv-cuda` | Build OpenCV+CUDA into `/opt/opencv-cuda` (slow) |
| `--tensorrt` | TensorRT runtime + headers |
| `--all` | Everything, including the OpenCV build |
| `--dry-run` | Print what would happen, change nothing |

On a single machine prefer the default. `--cuda all` installs a runtime this host may not be able to
use, and the script says so — installing the CUDA 13 runtime on 22.04 does **not** make NITROS use
`cuda_13_0`, because selection is by ABI floor, not by which runtime is present.

---

## Runtime environment

`isaac_ros_gxf` installs a generated `.dsv` environment hook that puts the GXF payload directories on
`LD_LIBRARY_PATH`.

This is needed because `isaac_ros_gxf` installs only `core`/`logger`/`multimedia`/`cuda` into `lib/`;
the rest of the payload (`libgxf_std.so` and friends) lands under
`share/isaac_ros_gxf/gxf/lib/<subsystem>/`, which is not a default loader path, and those are
`DT_NEEDED` by NITROS components. Without it, nodes die at `dlopen` with
`libgxf_std.so: cannot open shared object file`.

The hook is a `.dsv`, not a shell hook, on purpose: the top-level `install/setup.bash` processes
`.dsv` entries, while a `.sh` environment hook is only applied when sourcing that one package's
`local_setup.bash`. The directory list is enumerated at configure time, so it always matches the
selected flavour.

**There is no `isaac_nitros_env.sh` and nothing to add to `~/.bashrc`.** Sourcing
`install/setup.bash` is the whole story. If you find such a script on a machine, it predates this and
should be deleted.

---

## CPU fallback

`isaac_launch` decides automatically — there is no flag. It reads the flavour `isaac_ros_gxf`
recorded, so it cannot disagree with what was installed:

```
-- isaac_launch: NITROS boosted -- GXF payload gxf_x86_64_cuda_12_6 (link probe passed on ...)
```

When no payload is usable it emits a compile-time warning that the build is **not NITROS boosted**
and that perception will run on the CPU path with materially higher latency and CPU load. Note the
CPU path is a degraded mode: AV24 perception is expected to run GPU-accelerated.

---

## Troubleshooting

**`undefined reference to ...@GLIBC_2.38` / `@GLIBCXX_3.4.32`, from a `libgxf_*.so`**
A 24.04 payload on a 22.04 host. `tools/scripts/nitros_probe.sh --explain` will say why. Usually a
stale `install/` from before selection existed — rebuild `isaac_ros_gxf` and the `gxf_isaac_*`
extensions.

**`undefined reference to cusolverDn*@libcusolver.so.11`**
`libcusolver-12-6` is missing. See the soname note above.

**`libgxf_std.so: cannot open shared object file`**
`install/setup.bash` was not sourced, or `isaac_ros_gxf` predates the `.dsv` hook — rebuild it.

**`GXF_FACTORY_INCOMPATIBLE` at runtime**
Core and extensions from different flavours. Happens if `GXF_CORE_LIB_DIR_OVERRIDE` was set without
a matching `GXF_CORE_INCLUDE_DIR_OVERRIDE`, or extensions were not rebuilt after the core changed.
Rebuild `isaac_ros_gxf` and every `gxf_isaac_*`.

**`cannot find -lopencv_cudaarithm`**
No CUDA-enabled OpenCV found. Install to `/opt/opencv-cuda` or set `OPENCV_CUDA_ROOT`.

**`No CMAKE_CUDA_COMPILER could be found`**
`nvcc` is not on `PATH`. Add `/usr/local/cuda-<ver>/bin`.

---

## What was changed, and why

The stack previously failed to build with undefined references coming out of GXF binaries, and
required a hand-sourced env script. This is the full set of changes.

### 1. GXF payload selection (`isaac_ros_gxf`)

`cmake/isaac_ros_gxf_payload_select.cmake` — new. Link-probes each vendored payload and picks the
first that works. Sets the lib dir and the matching include dir together.

The tree shipped **three independent knobs** — `GXF_CORE_LIB_DIR_OVERRIDE`,
`GXF_CORE_INCLUDE_DIR_OVERRIDE`, `GXF_EXT_LIB_SUBDIR` — all defaulting to `cuda_13_0`, and nothing
set them. A plain `colcon build` therefore installed the Ubuntu-24.04 payload onto a 22.04 host, and
the failure surfaced later while linking an unrelated package:

```
/bin/ld: .../libgxf_multimedia.so: undefined reference to `std::ios_base_library_init()@GLIBCXX_3.4.32'
```

### 2. One decision, propagated

`isaac_ros_gxf-extras.cmake` is now generated by `configure_file` from
`isaac_ros_gxf-extras.cmake.in`, carrying the selected flavour inside the package's existing cmake
config. It sets `GXF_EXT_LIB_SUBDIR`, which every `gxf_isaac_*` extension already honoured — so ~20
extension packages follow with no per-package patching.

### 3. cuVSLAM / cuApriltags (`isaac_ros_nitros`)

`CUVSLAM_LIB_PATH` was hardcoded to `lib_x86_64_cuda_13_0`, which made `isaac_ros_visual_slam`
unbuildable on 22.04 (its 13_0 build needs glibc 2.38; the 12_6 build needs only 2.34). Now derived
from the selected flavour. `isaac_ros_visual_slam` also had a `COLCON_IGNORE` — removed.

### 4. CUDA toolkit pinning (`isaac_ros_common`)

`cmake/isaac_ros_cuda_flavour.cmake` — new, included from `isaac_ros_common-extras.cmake` (loaded by
every Isaac package) and from `isaac_ros_common`'s own `CMakeLists.txt` before
`enable_language(CUDA)`. Also applied from `isaac_ros_gxf`'s extras.

Without it, source-built packages compiled against whatever `nvcc` was first on `PATH`, so a host
with the CUDA 13 toolkit and a `cuda_12_6` payload loaded **two CUDA runtimes** in one NITROS
container. Verified by putting `nvcc 13` first on `PATH` deliberately: the pin still yields
`libcudart.so.12` and `libnpp*.so.12`.

Three bugs were found here, all of which failed **silently** — packages simply stayed on CUDA 13
while the rest of the stack moved to 12.6:

- Bailing out when `CUDA_TOOLKIT_ROOT_DIR` was already set. A sibling package's
  `find_package(CUDA)` sets it from `PATH`, so the pin never applied. The pin must be unconditional
  (`ISAAC_ROS_CUDA_PIN=OFF` opts out).
- Searching only `CMAKE_PREFIX_PATH`. Under colcon's isolated install the sibling prefixes come from
  `AMENT_PREFIX_PATH`; now both, via `find_file`.
- Ordering. `isaac_ros_common`'s extras call `find_package(CUDA REQUIRED)`, which caches
  `CUDA_nppial_LIBRARY=…cuda-13.0…` before the gxf extras fire — so the pin has to land in
  `isaac_ros_common` too, not only in `isaac_ros_gxf`.

Because these are silent, verify by inspecting the artifacts (`objdump -p | grep libcudart`), not by
the build succeeding.

### 5. Runtime environment

`isaac_ros_gxf` installs a generated `.dsv` environment hook listing the payload's subsystem
directories. Emitted as `.dsv`, not a shell hook: the top-level `install/setup.bash` processes `.dsv`
entries, while a `.sh` environment hook only applies when sourcing that one package's
`local_setup.bash`. **`isaac_nitros_env.sh` and the `~/.bashrc` `LD_LIBRARY_PATH` block are gone.**

### 6. Triton

`gxf_isaac_triton` ships a `cuda_13_0` payload only. Its `CMakeLists.txt` now hard-fails rather than
silently installing CUDA-13 binaries next to a CUDA-12 stack, and it is excluded from the build.
`isaac_ros_unet` was dropped from `isaac_launch`'s dependencies because its `exec_depend` on
`isaac_ros_triton` pulled Triton into the closure. Nothing in the ART perception path uses the Triton
backend — `isaac_ros_tensor_rt` is the inference backend.

### 7. yolov8 and OpenCV

`cmake/nitros_cuda_flavour.cmake` in the yolov8 package makes its toolkit follow the payload, reading
the recorded flavour textually (not via `find_package(isaac_ros_gxf)`, which is included before
`ament_cmake` exists and dies with `Unknown CMake command "ament_index_get_resource"`).

`cmake/opencv_cuda_prefix.cmake` auto-discovers a CUDA-enabled OpenCV under `/opt`. Ubuntu's packaged
OpenCV has no CUDA modules, so without this the link failed on `cannot find -lopencv_cudaarithm` and
every machine needed its own `-DOpenCV_DIR`.

### 8. `LAUNCH_VSLAM`

A `race.env` toggle, like `LAUNCH_COMPRESSION`. When true, `vimba.launch.py` composes two mono
converters plus the cuVSLAM node into the **same** camera container — cuVSLAM consumes NITROS image
handles, which only resolve inside the publishing process. Components live in
`components/perception_components/localization_components.py`. The stereo pair per vehicle is declared
as `stereo_pair` in `VIMBA_CAMERA_SOURCES`.

> **The IAC pair is not stereo-calibrated.** `front_left_center` and `front_right_center` both have
> `P[0][3] == 0` and mismatched intrinsics — two independent monocular calibrations. cuVSLAM will
> start and warn, but its odometry is **not valid** until a stereo calibration exists. Launch prints
> this loudly rather than letting quietly-wrong poses reach the stack.

### 9. Dependency installer

`tools/scripts/install_isaac_deps.sh` and `tools/scripts/nitros_probe.sh` — new. See above. Notable
dependencies that are easy to miss:

- **cuSOLVER's soname trails its toolkit** — `libcusolver-12-6` ships `.so.11`. Nothing fails until
  `isaac_ros_visual_slam` links.
- **cuDNN lives in the multiarch system paths**, which OpenCV's `FindCUDNN` does not search, so an
  installed cuDNN still reported `cuDNN: NO`. Passed explicitly now.
- **`cuda-nvtx`** supplies the nvtx3 headers; without it `isaac_ros_common` could not create
  `CUDA::nvtx3`. That package now treats NVTX as genuinely optional.
- **TensorRT is a ~18-package family** bound by strict `=` version deps. Pinning a subset leaves apt
  unable to resolve (`held broken packages`), so the family is derived from the repository.

## Notes for maintainers

- `isaac_ros_visual_slam` was previously disabled with a `COLCON_IGNORE` because only the 13_0
  cuVSLAM was wired up and it could not build on 22.04. It is enabled now that cuVSLAM follows the
  same auto-selection.
- `gxf_isaac_triton` ships only a 13_0 x86_64 binary. This is harmless on 22.04: `isaac_ros_unet`
  and `isaac_ros_detectnet` depend on Triton via `exec_depend`/`test_depend` only, so nothing links
  it. The TensorRT backend (`isaac_ros_tensor_rt`) is what the ART stack uses.
- `cuapriltags` ships only a 12_6 x86_64 binary upstream, so selection falls back to it on 24.04.
- Several extensions (`gxf_isaac_tensor_rt`, `tensorops`, `camera_utils`, `image_flip`, `ros_unet`,
  `detectnet`, `gems`) are built from source and need no flavour choice — they compile against
  whichever headers were selected.
- When adding a payload flavour, drop it in `gxf/core/lib/`, add matching headers as
  `gxf/core/include_cuda_<x_y>`, and add it to the candidate list in the selection module. The link
  probe handles the rest.
