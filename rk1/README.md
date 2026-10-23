# SteamOS-Mainline — RK1 / Turing Pi variant

This subdirectory adapts the Rock 5B+ build (see [`../README.md`](../README.md)) to a
**Turing Pi RK1** compute module that is *also* a live k3s node — i.e. a board stuck
on the **vendor 6.1 BSP + Mali kbase** stack rather than mainline/panthor.

**Read this first:** on the vendor-kernel/kbase path you can get the **native Steam
Big Picture UI on HDMI and log in**, but you **cannot cleanly launch games** — see
[Status](#status). For actual gaming use the mainline/panthor Rock 5B+ build, not this.
This variant exists to run the stack on a board you can't move off the vendor kernel
(NPU, Turing carrier peripherals, cluster role), and to document exactly where it stops.

## Target

- Turing Pi RK1 (RK3588, Mali-G610), Ubuntu 24.04, **vendor kernel `6.1.x-rockchip`**
  (NOT mainline panthor), Mali via **kbase** (`/dev/mali0`), 16/32 GB.
- The board here (`the RK1`) is a live **k3s control-plane + Wi-Fi gateway**, so the
  installer is deliberately **non-destructive**: no NVMe format, no hostname change
  (keeps the k3s node identity), existing `/mnt/nvme` data untouched. `game-perf`
  stops/starts k3s only for the duration of a session.
- Assumes the GPU/emulation stack is already staged under `/opt` (bind-mounted on
  `/mnt/nvme`): `mesa-kbase/lib/.../libvulkan_panfrost_fix20.so`, `fex`, `gamescope`,
  `hangover`, `wine`, `dxvk`, `vkd3d`. (fix20 = PanVK-kbase, the 20-patch Mesa series
  from `../research/RESEARCH.md`.)

## Contents

| File | Purpose |
|---|---|
| `install-rk1.sh` | Non-destructive installer (reuses `../fetch-steam-arm64.sh` for the client). |
| `steam-play.rk1.in` | Launcher. Brings up **weston** (kiosk-shell, XWayland, pixman) on HDMI, then runs the native aarch64 Steam client as an X11 client. `@GAME_USER@`/`@UID@` substituted at install. |
| `game-perf.rk1` | `on`/`off`: pins CPU/GPU/DMC + fan **and stops/starts k3s** for the session. |
| `steam-kiosk.service` | systemd unit that runs `steam-play` on seat0/tty1 (installed **disabled**; `Restart=no`). |

## Install

```sh
# on the RK1, as root; defaults assume the /opt staging above
sudo ./install-rk1.sh          # GAME_USER=player, DRIVER_SO=.../libvulkan_panfrost_fix20.so
# then, with a monitor on HDMI, from a tty login as the game user:
steam-play                     # weston kiosk -> Steam Big Picture -> QR login
sudo systemctl stop steam-kiosk && sudo game-perf off   # tear down + restore k3s
```

## Status

| Piece | State |
|---|---|
| Native aarch64 Steam client (download / update / verify / **login**) | ✅ works |
| Mali-G610 Vulkan (PanVK-kbase fix20) as system ICD; `GpuTopology` → Mali-G610 | ✅ works |
| FEX + Proton (incl. ARM64) + DXVK/VKD3D present | ✅ works |
| **Display**: Big Picture UI rendered on HDMI, logged in, navigable | ✅ works (via **weston**; software-composited → laggy) |
| **Launching games** | ❌ **blocked** — `X Error: BadAtom` (Steam's X11 game-launch vs weston's rootless XWayland); game exits in ~1 s |

### Why weston (not gamescope or cage)

Steam's bundled SDL is **X11-only** (`SDL_VIDEODRIVER=wayland` → "wayland not
available") and needs a *working* X server.

- **gamescope** `--backend drm`: its XWayland satisfies Steam, but gamescope **can't
  scan out on the vendor kernel** (`Syncobjs are not supported` / `Immediate flips are
  not supported`) → frozen screen. Nesting it (`--backend wayland`) in cage or weston
  came up 0×0 / didn't present.
- **cage**: page-flips fine, but its XWayland did **not** satisfy Steam's SDL
  (`SDL_Init: No available video device`).
- **weston**: its reference XWayland **does** satisfy SDL, and it drives the VOP2 with
  plain atomic modeset (confirmed live flipping). So the UI works. kiosk-shell
  fullscreens Steam; `--renderer=pixman` avoids depending on GLES/EGL (only a
  `libmali-x11` variant is installed, no gbm/wayland one), which is why it's
  software-composited and laggy.

### The game-launch wall

Even with **Proton 11 (ARM64)** mapped for the title, launch dies instantly with
repeated `X Error: BadAtom (invalid Atom parameter)` → `Steam: An X Error occurred`.
That's Steam's X11 game-launch/atom code (e.g. the `STEAM_GAME` atom) hitting weston's
rootless XWayland. The compositor that handles Steam's X correctly is gamescope — which
can't display here. **No single compositor on the vendor 6.1 kernel both displays and
launches games.**

## Launcher fixes (baked into `steam-play.rk1.in`)

Hard-won, in case they help elsewhere:

1. Launch the native `steamrtarm64/steam` binary, **not** `steam.sh` (that's the x86
   launcher → `ubuntu12_32`/`amd64` → `Exec format error`).
2. `LIBGL_ALWAYS_SOFTWARE=1` — the first-run **GLX update window** has no GL driver on
   this Vulkan-only board and otherwise hangs the updater.
3. Wait for `steamwebhelper` to exist before using `-gamepadui` (first-run installs it;
   gamepadui before it wedges the updater).
4. `dbus-run-session` — no session bus → gamepadui/CEF inits then quits.
5. `-cef-disable-gpu-compositing -cef-disable-gpu` — CEF's GPU process hits Chromium's
   `exit_on_context_lost` on Mali-kbase and quits, taking Steam with it.
6. **Never `SIGKILL` Steam** — it leaves `~/.local/share/Steam/.crash`, which triggers a
   "didn't shut down cleanly → verify → relaunch" loop (don't pair with
   `Restart=on-failure` or systemd thrashes it).

## Conclusion

The RK1/vendor-kernel path proves the **driver + FEX + native-client stack end-to-end**
(login on screen), but gaming needs gamescope, and gamescope needs the **mainline/panthor
atomic-KMS-with-syncobj** path the vendor kernel lacks. For a box you actually play on,
use the mainline Rock 5B+ build ([`../README.md`](../README.md)) or ROCKNIX on a
supported board — not an RK1 you can't take off the vendor BSP.
