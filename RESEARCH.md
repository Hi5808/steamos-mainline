# Stock DXVK and VKD3D-Proton on RK3588 / Mali-G610 (Valhall v10 CSF) with a patched PanVK-kbase driver

Lab notebook, 2026-10-16 → 2026-10-17. All times are **HST (UTC-10)**; RK1 clock/dmesg (UTC) was converted in the source logs.
Compiled read-only from the logs on the build box on 2026-10-17 ~11:00 HST, while testing was still running. Nothing in this document was re-measured; every number comes from a file in `logs/` (cited per section).

Conventions:
- **[verified]**: measured on hardware and recorded in a log.
- **[unverified]**: written/built, or claimed, but not measured.
- **[hypothesis]**: an explanation that the logs do not prove.
- `P/F/NS/Crash` = dEQP Pass / Fail / NotSupported / Crash (assert or segfault).
- "assert" build = `-Dbuildtype=debugoptimized` with asserts and NIR validation; "ndebug" build = same source with `-Db_ndebug=true` (how release drivers ship).

Archive layout (this folder):
| Path | Contents |
|---|---|
| `RESEARCH.md` | this write-up |
| `PATCHES.md` | patch index: commit, title, purpose, proving test |
| `patches/mesa/` | 20-patch Mesa series `0001…0020` (+ `ALL-20-series.mbox` from `git format-patch 49d500b..kbase-applied`) |
| `patches/vkd3d/` | `vkd3d-0001-readback-no-host-cached-fallback.patch` |
| `logs/rock5bp/` | `kbase-20261016-2308.txt`, `sys-check.txt`, `kbase-e2e-20261017-0016.txt`, `kbase-blockers-20261017-0106.txt`, `vkd3d-20261017.txt` (the main chronological log, covers both boards), raw tarballs (qpa/stdout) |
| `logs/rk1/` | `rk1-20261017.txt`, DXVK dmesg deltas, raw tarballs |
| `logs/vkd3d-suite/` | rock5bp full D3D12 suite: `per-test.txt`, `bad.txt` |
| `scripts/` | test runners (`run_groups.py`, `runsuite.sh`, `runiso.sh`, `rkrun.sh`, `rksuite.sh`, `env.sh`, `pre-exclude.txt`), gate checker `check.py`, hang repro `noatt.c`, dEQP caselists |
| `screenshots/` | DXVK and VKD3D-Proton frames from both boards, Unigine Heaven on the RK1 |
| `reports/` | the pre-hardware research reports (web/source research, engineering map, DroidDeck gap matrix, package README) |

---

## 1. Goal

Run **unmodified upstream DXVK (D3D9/10/11) and VKD3D-Proton (D3D12)** on RK3588's Mali-G610 under x86 emulation on Linux, using an open-source Vulkan driver, and find and fix the driver bugs on the way.

Starting point (`reports/rk3588-directx-translation.md`, `reports/g610-gap-matrix.md`): mainline PanVK on v10 lacks `fillModeNonSolid`, `geometryShader`, `multiViewport`, `shaderClipDistance`, `shaderCullDistance` and `robustBufferAccess2`, so stock DXVK refuses the device; VKD3D-Proton additionally needs `robustImageAccess2`, `transformFeedbackQueries` and `storageTexelBufferOffsetSingleTexelAlignment`. The only known stack that emulates all of these on Mali v10 is the out-of-tree Android **PanVK-kbase** fork (zenithblue-oss), which had never been run on Linux, on panthor, or on Rockchip.

## 2. Hardware

| | rock-5b-plus ("rock5bp") | Turing Pi RK1, node 1 ("RK1") |
|---|---|---|
| SoC / GPU | RK3588, Mali-G610 MC4 (id 0xa867, shader_present 0x50005) | RK3588, Mali-G610 MC4 |
| RAM | 8 GB (7.6 GiB visible) | 31 GiB (~20.6 GiB available while k3s runs) |
| OS | Armbian 26.8.3 "resolute", booted from **SD card** (NVMe left untouched) | Ubuntu 24.04.1, eMMC 29 G (20 G free) |
| Kernel | 6.18.45-current-rockchip64 (mainline) | 6.1.0-1025-rockchip (Rockchip/Ubuntu vendor BSP) |
| GPU kernel driver | **panthor** 1.5.0 (uAPI < 1.7), no `/dev/mali0` | **vendor mali_kbase** CSF (fw git_sha ee476db4), `/dev/mali0`, kbase CSF uAPI 1.18, `/dev/dma_heap/{system,cma}` |
| System Mesa | 26.0.3-1ubuntu1 (baseline, untouched) | 23.0.5 panfork (untouched) |
| Display | no monitor; GNOME session locked → all tests on **Xvfb :99 1280x720** | headless; Xvfb :99 1280x720 |
| Role / caveats | primary dev board | also the cluster's internet gateway (NAT/dnsmasq) and runs k3s → a GPU wedge or reboot takes nodes 2–3 offline. Tested only after explicit user approval; all installs side by side under `/opt`. |

Sources: `logs/rock5bp/kbase-20261016-2308.txt`, `logs/rock5bp/vkd3d-20261017.txt` (08:13, 08:33 entries), `logs/rk1/rk1-20261017.txt`.

A third board, an Orange Pi 5 Plus 16 GB (vendor 6.1.0-1025, mali_kbase DDK g18p0-01eac0, libmali g24p0 ICD), got a **read-only** inventory at 08:13 HST; nothing was installed there (`vkd3d-20261017.txt`, 08:13).

## 3. Software stack and versions

| Component | Version | Notes / source |
|---|---|---|
| Mesa base | `5a07217f034b3e50d8c7c7794f97a2df1742613b` (26.3.0-devel) | base pinned by the fork's `sources.lock` (`reports/mesa-kbase-panthor-aarch64-20261016.README.md`) |
| PanVK-kbase fork | github.com/zenithblue-oss/panvk-kbase-android @ `5b87b74d3e2580d5816e7f2c629f6f016a462f28` ("RC3-lowmem") | series `common`(1) → `android`(4) → `kbase-common`(10) → `app-loader`(1) → `wsi`(2) → `csf`(2) → `csf-v11`(124), applied cleanly |
| Local tree | `mesa-full`, branch `kbase-applied`; `49d500b` = "kbase series applied" (2026-10-16 22:39 HST); head `f592c35` | our 20 fixes on top: `PATCHES.md` |
| Build | cross gcc 14.2 aarch64 on a Debian 13 host; `-Dvulkan-drivers=panfrost -Dpanfrost-kmds=panthor` (rock5bp), `panthor,kbase` (RK1, from 1304ba2 on); `-Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system`; prefix `/opt/mesa-kbase` | driverInfo "PanVK-kbase RC3-lowmem (Mesa 26.3.0-devel (git-…))", Vulkan 1.4.363 |
| VK-GL-CTS | `vulkan-cts-1.4.7.0`, cross-built `deqp-vk`, sampled caselists (`scripts/caselists/`) | |
| FEX-Emu | 2610 (ppa:fex-emu/fex). rock5bp: `fex-emu-armv8.2 2610-1~r`; RK1: the PPA's noble build `2610-1~n` extracted to `/opt/fex` (the `~r` build needs GLIBC_2.43) | Ubuntu 24.04 x86_64 SquashFS RootFS + **Vulkan host thunk** |
| Wine | 11.19 amd64-wow64 (Kron4ek build) | 64-bit apps only under FEX (see §6.8) |
| Hangover | 11.16 (Wine 11.16 arm64 + FEX `libwow64fex.dll`), noble tar from github.com/AndreRH/hangover, `dpkg -x` into `/opt/hangover/root` | RK1 only, for 32-bit Heaven |
| DXVK | 3.1.1 release DLLs (stock) | |
| dxvk-tests | `257d9e4`, built with mingw on the box | d3d11-triangle/compute/formats, d3d9-triangle, dxgi-adapters |
| VKD3D-Proton | 3.0.1 (stock), plus `vkd3d-0001` readback patch where noted | `tests/d3d12` suite = `d3d12.exe` |
| Overlay / fps | `VK_LAYER_MESA_overlay` `output_file` CSV, one sample per 0.5 s (RK1: system overlay 23.0.5) | |
| Benchmark | Unigine Heaven 4.0 (x86 32-bit), `https://assets.unigine.com/d/Unigine_Heaven-4.0.exe`, 259708359 B, sha256 `497865a09af205a7d2e8812bfc2dd54870216cc1e95541b63cef89a4433b0e5f` (= winget-pkgs manifest) | RK1 only |

## 4. Methodology

**Isolation.** All driver builds were installed side by side under `/opt` (`/opt/mesa-kbase`, `/opt/mesa-kbase-<sha>` side ICDs) and selected per process with `VK_DRIVER_FILES`; the system Mesa stayed the default on both boards. No kernel, bootloader, k3s or network change on either board. The rock5bp NVMe and its other Mesa build were not touched.

**dEQP-VK** (`scripts/run_groups.py`): resume-on-crash runner. Each group runs from a caselist; when `deqp-vk` dies it records the running case as `Crash` and restarts with the remaining cases (`restarts=` in the summary). It counts panthor `fault|reset|timeout` dmesg lines per group (`dmesg_gpu_lines`). Eight sampled groups: clipping (308), polygon-mode (84), multiviewport (212), geometry (200), tessellation (250), xfb-simple (400), robustness2 (400), depth-bounds (150).

**DXVK**: dxvk-tests under FEX + Wine on Xvfb :99 with `MESA_VK_WSI_DEBUG=sw`, 60 s (RK1) runs ended by `timeout` (`exit=124` = ran to the end), screenshots via `xwd -root` at fixed times, fps = overlay CSV mean (min–max), n = samples.

