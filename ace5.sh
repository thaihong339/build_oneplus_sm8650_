#!/bin/bash
set -e

# ── Colorized logging ───────────────────────────────────────────
info() {
  tput setaf 3; echo "[INFO] $1"; tput sgr0
}
error() {
  tput setaf 1; echo "[ERROR] $1"; tput sgr0; exit 1
}

# ── Default settings ───────────────────────────────────────────
KERNEL_SUFFIX="-android14-@hipuu"
ENABLE_KPM=true
ENABLE_LZ4KD=true

info "Select device:"
info "  1) OnePlus Ace 5"
info "  2) OnePlus 12"
info "  3) OnePlus Pad Pro"
read -rp "Enter choice [1-3]: " device_choice

case $device_choice in
  1) DEVICE_NAME="oneplus_ace5"; REPO_MANIFEST="oneplus_ace5.xml";;
  2) DEVICE_NAME="oneplus_12"; REPO_MANIFEST="oneplus12_v.xml";;
  3) DEVICE_NAME="oneplus_pad_pro"; REPO_MANIFEST="oneplus_pad_pro_v.xml";;
  *) error "Invalid selection — choose 1, 2 or 3.";;
esac

read -rp "Kernel name suffix (emoji/Chinese ok, enter to keep default): " input_suffix
[ -n "$input_suffix" ] && KERNEL_SUFFIX="$input_suffix"

read -rp "Enable KPM? (Default: Y) [y/N]: " kpm
[[ "$kpm" =~ ^[Yy]$ ]] && ENABLE_KPM=true || ENABLE_KPM=false

read -rp "Enable LZ4+Zstd? (Default: Y) [y/N]: " lz4
[[ "$lz4" =~ ^[Yy]$ ]] && ENABLE_LZ4KD=true || ENABLE_LZ4KD=false

# ── ccache setup ─────────────────────────────────────────────
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR=1
export CCACHE_HARDLINK=1
export CCACHE_DIR="$HOME/.ccache_${DEVICE_NAME}"
export CCACHE_MAXSIZE="8G"

if command -v ccache &>/dev/null; then
  if [ ! -f "$CCACHE_DIR/.ccache_initialized" ]; then
    info "Initializing ccache for $DEVICE_NAME…"
    mkdir -p "$CCACHE_DIR"
    ccache -M "$CCACHE_MAXSIZE"
    touch "$CCACHE_DIR/.ccache_initialized"
  else
    info "ccache already initialized for $DEVICE_NAME."
  fi
else
  info "ccache not found; skipping."
fi

# ── Workspace setup ───────────────────────────────────────────
WORKSPACE="$HOME/kernel_${DEVICE_NAME}"
mkdir -p "$WORKSPACE"; cd "$WORKSPACE"

# ── Dependencies check ────────────────────────────────────────
info "Checking dependencies…"
DEPS=(python3 git curl ccache flex bison libssl-dev libelf-dev bc zip)
MISSING=()
for pkg in "${DEPS[@]}"; do
  dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  info "Installing missing: ${MISSING[*]}"
  sudo apt update && sudo apt install -y "${MISSING[@]}" || error "Install failed."
else
  info "All dependencies are installed."
fi

# ── Git config ────────────────────────────────────────────────
info "Checking Git config…"
if [ -z "$(git config --global user.name)" ] || [ -z "$(git config --global user.email)" ]; then
  info "Setting Git user.name and user.email"
  git config --global user.name "thaihong339"
  git config --global user.email "thaivuhong09@gmail.com"
else
  info "Global Git identity already configured."
fi

# ── repo tool setup ───────────────────────────────────────────
if ! command -v repo &>/dev/null; then
  info "Installing repo tool…"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o ~/repo
  chmod a+x ~/repo
  sudo mv ~/repo /usr/local/bin/repo
else
  info "repo tool found."
fi

# ── Source initialization ─────────────────────────────────────
KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"
mkdir -p "$KERNEL_WORKSPACE" && cd "$KERNEL_WORKSPACE"

