#!/bin/bash
# Build the iOS app (iPad mini 2: A7 "cyclone", iOS 12) from the NA v1.2 lift.
#
#   ios/build_ios.sh            shards (if needed) + runtime + link + bundle + sign
#   ios/build_ios.sh rt         runtime + link + bundle only (shards already built)
#
# Needs gen/na (tools/gen_v2.sh with the NA exe) and ldid on the Mac.
# Output: out/ios/NFSU2.app  (gitignored, like all of out/)
#
# Differences from build.sh/link.sh (macOS):
#  - target arm64-apple-ios12.0, -mcpu=cyclone; -O2 instead of -O3 (smaller code: the
#    A7 has 64 KB L1i, the lifted code is ~35 MB)
#  - runtime: bundle_ios.m + ios_app.m replace bundle.m and the AppKit window;
#    tests/boot.c is compiled with -Dmain=nfs_boot_main (ios_app.m owns main)
#  - linked with a 16 KB __PAGEZERO: the default 4 GB one leaves only ~1.1 GB of
#    contiguous VA on the mini 2; with 16 KB, >= ~3 GB (vaprobe, PLAN.md section 7)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
WHAT="${1:-all}"
GEN=gen/na
OBJ=out/ios/obj_na
RO=out/ios/obj_rt
APP=out/ios/NFSU2.app
SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CC="$(xcrun -sdk iphoneos -f clang)"
TGT="-target arm64-apple-ios12.0 -isysroot $SDK -mcpu=cyclone"
OPT="${OPT:--O2 -fno-strict-aliasing}"
XDEF="-DNFS_EXE_NA=1 -include runtime/build_na.h -DNFS_ENHANCED=0 -DNFS_GUEST_IN_IMAGE=1"
VERSION="$(tr -cd '0-9' < VERSION 2>/dev/null)"; VERSION="${VERSION:-0}"
J="${J:-$(sysctl -n hw.ncpu)}"
[ -d "$GEN" ] || { echo "missing $GEN (run tools/gen_v2.sh for the NA exe)"; exit 1; }
mkdir -p "$OBJ" "$RO"

if [ "$WHAT" = all ]; then
  echo "== shards ($J jobs)"
  export CC TGT OPT ROOT OBJ
  ( cd "$GEN" && ls shard_*.c fntab.c stubs.c | xargs -P "$J" -n 1 sh -c '
      o="$ROOT/$OBJ/$(basename "$1" .c).o"
      [ -f "$o" ] && [ "$o" -nt "$1" ] && exit 0
      out=$($CC $TGT $OPT -c -I"$ROOT/runtime" -I. -Wno-unused-label -Wno-parentheses-equality -o "$o" "$1" 2>&1); r=$?
      [ -z "$out" ] || printf "%s\n" "$out" | head -5
      [ $r -eq 0 ] || echo "COMPILE FAILED: $1" >&2
      exit $r' sh )
fi

echo "== runtime"
CSRC="mem dispatch genexec win32 win32_ext com debug res fileio overrides d3dx_hle vsemu perflog wsfov gheap"
MSRC="metal audio gamepad bundle_ios ios_app"
pids=""
RTOPT="$OPT -g"     # runtime with debug info -> out/ios/NFSU2.dSYM (symbolicate device crashes)
for f in $CSRC; do
  $CC $TGT $RTOPT $XDEF -DNFS_VERSION=$VERSION -Iruntime -I$GEN -c -o "$RO/$f.o" "runtime/$f.c" & pids="$pids $!"
done
for f in $MSRC; do
  $CC $TGT $RTOPT $XDEF -DNFS_VERSION=$VERSION -fobjc-arc -Wno-unguarded-availability-new -Iruntime -I$GEN \
      -c -o "$RO/$f.o" "runtime/$f.m" & pids="$pids $!"
done
$CC $TGT $OPT -Iruntime -I$GEN -c -o "$RO/impargs.o" $GEN/impargs.c & pids="$pids $!"
$CC $TGT $RTOPT $XDEF -Dmain=nfs_boot_main -Iruntime -I$GEN -c -o "$RO/boot.o" tests/boot.c & pids="$pids $!"
for p in $pids; do wait "$p" || { echo "runtime compile error"; exit 1; }; done

echo "== link"
rm -rf "$APP"; mkdir -p "$APP"
RT=""; for f in $CSRC $MSRC impargs boot; do RT="$RT $RO/$f.o"; done
$CC $TGT -o "$APP/NFSU2" $OBJ/shard_*.o $OBJ/fntab.o $OBJ/stubs.o $RT \
    -Wl,-pagezero_size,0x4000 -Wl,-dead_strip \
    -lm -framework UIKit -framework Foundation -framework Metal -framework QuartzCore \
    -framework ImageIO -framework CoreGraphics -framework AudioToolbox -framework AVFoundation \
    -framework GameController
rm -rf out/ios/NFSU2.dSYM; dsymutil "$APP/NFSU2" -o out/ios/NFSU2.dSYM 2>/dev/null || true
strip -S "$APP/NFSU2"
cp ios/Info.plist "$APP/Info.plist"
# App icon from a square image OUTSIDE the repo (the fork is public: no logos in git).
# ICON=<path>, default ../nfsug2.jpg (apps/legacy-ios12-arm64/NFSU2iOS/nfsug2.jpg).
ICON="${ICON:-$ROOT/../nfsug2.jpg}"
if [ -f "$ICON" ]; then
  for spec in "Icon-76:76" "Icon-76@2x:152" "Icon-83.5@2x:167" "Icon-40:40" "Icon-40@2x:80" "Icon-29:29" "Icon-29@2x:58"; do
    sips -s format png -z "${spec#*:}" "${spec#*:}" "$ICON" --out "$APP/${spec%%:*}~ipad.png" >/dev/null
  done
else
  echo "no icon source ($ICON): building without an icon"
fi
printf 'APPL????' > "$APP/PkgInfo"
ldid -Sios/entitlements.plist -Icom.legacylab.nfsu2 "$APP/NFSU2"
ls -l "$APP/NFSU2"
otool -l "$APP/NFSU2" | grep -A5 'segname __PAGEZERO' | grep vmsize
echo "built $APP"