**D3D12 suite** (`scripts/runsuite.sh` rock5bp, `scripts/rksuite.sh` RK1): resumable. Each run excludes every finished or bad test (`VKD3D_TEST_EXCLUDE`); a **log-growth watchdog** kills `d3d12.exe` after `STALL` s with no output (300 s, later 150 s) and records the running test as `hang`; a non-zero exit without stall = `crash`.

**Memory caps / watchdogs.**
- rock5bp until 04:07: no cap (→ §9 OOM lockup).
- rock5bp from 07:47: transient systemd unit `MemoryMax=4608M, MemorySwapMax=512M`, STALL=150.
- rock5bp isolation runs (`scripts/runiso.sh`): one test per transient unit with the same caps; counts panthor "job timeout" lines.
- RK1 (`scripts/rkrun.sh`): every GPU test in a transient system unit `MemoryMax=16G, MemorySwapMax=0, RuntimeMaxSec`, log-growth stall watchdog, dmesg delta; risky D3D12 tests one at a time (`rkiso.sh`, 200 s cap) with a dEQP `api.smoke.triangle` health check after each, stop if unhealthy. 28 rock5bp-risky tests (`scripts/pre-exclude.txt`) were pre-excluded from the RK1 bulk run.

**Offline gate check** (`scripts/check.py`): reads `vulkaninfo` JSON and evaluates DXVK `227b83b3`'s 56 required items and VKD3D-Proton `0bb64c56`'s 23 device-creation gates.

## 5. Timeline (HST)

| Time | Event | Source |
|---|---|---|
| 10-16 22:26–23:00 | Web/source research, engineering map, DroidDeck/Turnip gap matrix written | `reports/` |
| 10-16 22:39 | `49d500b` fork series applied on Mesa 5a07217f | git |
| 10-16 23:04–23:08 | First board run (rock5bp, panthor): BC1–BC7 native; gate check DXVK 56/56, VKD3D 23/23 with kbase vs 50/56, 19/23 system Mesa | `kbase-20261016-2308.txt` |
| 23:31 / 23:45 / 23:52 | Fixes 0001 `de2237b`, 0002 `19cfc8b`, 0003 `256c5fd` | git, `kbase-e2e…` |
| ~23:47 | dEQP rerun started (time from the chat log, not a file) | parent conversation |
| 10-17 00:15 | dEQP + DXVK end-to-end report: DXVK D3D11/D3D9 render on G610 | `kbase-e2e-20261017-0016.txt` |
| 00:22–00:59 | Fixes 0004–0013 (clip/cull through GS/TCS, TES, XFB, ViewportIndex, VB size, barriers) | git |
| ~01:02–01:07 | Before/after dEQP on `d5e258e`: clipping 308/308, multiviewport 212/212, no asserts | `kbase-blockers-20261017-0106.txt` |
| 01:17 | D3D12 caps: FL 11_1, SM 6.0 on stock VKD3D-Proton | `vkd3d-20261017.txt` |
| 01:33 | Bug: READBACK heap E_OUTOFMEMORY → `vkd3d-0001` | same |
| 01:38 | Bug: no present with present_timing → workaround; full D3D12 suite started | same |
| 01:41 | 0014 `b2e12f7` present-timing WSI fix (staged, untested on rock5bp) | same |
| 02:10–02:49 | Suite hangs/crashes accumulate (127 → 211 tests) | same |
| 02:49 / 02:53 | 0015 `95a35d6` timestamp NONE, 0016 `1304ba2` bbox clamp | same |
| 02:56 | Last good contact with rock5bp; sshd stops answering | same |
| 02:58:52 | run20 starts `test_stress_fallback_render_target_allocation_device` (allocates until failure) | same |
| 03:22 | Agent stops retrying; board needs a power cycle | same |
| 04:06:57 / 04:07 | OOM kill of the test; FEXServer gone; runner FINISHED | same (from SD-card files) |
| ~07:42 | Manual reboot by the user | same |
| 07:47 | Suite resumed in a 4608M unit from run22 | same |
| 08:13 | Orange Pi 5 Plus read-only inventory | same |
| 08:24 | rock5bp D3D12 suite done: 545 tests, 485 PASS | same |
| ~08:31 | RK1 reboots (Wi-Fi overlay work by another agent; uptime 2 min at 08:33) | `rk1-20261017.txt` |
| 08:31–08:55 | rock5bp isolation: 0015 fixes all 7 assert crashes; 0016 does **not** fix the no-attachment hang | `vkd3d-20261017.txt` |
| 08:37–08:48 | RK1 driver built with `panthor,kbase`, `vulkaninfo` OK via `/dev/mali0` | `rk1-20261017.txt` |
| 08:49 | Bug: dma-heap incoherence on kbase (dEQP mass miscompares, smoke 2/8) | same |
| 08:55 | RK1 dEQP with dma-heap disabled = identical to rock5bp panthor | same |
| 09:02 | 0017 `512908d` dma-heap coherence probe | git |
| 09:10 | FEX Vulkan thunk activated on RK1 (ThunksDB.json location) | same |
| 09:16 | RK1 DXVK results | same |
| 09:25 | RK1 VKD3D-Proton results; 0014 present-timing fix verified | same |
| 09:33 | Root cause of the no-attachment hang (layered tiler contexts) | `vkd3d-20261017.txt` |
| 09:34 | RK1 D3D12 bulk run (phase A): 1 run, 437 s, no crash/stall | `rk1-20261017.txt` |
| 09:39 / 09:41 | 0018 `421748d` tiler bin budget; 6 hangs fixed on rock5bp | same |
| 09:51 | 0019 `964e4f2` OOB index fetch (stream-output fault) | git |
| 09:58 | Risky tests update both boards | `rk1-20261017.txt` |
| 10:49 | 0020 `f592c35` WC dumb-buffer dma-bufs (WoW64 placed maps) | git |
| ~10:53–10:58 | Unigine Heaven 4.0 rendering on RK1 (t=231 s frame), ~1.7 fps | `rk1-20261017.txt`, `screenshots/rk1-heaven/` |

## 6. Driver and stack bugs found

Numbers are "before → after" on the same board/test. Commit = `mesa-full` `kbase-applied`; patch numbers = `patches/mesa/00NN-*.patch`.

### 6.1 Fork bugs exposed on panthor by dEQP (0001–0003)
| # | Symptom | Root cause | Fix | Verification |
|---|---|---|---|---|
| 0001 `de2237b` | Depth-bounds fragment-shader robustness state hit `UNREACHABLE` for `DEVICE_DEFAULT` (per commit title) | robustness state for the depth-bounds FS not handled | sets the state | depth-bounds 115P/35NS (ndebug, 256c5fd). **Pre-fix numbers for this specific crash were not logged** (49d500b depth-bounds exited rc=0) |
| 0002 `19cfc8b` | At 49d500b (assert) groups clipping…robustness2 **aborted on their first test**, rc=134 | `panvk_gpu_prerast_lower_vs_outputs` adds control flow but preserved CF metadata → NIR validation failure | don't preserve CF metadata | 19cfc8b: clipping 102P/14F/192Crash, multiviewport 72P/60F/80Crash, geometry 196 Crash (now runs, next assert) |
| 0003 `256c5fd` | geometry 196/200 Crash at 19cfc8b | `pan_nir_lower_mediump_io` run on GS/TCS stages | only VS/FS | geometry 194P/2Crash/4NS (assert), 196P/4NS (ndebug) |

Source: `logs/rock5bp/kbase-e2e-20261017-0016.txt`.

### 6.2 Clip/cull, tessellation, XFB, ViewportIndex (0004–0011)
| # | Symptom | Root cause | Verification (assert build) |
|---|---|---|---|
| 0004 `8a4d08d` | asserts turning GS/TCS into compute kernels | dead arrayed I/O vars survived | clipping 126P/54F/128Crash |
| 0005 `d93bf5d` | compact arrayed vars survived TES→VS switch | DCE needed before dropping dead TES inputs | clipping 176P/68F/64Crash |
| 0006 `055b5ae` | 128 clipping "Rendered image(s) are incorrect" in every `vert_geom*`/`vert_tess_geom*` combo | VS/TES pack clip/cull into clip0/1+cull0/1, but GS/TCS read/wrote the merged layout | clipping 202P/14F/92Crash (ndebug 252P/16F/40Crash) |
| 0007 `1c72ff4` | tessellation asserts (BASE_INSTANCE) | nested indirect TES draw didn't re-dirty BASE_INSTANCE | tessellation d93bf5d 106P/85Crash/59NS → 191P/59NS at f8efd00 (with 0008) |
| 0008 `cc29184` | `psiz->num_components == 1` assert | passthrough VS stored every slot as vec4 | (same as 0007) |
| 0009 `f8efd00` | FS reading `gl_CullDistance` got 0.0; stale use-lists (nir_validate) | CULL_DIST varyings carry is-negative flags, not raw values | clipping **308/308** assert+ndebug |
| 0010 `778956f` | every XFB case with a GS kernel aborted (assert) | GS compute kernel kept `xfb_info` | xfb-simple f8efd00 20P/234Crash/146NS → 254P/146NS |
| 0011 `f144ee7` | 60 multiviewport `fragment_shader` Fail ("Rendered image is not correct") | prerast passthroughs consumed ViewportIndex and never wrote it as a varying | multiviewport 152P/60F → **212/212** |

Costs [from the commit messages / design]: shaders that write cull distances now use extra internal varying slots (raw cull vec4s in BOUNDING_BOX0/1); ViewportIndex uses the otherwise unused FOGC slot.
Source: `logs/rock5bp/kbase-blockers-20261017-0106.txt`.

