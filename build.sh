#!/usr/bin/env bash
#
# build-camellian-kernel.sh
#
# Local (Ubuntu 22.04) equivalent of:
#   .github/workflows/build-kernel.yml
#
# Run from the root of the kernel source tree:
#   cd /root/camellian-t-os
#   chmod +x build-camellian-kernel.sh
#   ./build-camellian-kernel.sh
#
# Optional:
#   DEFCONFIG=camellian_gl_defconfig ./build-camellian-kernel.sh
#   SKIP_DEPS=1 ./build-camellian-kernel.sh   # skip sudo apt install
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (mirrors workflow env + inputs)
# ---------------------------------------------------------------------------
DEFCONFIG="${DEFCONFIG:-camellian_gl_defconfig}"
ARCH="arm64"
CLANG_VERSION="clang-r383902"
CLANG_REF="4114ce222c83ba93e9c12c91c6ced2541b28f88c"
CLANG_REPO_URL="https://github.com/msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86.git"
GCC_REPO_URL="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git"
GCC_REF="lineage-19.1"

KERNEL_DIR="$(pwd)"
test -f "$KERNEL_DIR/Makefile" || {
  echo "ERROR: run this script from the kernel source root (Makefile not found)."
  exit 1
}

TOOLCHAIN_SRC="$KERNEL_DIR/toolchain-src"
CLANG_DEST="$KERNEL_DIR/prebuilts/clang/host/linux-x86/$CLANG_VERSION"
CLANG_BIN="$CLANG_DEST/bin"
GCC_DEST="$KERNEL_DIR/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"
GCC_BIN="$GCC_DEST/bin"

echo "Kernel source : $KERNEL_DIR"
echo "Defconfig     : $DEFCONFIG"
echo "Clang version : $CLANG_VERSION"
echo

# ---------------------------------------------------------------------------
# 1) Install Dependencies
# ---------------------------------------------------------------------------
if [ "${SKIP_DEPS:-0}" != "1" ]; then
  echo "=== [1/7] Install Dependencies ==="
  sudo apt-get update
  sudo apt-get install -y \
    bc bison build-essential ccache \
    curl flex git libelf-dev libssl-dev \
    libncurses-dev lld make \
    python3 rsync unzip zip \
    device-tree-compiler \
    gcc g++ liblz4-tool
else
  echo "=== [1/7] Install Dependencies (skipped, SKIP_DEPS=1) ==="
fi

# ---------------------------------------------------------------------------
# 2) Checkout AOSP Clang R383902 (sparse)
# ---------------------------------------------------------------------------
echo "=== [2/7] Checkout AOSP Clang R383902 ==="
mkdir -p "$TOOLCHAIN_SRC"

if [ ! -d "$TOOLCHAIN_SRC/clang/.git" ]; then
  git clone --filter=blob:none --sparse \
    "$CLANG_REPO_URL" "$TOOLCHAIN_SRC/clang"
fi

pushd "$TOOLCHAIN_SRC/clang" >/dev/null
git sparse-checkout set "$CLANG_VERSION"
git fetch --depth 1 origin "$CLANG_REF"
git checkout "$CLANG_REF"
popd >/dev/null

# ---------------------------------------------------------------------------
# 3) Checkout Android GCC 4.9
# ---------------------------------------------------------------------------
echo "=== [3/7] Checkout Android GCC 4.9 ==="
if [ ! -d "$TOOLCHAIN_SRC/gcc/.git" ]; then
  git clone --depth 1 -b "$GCC_REF" \
    "$GCC_REPO_URL" "$TOOLCHAIN_SRC/gcc"
fi

# ---------------------------------------------------------------------------
# 4) Setup TOS Toolchains
# ---------------------------------------------------------------------------
echo "=== [4/7] Setup TOS Toolchains ==="
mkdir -p "$KERNEL_DIR/prebuilts/clang/host/linux-x86"
mkdir -p "$KERNEL_DIR/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

