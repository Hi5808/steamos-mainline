# SteamOS-Mainline (RK3588 / Rock 5B+)

A reproducible build that turns a stock **Armbian mainline** install on a
**Radxa Rock 5B+** into a couch-gaming box: the **native aarch64 Steam client**
running **x86 Windows games** through **FEX + Proton + VKD3D/DXVK** on an
**open-source Mali-G610 Vulkan driver**, out an **HDMI** display.

This is the clean, data-free packaging of the hand-built system in
[`../research/RESEARCH.md`](../research/RESEARCH.md). Run one script on the board.

## What it sets up

1. **HDMI fix** — works around the mainline `rockchip dw-hdmi-qp` bug that
   mis-parses some EDIDs ("HDMI Sink doesn't support RGB"), fails the modeset,
   and black-screens the connector. A boot service overrides the EDID.
2. **Lean desktop** — disables ~10 disposable services and GNOME bloat and the
   screen lock, to claw back RAM for the game.
3. **NVMe library + 8 GB swap** — the game library lives on NVMe; the swapfile
   absorbs the FEX-JIT / shader-compile spikes that otherwise OOM-lock an 8 GB board.
4. **Feature-complete Mali Vulkan driver** — registers the PanVK-kbase driver
   (which exposes the Vulkan features DXVK/VKD3D require on Valhall v10) as a
   host ICD so pressure-vessel imports it. *You build/supply this `.so`.*
5. **FEX x86_64 guest rootfs** at `/usr/share/guestos/fex-mesa` — the piece
   Valve's `fex-compat-tool` expects (normally only on SteamOS-ARM / Steam Frame).
6. **Native aarch64 Steam client** — fetched straight from Valve's client manifest
   ([`fetch-steam-arm64.sh`](fetch-steam-arm64.sh)), with the correct x86_64
   `steamclient.so` SDK links so Proton's `lsteamclient` initialises.
7. **Performance + launcher** — `game-perf on|off` (pins A76 cores + Mali to max,
   fan up) and `steam-play [APPID]` (applies display/xhost/FEX/overlay fixes).

## Prerequisites

- Rock 5B+, Armbian 26.8.3 "resolute", kernel 6.18.45 mainline (panthor), GNOME/GDM.
- An NVMe SSD (library + swap) and an HDMI display + USB keyboard/controller.
- FEX-Emu installed (for `FEXRootFSFetcher`), or a FEX `Ubuntu_24_04.sqsh` to pass in.
- **The feature-complete Mali Vulkan driver** `libvulkan_panfrost.so`
  (PanVK-kbase). Build it per `research/RESEARCH.md` §13, then pass its path as
  `DRIVER_SO`. The stock distro Mesa will **not** work — DXVK/VKD3D reject it.

## Usage

```sh
sudo DRIVER_SO=/path/to/libvulkan_panfrost.so \
     GAME_USER=player \
     ./build-steamos-mainline.sh
# reboot, then on the desktop:
steam-play               # sign in with the QR code (Steam mobile app)
# install a game, set Proton Experimental, then:
steam-play <APPID>
sudo game-perf off       # when you're done
```

Env knobs: `GAME_USER`, `DRIVER_SO` (required), `NVME_DEV`, `NVME_FORMAT=1`,
`FEX_ROOTFS`, `HOSTNAME_NEW`. See the header of `build-steamos-mainline.sh`.

## Per-game rendering tips

- **Unity games → add `-force-vulkan` to the game's Steam launch options.**
  The native-Linux GL driver (`panthor`) does not load on this mainline stack, so
  Mesa silently falls back to **zink** (OpenGL-emulated-on-Vulkan), which renders
  glitchy on PanVK. Unity's native Vulkan renderer skips zink and draws correctly
  on the Mali-G610. Symptom: "game loads but renders wrong"; log shows
  `Renderer: zink Vulkan ...` and `failed to load driver: panthor`. (Verified on
  Vampire Survivors.) More generally: **prefer Vulkan over OpenGL** for any native
  Linux title — GL is the broken path here.
- **D3D games (Proton) → set Proton Experimental** as the compatibility tool
  (Properties > Compatibility). They go D3D → DXVK/VKD3D → Vulkan, which works.
- **Native-Linux renderer not on screen in the Proton container?** Native titles
  run on the host directly (the Mesa Vulkan overlay HUD works for them); Proton
  titles run in the pressure-vessel sandbox (overlay env is remapped).

## Game compatibility & anti-cheat (what actually runs)

| Category | Examples | On this ARM/FEX board |
|---|---|---|
| **No anti-cheat** | GnG Resurrection, Vampire Survivors, most single-player, co-op, indies, emulators | ✅ **works** |
| **EAC / BattlEye** (dev opt-in) | Halo Infinite, Elden Ring, Deep Rock Galactic | ❌ **does not load** — EAC module fails to map under FEX (error **206**) |
| **Kernel anti-cheat** | Delta Force (ACE), Valorant / LoL (Vanguard) | ❌ **blocked** — needs a Windows kernel driver |

**Anti-cheat of *any* kind does not work on this box.** EAC/BattlEye titles that run on
x86 Steam Deck still fail here because the anti-cheat runtime won't load inside FEX
(x86-on-ARM emulation). This is an open, unsolved problem — see
[fxgl/steamac#16](https://github.com/fxgl/steamac/issues/16): error 206 is unresolved;
the bleeding-edge path (patched FEX + x86-64 Proton + `PROTON_EAC_RUNTIME`) at best
reaches a title screen and crashes. **Treat all anti-cheat games as unsupported.** The
working target is the huge no-anti-cheat library.

## Honest limitations

- **8 GB is tight.** Desktop + Steam + FEX + Proton + a game ≈ 11 GB working set,
  so an 8 GB board leans on swap and stutters. It *runs*; it isn't buttery.
  16 GB boards are the comfortable target. Lower in-game resolution to help.
- **Rock 5B+ only.** Other RK3588 boards differ (DTB, PMIC, HDMI, power). This is
  not a drop-in image for Orange Pi 5 / 5-Plus, etc.
- **FEX emulation overhead** caps framerates regardless of GPU headroom; a locked
  60 fps is not guaranteed for every title.
- **`TSOENABLED=0`** in the launcher trades x86 memory-ordering correctness for
  speed. If a multithreaded game misbehaves, drop it from `steam-play`.

## Sterilization — what is deliberately NOT in this build

No personal data is written by these scripts. You supply your own on first use:

- **No account / login** — you sign into Steam yourself (QR code).
- **No passwords** — the build sets none; set your own for `GAME_USER`/`root`.
- **No SSH host keys, machine-id, Tailscale/VPN identity, or Wi-Fi secrets.**
- **No real names** — the user's GECOS is "Player".
- **No purchased game baked in** — `steam-play` takes any AppID; Ghosts 'n
  Goblins Resurrection (1375400) was only the bring-up test in RESEARCH.md.

The personal disk image (`../images/SteamOS-Mainline_Rock-5B-plus_*.img.zst`) is a
private full-disk backup and must **not** be committed to the repo — it contains
account tokens, keys, and the game library. This directory is the shareable part.