### 6.3 Vertex buffer size and barriers (0012–0013)
- **0012 `af71cfc`**: vertex straddling the end of the range returned partial data instead of (0,0,0,1); HW checks bytes, Vulkan requires whole strides. Spec-correct, but **did not change** the 2 robustness2 failures.
- **0013 `d5e258e`**: VS-with-stores runs as a gpu_prerast compute kernel on the COMPUTE subqueue, but pre-raster barriers only waited on vertex/tiler; also the tiler self-wait was dropped while COMPUTE waited on it (`emit_barrier_csf` assert `wait_sb_mask`). Removed that assert (robustness2 assert build: 2 Crash → 2 Fail). Cost [design inference]: barriers wait on COMPUTE when emulation is active, which may cost draw-heavy content; **not measured**.

### 6.4 VKD3D-Proton READBACK memory (vkd3d-0001) — panthor only
- Symptom: `test_clear_render_target_view` and `test_draw_instanced` "Failed to create buffer, hr 0x8007000e" then hang (exit 124).
- Root cause: on panthor uAPI < 1.7 PanVK exposes only `[0] DL`, `[1] DL|HV|HOST_COHERENT`; `PAN_KMOD_BO_FLAG_WB_MMAP` needs panthor uAPI ≥ 1.7 (`DRM_PANTHOR_BO_WB_MMAP`). vkd3d's suballocator asks for `HV|HOST_CACHED` for READBACK with no fallback.
- Fix (userspace workaround): `patches/vkd3d/vkd3d-0001` drops HOST_CACHED when no such type exists.
- Verified: `test_clear_render_target_view` 735 executed / 0 failures; `test_draw_instanced` 20 / 0. Proper fix: newer kernel (panthor uAPI 1.7+) or a backport. On kbase the bug doesn't apply (stock DLLs triangle renders on RK1, §8).
Source: `vkd3d-20261017.txt` 01:33, 01:58.

### 6.5 Present timing on the X11 software path (0014 `b2e12f7`)
- Symptom: with `VK_EXT_present_timing` enabled, the D3D12 swapchain never presents (0 fps rows, black, exit 137/3); vkd3d fixme "ID correlation list filled … present timing requests not properly returned".
- Workaround: `VKD3D_DISABLE_EXTENSIONS=VK_EXT_present_timing`.
- Fix: wsi/x11 reports present-timing completions on the sw (XPutImage/MIT-SHM) path.
- Verified **on RK1 only**: triangle with present_timing enabled 687.0 fps (593.1–737.7, n=18), renders. **Not separately verified on rock5bp** (all rock5bp suite/isolation runs kept the workaround).

### 6.6 CmdWriteTimestamp2 with STAGE_2_NONE (0015 `95a35d6`)
- Symptom: 7 suite crashes (exit=1) on assert `util_bitcount64(vk_stage) == 1` in `vk_stage_to_timestamp_subqueue_mask` (vkd3d `init_query_heap`).
- Fix: map NONE → TOP_OF_PIPE.
- Verified (rock5bp isolation, 1304ba2 assert): `query_timestamp` 20/0, `query_timestamp_write_after_read` 31/0, `resolve_non_issued_query_data` 21/0 (2 todo), `render_pass_suspend_resume_opts_{enabled,inline_clears,disabled}` 547/0 each, `execute_indirect_state_predication` 1572 executed / **8 fail** (no longer crashes).

### 6.7 Attachment-less / layered pass GPU hang (0016 ineffective → 0018 `421748d`)
- Symptom: `draw_uav_only`, `null_rtv`, `atomic_instructions_dxbc/_dxil`, `rendering_no_attachments_layers`, `unused_attachments_mix_and_match` time out (2–3 panthor job timeouts each); on kbase the test stalls with nothing in dmesg.
- First hypothesis (0016 `1304ba2`, 02:53): vkd3d sets renderArea 32768×32768 and 256 layers for attachment-less passes; clamp RUN_FRAGMENT bbox. **Disproved**: all 6 still hang at 150 s with 1304ba2 (08:55). 0016 is still in the tree; whether to drop it is open.
- Root cause (native repro `scripts/noatt.c`, 09:33): hangs iff render area is large **and** layerCount high (e.g. HANG 4096²×7, 32768²×8; OK 32768²×1..4, 2048²×256). Atomics irrelevant. `PANVK_TILER_BIN_BUDGET` 512K/256K still hang, 128K/64K pass → the tiler bin-pointer budget (a whole heap chunk per layer) is too big for layered tiler contexts (up to 8 layers per context on v10).
- Fix 0018: budget = (chunk_size−64)/min(layers,8), capped at 128 KiB when layers>1 (plain division alone still hung).
- Verified rock5bp: every repro case passes (32768²×256 in 16.7 ms, 1000000 count correct); `draw_uav_only` 21/0, `null_rtv` 20/0, `atomic_instructions_dxbc` 159/0, `_dxil` 160/0, `rendering_no_attachments_layers` 1040/0, `unused_attachments_mix_and_match` 5227/0, 0 job timeouts. RK1: same tests pass, plus `map_placed_resources` 44/0, `tessellation_read_tesslevel` 53/0, `line_tessellation_dxbc` 87/0, `_dxil` 88/0.

### 6.8 kbase dma-heap incoherence (0017 `512908d`) — kbase only
- Symptom (RK1, default env): massive dEQP miscompares, no GPU faults: clipping 189P/119F, multiviewport 4P/208F, depth-bounds 0P/115F/35NS, geometry 8P/188F/4NS, xfb 237P/17F/146NS, tessellation 129P/62F/59NS; `api.smoke` 2/8.
- Root cause: every non-exec BO came from `/dev/dma_heap/system` and was imported with COHERENT_SYSTEM; kbase strips it (flags 0x4040f → 0x4500f) because RK3588's GPU isn't IO-coherent, while the dma-buf CPU mapping stays cacheable and no `DMA_BUF_IOCTL_SYNC` is issued.
- Workaround: `PANVK_KBASE_DMA_HEAP=/nonexistent` → smoke 8/8 and dEQP identical to rock5bp panthor (§7).
- Fix 0017: probe the first dma-heap import; fall back to native kbase allocations when coherence is stripped (warns once). `PANVK_KBASE_DMA_HEAP_FORCE=1` = old behaviour. Verified: smoke 8/8 assert+ndebug with the default heap.

### 6.9 Stream-output GPU fault: OOB software index fetch (0019 `964e4f2`)
- Symptom: `index_buffer_edge_case_stream_output` stall; kbase dmesg "Unhandled page fault AS1 VA 0x1000 TRANSLATION_FAULT … READ" → CS_BUS_FAULT ×3 → DEVICE_LOST; panthor CS_FATAL.
- Root cause: `CmdBindIndexBuffer2(NULL)` binds dev_addr 0x1000 size 0 on v10+; the software vertex pull (`panvk_poly_load_raw_vertex_id`) clamped OOB ids to 0 but still loaded element 0 at 0x1000.
- Fix: load from `PAN_SHADER_OOB_ADDRESS` when OOB.
- Verified rock5bp (ndebug side ICD): `index_buffer_edge_case_stream_output` 49/0 (19 s, 0 job timeouts), `vertex_shader_stream_output_dxbc` 35/0, `primitive_restart_list_topology_stream_output` 47/0. **Not yet re-run on RK1.**

### 6.10 Placed memory maps on kbase for 32-bit WoW64 (0020 `f592c35`) — kbase only
- Symptom: DXVK x32 under Hangover WoW64: "kbase: placed map of a non-dma-buf BO is not supported" → `VK_ERROR_MEMORY_MAP_FAILED` (winevulkan needs `VK_EXT_map_memory_placed` below 4 GiB).
- Root cause: after 0017, BOs are native SAME_VA kbase allocations; kbase `get_unmapped_area` rejects MAP_FIXED and address hints.
- Fix: BOs without an exclusive VM come from a rockchip-drm dumb buffer (`PANVK_KBASE_WC_DRM`, default `/dev/dri/card0`), exported via PRIME and imported into kbase; rockchip-drm maps dumb buffers write-combined, so no cache maintenance is needed and MAP_FIXED works.
- Verified: dEQP smoke 8/8 (RK1 "fix20" ICD = 964e4f2 + f592c35, ndebug; lib reports git-964e4f2a5c because it was built before the commit). Heaven (32-bit) renders with it (§8.4).

### 6.11 Non-driver issues
| Issue | Fix / workaround | Source |
|---|---|---|
| Wayland vkcube: compositor rejects AFBC swapchain dmabuf ("failed to import supplied dmabufs") | `PANVK_DEBUG=wsi_no_afbc` (or `noafbc`) | `kbase-20261016-2308.txt` |
| Locked GNOME session caps presents at 1 fps | Xvfb :99 + `MESA_VK_WSI_DEBUG=sw` | `kbase-e2e…` |
| DXVK D3D9 finds 0 adapters under Xvfb | `DXVK_CONFIG='d3d9.enumerateByDisplays = False'` | `kbase-e2e…` |
| RK1: driver fails to load | install `libxcb-randr0`, `libxcb-keysyms1` | `rk1-20261017.txt` |
| RK1: FEX Vulkan thunk inactive (guest loader tried to dlopen the aarch64 ICD → "Failed to create Vulkan instance") | copy `ThunksDB.json` into a FEX *config* dir (`$HOME/.fex-emu/`) | `rk1-20261017.txt` |
| RK1: `wineboot -i` hung >300 s (mono/gecko prompt on Xvfb) | `wineboot -u` with `mscoree,mshtml=` disabled (50 s) | `vkd3d-20261017.txt` 09:05 |
| x86_64 Wine 11.19 wow64 cannot start any 32-bit exe under FEX (syswow64 empty, i386 loader segfault) | Hangover 11.16 (ARM64 Wine + `libwow64fex.dll`). [hypothesis] FEX's Linux frontend doesn't emulate the far jump to a 32-bit code segment that new-WoW64 needs | `rk1-20261017.txt` |
| Heaven shaders fail with Wine's builtin d3dcompiler_42 ("E5017 … SM4 half multiplication") | `WINEDLLOVERRIDES=d3dcompiler_42,d3dx11_42,d3dx9_42=n` (use the DLLs shipped in Heaven's bin) | `rk1-20261017.txt` |

