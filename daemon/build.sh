#!/bin/bash
# daemon/build.sh — 使用 Android NDK 交叉编译 hotspotd
# 用法：
#   export ANDROID_NDK=/path/to/android-ndk
#   bash daemon/build.sh [arm64|arm|x86_64]
#
# 输出：daemon/prebuilt/<arch>/hotspotd
# 模块 ZIP 中预置的二进制在 bin/hotspotd（arm64-v8a）

set -e
cd "$(dirname "$0")"

ARCH=${1:-arm64}
SRC=hotspotd.c
OUTDIR=prebuilt/${ARCH}
OUT=${OUTDIR}/hotspotd

mkdir -p "$OUTDIR"

# ── 方案一：使用 NDK standalone toolchain ──────────────────────
if [ -z "$ANDROID_NDK" ] && [ -z "$CC" ]; then
    echo "[build] ERROR: 请设置 ANDROID_NDK 或 CC 环境变量"
    echo "  export ANDROID_NDK=/path/to/android-ndk-r26"
    echo "  或 export CC=aarch64-linux-android21-clang"
    exit 1
fi

case "$ARCH" in
    arm64)   TARGET=aarch64-linux-android;  API=21 ;;
    arm)     TARGET=armv7a-linux-androideabi; API=21 ;;
    x86_64)  TARGET=x86_64-linux-android;   API=21 ;;
    *)       echo "Unknown arch: $ARCH"; exit 1 ;;
esac

if [ -n "$ANDROID_NDK" ]; then
    HOST_TAG=$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)
    TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/$HOST_TAG"
    CC="$TOOLCHAIN/bin/${TARGET}${API}-clang"
fi

echo "[build] Compiler: $CC"
echo "[build] Target:   $ARCH  Output: $OUT"

$CC \
    -O2 \
    -std=c11 \
    -Wall \
    -Wextra \
    -static-libgcc \
    -D_GNU_SOURCE \
    -DANDROID \
    -fPIE -pie \
    -o "$OUT" \
    "$SRC"

strip "$OUT" 2>/dev/null || true
echo "[build] OK: $(ls -lh "$OUT" | awk '{print $5}')  $OUT"

# ── 复制到 bin/ 供打包 ─────────────────────────────────────────
BINDIR=../bin
mkdir -p "$BINDIR"
cp "$OUT" "$BINDIR/hotspotd"
echo "[build] Copied to $BINDIR/hotspotd"

# ── 在 HOST Linux 上快速测试编译（功能测试用，非 Android）──────
echo ""
echo "=== Host build (for syntax check only) ==="
HOST_OUT=${OUTDIR}/hotspotd_host
gcc -O0 -std=c11 -Wall -D_GNU_SOURCE -o "$HOST_OUT" "$SRC" 2>&1 || true
[ -f "$HOST_OUT" ] && echo "Host build: OK" || echo "Host build: skipped (different libc)"