rm -rf "$CLANG_DEST"
cp -a "$TOOLCHAIN_SRC/clang/$CLANG_VERSION" \
      "$KERNEL_DIR/prebuilts/clang/host/linux-x86/"

cp -a "$TOOLCHAIN_SRC/gcc/." "$GCC_DEST/"

chmod +x "$CLANG_BIN/clang"

test -x "$CLANG_BIN/clang"
test -x "$CLANG_BIN/ld.lld"
test -x "$GCC_BIN/aarch64-linux-androidkernel-gcc"

export PATH="$CLANG_BIN:$GCC_BIN:$PATH"
export LD_LIBRARY_PATH="$CLANG_DEST/lib64:${LD_LIBRARY_PATH:-}"

echo "=== CLANG ==="
"$CLANG_BIN/clang" --version
echo "=== LLD ==="
"$CLANG_BIN/ld.lld" --version
echo "=== GCC ==="
"$GCC_BIN/aarch64-linux-androidkernel-gcc" --version

# ---------------------------------------------------------------------------
# 5) Verify Source
# ---------------------------------------------------------------------------
echo "=== [5/7] Verify Source ==="
echo "=== KERNEL VERSION ==="
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile

echo "=== DEFCONFIG ==="
test -f "arch/arm64/configs/$DEFCONFIG"
echo "$DEFCONFIG"

echo "=== TOOLCHAIN CONFIG ==="
cat build.config.mtk.aarch64

# ---------------------------------------------------------------------------
# 6) Build Kernel
# ---------------------------------------------------------------------------
echo "=== [6/7] Build Kernel ==="

CROSS_COMPILE="$GCC_BIN/aarch64-linux-androidkernel-"

BUILD_ARGS=(
  -j"$(nproc)"
  O=out
  ARCH=arm64
  CC=clang
  LD=ld.lld
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  AR=llvm-ar
  OBJDUMP=llvm-objdump
  STRIP=llvm-strip
  CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE="$CROSS_COMPILE"
)

echo "=== GENERATING CONFIG ==="
make "${BUILD_ARGS[@]}" "$DEFCONFIG"

echo "=== BUILDING KERNEL ==="
make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

echo "=== BUILD OUTPUT ==="
find out/arch/arm64/boot -maxdepth 2 -type f

# ---------------------------------------------------------------------------
# 7) Validate Artifacts (mirrors `if-no-files-found: error`)
# ---------------------------------------------------------------------------
echo "=== [7/7] Validate Artifacts ==="
ARTIFACTS=(
  "out/arch/arm64/boot/Image"
  "out/arch/arm64/boot/Image.gz"
  "out/arch/arm64/boot/Image.gz-dtb"
  "out/vmlinux"
  "out/System.map"
  "out/.config"
  "build.log"
)

missing=0
for f in "${ARTIFACTS[@]}"; do
  if [ -e "$f" ]; then
    echo "  OK   $f"
  else
    echo "  MISS $f"
    missing=1
  fi
done

dtb_count="$(find out/arch/arm64/boot -type f -name '*.dtb' 2>/dev/null | wc -l)"
echo "  DTBs: $dtb_count file(s)"
if [ "$dtb_count" -eq 0 ]; then
  echo "  MISS no .dtb files found"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  echo "ERROR: one or more expected artifacts are missing."
  exit 1
fi

echo
echo "Build complete. Artifacts are under: $KERNEL_DIR/out/"
echo "  - Image        : out/arch/arm64/boot/Image"
echo "  - Image.gz     : out/arch/arm64/boot/Image.gz"
echo "  - Image.gz-dtb : out/arch/arm64/boot/Image.gz-dtb"
echo "  - vmlinux      : out/vmlinux"
echo "  - System.map   : out/System.map"
echo "  - .config      : out/.config"
echo "  - build log    : build.log"
