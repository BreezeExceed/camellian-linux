#!/usr/bin/env bash
# =============================================================================
#  build-kernel.sh  --  Build Camellian TOS Kernel (Linux 4.14.186 ARM64)
#
#  Local / Ubuntu 22.04 version of .github/workflows/build-kernel.yml
#  Every workflow step is kept, in the same order:
#     Checkout TOS Kernel -> Install Dependencies -> Checkout AOSP Clang R383902
#     -> Checkout Android GCC 4.9 -> Setup TOS Toolchains -> Verify Source
#     -> Build Kernel -> Upload Kernel Artifacts (collected into ./artifacts/)
#
#  Run it from INSIDE the kernel source directory:
#     cd /path/to/camellian-t-os
#     bash /path/to/build-kernel.sh                      # interactive menu
#     bash /path/to/build-kernel.sh camellian_ru_defconfig   # skip the menu
#     DEFCONFIG=camellian_tr_defconfig bash build-kernel.sh  # same, via env
#
#  Optional env vars:
#     BUILD_TIMEOUT_MIN=180   kernel build time limit in minutes (0 = no limit)
# =============================================================================

set -Eeuo pipefail
trap 'rc=$?; echo "[ERROR] line ${LINENO}: \"${BASH_COMMAND}\" exited with status ${rc}" >&2' ERR

step() { printf '\n==================== %s ====================\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# prompt on stderr, answer into $REPLY (falls back to default on empty / EOF)
ask() {
  local prompt="$1" default="${2-}"
  printf '%s' "$prompt" >&2
  IFS= read -r REPLY || REPLY=""
  REPLY="${REPLY:-$default}"
}

# -----------------------------------------------------------------------------
# Workflow "env:" block
# -----------------------------------------------------------------------------
KERNEL_DIR="$(pwd)"
WORKSPACE="$KERNEL_DIR"                 # == $GITHUB_WORKSPACE in the workflow
export ARCH=arm64
export CLANG_VERSION=clang-r383902
BUILD_TIMEOUT_MIN="${BUILD_TIMEOUT_MIN:-180}"   # workflow: timeout-minutes: 180

CFG_DIR="arch/arm64/configs"

# Debug defconfigs intentionally NOT listed.
DEFCONFIG_OPTIONS=(
  camellian_defconfig
  camellian_gl_defconfig
  camellian_id_defconfig
  camellian_in_eea_defconfig
  camellian_ru_defconfig
  camellian_tr_defconfig
)
CUSTOM_INDEX=$(( ${#DEFCONFIG_OPTIONS[@]} + 1 ))

# -----------------------------------------------------------------------------
# Custom defconfig writer
# -----------------------------------------------------------------------------
find_editor() {
  local e
  for e in "${VISUAL:-}" "${EDITOR:-}" nano vim vi; do
    [ -n "$e" ] || continue
    if command -v "${e%% *}" >/dev/null 2>&1; then
      printf '%s' "$e"
      return 0
    fi
  done
  return 1
}

write_custom_defconfig() {
  local name target method base i tmp editor

  ask "Custom defconfig name [camellian_custom_defconfig]: " camellian_custom_defconfig
  name="$(basename -- "$REPLY")"
  case "$name" in
    *_defconfig) ;;
    *) name="${name}_defconfig" ;;      # kbuild only accepts *_defconfig
  esac
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid defconfig name: $name"
  target="$CFG_DIR/$name"

  if [ -f "$target" ]; then
    warn "$target already exists."
    ask "  [u]se as is / [r]ewrite (backup is kept) / [a]bort  [u]: " u
    case "$REPLY" in
      r|R) cp -a "$target" "$target.bak-$(date +%Y%m%d-%H%M%S)" ;;
      a|A) die "Aborted." ;;
      *)   DEFCONFIG="$name"; info "Using existing $target"; return 0 ;;
    esac
  fi

  {
    echo "How do you want to write it?"
    echo "  1) Open in a text editor (can start from an existing defconfig)"
    echo "  2) Paste / type it here (finish with Ctrl+D on a new line)"
  } >&2
  ask "Method [1]: " 1
  method="$REPLY"

  tmp="$(mktemp)"

  editor=""
  if [ "$method" != "2" ]; then
    if ! editor="$(find_editor)"; then
      warn "No text editor found (nano/vim/vi) - switching to paste mode."
      method=2
    fi
  fi

  if [ "$method" = "2" ]; then
    echo "Paste your defconfig now, then press Ctrl+D:" >&2
    cat > "$tmp"
  else
    {
      echo "Start from:"
      echo "  0) empty file"
      for i in "${!DEFCONFIG_OPTIONS[@]}"; do
        printf '  %d) copy of %s\n' $((i + 1)) "${DEFCONFIG_OPTIONS[$i]}"
      done
    } >&2
    ask "Base [0]: " 0
    base="$REPLY"
    if [[ "$base" =~ ^[0-9]+$ ]] && [ "$((10#$base))" -ge 1 ] && [ "$((10#$base))" -le "${#DEFCONFIG_OPTIONS[@]}" ] \
       && [ -f "$CFG_DIR/${DEFCONFIG_OPTIONS[$((10#$base - 1))]}" ]; then
      cp "$CFG_DIR/${DEFCONFIG_OPTIONS[$((10#$base - 1))]}" "$tmp"
    else
      printf '# Custom defconfig: %s\n' "$name" > "$tmp"
    fi
    # shellcheck disable=SC2086
    $editor "$tmp"
  fi

  sed -i 's/\r$//' "$tmp"     # strip Windows line endings from pasted text

  if ! grep -Eq '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' "$tmp"; then
    rm -f "$tmp"
    die "No CONFIG_xxx lines found - nothing written."
  fi

  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
  DEFCONFIG="$name"
  info "Custom defconfig written: $target ($(wc -l < "$target") lines)"
}