## 7. dEQP-VK results (sampled caselists, VK-GL-CTS 1.4.7.0)

### 7.1 rock5bp, panthor — before and after
| group (total) | 49d500b assert | 19cfc8b assert | 256c5fd assert | 256c5fd ndebug | d5e258e assert | d5e258e ndebug |
|---|---|---|---|---|---|---|
| clipping (308) | abort rc=134 | 102P/14F/192Crash | 102P/14F/192Crash | 180P/128F | **308P** | **308P** |
| polygon-mode (84) | abort | 1P/3Crash/80NS | 2P/2Crash/80NS | 4P/80NS | 4P/80NS | 4P/80NS |
| multiviewport (212) | abort | 72P/60F/80Crash | 88P/60F/64Crash | 152P/60F | **212P** | **212P** |
| geometry (200) | abort | 196Crash/4NS | 194P/2Crash/4NS | 196P/4NS | 196P/4NS | 196P/4NS |
| tessellation (250) | abort | not run | not run | 191P/59NS | 191P/59NS | 191P/59NS |
| xfb-simple (400) | abort | not run | not run | 254P/146NS | 254P/146NS | 254P/146NS |
| robustness2 (400) | abort | not run | not run | 167P/2F/231NS | 167P/2F/231NS | 167P/2F/231NS |
| depth-bounds (150) | rc=0 | not run | not run | 115P/35NS | 115P/35NS | 115P/35NS |

`dmesg_gpu_lines` = 0 in every group, every build. No asserts in any assert-build stdout at d5e258e.
Sources: `logs/rock5bp/kbase-e2e-20261017-0016.txt`, `logs/rock5bp/kbase-blockers-20261017-0106.txt`; raw qpa/stdout in `logs/rock5bp/*.tgz`.

NotSupported reasons (ndebug 256c5fd): polygon-mode needs meshShader / EDS3 polygonMode / polygonModePointSize; tessellation needs shaderFloat64 (54) or shader_object (5); xfb-simple needs >4 streams / >4 buffers; robustness2 needs ray tracing (115), an exclusive compute queue (56), MSAA storage images (20), STORAGE_READ_WITHOUT_FORMAT (15); depth-bounds D16_UNORM_S8_UINT (34); geometry maxGeometryShaderInvocations < 127 (4). (`kbase-e2e…`)

### 7.2 RK1, vendor kbase
| group | default env (1304ba2 assert, dma-heap on) | `PANVK_KBASE_DMA_HEAP=/nonexistent`, assert = ndebug | rock5bp panthor d5e258e |
|---|---|---|---|
| clipping | 189P/119F | 308P | 308P |
| polygon-mode | 4P/80NS | 4P/80NS | 4P/80NS |
| multiviewport | 4P/208F | 212P | 212P |
| depth-bounds | 0P/115F/35NS | 115P/35NS | 115P/35NS |
| robustness2 | 167P/2F/231NS | 167P/2F/231NS | 167P/2F/231NS |
| geometry | 8P/188F/4NS | 196P/4NS | 196P/4NS |
| xfb-simple | 237P/17F/146NS | 254P/146NS | 254P/146NS |
| tessellation | 129P/62F/59NS | 191P/59NS | 191P/59NS |
| api.smoke | 2/8 | 8/8 | — |

All runs in 16G units; no GPU faults, no stalls. After 0017 the default env gives smoke 8/8; the full groups were not re-run on the 0017 build in the logs (they were run with the env workaround, which takes the same allocation path). Source: `logs/rk1/rk1-20261017.txt`, `vkd3d-20261017.txt` 08:49–08:55.

### 7.3 The 2 robustness2 failures
`vertex_attribute_fetch` rg32f len_20 and r32i null_descriptor fail on both boards. Full CTS filter `*vertex_attribute_fetch*` on d5e258e ndebug: 374 cases, 12 Pass / 294 Fail / 68 NotSupported; only fully in-bounds r32 cases pass. The earlier "(0,0,0,0) vs (0,0,0,1) alpha" hypothesis is **ruled out**: OOB fetches return non-zero data, i.e. no effective bounds check, in the gpu_prerast compute-VS path. **Open, parked.** Source: `vkd3d-20261017.txt` first entry.

## 8. DXVK and VKD3D-Proton results

### 8.1 DXVK 3.1.1 on rock5bp (panthor)
| test | build | result | fps mean (min–max), n |
|---|---|---|---|
| d3d11-triangle | de2237b assert | FL 11_1, renders, exit 124 | 123.8 (59.9–196.8), 136 |
| d3d11-triangle | 256c5fd assert | FL 11_1, exit 124 | 115.1 (59.7–171.3), 124 |
| d3d11-triangle | d5e258e assert | FL 11_1 | 126.8, 91 rows |
| d3d9-triangle | de2237b assert | renders (needs DXVK_CONFIG, §6.11) | 629.9 (436.7–712.5), 107 |
| d3d9-triangle | d5e258e assert | | 612.8, 76 rows |
| d3d11-compute | de2237b assert | FL 11_0 | 336.5 (263.9–360.0), 107 |
| d3d11-compute | d5e258e assert | FL 11_0 | 338.6, 75 rows |
| d3d11-formats | 256c5fd | exit 0, FL 11_1; TiledResourcesTier 0, ROVs 0, ConservativeRaster 0, FP64 0, TypedUAVLoadAdditionalFormats 1, VPAndRTArrayIndexFromAnyShaderFeedingRasterizer 1 | — |
| dxgi-adapters | 256c5fd | Mali-G610 MC4, vendor 0x13b5, 6114246656 bytes, DISPLAY1 1280x720 | — |
| d3d11/d3d9 on **system Mesa 26.0.3** | — | refused: "Device does not support required feature 'fillModeNonSolid'"; black | — |

No new panthor dmesg during DXVK runs. Sources: `kbase-e2e-20261017-0016.txt`, `kbase-blockers-20261017-0106.txt`. Screenshots: `screenshots/rock5bp-dxvk/`, `screenshots/rock5bp-dxvk-d5e258e/`.

### 8.2 DXVK 3.1.1 on RK1 (kbase, ICD dmafix assert, 60 s runs)
| test | RK1 fps mean (min–max), n | rock5bp |
|---|---|---|
| d3d11-triangle (FL 11_1) | 41.1 (30.1–52.0), 56 | 123.8 / 115.1 — **3× slower on kbase, unexplained** |
| d3d9-triangle | 859.6 (784.1–933.4), 51 | 629.9 |
| d3d11-compute (FL 11_1) | 411.5 (381.2–448.9), 58 | 336.5 |
| dxgi-adapters / d3d11-formats | exit 0; FL 11_1, Tiled 0, CR 0 | same |

GPU fault during the d3d9-triangle window, 09:14:12: `CS_FATAL.EXCEPTION_TYPE: 0x41 (CS_UNRECOVERABLE)`, "queue not bound when handling fatal event", soft reset, "Reset complete"; GPU not wedged, fps steady, next 3 runs fine. **Cause unknown.** Note: d3d11-compute reports FL 11_1 on RK1 vs 11_0 on rock5bp; not investigated. Source: `logs/rk1/rk1-20261017.txt`; screenshots `screenshots/rk1-dxvk/*/shot-35s.png` (20 s shots of d3d11-triangle are black, app not up yet).

### 8.3 VKD3D-Proton 3.0.1
**Caps** (both boards, stock): MaxFL 0xb100 (**11_1**), HighestSM 0x60 (**6.0**), ResourceBindingTier 3, HeapTier 2, Tiled 0, ROV 0, CR 0, FP64 0, MinPrecision 2, WaveOps 1 lanes 16–16, TotalLaneCount 512, Int64 1, RT 0, Mesh 0, VRS 0, Native16 0. With `VKD3D_FEATURE_LEVEL=12_2` it reports 12_2 / SM 6.5 — **spoofed, not real**. `test_create_device` 19/0.

| run | rock5bp (640x480, 40 s, mean fps) | RK1 (40 s; first frame after 20–35 s under FEX, n≈17) |
|---|---|---|
| triangle stock DLLs, present_timing off | 546.6 (55 rows) | 683.4 (654.8–711.6), n=18 |
| triangle patched, assert | last 560.5/559.2 (tri-A) | 678.2 (579.6–710.8), n=17 |
| triangle patched, ndebug | 575.6 (67 rows) | 693.2 (563.8–748.9), n=16 |
| triangle patched, present_timing **on** | black, 0 rows (bug §6.5) | 687.0 (593.1–737.7), n=18 (0014 works) |
| gears patched, assert | 804.4 (66 rows) | 1109.3 (727.9–1311.8), n=17 |
| gears patched, ndebug | 825.7 (64 rows) | 987.1 (777.2–1211.0), n=18 |

Sources: `vkd3d-20261017.txt` 01:17–01:46, `rk1-20261017.txt` 09:25. Screenshots: `screenshots/rock5bp-vkd3d/`, `screenshots/rk1-vkd3d/`.

