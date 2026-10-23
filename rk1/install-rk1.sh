#!/bin/bash
# =============================================================================
# install-rk1.sh -- SteamOS-Mainline packaging for the Turing Pi RK1.
#
# Unlike build-steamos-mainline.sh (Rock 5B+, Armbian mainline/panthor, GNOME),
# this targets the RK1 as it is: Ubuntu 24.04, vendor 6.1 rockchip kernel, Mali
# via kbase (/dev/mali0), gamescope + FEX already staged under /opt (on NVMe).
#
# It is NON-DESTRUCTIVE: it does NOT format NVMe, change the hostname, disable
# cluster services, or touch /mnt/nvme Studio data. k3s keeps its identity
# (<your-k3s-node>); game-perf stops/starts k3s only for the duration of a game.
#
# Config via env (all optional):
#   GAME_USER   default: player
#   DRIVER_SO   default: /opt/mesa-kbase/lib/aarch64-linux-gnu/libvulkan_panfrost_fix20.so
#   FEX_ROOTFS  default: /opt/fex/RootFS/Ubuntu_24_04 (extracted rootfs dir)
#   STEAM_ROOT  default: /mnt/nvme/steamos/root
#   SKIP_STEAM  set to 1 to skip the (network) Steam client download
# =============================================================================
set -euo pipefail
GAME_USER="${GAME_USER:-player}"
DRIVER_SO="${DRIVER_SO:-/opt/mesa-kbase/lib/aarch64-linux-gnu/libvulkan_panfrost_fix20.so}"
FEX_ROOTFS="${FEX_ROOTFS:-/opt/fex/RootFS/Ubuntu_24_04}"
STEAM_ROOT="${STEAM_ROOT:-/mnt/nvme/steamos/root}"
SKIP_STEAM="${SKIP_STEAM:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
log(){ echo -e "\n==> $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
grep -q rk3588 /proc/device-tree/compatible 2>/dev/null || echo "WARN: not RK3588?"
[ -f "$DRIVER_SO" ] || { echo "DRIVER_SO not found: $DRIVER_SO"; exit 1; }
[ -d "$FEX_ROOTFS" ] || { echo "FEX_ROOTFS not found: $FEX_ROOTFS"; exit 1; }

log "1/8 packages"
apt-get update -qq
apt-get install -y -qq curl unzip zstd python3 squashfs-tools fonts-dejavu-core libvulkan1 vulkan-tools >/dev/null || \
  apt-get install -y -qq curl unzip zstd python3 squashfs-tools fonts-dejavu-core >/dev/null

log "2/8 game user '$GAME_USER'"
id "$GAME_USER" &>/dev/null || adduser --disabled-password --gecos "Player" "$GAME_USER"
for g in video render input audio games plugdev; do usermod -aG "$g" "$GAME_USER" 2>/dev/null || true; done
GUID=$(id -u "$GAME_USER")

log "3/8 register Mali PanVK-kbase fix20 as the system Vulkan ICD"
install -d /usr/share/vulkan/icd.d
APIV=$(VK_DRIVER_FILES= VK_ICD_FILENAMES= bash -c "true"; echo 1.4.363)
cat > /usr/share/vulkan/icd.d/panvk-kbase.json <<EOF
{ "ICD": { "api_version": "$APIV", "library_path": "$DRIVER_SO" }, "file_format_version": "1.0.0" }
EOF
echo "    -> $DRIVER_SO"

log "4/8 FEX x86_64 guest rootfs -> /usr/share/guestos/fex-mesa"
install -d /usr/share/guestos
ln -sfn "$FEX_ROOTFS" /usr/share/guestos/fex-mesa

log "5/8 game-perf (perf governors + fan + stop/start k3s)"
install -m755 "$HERE/game-perf.rk1" /usr/local/sbin/game-perf
cat > /etc/sudoers.d/game-perf <<EOF
$GAME_USER ALL=(root) NOPASSWD: /usr/local/sbin/game-perf
EOF
chmod 440 /etc/sudoers.d/game-perf

log "6/8 steam-play launcher (gamescope on HDMI) + kiosk service (disabled)"
sed -e "s/@GAME_USER@/$GAME_USER/g" -e "s/@UID@/$GUID/g" "$HERE/steam-play.rk1.in" > /usr/local/bin/steam-play
chmod 755 /usr/local/bin/steam-play
sed -e "s/@GAME_USER@/$GAME_USER/g" -e "s/@UID@/$GUID/g" "$HERE/steam-kiosk.service" > /etc/systemd/system/steam-kiosk.service
systemctl daemon-reload
echo "    (enable with: systemctl enable steam-kiosk.service  -- do this only with a monitor attached)"

log "7/8 native aarch64 Steam client -> $STEAM_ROOT"
if [ "$SKIP_STEAM" = 1 ]; then
  echo "    SKIP_STEAM=1, skipping download"
else
  install -d "$(dirname "$STEAM_ROOT")"
  STEAM_ROOT="$STEAM_ROOT" GAME_USER="$GAME_USER" bash "$HERE/../fetch-steam-arm64.sh"
fi

log "8/8 per-user Steam SDK links for $GAME_USER"
su - "$GAME_USER" -c "
  mkdir -p ~/.steam ~/.local/share
  ln -sfn $STEAM_ROOT ~/.local/share/Steam
  ln -sfn $STEAM_ROOT ~/.steam/steam
  ln -sfn $STEAM_ROOT ~/.steam/root
  ln -sfn $STEAM_ROOT/linux64      ~/.steam/sdk64     2>/dev/null || true
  ln -sfn $STEAM_ROOT/linux32      ~/.steam/sdk32     2>/dev/null || true
  ln -sfn $STEAM_ROOT/linuxarm64   ~/.steam/sdkarm64  2>/dev/null || true
  ln -sfn $STEAM_ROOT/steamrtarm64 ~/.steam/bin64     2>/dev/null || true
  ln -sfn $STEAM_ROOT/steamrtarm64 ~/.steam/bin32     2>/dev/null || true
"

cat <<EOF

================  SteamOS-Mainline (RK1) install complete  ================
What was set up (non-destructive; k3s identity + /mnt/nvme Studio data untouched):
  * Mali PanVK-kbase fix20 registered as the system Vulkan ICD
  * FEX guest rootfs linked at /usr/share/guestos/fex-mesa
  * game-perf (stops k3s + maxes CPU/GPU/DMC/fan for a session)
  * steam-play launcher (gamescope Big Picture on HDMI)
  * steam-kiosk.service (installed, DISABLED)
  * native aarch64 Steam client at $STEAM_ROOT

To game (ATTACH A MONITOR to the RK1's HDMI first):
  From a tty1 login as '$GAME_USER':   steam-play         # sign in via QR code
  Then install a game and:             steam-play <APPID>
  When done:                           sudo game-perf off  # reverts + restarts k3s
  Optional auto-boot to Steam:         sudo systemctl enable --now steam-kiosk.service
=================================================================================
EOF