# -----------------------------------------------------------------------------
# Workflow "inputs.defconfig" (choice)  -> interactive menu
# -----------------------------------------------------------------------------
choose_defconfig() {
  local i choice
  {
    echo "Select Camellian defconfig:"
    for i in "${!DEFCONFIG_OPTIONS[@]}"; do
      if [ "$i" -eq 0 ]; then
        printf '  %d) %s   (default)\n' $((i + 1)) "${DEFCONFIG_OPTIONS[$i]}"
      else
        printf '  %d) %s\n' $((i + 1)) "${DEFCONFIG_OPTIONS[$i]}"
      fi
    done
    printf '  %d) Custom defconfig (write your own)\n' "$CUSTOM_INDEX"
  } >&2

  while true; do
    ask "Choice [1]: " 1
    choice="$REPLY"
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      choice=$((10#$choice))
      if [ "$choice" -ge 1 ] && [ "$choice" -le "$CUSTOM_INDEX" ]; then
        break
      fi
    fi
    warn "Invalid choice: $REPLY"
  done

  if [ "$choice" -eq "$CUSTOM_INDEX" ]; then
    write_custom_defconfig
  else
    DEFCONFIG="${DEFCONFIG_OPTIONS[$((choice - 1))]}"
  fi
}

# =============================================================================
#  Step: Checkout TOS Kernel  (local: we are already in the kernel tree)
# =============================================================================
step "Checkout TOS Kernel"
[ -f Makefile ] && [ -d "$CFG_DIR" ] && grep -q '^VERSION' Makefile \
  || die "Run this script from the kernel source root (Makefile + $CFG_DIR not found in $KERNEL_DIR)."
info "Kernel source: $KERNEL_DIR"

# ---- pick the defconfig up front so the rest can run unattended ------------
DEFCONFIG="${1:-${DEFCONFIG:-}}"
if [ -z "$DEFCONFIG" ]; then
  choose_defconfig
fi
export DEFCONFIG
info "DEFCONFIG = $DEFCONFIG"

# ---- environment sanity (the workflow runs on ubuntu-22.04 x86_64) ---------
if [ -r /etc/os-release ]; then
  os_id="$(. /etc/os-release && echo "${ID:-}")"
  os_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  if [ "$os_id" != "ubuntu" ] || [ "$os_ver" != "22.04" ]; then
    warn "Designed for Ubuntu 22.04, detected: ${os_id:-unknown} ${os_ver}. Continuing anyway."
  fi
fi
[ "$(uname -m)" = "x86_64" ] || die "The prebuilt AOSP clang/gcc toolchains are x86_64 only (this machine: $(uname -m))."

if [ -f .config ] || [ -d include/config ]; then
  warn "Source tree is not clean (.config / include/config found). O=out builds need a clean tree;"
  warn "if make complains, run:  make ARCH=arm64 mrproper"
fi

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# =============================================================================
#  Step: Install Dependencies
# =============================================================================
step "Install Dependencies"
$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  bc bison build-essential ccache \
  curl flex git libelf-dev libssl-dev \
  libncurses-dev lld make \
  python3 rsync unzip zip \
  device-tree-compiler \
  gcc g++ liblz4-tool

# =============================================================================
#  Step: Checkout AOSP Clang R383902
#    repo : msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86
#    ref  : 4114ce222c83ba93e9c12c91c6ced2541b28f88c
#    path : toolchain-src/clang   (sparse-checkout, cone mode: clang-r383902)
# =============================================================================
step "Checkout AOSP Clang R383902"
CLANG_REPO="https://github.com/msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86.git"
CLANG_REF="4114ce222c83ba93e9c12c91c6ced2541b28f88c"
CLANG_SRC="$WORKSPACE/toolchain-src/clang"

if [ -e "$CLANG_SRC/clang-r383902/bin/ld.lld" ]; then
  info "Clang source already present: $CLANG_SRC (skipping download)"
else
  rm -rf "$CLANG_SRC"
  mkdir -p "$CLANG_SRC"
  git -C "$CLANG_SRC" init -q
  git -C "$CLANG_SRC" remote add origin "$CLANG_REPO"
  git -C "$CLANG_SRC" sparse-checkout init --cone
  git -C "$CLANG_SRC" sparse-checkout set clang-r383902
  git -C "$CLANG_SRC" fetch --depth=1 --filter=blob:none origin "$CLANG_REF"
  git -C "$CLANG_SRC" -c advice.detachedHead=false checkout --detach FETCH_HEAD
fi

# =============================================================================
#  Step: Checkout Android GCC 4.9
#    repo : LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9
#    ref  : lineage-19.1   (depth 1)   path: toolchain-src/gcc
# =============================================================================
step "Checkout Android GCC 4.9"
GCC_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git"
GCC_SRC="$WORKSPACE/toolchain-src/gcc"

if [ -e "$GCC_SRC/bin/aarch64-linux-androidkernel-gcc" ]; then
  info "GCC source already present: $GCC_SRC (skipping download)"
else
  rm -rf "$GCC_SRC"
  git clone --depth 1 --branch lineage-19.1 "$GCC_REPO" "$GCC_SRC"
fi

# =============================================================================
#  Step: Setup TOS Toolchains
# =============================================================================
step "Setup TOS Toolchains"
cd "$WORKSPACE"

mkdir -p prebuilts/clang/host/linux-x86
mkdir -p prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9

if [ ! -e prebuilts/clang/host/linux-x86/clang-r383902/bin/ld.lld ]; then
  cp -a toolchain-src/clang/clang-r383902 \
    prebuilts/clang/host/linux-x86/
fi

if [ ! -e prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-gcc ]; then
  cp -a toolchain-src/gcc/. \
    prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/
fi

CLANG_BIN="$WORKSPACE/prebuilts/clang/host/linux-x86/clang-r383902/bin"
GCC_BIN="$WORKSPACE/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"

chmod +x "$CLANG_BIN/clang"

test -x "$CLANG_BIN/clang"
test -x "$CLANG_BIN/ld.lld"
test -x "$GCC_BIN/aarch64-linux-androidkernel-gcc"

# workflow: echo ... >> "$GITHUB_PATH"  ->  local: export PATH
export PATH="$GCC_BIN:$CLANG_BIN:$PATH"

echo "=== CLANG ==="
"$CLANG_BIN/clang" --version

echo "=== LLD ==="
"$CLANG_BIN/ld.lld" --version

echo "=== GCC ==="
"$GCC_BIN/aarch64-linux-androidkernel-gcc" --version

# =============================================================================
#  Step: Verify Source
# =============================================================================
step "Verify Source"
echo "=== KERNEL VERSION ==="
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile

echo "=== DEFCONFIG ==="
test -f "arch/arm64/configs/$DEFCONFIG"
echo "$DEFCONFIG"

echo "=== TOOLCHAIN CONFIG ==="
cat build.config.mtk.aarch64

# =============================================================================
#  Step: Build Kernel
# =============================================================================
step "Build Kernel"

CLANG_DIR="$WORKSPACE/prebuilts/clang/host/linux-x86/clang-r383902"
GCC_BIN="$WORKSPACE/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"

export PATH="$CLANG_DIR/bin:$GCC_BIN:$PATH"
export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"

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
timeout "${BUILD_TIMEOUT_MIN}m" make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

echo "=== BUILD OUTPUT ==="
find out/arch/arm64/boot -maxdepth 2 -type f

# =============================================================================
#  Step: Upload Kernel Artifacts   (local: copied into ./artifacts/<name>/)
#    workflow: name Camellian-TOS-Kernel-<run_number>, if-no-files-found: error
#    (retention-days: 14 is a GitHub-only setting, not applicable locally)
# =============================================================================
step "Upload Kernel Artifacts"

ARTIFACT_ROOT="$WORKSPACE/artifacts"
mkdir -p "$ARTIFACT_ROOT"
RUN_NUMBER_FILE="$ARTIFACT_ROOT/.run_number"
RUN_NUMBER=$(( $(cat "$RUN_NUMBER_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$RUN_NUMBER" > "$RUN_NUMBER_FILE"

ARTIFACT_NAME="Camellian-TOS-Kernel-${RUN_NUMBER}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$ARTIFACT_NAME"
mkdir -p "$ARTIFACT_DIR"

ARTIFACT_FILES=(
  out/arch/arm64/boot/Image
  out/arch/arm64/boot/Image.gz
  out/arch/arm64/boot/Image.gz-dtb
  out/vmlinux
  out/System.map
  out/.config
  build.log
)

copied=0
for f in "${ARTIFACT_FILES[@]}"; do
  if [ -f "$f" ]; then
    cp --parents -a "$f" "$ARTIFACT_DIR/"
    copied=$((copied + 1))
  else
    warn "Not found, skipped: $f"
  fi
done

# out/arch/arm64/boot/**/*.dtb
while IFS= read -r -d '' f; do
  cp --parents -a "$f" "$ARTIFACT_DIR/"
  copied=$((copied + 1))
done < <(find out/arch/arm64/boot -type f -name '*.dtb' -print0)

if [ "$copied" -eq 0 ]; then
  die "No artifact files were found (if-no-files-found: error)."
fi

echo "=== ARTIFACT: $ARTIFACT_NAME ($copied files) ==="
( cd "$ARTIFACT_DIR" && find . -type f -printf '%10s  %p\n' | sort -k2 )
echo
info "Done. Artifacts saved in: $ARTIFACT_DIR"
