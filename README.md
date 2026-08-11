# I screwed up and mis-named this repo. You are probably looking for this one:

[nvimx296camerasrc](https://github.com/sealfoss/GStreamer-NV-IMX296-Camera-Source)


# nvimx296camerasrc

GStreamer source element for the Raspberry Pi Global Shutter Camera (Sony
IMX296) on NVIDIA Jetson Orin: **zero-copy** raw V4L2 capture + a fused CUDA
ISP using the real RPi/libcamera tuning data, outputting NV12 in
`memory:NVMM` buffers. **Bypasses Argus entirely** — no AE hunting, no TNR
smear, no untuned color, deterministic manual control of everything.

```
sensor DMA ──(V4L2 DMABUF, zero-copy)──▶ one fused CUDA kernel:
  black-level LUT → bilinear debayer (linear) → WB·CCM·digital-gain 3×3
  → tone LUT (preset/contrast/brightness/knee) → BT.601 NV12
    (+ blue-noise dither, highlight desaturation, optional 180° flip)
──▶ NvBufSurface (memory:NVMM) ──▶ nv3dsink / nvv4l2h265enc / nvjpegenc / …
```

> **Status: working, validated on hardware** (Jetson Orin NX 16GB devkit,
> JetPack 6 / L4T r36.5.0, CUDA 12.6):
> - color math **byte-exact** (≤1 LSB) against the reference Python
>   implementation of the RPi tuning pipeline (golden-tested)
> - fused kernel **≈1.35 ms/frame** at 1456×1088 (~740 fps equivalent) —
>   both sensor modes run at full rate with the GPU >90% idle and ~zero CPU
> - **60 fps** @ 1456×1088 and **90 fps** @ 1280×720 sustained, verified
>   with on-sensor control readback
> - end-to-end zero-copy: sensor DMA lands in EGL/CUDA-mapped dmabufs, the
>   kernel reads them in place, NVMM output goes downstream without copies
> - interop verified with `nvjpegenc`, `nvv4l2h265enc` (60 & 90 fps H.265),
>   `nv3dsink`, `fakesink`

## Why this exists

NVIDIA's Argus has no tuning profile for the IMX296 (tuning files are
partner-gated), so `nvarguscamerasrc` gives approximate color and an untuned
auto-exposure loop that visibly hunts (~25% brightness oscillation
measured). The RPi ecosystem ships real, measured calibration for this exact
camera (`imx296_16mm.json`: black level, CT curve, per-illuminant CCMs, tone
curve) — but no way to feed it to Argus. This element applies that
calibration where it was designed to apply (linear raw domain), on the GPU,
inside a normal GStreamer source.

## Requirements

- Jetson Orin (any variant) on JetPack 6 / L4T r36.x, CUDA 12.x
- GStreamer dev headers and `/usr/src/jetson_multimedia_api` (both stock)
- The IMX296 **sensor driver + device-tree overlay** — see the companion
  [jetson-imx296-driver][driver-repo] project (fixed exposure control, black
  line, black-level-servo flicker; provides the `preferred_stride`,
  `exposure`, `gain`, `frame_rate` V4L2 controls this element drives, and
  the 1456×1088@60 / 1280×720@90 sensor modes it negotiates)
- The RPi tuning JSON ships in this repo (`data/imx296_16mm.json`)

## Build & install (native, on the Jetson)

```bash
./install.sh          # dependency preflight -> build -> sudo install -> verify
```

(`./install.sh --help` for `--prefix`, `--plugin-dir`, `--build-only`,
`--uninstall`.) Or by hand:

```bash
mkdir -p build && cd build
cmake .. && make -j$(nproc)
sudo make install
gst-inspect-1.0 nvimx296camerasrc     # found system-wide, no GST_PLUGIN_PATH
```

`make install` puts:
- the plugin in the **system GStreamer plugin directory** (autodetected from
  `pkg-config --variable=pluginsdir gstreamer-1.0`; override with
  `cmake -DGST_PLUGIN_INSTALL_DIR=...`) — every gst app finds it with no
  environment setup;
- the RPi tuning JSON in `<prefix>/share/nvimx296camerasrc/` — compiled in
  as the element's default `tuning-file`, so pipelines need no path either;
- `imx296_kernel_test` in `<prefix>/bin/`.

Uninstall: `sudo xargs rm -v < build/install_manifest.txt`.

Running **without** installing also works: `export GST_PLUGIN_PATH=$PWD`
from the build dir — the element then falls back to the source tree's
`data/imx296_16mm.json` automatically.

## Use

```bash
# live view (display attached):
gst-launch-1.0 nvimx296camerasrc exposure=8333 gain=60 ! \
  'video/x-raw(memory:NVMM),width=1456,height=1088,framerate=60/1' ! nv3dsink

# 720p @ 90 fps H.265 recording:
gst-launch-1.0 -e nvimx296camerasrc exposure=8333 gain=80 ! \
  'video/x-raw(memory:NVMM),width=1280,height=720,framerate=90/1' ! \
  nvv4l2h265enc bitrate=20000000 ! h265parse ! matroskamux ! filesink location=clip.mkv

# tone controls, all runtime-mutable:
... nvimx296camerasrc contrast=1.2 saturation=1.3 tone-preset=tuning \
    knee-point=0.85 knee-strength=0.5 awb=auto flip=true ...
```