### 8.4 Unigine Heaven 4.0 (RK1, in progress at time of writing)
- Stack: Hangover 11.16 WoW64 prefix, DXVK 3.1.1 x32, ICD fix20 (964e4f2 + f592c35, ndebug), D3D11 1280x720 windowed, QUALITY_MEDIUM, TESSELLATION_NORMAL, AA off, `-extern_define PHORONIX` (auto-benchmark), in a 16G unit with a 300 s framebuffer/log stall watchdog.
- At t=231 s it was rendering the Heaven scene (`screenshots/rk1-heaven/now-t231.png`, 1/4 scale); a black rectangle is visible lower right.
- Later live frame `screenshots/rk1-heaven/heaven-now-1.7fps.png` (10:57 HST): Heaven's FPS counter shows **1.7**, DXVK HUD ~2. No GPU faults reported in the chat at that time. **No benchmark score, average fps, or tessellation-off run is in the logs yet.**
- [hypothesis] slowness from emulated tessellation running as compute and/or software presentation (`MESA_VK_WSI_DEBUG=sw` on Xvfb); untested.

## 9. D3D12 suite (VKD3D-Proton 3.0.1 `tests/d3d12`)

### 9.1 rock5bp full suite (vkd3d-0001 DLLs, assert ICD d5e258e, present_timing disabled, 36 runs 01:38–08:23 incl. the 02:58–07:45 outage)
| total | PASS | FAIL | HANG | CRASH | skipped |
|---|---|---|---|---|---|
| 545 | 485 (89%) | 25 | 26 | 8 | 1 (`stress_suballocation_rebar`, OOM risk) |

Crashes: 7 × timestamp assert (fixed by 0015), 1 × OOM (`stress_fallback_render_target_allocation_device`, §10).
Hangs by category:
| category | tests | status after fixes (§9.3) |
|---|---|---|
| no / unused color attachment (6) | draw_uav_only, null_rtv, atomic_instructions_dxbc/_dxil, rendering_no_attachments_layers, unused_attachments_mix_and_match | **fixed** by 0018 (both boards) |
| stream output (4) | index_buffer_edge_case_stream_output, vertex_shader_stream_output_dxbc/_dxil, primitive_restart_list_topology_stream_output | pass with 0018 except index_buffer_edge_case (fixed by 0019 on rock5bp) |
| tessellation (3) | tessellation_read_tesslevel, line_tessellation_dxbc/_dxil | pass on RK1 fix18 |
| sampler feedback (3) | implicit_lod, _bias, _aniso | pass on rock5bp fix18b; `_aniso` **stalls on RK1** fix18 |
| derivatives (2) | derivative_hoisting_dxbc/_dxil | dxbc 22/0 (RK1), exit 137 on rock5bp; dxil **2/22 fail** both |
| stress/alloc (2) | stress_suballocation, _multithread | pass on RK1 (27022/0, 216005/0); exit 124 at 150 s cap on rock5bp |
| other (6) | map_placed_resources, execute_indirect_state, vbv_stride_edge_cases, fence_wait_robustness_shared, dynamic_index_strip_cut, vs_instance_input_nonuniform_workarounds | map_placed 44/0, strip_cut 36/0, vs_instance 35/0; execute_indirect_state **139/267 fail** (no hang); vbv_stride **18/120 fail**; fence_wait_robustness_shared **stalls on both** |

Top FAIL (failed checks): fence_ping_pong_deadlock_stress_shared 32754, suballocate_small_textures_size 9586, fence_pending_signal_cpu_rewind_shared 320, undefined_structured_raw_read_typed_dxil/_dxbc 305 each, multisample_resolve_formats 96, renderpass_resolve_suspend_resume 40, sampler_rounding 25, execute_indirect_multi_dispatch_root_descriptors 16, instance_id_dxil/_dxbc 12 each, execute_indirect_multi_dispatch_root_constants 8, others ≤ 7.
Sources: `vkd3d-20261017.txt` 08:24, `logs/vkd3d-suite/per-test.txt`, `logs/vkd3d-suite/bad.txt`.

### 9.2 RK1 bulk run, phase A (dmafix ICD, 28 risky tests pre-excluded)
One run, 437 s, no crash, no stall, no mali faults. "23340997 tests executed (10449 failures, 369 successful todo, 206 skipped, 465 todo, 0 bugs)"; 516 tests ended, 25 with failures (same top list as rock5bp, plus small ones: undefined_structured_raw_alias, virtual_queries, multisample_resolve_strongly_typed, line_rasterization, execute_indirect_state_vbo_offsets, null_vbv, *_queue_depth_stencil_msaa, …). The rock5bp shared-fence failures (32754, 320) **pass on RK1**; the 7 timestamp crashes don't occur (0015 in build). Source: `rk1-20261017.txt` 09:34.

### 9.3 Risky tests after the fixes (one per unit)
RK1 fix18 (09:43–10:58): draw_uav_only 21/0, map_placed_resources 44/0, null_rtv 20/0, atomic_instructions 159/0 & 160/0, execute_indirect_state 267/139 fail, tessellation_read_tesslevel 53/0, line_tessellation 87/0 & 88/0, vertex_shader_stream_output 35/0 & 36/0, primitive_restart_list_topology_stream_output 47/0, stress_suballocation 27022/0, _multithread 216005/0, stress_fallback_render_target_allocation_device 2055/0, stress_suballocation_rebar 10247/0, vbv_stride_edge_cases 120/18 fail, rendering_no_attachments_layers 1040/0, dynamic_index_strip_cut 36/0, sampler_feedback_implicit_lod 4119/0, _bias 4119/0, vs_instance_input_nonuniform_workarounds 35/0, derivative_hoisting_dxbc 22/0, _dxil 22/2 fail, unused_attachments_mix_and_match 5227/0. Still hanging on RK1 fix18: index_buffer_edge_case_stream_output (GPU recovered; fixed by 0019 on rock5bp), fence_wait_robustness_shared (9 "Test failed" before the stall), sampler_feedback_implicit_lod_aniso. All health checks passed.
rock5bp fix18b/964e4f2: see §6.7, §6.9 and the table above. Source: `rk1-20261017.txt` 09:43, 09:58, 10:58.

**Not done yet:** a full-suite re-run with 0015–0020 combined on either board.

## 10. kbase vs panthor differences (same 1304ba2 build)
| | panthor (rock5bp, 6.18.45, uAPI < 1.7) | vendor kbase (RK1, 6.1.0-1025, CSF uAPI 1.18) |
|---|---|---|
| Memory types | 2: [0] DL, [1] DL\|HV\|HCOH — **no HOST_CACHED** | 3: [0] DL, [1] DL\|HV\|HCOH, [2] DL\|HV\|HOST_CACHED (non-coherent) |
| Heap / budget | budget 4.71 GiB (vkd3d earlier saw a 5.69 GiB DEVICE_LOCAL heap on 7.6 GiB RAM) | 23.27 GiB heap, budget 18.15 GiB |
| deviceID | 0xa8670005 | 0xa8670000 |
| Device extensions | 185 | 184 (only VK_AMD_anti_lag missing; [hypothesis] vulkaninfo/loader 1.3.275, not the driver) |
| Limits | 32768×32768×256 FB, subgroup 16, timestampPeriod 41.6667 | same |
| Generic BO allocation | panthor GEM | dma-heap import is **incoherent** on RK3588 → 0017 native allocs, 0020 WC DRM dumb buffers for exportable/placed BOs |
| Placed maps (`VK_EXT_map_memory_placed`) | works | native SAME_VA cannot be placed → 0020 |
| vkd3d READBACK | needs `vkd3d-0001` | stock DLLs work |
| Hang reporting | panthor "job timeout" in dmesg | stalls silently; page faults logged as TRANSLATION_FAULT / CS_BUS_FAULT |
| Shared fences in d3d12 suite | 2 tests fail heavily | pass |
| Benign log noise | — | "mali fb000000.gpu: Unknown ioctl 0xc010640c nr:12" (DRM GET_CAP on the kbase fd) per device open |
| dEQP sampled groups | identical results once the dma-heap path is fixed | |

Sources: `rk1-20261017.txt` 08:48, `vkd3d-20261017.txt` 01:33, 01:58, 07:45.

## 11. Incident: rock5bp lockup (02:56–07:42)
- **Symptom:** from 02:56 ping OK and TCP:22 accepted, but sshd never sent a banner (18+ attempts); no serial console or remote power → manual power cycle by the user at ~07:42.
- **Lost evidence:** the kernel log of that boot is gone; journal not persistent (`/var/log.hdd/journal` empty), `/var/log` is armbian-ramlog zram (last sync 00:07).
- **Cause, reconstructed from suite files on the SD card:** run18/run19 (`stress_suballocation`, `_multithread`) hung and were killed; run20 started 02:58:52 `test_stress_fallback_render_target_allocation_device`, which allocates until failure ("DRM_IOCTL_PANTHOR_BO_CREATE failed (err=12)", repeated "Failed to create heap, hr 0x8007000e") and ran **68 min** until "Killed" at 04:06:57 (OOM kill; no watchdog stall file, because it kept logging). PanVK reports a 5.69 GiB DEVICE_LOCAL heap on 7.6 GiB of RAM shared with Wine+FEX → system RAM exhausted, thrashing into zram swap → sshd stall. run21 (04:07) found FEXServer killed by the OOM too → runner aborted. **Not a GPU hang** (the earlier "back-to-back stream-output hangs" suspicion was wrong).
- **Mitigations adopted:** cgroup memory caps on every test (4608M on rock5bp, 16G on RK1, swap capped/zero), stall watchdogs, one-at-a-time risky tests with health checks, the 32 GB RK1 for memory-heavy tests (the same test passes on RK1: 2055/0 in 41 s).
- **Not done:** persistent journal on the board (would be a system change).
Source: `vkd3d-20261017.txt` 02:56–07:47.

