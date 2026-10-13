#!/bin/bash
# Build Better Music for Dopamine (rootless, iOS 15).
#
#   THEOS      path to Theos            (default: $HOME/theos; needs the iOS 15 SDK in $THEOS/sdks)
#   ALLEMANDE  optional: path to the "allemande" arm64e new-ABI converter. Needed ONLY when building on Linux for
#              A12+ iPhones (arm64e); on macOS the Xcode toolchain already produces the right ABI.
#   LDID       path to ldid, used to re-sign after conversion (default: ldid from PATH or Theos toolchain)
#
# Output: dist/com.rocketkid300.bettermusic_<version>_iphoneos-arm64.deb
set -euo pipefail
cd "$(dirname "$0")"
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"

make clean package FINALPACKAGE=1
DEB=$(ls -t packages/com.rocketkid300.bettermusic_*.deb | head -1)
mkdir -p dist

if [ -n "${ALLEMANDE:-}" ]; then
  LDID="${LDID:-$(command -v ldid || echo "$THEOS/toolchain/linux/iphone/bin/ldid")}"
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
  dpkg-deb -x "$DEB" "$WORK/root"; dpkg-deb -e "$DEB" "$WORK/root/DEBIAN"
  for f in "$WORK"/root/var/jb/Library/MobileSubstrate/DynamicLibraries/*.dylib \
           "$WORK"/root/var/jb/Library/PreferenceBundles/BetterMusicPrefs.bundle/BetterMusicPrefs; do
    echo ">> converting $(basename "$f") to the arm64e new ABI"
    "$ALLEMANDE" "$f" "$f" >/dev/null
    "$LDID" -s "$f"; "$LDID" -S "$f"
  done
  OUT="dist/$(basename "$DEB")"
  dpkg-deb -b -Zgzip --root-owner-group "$WORK/root" "$OUT" >/dev/null
else
  OUT="dist/$(basename "$DEB")"; cp "$DEB" "$OUT"
  echo ">> ALLEMANDE not set: skipping the arm64e conversion (fine on macOS)"
fi
echo ">> built $OUT"