The negotiated caps select the sensor mode: 1456×1088 → mode0 (≤60 fps,
full array), 1280×720 → mode1 (≤90 fps, centered ROI crop — ~14% narrower
field of view, not a downscale).

Exposure guidance: **8333 µs is the only mains-flicker-immune exposure** at
any frame rate under 100/120 Hz lighting; under DC light (daylight, DC
lamps) use 2–4 ms for crisp motion and raise gain. Gain is dB×10 (0–480);
halving exposure needs about +60 gain.

## Properties

| name | range (default) | notes |
|---|---|---|
| `device` | (`/dev/video0`) | |
| `tuning-file` | path (installed JSON) | RPi imx296 tuning JSON |
| `exposure` | 15–15699 µs (8333) | sensor clamps to ~11066 in mode1 (90 fps) |
| `gain` | 0–480 dB×10 (60) | sensor analog gain |
| `tone-preset` | tuning/srgb/rec709/linear | `linear` = radiometric, for CV consumers |
| `contrast` | 0–2 (1) | S-curve about mid |
| `brightness` | −1–1 (0) | post-curve offset |
| `saturation` | 0–2 (1) | folded into the NV12 chroma matrix — free |
| `digital-gain` | 0.25–4 (1) | linear, pre-curve; fine trim between gain steps |
| `dither` | bool (true) | blue-noise at the 10→8-bit quantize (anti-banding) |
| `black-offset` | −32–32 (0) | manual pedestal trim (the driver disables the sensor's oscillating auto black-level servo; this compensates slow thermal drift) |
| `knee-point` / `knee-strength` | 0.5–1 (1=off) / 0–1 (0) | highlight shoulder |
| `tone-lut-file` | path | 1024-entry custom curve override |
| `awb` | auto/tuning/off (auto) | auto = grey-world **constrained to the calibrated CT curve** (can't be fooled toward magenta by green scenes); estimated CT also selects the CCM |
| `awb-ct` | 2000–10000 (4560) | fixed illuminant for `awb=tuning` |
| `flip` | bool (false) | rotate output 180° (upside-down mount) |
| `zero-copy` | bool (true) | force the MMAP+copy capture path with `false` (A/B/debug) |

All tone/color properties are **runtime-mutable** and nearly free: they
pre-bake on the CPU into one 3×3 matrix + two LUTs; the GPU kernel never
changes shape. Highlight handling: sensor-clipped pixels are automatically
desaturated toward white over the top ~5% of the raw range (prevents
WB-gain magenta in blown highlights; independent of the `knee-*` shoulder).

## How the zero-copy capture works

The classic obstacle (driver `bytesperline` vs allocator pitch — the reason
NVIDIA's own `nvv4l2camerasrc` carries copy-remap paths) is solved in
reverse: the element allocates a probe `NvBufSurface` first, reads the pitch
the allocator wants, and **imposes it on the VI** via the sensor driver's
`preferred_stride` control, verifying `bytesperline == pitch` after `S_FMT`.
Capture buffers are then queued to V4L2 as dmabufs (`V4L2_MEMORY_DMABUF`)
and EGL/CUDA-registered once at setup — per-frame cost is DQBUF → kernel →
QBUF. If any negotiation step fails, the element falls back automatically to
MMAP + pinned-HtoD (still fast; the copy is DMA-driven).

## Golden test

```
imx296_kernel_test <raw.bin> <tuning.json> <out.rgb> [W H STRIDE] [ct]
```

Runs the exact element kernel on a canned raw capture (as written by
`v4l2-ctl --stream-to`) and dumps interleaved RGB8, plus kernel-only timing
for the production NV12 path. The RGB path is kept math-identical to the
reference Python pipeline in the [driver repo][driver-repo]
(`scripts/imx296_isp_pipeline.py --input raw.bin --awb tuning --ct <ct>`)
for byte-level comparison — that equivalence is the element's correctness
anchor.

## Known limitations

- NV12 8-bit output only (P010 dead-ends in the stock downstream elements;
  the dither exists precisely to make the 8-bit crush invisible).
- Single element instance per sensor; two modes (1456×1088, 1280×720).
- AWB is intentionally simple (constrained grey-world + EMA); `awb=tuning`
  with a measured CT is the deterministic option.
- Do not `rmmod` the sensor driver while any camera client is running
  (NVIDIA stack race — see the driver repo's known issues).

## License

MIT (see [LICENSE](LICENSE)). Color science derived from the Raspberry
Pi / libcamera tuning data and pipeline model; NVMM buffer conventions from
NVIDIA's gst-nvv4l2camera/gst-nvarguscamera sources.

<!-- Companion-repo link: update this ONE definition when linking to the
     published driver repository. -->
[driver-repo]: https://github.com/sealfoss/jetson-orin-nano-devkit-imx296-rpi-global-shutter
