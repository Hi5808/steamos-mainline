#!/bin/bash
# =============================================================================
# build-steamos-mainline.sh
#
# Turn a stock Armbian (mainline / panthor) RK3588 install into "SteamOS-Mainline":
# a native-aarch64 Steam client that runs x86 Windows games through FEX + Proton +
# VKD3D/DXVK on an open-source Mali-G610 Vulkan driver, on an HDMI display.
#
# Reproduces, from scratch and with NO personal data, the hand-built system
# documented in ../research/RESEARCH.md. You run this as root on the target board.
#
# TARGET (verified): Radxa Rock 5B+ (rk3588), Armbian 26.8.3 "resolute",
#   kernel 6.18.45 mainline (panthor), GNOME/GDM, an NVMe SSD, an HDMI display.
#
# NOT a drop-in for other boards. Orange Pi 5 / 5-Plus etc. are different boards
# (DTB, PMIC, HDMI routing); at minimum the HDMI step and fdtfile differ.
#
# Honest limits:
#   * 8 GB boards swap heavily with the full desktop + Steam + a game running
#     (~11 GB working set). Playable with the NVMe swap below, but not smooth;
#     16 GB boards are the comfortable target.
#   * The feature-complete Mali Vulkan driver is a prerequisite you supply
#     (DRIVER_SO); build it per ../research/RESEARCH.md section 13.
#
# Config via env (all optional except DRIVER_SO):
#   GAME_USER   desktop/game user to set up        (default: player)
#   DRIVER_SO   path to the feature-complete        (REQUIRED)
#               libvulkan_panfrost.so (PanVK-kbase, see RESEARCH.md s13)
#   NVME_DEV    NVMe partition for the library      (default: /dev/nvme0n1p1)
#   NVME_FORMAT set to 1 to mkfs.ext4 NVME_DEV      (default: 0 = use as-is)
#   FEX_ROOTFS  path to a FEX x86_64 rootfs .sqsh   (default: fetch via FEXRootFSFetcher)
#   HOSTNAME_NEW                                    (default: SteamOS-Mainline)
# =============================================================================
set -euo pipefail