## 12. Open issues and next steps
1. **robustness2 vertex_attribute_fetch** OOB on the gpu_prerast compute-VS path (294/374 fail in the full filter): needs real bounds checks in the software vertex fetch.
2. **fence_wait_robustness_shared** stalls on both boards; shared-fence failures on panthor (32754 / 320 checks) but not kbase.
3. **execute_indirect_state** 139/267 fail; `_predication` 8/1572; `vbv_stride_edge_cases` 18/120; `derivative_hoisting_dxil` 2/22; `sampler_feedback_implicit_lod_aniso` stall on RK1.
4. Top-FAIL list (§9.1), e.g. `suballocate_small_textures_size` 9586, `undefined_structured_raw_read_typed` 305×2.
5. Re-run the full D3D12 suite and the dEQP groups with 0015–0020 on both boards; verify 0019 on RK1 and 0014 on rock5bp.
6. Decide whether to drop 0016 (ineffective; superseded by 0018).
7. RK1 d3d11-triangle 3× slower than rock5bp (41.1 vs 123.8 fps) — unexplained; the d3d9/compute/vkd3d numbers are faster on RK1.
8. RK1 CS_UNRECOVERABLE fault during d3d9-triangle (recovered) — unexplained.
9. Heaven: finish the run, record score/avg fps, run tessellation off, profile the 1.7 fps; investigate the black rectangle.
10. panthor HOST_CACHED needs a kernel with panthor uAPI ≥ 1.7 (or backport); then drop `vkd3d-0001`.
11. Performance cost of 0013's COMPUTE barrier wait and 0009's extra varyings — not measured.
12. x86_64 Wine new-WoW64 under FEX can't run 32-bit apps — use Hangover, or report upstream.
13. Next target: a real game via the unofficial ARM Steam client + Proton ARM64/FEX (not started).
14. Upstreaming: these fixes are against an out-of-tree fork on Mesa 26.3-devel; mainline has 57 drifting patches (`reports/g610-gap-matrix.md`).

## 13. Reproduction

### 13.1 Build the driver
```sh
git clone https://gitlab.freedesktop.org/mesa/mesa.git mesa-full && cd mesa-full
git checkout -b kbase-applied 5a07217f034b3e50d8c7c7794f97a2df1742613b
# apply github.com/zenithblue-oss/panvk-kbase-android @5b87b74d series in order:
#   common, android, kbase-common, app-loader, wsi, csf, csf-v11   -> commit as "kbase series applied"
git am /path/to/research/patches/mesa/00*.patch           # 0001..0020
meson setup build --cross-file aarch64-cross.ini -Dprefix=/opt/mesa-kbase -Dlibdir=lib/aarch64-linux-gnu \
  -Dbuildtype=debugoptimized -Dvulkan-drivers=panfrost -Dgallium-drivers=panfrost -Dplatforms=wayland,x11 \
  -Dpanfrost-kmds=panthor,kbase -Dllvm=disabled -Ddisplay-info=disabled -Dmesa-clc=system -Dprecomp-compiler=system
# release-style build: add -Db_ndebug=true in a second build dir
ninja -C build install
```
`mesa_clc`, `vtn_bindgen2` and `panfrost_compile` are host tools built from the same patched tree. Max glibc symbol of the board libs: 2.38.

### 13.2 Select it (per process)
```sh
export VK_DRIVER_FILES=/opt/mesa-kbase/share/vulkan/icd.d/panfrost_icd.aarch64.json          # assert
export VK_DRIVER_FILES=/opt/mesa-kbase/share/vulkan/icd.d/panfrost_icd.ndebug.aarch64.json   # ndebug lib libvulkan_panfrost_ndebug.so
```
Driver knobs used in this work:
| Variable | Effect |
|---|---|
| `PANVK_KBASE_DMA_HEAP=/nonexistent` | pre-0017 workaround: disable dma-heap allocs on kbase |
| `PANVK_KBASE_DMA_HEAP_FORCE=1` | restore old dma-heap behaviour (0017) |
| `PANVK_KBASE_WC_DRM=/dev/dri/card0` | DRM node for WC dumb-buffer dma-bufs (0020) |
| `PANVK_TILER_BIN_BUDGET=<bytes>` | override tiler bin budget (0018, investigation only) |
| `PANVK_DEBUG=wsi_no_afbc` / `noafbc` | Wayland AFBC swapchain workaround |
| `MESA_VK_WSI_DEBUG=sw` | software present path (used on Xvfb) |

### 13.3 FEX + Wine
- FEX 2610 from `ppa:fex-emu/fex` (noble build on Ubuntu 24.04), Ubuntu 24.04 x86_64 RootFS; enable the Vulkan host thunk and make sure `ThunksDB.json` is in a FEX config dir (`$HOME/.fex-emu/` or `<prefix>/share/fex-emu`).
- Wine 11.19 amd64-wow64 (Kron4ek Wine-Builds) for 64-bit apps; `WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u` for a headless prefix.
- 32-bit apps: Hangover 11.16 (github.com/AndreRH/hangover), copy DXVK x32 DLLs into `syswow64`.
- Display: `Xvfb :99 -screen 0 1280x720x24`, `DISPLAY=:99`.

### 13.4 DXVK
```sh
# DXVK 3.1.1 DLLs into the prefix (system32 / syswow64), then
FEXBash -c "wine d3d11-triangle.exe"
DXVK_CONFIG='d3d9.enumerateByDisplays = False' FEXBash -c "wine d3d9-triangle.exe"   # needed on Xvfb
```

### 13.5 VKD3D-Proton
```sh
export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n,b"
export VKD3D_DISABLE_EXTENSIONS=VK_EXT_present_timing   # only needed without 0014
# panthor < uAPI 1.7: use DLLs built with patches/vkd3d/vkd3d-0001
VKD3D_TEST_EXCLUDE=... VKD3D_TEST_MATCH=<test> FEXBash -c "wine d3d12.exe"
```
Run the suite with `scripts/runsuite.sh` / `scripts/rksuite.sh` inside a memory-capped unit (`scripts/rkrun.sh` pattern: `systemd-run -p MemoryMax=… -p MemorySwapMax=… -p RuntimeMaxSec=…`). Exclude or cap `test_stress_*` on boards with ≤ 8 GB.

### 13.6 Heaven
Download the official installer (URL and sha256 in §3), extract with `innoextract`, set `WINEDLLOVERRIDES=d3dcompiler_42,d3dx11_42,d3dx9_42=n` in a Hangover prefix with DXVK x32, and run `bin/Heaven.exe` in D3D11 1280x720 windowed, QUALITY_MEDIUM, TESSELLATION_NORMAL, `-video_multisample 0`, `-extern_define PHORONIX`. The full launch command line lives on the RK1 and is **not in the box logs** (gap).

