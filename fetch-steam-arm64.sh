#!/bin/bash
# fetch-steam-arm64.sh  -- download and assemble Valve's native aarch64 Steam
# client (the one shipped with the Steam Frame) straight from Valve's client
# manifest. No account or login involved; this only lays down the client files.
#
# Env:
#   STEAM_ROOT   where to assemble the client   (default /mnt/nvme/steamos/root)
#   GAME_USER    owner of the files             (default player)
#   CHANNEL      stable | publicbeta            (default stable)
#
# The depot zips use Windows-style '\' path separators and store NO unix exec
# bits, so we extract with python (rewrite '\'->'/', chmod +x every ELF).
set -euo pipefail
STEAM_ROOT="${STEAM_ROOT:-/mnt/nvme/steamos/root}"
GAME_USER="${GAME_USER:-player}"
CHANNEL="${CHANNEL:-stable}"
BASE=https://client-update.fastly.steamstatic.com
case "$CHANNEL" in
  stable)     MANIFEST=steam_client_linuxarm64 ;;
  publicbeta) MANIFEST=steam_client_publicbeta_linuxarm64 ;;
  *) echo "CHANNEL must be stable|publicbeta"; exit 1 ;;
esac

W=$(dirname "$STEAM_ROOT"); mkdir -p "$W/depot" "$STEAM_ROOT"
echo "==> fetching manifest $MANIFEST"
curl -fsSL "$BASE/$MANIFEST" -o "$W/manifest.vdf"
VER=$(awk -F'"' '/"version"/{print $4; exit}' "$W/manifest.vdf")
echo "    client version $VER"

# Pull every component ending in _all or _linuxarm64_linuxarm64 (name file sha).
awk '
  /^\t"[a-z0-9_]+"$/ { name=$1; gsub(/"/,"",name) }
  /"file"/ { gsub(/"/,""); file=$2 }
  /"sha2"[^v]/ { gsub(/"/,""); sha=$2;
    if (name ~ /(_all|_linuxarm64_linuxarm64)$/) print file, sha }
' "$W/manifest.vdf" > "$W/comps.txt"

n=$(wc -l < "$W/comps.txt"); i=0
while read -r file sha; do
  i=$((i+1)); out="$W/depot/$file"
  if [ ! -f "$out" ] || [ "$(sha256sum < "$out" | cut -d' ' -f1)" != "$sha" ]; then
    echo "    [$i/$n] get $file"
    curl -fsSL "$BASE/$file" -o "$out"
  fi
  [ "$(sha256sum < "$out" | cut -d' ' -f1)" = "$sha" ] || { echo "SHA MISMATCH $file"; exit 1; }
done < "$W/comps.txt"

echo "==> extracting (fixing '\\' paths + exec bits)"
python3 -I - "$W/depot" "$STEAM_ROOT" <<'PY'
import sys, os, glob, zipfile, stat
depot, root = sys.argv[1], sys.argv[2]
for z in sorted(glob.glob(os.path.join(depot, "*.zip.*"))):
    with zipfile.ZipFile(z) as zf:
        for m in zf.infolist():
            name = m.filename.replace("\\", "/")
            if name.endswith("/"):
                continue
            dst = os.path.join(root, name)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with zf.open(m) as src, open(dst, "wb") as out:
                out.write(src.read())
# mark every ELF executable (depot zips carry no unix mode bits)
n = 0
for dp, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(dp, f)
        try:
            with open(p, "rb") as fh:
                if fh.read(4) == b"\x7fELF":
                    os.chmod(p, 0o755); n += 1
        except Exception:
            pass
print(f"    extracted; chmod +x on {n} ELF files")
PY

chown -R "$GAME_USER":"$GAME_USER" "$STEAM_ROOT"
echo "==> native arm64 Steam client assembled at $STEAM_ROOT (v$VER)"