GAME_USER="${GAME_USER:-player}"
DRIVER_SO="${DRIVER_SO:?set DRIVER_SO to the feature-complete libvulkan_panfrost.so (see research/RESEARCH.md s13)}"
NVME_DEV="${NVME_DEV:-/dev/nvme0n1p1}"
NVME_FORMAT="${NVME_FORMAT:-0}"
FEX_ROOTFS="${FEX_ROOTFS:-}"
HOSTNAME_NEW="${HOSTNAME_NEW:-SteamOS-Mainline}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STEAM_ROOT=/mnt/nvme/steamos/root
log(){ echo -e "\n==> $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
grep -q rk3588 /proc/device-tree/compatible 2>/dev/null || echo "WARN: doesn't look like RK3588"
[ -f "$DRIVER_SO" ] || { echo "DRIVER_SO not found: $DRIVER_SO"; exit 1; }

log "1/12 packages"
apt-get update -qq
apt-get install -y -qq curl unzip zstd python3 squashfs-tools fonts-dejavu-core >/dev/null

log "2/12 game user '$GAME_USER' + autologin"
id "$GAME_USER" &>/dev/null || adduser --disabled-password --gecos "Player" "$GAME_USER"
for g in video render input audio games sudo plugdev; do usermod -aG "$g" "$GAME_USER" 2>/dev/null || true; done
GUID=$(id -u "$GAME_USER")
install -d /etc/gdm3
cat > /etc/gdm3/custom.conf <<EOF
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = $GAME_USER
WaylandEnable = true
EOF

log "3/12 HDMI dw-hdmi-qp RGB workaround (boot service + kernel cmdline)"
install -m755 "$HERE/files/hdmi-edid-fix.sh" /usr/local/sbin/hdmi-edid-fix.sh
install -m644 "$HERE/files/hdmi-edid-fix.service" /etc/systemd/system/hdmi-edid-fix.service
systemctl enable hdmi-edid-fix.service
if [ -f /boot/armbianEnv.txt ] && ! grep -q edid_firmware /boot/armbianEnv.txt; then
  cp -a /boot/armbianEnv.txt /boot/armbianEnv.txt.bak
  sed -i 's#^extraargs=\(.*\)#extraargs=\1 drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin video=HDMI-A-1:1920x1080@60#' /boot/armbianEnv.txt \
    || echo 'extraargs=drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin video=HDMI-A-1:1920x1080@60' >> /boot/armbianEnv.txt
fi

log "4/12 lean: disable disposable services + GNOME bloat + screen lock"
for s in packagekit fwupd cups cups-browsed avahi-daemon ModemManager geoclue colord switcheroo-control; do
  systemctl disable --now "$s" 2>/dev/null || true
done
for f in /etc/xdg/autostart/org.gnome.Software.desktop /etc/xdg/autostart/evolution-alarm-notify.desktop; do
  [ -f "$f" ] && mv "$f" "$f.disabled" || true
done
install -d /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-steamos <<'EOF'
[org/gnome/desktop/lockdown]
disable-lock-screen=true
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
[org/gnome/desktop/session]
idle-delay=uint32 0
[org/gnome/desktop/interface]
enable-animations=false
EOF
dconf update || true

log "5/12 NVMe library + 8G swap (absorbs FEX/shader spikes; avoids OOM lock)"
install -d /mnt/nvme
if [ "$NVME_FORMAT" = 1 ]; then echo "  formatting $NVME_DEV"; mkfs.ext4 -F "$NVME_DEV"; fi
mountpoint -q /mnt/nvme || mount "$NVME_DEV" /mnt/nvme
UUID=$(blkid -s UUID -o value "$NVME_DEV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/nvme ext4 defaults,nofail,x-systemd.device-timeout=20 0 2" >> /etc/fstab
if [ ! -f /mnt/nvme/swapfile ]; then
  fallocate -l 8G /mnt/nvme/swapfile || dd if=/dev/zero of=/mnt/nvme/swapfile bs=1M count=8192
  chmod 600 /mnt/nvme/swapfile; mkswap /mnt/nvme/swapfile
fi
swapon /mnt/nvme/swapfile || true
grep -q /mnt/nvme/swapfile /etc/fstab || echo "/mnt/nvme/swapfile none swap sw,pri=10,x-systemd.requires=/mnt/nvme 0 0" >> /etc/fstab
sysctl -w vm.swappiness=10 >/dev/null; grep -q vm.swappiness /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf

log "6/12 feature-complete Mali Vulkan driver + host ICD"
install -d /opt/mesa-kbase/lib
install -m644 "$DRIVER_SO" /opt/mesa-kbase/lib/libvulkan_panfrost.so
cat > /usr/share/vulkan/icd.d/panvk-kbase.json <<EOF
{ "ICD": { "api_version": "1.4.363", "library_path": "/opt/mesa-kbase/lib/libvulkan_panfrost.so" }, "file_format_version": "1.0.0" }
EOF

log "7/12 FEX x86_64 guest rootfs -> /usr/share/guestos/fex-mesa"
if [ -z "$FEX_ROOTFS" ]; then
  command -v FEXRootFSFetcher >/dev/null || { echo "install FEX (fex-emu) or pass FEX_ROOTFS=<path to Ubuntu_24_04.sqsh>"; exit 1; }
  su - "$GAME_USER" -c 'FEXRootFSFetcher --distro-name=ubuntu --distro-version=24.04 -y' || true
  FEX_ROOTFS=$(ls /home/"$GAME_USER"/.fex-emu/RootFS/*.sqsh 2>/dev/null | head -1)
fi
[ -f "$FEX_ROOTFS" ] || { echo "no FEX rootfs"; exit 1; }
install -d /mnt/nvme/guestos
unsquashfs -f -d /mnt/nvme/guestos/fex-mesa "$FEX_ROOTFS"
install -d /usr/share/guestos
ln -sfn /mnt/nvme/guestos/fex-mesa /usr/share/guestos/fex-mesa

log "8/12 native aarch64 Steam client"
STEAM_ROOT="$STEAM_ROOT" GAME_USER="$GAME_USER" bash "$HERE/fetch-steam-arm64.sh"

log "9/12 per-user Steam SDK links (x86_64 steamclient for Proton's lsteamclient)"
su - "$GAME_USER" -c "
  mkdir -p ~/.steam ~/.local/share
  ln -sfn $STEAM_ROOT ~/.local/share/Steam
  ln -sfn $STEAM_ROOT ~/.steam/steam
  ln -sfn $STEAM_ROOT ~/.steam/root
  ln -sfn $STEAM_ROOT/linux64     ~/.steam/sdk64
  ln -sfn $STEAM_ROOT/linux32     ~/.steam/sdk32
  ln -sfn $STEAM_ROOT/linuxarm64  ~/.steam/sdkarm64
  ln -sfn $STEAM_ROOT/steamrtarm64 ~/.steam/bin64
  ln -sfn $STEAM_ROOT/steamrtarm64 ~/.steam/bin32
"

log "10/12 performance governor tool + passwordless hook"
install -m755 "$HERE/files/game-perf" /usr/local/sbin/game-perf
echo "$GAME_USER ALL=(root) NOPASSWD: /usr/local/sbin/game-perf" > /etc/sudoers.d/game-perf
chmod 440 /etc/sudoers.d/game-perf

log "11/12 launcher: /usr/local/bin/steam-play [APPID] + desktop app entry"
sed -e "s/@GAME_USER@/$GAME_USER/g" -e "s/@UID@/$GUID/g" "$HERE/files/steam-play.in" > /usr/local/bin/steam-play
chmod 755 /usr/local/bin/steam-play
# clickable app in the GNOME grid/dash
install -Dm644 "$HERE/files/steam.desktop" /usr/share/applications/steam-steamos-mainline.desktop
update-desktop-database /usr/share/applications 2>/dev/null || true

log "12/12 hostname -> $HOSTNAME_NEW"
echo "$HOSTNAME_NEW" > /etc/hostname
sed -i "s/\b$(hostname)\b/$HOSTNAME_NEW/g" /etc/hosts 2>/dev/null || true
hostnamectl set-hostname "$HOSTNAME_NEW" 2>/dev/null || true
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="SteamOS-Mainline"/' /etc/os-release 2>/dev/null || true

cat <<EOF

================  SteamOS-Mainline build complete  ================
Reboot, then on the desktop (auto-login as '$GAME_USER'):
  1. Run:  steam-play            # starts Steam; sign in with the QR code
  2. Install a game. For a D3D game, set its compatibility tool to
     Proton (Properties > Compatibility > Proton Experimental).
  3. Launch it fullscreen with:  steam-play <APPID>
     (applies perf mode, FEX speed levers, display + FPS overlay)
  4. When done gaming:  sudo game-perf off

No credentials are stored by this build -- you log into Steam yourself.
8 GB board: expect swap pressure; lower in-game resolution for smoother play.
===================================================================
EOF