info "Repo init & sync…"
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1 \
  || error "repo init failed"
repo sync -c -j"$(nproc)" --no-tags || error "repo sync failed"

# ── Clean ABI/dirty flags ─────────────────────────────────────
info "Cleaning ABI and -dirty flags…"
for d in kernel_platform/common kernel_platform/msm-kernel; do
  rm "$d"/android/abi_gki_protected_exports_* 2>/dev/null || true
done

for f in kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
done

# ── Kernel suffix injection & config tweaks ───────────────────
info "Injecting kernel name suffix into config…"
cd kernel_platform/common/arch/arm64/configs
DEFCONFIG="gki_defconfig"
echo "CONFIG_LOCALVERSION=\"${KERNEL_SUFFIX}\"" >> "$DEFCONFIG"
if [ "$ENABLE_KPM" = true ]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG"
fi
cd ../../../../

# ── Setup SukiSU & patches ────────────────────────────────────
info "Setting up SukiSU…"
cd kernel_platform
curl -LSs https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh | bash -s susfs-main
cd KernelSU
KSU_VERSION=$(( $(git rev-list --count main) + 10700 ))
export KSU_VERSION
sed -i "s/DKSU_VERSION=.*/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile

info "Applying SUSFS and extra patches…"
cd "$KERNEL_WORKSPACE"
git clone -b gki-android14-6.1 https://gitlab.com/simonpunk/susfs4ksu.git || true
git clone https://github.com/Xiaomichael/kernel_patches.git || true
git clone -q https://github.com/SukiSU-Ultra/SukiSU_patch.git || true

cd kernel_platform/common
cp ../../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./
cp ../../kernel_patches/next/syscall_hooks.patch ./
cp ../../susfs4ksu/kernel_patches/fs/* ./fs/
cp ../../susfs4ksu/kernel_patches/include/linux/* ./include/linux/

if [ "$ENABLE_LZ4KD" = true ]; then
  cp ../../kernel_patches/001-lz4.patch ./
  cp ../../kernel_patches/lz4armv8.S ./lib/
  cp ../../kernel_patches/002-zstd.patch ./
fi

patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
cp ../../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F3 < syscall_hooks.patch
if [ "$ENABLE_LZ4KD" = true ]; then
  git apply -p1 < 001-lz4.patch || true
  patch -p1 < 002-zstd.patch || true
fi

# ── Build kernel ───────────────────────────────────────────────
info "Building kernel..."
export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

cd "$KERNEL_WORKSPACE/kernel_platform/common"
make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" \
  O=out gki_defconfig

make -j"$(nproc)" LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" \
  O=out Image

if [ "$ENABLE_KPM" = true ]; then
  info "Applying KPM patch to Image…"
  cd out/arch/arm64/boot
  curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
  chmod +x patch_linux && ./patch_linux
  mv oImage Image
fi

# ── Package with AnyKernel3 ────────────────────────────────────
info "Packaging kernel zip…"
cd "$WORKSPACE"
git clone -q https://github.com/showdo/AnyKernel3.git --depth=1 || true
rm -rf AnyKernel3/.git AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" AnyKernel3/
cd AnyKernel3
zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" ./*

# ── Copy outputs to Windows ────────────────────────────────────
WIN_OUTPUT="/mnt/c/Kernel_Build/${DEVICE_NAME}"
mkdir -p "$WIN_OUTPUT"
cp Image "$WIN_OUTPUT/"
cp "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" "$WIN_OUTPUT/"

info "Build complete. Check output at C:/Kernel_Build/${DEVICE_NAME}/"

# ── Clean workspace (optional) ────────────────────────────────
read -rp "Remove build workspace? [y/N]: " cleanup
if [[ "$cleanup" =~ ^[Yy]$ ]]; then
  sudo rm -rf "$WORKSPACE"
  info "Workspace removed."
fi