## 14. Comparison with DroidDeck's Turnip stack (Adreno, Android)
Source: `reports/g610-gap-matrix.md`.
| | DroidDeck 0.4.0 (Adreno) | This work (Mali-G610) |
|---|---|---|
| Vulkan driver | DD-Turnip v0.2.0 = Mesa 26.3.0-devel bffd91947e + 17 patches | PanVK-kbase (Mesa 26.3.0-devel 5a07217f + fork) + 20 local fixes |
| How DXVK gates are met | in hardware (GS, tess, XFB, polygon mode, 16 viewports, clip/cull) | **emulated** on the GPU: GS/tess/XFB/fill mode through the gpu_prerast compute path, clip/cull via varyings + FS discard, viewports in the passthrough VS |
| DXVK / VKD3D | stock (from Valve ARM64 Proton 11.0-2c or Nightlies) | stock DXVK 3.1.1; VKD3D-Proton 3.0.1 stock on kbase, `vkd3d-0001` on old panthor |
| Caps spoofing | `VKD3D_FEATURE_LEVEL=12_2`, `VKD3D_SHADER_MODEL=6_9` by default | none: honest FL 11_1 / SM 6.0 (12_2 only as a test) |
| WaveSize patch | Nightlies `relax-wave-size` | carried as fallback, **not needed** so far (subgroup fixed at 16) |
| x86 translation | FEX inside ARM64 Proton (ARM64EC/WoW64) | FEX 2610 Linux + x86_64 Wine (64-bit) / Hangover (32-bit) |
| Mesh shaders | DD-Turnip compute emulation | none |
| Sparse/tiled | KGSL/MSM PRR | Tiled 0 (sparseResidencyAliased false; kbase UAPI can't) |

---

## Updates
<!-- Append new entries at the top of this list: "### YYYY-MM-DD HH:MM HST — title", then bullets with the source log for each number. -->
### 2026-10-19 ~05:xx UTC — FULL stack runs as one user; DRM master now HELD + patched; but vendor kbase VOP2 will not flip (frozen fb) → needs panthor
Major progress and a hard kernel-level wall, both on the RK1 (node1, vendor 6.1 kbase). Every userspace layer now works; the vendor VOP2 KMS cannot present gamescope's live frames. Physical panel still never shows a usable UI (shows stale console), but the cause is now pinned to the kernel, not userspace.
- **[verified] Wrote + built the missing `drmSetMaster` in gamescope's DRM backend; master now HELD.** Stock gamescope (`src/Backends/DRMBackend.cpp`) opens the KMS node via `wlsession_open_kms` and never calls `drmSetMaster`, relying on a session handoff that never happens here. Recovered the lost render-node fallback (renderD128 for alloc, `GAMESCOPE_PRIMARY_NODE`→card0 for scanout) in `rendervulkan.cpp`+`DRMBackend.cpp`, **added an explicit `drmSetMaster(drm->fd)`**, rebuilt (meson, PKG_CONFIG_PATH=/opt/gamescope/lib/pkgconfig:/opt/gamescope/share/pkgconfig), installed to `/opt/gamescope/bin`. `/sys/kernel/debug/dri/0/clients` now shows `gamescope-wl master=y active=y` **stable** (was always `master=n`).
- **[verified] The winning session config = all-`ubuntu`, libseat `builtin` (embedded seatd) on tty1.** logind never activated the seat; external seatd opened the device but master dropped. `LIBSEAT_BACKEND=builtin` embeds seatd and is VT-bound, holds master, and does the VT KD_GRAPHICS switch (console blanks, `vtcon1/bind`→0). As `ubuntu` it needs: `setcap cap_sys_admin,cap_sys_nice,cap_sys_tty_config+ep /opt/gamescope/bin/gamescope`; the PanVK-kbase ICD copied to `/etc/vulkan/icd.d/` (setcap→secure-exec makes the Vulkan loader ignore `VK_DRIVER_FILES`); and **ubuntu in group `tty` + `/dev/tty[0-9]*` mode 0660** (builtin seatd must open `/dev/tty0`, else "Could not open target tty: Permission denied" → "card0: Operation not permitted" → "Failed to create backend"). udev rule `99-gamescope-vt.rules`.
- **[verified] Full Valve arm64 Steam client runs with the UI stack up — as the SAME user as gamescope.** `steamwebhelper`/CEF gamepad UI = ~10 procs, **0 X11 errors**, cef_log live. Running gamescope as root + Steam as a different user had failed with Xwayland `Authorization required` (no shared cookie; gamescope's xwm connects via its pre-opened listenfd, socket clients need auth); single-user eliminates it. Steam's legacy GLX update splash (`CreateGlFont`/`BadAlloc`) is non-fatal; `LIBGL_ALWAYS_SOFTWARE=1` avoids its crash; `-noverifyfiles -nobootstrapupdate -skipinitialbootstrap` + `steam.cfg BootStrapperInhibitAll=Enable` skip the verify loop.
- **[verified] HARD WALL: gamescope does ONE VOP2 modeset then never page-flips — `fb=232` frozen across all reads, composite_force / fence-disable convars don't unstick it.** dmesg shows `vop2_crtc_atomic_enable Update mode to 1920x1080p60 (if:HDMI0) for vp0`, `master=y`, `fbcon=0`, HDMI-A-1→video_port0 active with gamescope's fb — yet the physical panel keeps showing stale console. gamescope issues the modeset commit and then stalls waiting on a flip-completion/fence the vendor VOP2 never delivers (`drm: Immediate flips are not supported` + `Syncobjs are not supported by the KMS driver`). This is a gamescope↔vendor-6.1-VOP2 KMS presentation incompatibility, **not** fixable in userspace on this kernel. Confirms the earlier 2026-10-18 09:1x/08:35 hypothesis: needs **panthor/mainline**, not vendor kbase. Next: do the gamescope+Steam session on the **rock5bp (panthor, mainline 6.18)** where the flip path works. Board left quiet (gamescope autostart gated behind `/mnt/nvme/steam-arm64/ENABLE_GS`); launcher `steamos-console.sh`, backups `*.bak`.

### 2026-10-19 ~03:4x UTC — CORRECTION + root cause: gamescope never acquires DRM master on card0; HDMI has NEVER shown the UI
User confirms the physical HDMI has **never** displayed the Steam/gamescope UI — not once; the panel only ever shows the kernel text console (fbcon). The 2026-10-18 "LOGIN UI on screen" entry below was inferred from the CEF `library.js` login logs, **not** eyes-on; its "on screen"/"on the HDMI" wording is wrong and is retracted. The compositor runs, but nothing is scanned out.
- **[verified] gamescope composites but holds no DRM master → no KMS scanout.** With the tty1 autologin launcher running, `steamwebhelper`/CEF, Xwayland `:0`, and Steam all run and render into gamescope; gamescope's DRM backend reads the HDMI EDID ("HDMI-A-1 → HP X24i") and selects 1920x1080@60. But `/sys/kernel/debug/dri/0/clients` (card0 = rockchip display) shows `gamescope-wl … master=n` while fbcon (`/sys/class/vtconsole/vtcon1/bind`) stays `1` (console owns the panel). No process holds DRM master on card0 → gamescope can't modeset → text console remains.
- **[verified] Not a privilege or seat-activation problem.** Tried three launch paths, all `master=n`, `fbcon bind=1`: (a) `LIBSEAT_BACKEND=logind` via `login -f` on tty1 — session `Active=yes` on seat0, card0 correctly udev-tagged `seat0`/`master-of-seat`, `CanGraphical=yes`, but libseat never logs "Enabling seat" (no activation handshake), `active=n`; (b) `LIBSEAT_BACKEND=seatd` (seatd daemon, socket group `video`) launched on tty1 — libseat logs "Enabling seat", seat `active=y`, **but seatd's journal shows NO device-open** for card0 — gamescope opened card0 outside the session; (c) gamescope **as root** (sudo, Steam re-dropped to `ubuntu` via setpriv) — `active=y uid=0`, still `master=n`. Even with CAP_SYS_ADMIN gamescope does not become master.
- **[hypothesis] The custom render-node-fallback patch opens card0 for scanout without ever calling `drmSetMaster` (nor via the session).** That patch (the "no render node → fall back to /dev/dri/renderD128 for alloc, card0 as primary/scanout" change) brings up compositing + mode-select but omits the master-acquire on the fallback scanout fd. Fix = patch gamescope's DRM backend to (i) open the card0 scanout node through `wlr_session`/libseat so seatd does `drmSetMaster`, or (ii) `drmSetMaster()` the scanout fd directly, then rebuild. Until then HDMI shows only fbcon.
- **[verified] Also seen, non-blocking:** rockchip KMS logs `Syncobjs are not supported` + `Immediate flips are not supported` (card0 is display-only; may force gamescope to legacy/blocking flips once master is fixed); `setpriv` wrapper in path (c) broke Steam (`execl errno 2`) — reverted. Board left in the path-(b) seatd state: gamescope + Steam running under seatd, seat active, Steam as `ubuntu`, only the master-acquire missing. `steamos-console.sh.logind.bak` / `.seatd.bak` keep the prior launchers.

### 2026-10-18 ~11:4x HST — Steam Big Picture LOGIN UI on screen via gamescope on RK1/Mali kbase (DroidDeck #736 solved)
> **Retraction (2026-10-19):** "on screen"/"on the HDMI" here is inferred from CEF logs only; the panel never actually displayed the UI. See the 2026-10-19 entry above.
Solved the kbase "no render node" blocker *on the RK1* (user wants the RK1 as the focus, not rock5bp) with a gamescope patch, and brought the native client's Big Picture UI up on the HDMI.
- **[verified] gamescope render-node fallback patch (novel; fixes DroidDeck issue #736).** Patched `src/rendervulkan.cpp` `CVulkanDevice::createDevice`: when the Vulkan device has no DRM render node (PanVK-kbase on `/dev/mali0`), fall back to a system render node (`/dev/dri/renderD128`, rockchip-drm) for GBM/dmabuf allocation and set primary/scanout to `/dev/dri/card0` (env overrides `GAMESCOPE_RENDER_NODE`/`GAMESCOPE_PRIMARY_NODE`); Vulkan still renders on Mali. gamescope then reads the HDMI EDID ("HDMI-A-1 → HP X24i"), selects 1920x1080@60, enumerates Mali↔rockchip dmabuf formats, starts Xwayland :0. (Patch on top of orin's tegra patch; the upstream `hasRender` check was an unconditional `return false`.)
- **[verified] Runs as the `ubuntu` user via seatd** (not root — Steam refuses root: `tier0/threadtools Permission denied`). `seatd -g video` (socket group `video`, which `ubuntu` is in) + `LIBSEAT_BACKEND=seatd`; gamescope launches the native client as its child, so Steam inherits DISPLAY=:0 and runs unprivileged.
- **[verified] Steam Big Picture UI + LOGIN reached.** `steamwebhelper` (CEF) runs — main + zygotes + network-service + GPU process (recovered after one crash, 156 ms). `cef_log.txt`: `"Login: Failed to poll auth session. Result 2. Transport Error: 2", source: https://steamloopback.host/library.js` — the gamepad-UI login frontend is executing. Boundary reached: **user completes the Steam login (account/2FA)** — not automatable.
- **Open:** legacy GL update-splash fails (`updateui_gl CreateGlFont` / X `BadAlloc`/`BadDrawable`, `XRRGetOutputInfo not available`) but does not block the CEF UI; ALSA-only audio (no PulseAudio); the auth-poll "Transport Error 2" may need an RTC/clock + network check if login doesn't proceed (cf. orin-steamos clock-before-login handling).

### 2026-10-18 ~09:1x HST — gamescope built on RK1, but kbase has no DRM render node (blocker); needs panthor
Goal = get the native client on-screen via a real compositor (DroidDeck uses gamescope). Built gamescope 3.16.28 on the RK1 (noble arm64) using orin-steamos's `build-gamescope` recipe verbatim (newer deps wayland 1.24 / wayland-protocols 1.47 / pixman 0.46.4 / libdrm 2.4.129 / xkbcommon 1.8.1 into `/opt/gamescope`, rpath). Needed `bison` (not in the recipe's apt list on this image). Also applied orin's `gamescope-3.16.28-tegra.patch`.
- **[verified] gamescope selects Mali via PanVK-kbase fix20**: `MESA: panvk: gpu_id 0xa8670000 … Mali-G610`, `vulkan: selecting physical device 'Mali-G610 MC4'`, `physical device supports DRM format modifiers`.
- **[verified] BLOCKER: `vulkan: physical device has no render node` → Failed to initialize Vulkan → Failed to create backend.** The tegra patch removes the `hasPrimary` requirement (that error cleared) but the `hasRender` requirement remains, and **vendor kbase exposes the GPU via `/dev/mali0`, not a DRM render node** (card0 = rockchip-drm display-only; card1 = RKNPU; no Mali renderDxxx). gamescope/wlroots require a DRM render node on the Vulkan device.
- **[hypothesis] Needs panthor, not kbase.** The mainline `panthor` KMD exposes a proper `/dev/dri/renderD128`, which gamescope requires. The rock5bp runs panthor (mainline 6.18); this RK1 runs vendor kbase (6.1 BSP). So the gamescope + native-client session should be done on the **panthor** board (rock5bp), or the RK1 would need a mainline/panthor kernel. The earlier DXVK/Heaven/VKD3D proofs + the native Steam client engine bring-up all work on kbase; only the gamescope compositor needs panthor's DRM node.

### 2026-10-18 ~08:35 HST — NATIVE aarch64 Steam client (Steam Frame) runs on RK1/Mali-G610 up to the CEF UI
Toward the real project goal (**SteamOS on ARM64**, see memory `rk3588-steamos-arm64`), brought up Valve's *native* aarch64 Steam client — the one shipped with the Steam Frame, NOT the x86_64-client-under-FEX path. Recipe pinned from Valve's manifest (github.com/Daaboulex/steam-arm64-nix). Installed to node1 (RK1) `/mnt/nvme/steam-arm64`; eMMC left alone.
- **[verified] Client is genuinely native arm64.** Assembled 17 publicbeta depot zips (ver 1792192922, 345 MB from client-update.fastly.steamstatic.com) → `steamrtarm64/steam` = `ELF 64-bit aarch64 PIE, interp /lib/ld-linux-aarch64.so.1`. No x86 emulation for the client itself.
- **[verified] Self-updates and engine inits.** With `~/.steam/{steam,root}` scaffolding, the bootstrap downloaded+installed a 651 MB `steam_client_linuxarm64` package ("Update complete, launching Steam"). After adding host libs (`libgtk2.0-0 libegl1 libxinerama1 libopenal1 libpipewire-0.3-0 libva2 libnm0 libsdl2-2.0-0`), `steamclient.so` initializes (the "32-bit app" assert text is stock boilerplate; real cause was missing `libnm.so.0`).
- **[verified] GPU topology query succeeds via Mali.** With `VK_DRIVER_FILES=.../panfrost_icd.fix20.aarch64.json`, the client runs `GpuTopology` query and gets `Response: gpu_topology {` — i.e. the native client sees Mali-G610 through PanVK-kbase fix20.
- **[verified] Headless ceiling = CEF UI.** Client spawns `steamwebhelper` (auto-sets `LIBGL_KOPPER_DISABLE=true`), retries ~12×, then `steamuisharedjscontroller.cpp (583): Failed creating offscreen shared JS context` under Xvfb :99 even with `LIBGL_ALWAYS_SOFTWARE=1`. The login screen is Chromium; it needs a GPU-backed display (gamescope / KMS+panfrost GL), not Xvfb.
- **Feasibility note:** RK1 is `CONFIG_ARM64_4K_PAGES=y` + KVM on, so the client's 4K-page-guest requirement is met natively — muvm not needed here.
- **Next:** stand up gamescope (or KMS+panfrost GL) for the CEF UI, then user completes Steam login (account/2FA — not automatable).

### 2026-10-18 ~08:10 HST — max-clock ("god speed") Heaven re-run: clocks are not the bottleneck
Pinned every clock on the RK1 and re-ran Heaven under fix20 (nodes 2/3 off, full headroom). State before the run: CPU already `performance` on all three policies (1.8/2.256/2.256 GHz), GPU devfreq `fb000000.gpu` already `performance` at its top bin **1.0 GHz**; the only change made was DRAM controller `dmc` `dmc_ondemand`→`performance`, **528 MHz→2112 MHz**. Logs in `logs/rk1/heaven/godspeed-*`.
- **[verified] Marginal gain.** TESSELLATION_NORMAL **2.40442 FPS** (634 frames / 263.681 s) vs 2.351 baseline = **+2.3%** (`godspeed-tessnormal.log`). TESSELLATION_DISABLED **10.1784 FPS** (2669 / 262.223 s) vs 10.043 = **+1.3%** (`godspeed-tessoff.log`). Both `rc=0`.
- **[hypothesis] Bottleneck is the emulated prerast path, not HW clocks.** The sub-2% gain from maxing CPU+DRAM (GPU was already maxed) indicates Heaven here is bound by the GPU-side GS/tess/XFB compute emulation at the fixed 1.0 GHz GPU ceiling, not by CPU or memory bandwidth. Faster needs a cheaper driver prerast path, not more clocks.
- **[verified] `dmesg_new=3397` on tessnormal is all DisplayPort noise, 0 GPU faults.** 3396× `dw-dp fde50000.dp: test_type0 is not support` + 1 `aux failed to read dpcd: -110` (headless DP port polled with no monitor); `godspeed-tessoff` logged 0 lines. Not a GPU regression.

### 2026-10-18 ~07:55 HST — fix20 clears the last two RK1 hangs
Re-ran the only two tests still hanging on RK1 fix18 (per the 10:58 10-17 entry) under ICD **fix20** (`964e4f2 + f592c35`), on the freshly rebooted RK1 (nodes 2/3 powered off, GPU idle). One test per 16 G unit, 120 s stall watchdog, dEQP smoke health check after each (`scripts/rkiso.sh`, tag `fix20-recheck`). Logs in `logs/rk1/iso-fix20-recheck/`.
- **[verified] `fence_wait_robustness_shared`: fixed.** `why=done secs=30`, "3 tests executed (0 failures …)", `fails=0 gpu_dmesg=0 health=1` (was STALL 159 s on fix18, `summary.txt`).
- **[verified] `sampler_feedback_implicit_lod_aniso`: fixed.** `why=done secs=31`, "3 tests executed (0 failures …)", `fails=0 gpu_dmesg=0 health=1` (was STALL 179 s on fix18).
- **[hypothesis]** both were resolved by the fix18→fix20 delta (0019 OOB software-index sink and/or 0020 WC dumb-buffer backing for placed maps); not individually bisected. With this, **every RK1 D3D12 test that previously stalled on fix18 now completes cleanly on fix20** (the stream-output hang was already fixed by 0019 and verified on rock5bp).

### 2026-10-17 ~11:19 HST — Unigine Heaven 4.0 completes on the RK1 (fix20); recovered after 2026-10-18 reboot
Logs recovered from the RK1 (`/opt/rktest/logs`, persisted on eMMC) after a 2026-10-18 reboot; copied to `logs/rk1/heaven/` (`heaven-ho-tessnormal.{log,result,dmesg}`, `heaven-ho-tessoff.{log,result,dmesg}`, `heaven-tessnormal.*`, `suite-fix18.*`). All three Heaven runs were under ICD **fix20** (`964e4f2 + f592c35`, ndebug) via **Hangover 11.16** WoW64, DX11 1280×720 windowed, QUALITY_MEDIUM, AA off, `-extern_define PHORONIX`.
- **[verified] Heaven finishes and benchmarks.** TESSELLATION_NORMAL: `exit=0`, Heaven reports **Time 263.717 s, Frames 620, FPS 2.351** (`heaven-ho-tessnormal.log`, 20:59:28 UTC entry; `.result` `why=done secs=387 rc=0 dmesg_new=11`). TESSELLATION_DISABLED: `exit=0`, **Time 262.168 s, Frames 2633, FPS 10.0432** (`heaven-ho-tessoff.log`, 21:09:08 UTC; `.result` `why=done secs=407 rc=0 dmesg_new=0`). Both report Max feature level `D3D_FEATURE_LEVEL_11_1`. The ~4.3× frame-rate gap with tessellation on matches the emulated GS/tess/XFB prerast path.
- **[verified] tessellation-normal run was GPU-clean.** The 11 "new dmesg" lines are DisplayPort-controller noise, not GPU faults: ten `dw-dp fde50000.dp: test_type0 is not support` + one `aux failed to read dpcd: -110` (`heaven-ho-tessnormal.dmesg`). tessoff had 0 new dmesg lines.
- **[verified] Pure FEX + x86_64 Wine cannot launch 32-bit Heaven.** `heaven-tessnormal.log` (20:31–20:32 UTC): `end ShellExecuteEx failed: exit=1` at t=10 s — confirms §13.6/Failure 1; Hangover is the only working 32-bit path.
- **[verified] fix18 D3D12 suite re-run clean.** `suite-fix18.result` `why=done secs=543 rc=0 dmesg_new=0`.
- **[unverified] overlay still unusable on Heaven.** `heaven/failed/tessoff-overlay23/` (system Mesa 23.0.5 `VK_LAYER_MESA_overlay` over the fix20 driver) fails device creation: `Failed to create Vulkan device: VK_ERROR_FEATURE_NOT_PRESENT` (`stdout.txt`). The benchmark FPS above come from Heaven's own `-extern_define PHORONIX` output, not the overlay CSV.

### 2026-10-17 ~11:00 HST — archive created
- Snapshot of all logs up to `rk1-20261017.txt` 10:58 entry. Heaven run, tessellation-off run, and any post-0020 re-runs were still in progress.
