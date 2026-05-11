#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
cyan='\033[0;36m'
nc='\033[0m'

log()   { echo -e "${green}[✓] $*${nc}"; }
info()  { echo -e "${cyan}[*] $*${nc}"; }
warn()  { echo -e "${yellow}[!] $*${nc}"; }
error() { echo -e "${red}[✗] $*${nc}"; exit 1; }
title() { echo -e "\n${cyan}══════════════════════════════════════${nc}";
          echo -e "${cyan}  $*${nc}";
          echo -e "${cyan}══════════════════════════════════════${nc}"; }

deps="git ninja patchelf unzip curl pip flex bison zip glslangValidator python3 patch"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
BUILD_VERSION="${BUILD_VERSION:-1.0}"

MESA_MAIN="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_A8XX="https://github.com/whitebelyash/mesa-tu8.git"
PATCH_8G2="https://raw.githubusercontent.com/Other-backup/freedreno_turnip-CI/normal/8g2_ui_glitch.patch"
MR_A7XX=41451

check_deps() {
    title "Checking dependencies"
    local missing=()
    for dep in $deps; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if ! command -v meson >/dev/null 2>&1; then
        info "Installing meson via pip..."
        pip install meson --break-system-packages &>/dev/null || missing+=("meson")
    fi
    [ ${#missing[@]} -gt 0 ] && error "Missing dependencies: ${missing[*]}"
    pip install mako --break-system-packages &>/dev/null || true
    log "Dependencies OK"
}

prepare_ndk() {
    title "Preparing NDK ($ndkver)"
    mkdir -p "$workdir"
    cd "$workdir"
    if [ ! -d "$ndkver" ]; then
        info "Downloading NDK..."
        curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
             -o "${ndkver}-linux.zip"
        unzip -q "${ndkver}-linux.zip"
        rm -f "${ndkver}-linux.zip"
    fi
    log "NDK ready at $workdir/$ndkver"
}

setup_toolchain_env() {
    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang"   "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang  CXX=clang++
    export AR=llvm-ar  RANLIB=llvm-ranlib  STRIP=llvm-strip
    export OBJDUMP=llvm-objdump  OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"
}

detect_clang_ver() {
    local cver="36"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"
    echo "$cver"
}

write_cross_files() {
    local cver="$1"
    cat <<EOF >"android-aarch64.txt"
[binaries]
ar      = '$ndk/llvm-ar'
c       = '$ndk/aarch64-linux-android${cver}-clang'
cpp     = '$ndk/aarch64-linux-android${cver}-clang++',
           '-fno-exceptions', '-fno-unwind-tables',
           '-fno-asynchronous-unwind-tables',
           '--start-no-unused-arguments', '-static-libstdc++',
           '--end-no-unused-arguments']
c_ld    = '$ndk/ld.lld'
cpp_ld  = '$ndk/ld.lld'
strip   = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system     = 'android'
cpu_family = 'aarch64'
cpu        = 'armv8'
endian     = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c          = 'clang'
cpp        = 'clang++'
ar         = 'llvm-ar'
strip      = 'llvm-strip'
c_ld       = 'ld.lld'
cpp_ld     = 'ld.lld'
system     = 'linux'
cpu_family = 'x86_64'
cpu        = 'x86_64'
endian     = 'little'
EOF
}

apply_android_stub_fixes() {
    info "Applying Android stub fixes..."
    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' \
        include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' \
        src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' \
        src/vulkan/runtime/vk_android.c || true
    sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' \
        src/vulkan/runtime/vk_android.c || true
}

meson_build_and_install() {
    local prefix="$1"
    local cver
    cver=$(detect_clang_ver)
    write_cross_files "$cver"

    rm -rf build-android-aarch64

    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file  "native.txt" \
        --prefix "$prefix" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version=36 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled

    ninja -C build-android-aarch64 install
}

package_zip() {
    local prefix="$1"
    local zip_name="$2"
    local meta_name="$3"
    local meta_desc="$4"
    local meta_ver="$5"

    [ ! -f "$prefix/lib/libvulkan_freedreno.so" ] && \
        error "libvulkan_freedreno.so not found — build failed"

    cd "$prefix/lib"
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "$meta_desc",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$meta_ver",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
    local out="$workdir/${zip_name}-V${BUILD_VERSION}.zip"
    zip -9 "$out" libvulkan_freedreno.so meta.json
    log "Package ready: $(basename "$out")"
}

build_a8xx() {
    title "BUILD 1/4 — Turnip A8xx"
    local srcdir="$workdir/mesa-a8xx"
    local prefix="/tmp/turnip-a8xx"

    rm -rf "$srcdir" "$prefix"
    git clone "$MESA_A8XX" --depth=1 --no-single-branch "$srcdir"
    cd "$srcdir"
    git checkout "origin/gen8"

    echo '#define TUGEN8_DRV_VERSION ""' > ./src/freedreno/vulkan/tu_version.h

    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.cc 2>/dev/null || true
    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.c  2>/dev/null || true

    apply_android_stub_fixes
    setup_toolchain_env
    meson_build_and_install "$prefix"

    package_zip "$prefix" \
        "Turnip-A8xx" \
        "Turnip A8xx" \
        "Mesa tu8 fork — A8xx support (Adreno 8xx / Snapdragon 8 Gen 3+)" \
        "Vulkan 1.4.348"
}

build_a6xx() {
    title "BUILD 2/4 — Turnip A6xx"
    local srcdir="$workdir/mesa-a6xx"
    local prefix="/tmp/turnip-a6xx"

    rm -rf "$srcdir" "$prefix"
    git clone "$MESA_MAIN" --depth=1 -b main "$srcdir"
    cd "$srcdir"

    info "Applying A6xx fix (revert tu_bo_init_new_cached)..."
    python3 - "src/freedreno/vulkan/tu_device.h" <<'PYEOF'
import re, sys, os

path = sys.argv[1]
if not os.path.exists(path):
    print(f"File not found: {path}"); sys.exit(0)

with open(path) as f:
    content = f.read()

pattern = (
    r"/\* Use cached-coherent when available, for faster CPU readback\."
    r"\s*\*/\s*static inline VkResult\s*tu_bo_init_new_cached[\s\S]*?\}\s*"
)
if re.search(pattern, content):
    content = re.sub(pattern, "", content)
    print("  Removed tu_bo_init_new_cached definition from tu_device.h")
else:
    print("  tu_bo_init_new_cached not found in header")

with open(path, 'w') as f:
    f.write(content)
PYEOF

    find src/freedreno/vulkan \( -name "*.cc" -o -name "*.c" \) \
        -exec sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' {} +
    log "Replaced tu_bo_init_new_cached calls with tu_bo_init_new"

    apply_android_stub_fixes
    setup_toolchain_env
    meson_build_and_install "$prefix"

    package_zip "$prefix" \
        "Turnip-A6xx" \
        "Turnip A6xx" \
        "Mesa Main — A6xx fix: revert tu_bo_init_new_cached to tu_bo_init_new" \
        "Vulkan 1.4"
}

build_a7xx() {
    title "BUILD 3/4 — Turnip A7xx"
    local srcdir="$workdir/mesa-a7xx"
    local prefix="/tmp/turnip-a7xx"

    rm -rf "$srcdir" "$prefix"
    git clone "$MESA_MAIN" --depth=100 -b main "$srcdir"
    cd "$srcdir"
    git config user.email "ci@turnip.builder"
    git config user.name  "Turnip CI"

    info "Merging MR ${MR_A7XX}..."
    git fetch origin "refs/merge-requests/${MR_A7XX}/head" --depth=100
    if ! git merge FETCH_HEAD --no-edit; then
        warn "Conflicts merging MR ${MR_A7XX} — resolving (theirs)..."
        git checkout --theirs . 2>/dev/null || true
        git add -A
        git -c core.editor=true merge --continue || true
    fi
    log "MR ${MR_A7XX} applied"

    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' \
        src/freedreno/common/freedreno_devices.py || true

    apply_android_stub_fixes
    setup_toolchain_env
    meson_build_and_install "$prefix"

    package_zip "$prefix" \
        "Turnip-A7xx" \
        "Turnip A7xx" \
        "Mesa Main + MR${MR_A7XX} + No Early Preamble (Adreno 7xx)" \
        "Vulkan 1.4.348"
}

build_a7xx_oneui() {
    title "BUILD 4/4 — Turnip A7xx OneUI"
    local srcdir="$workdir/mesa-a7xx-oneui"
    local prefix="/tmp/turnip-a7xx-oneui"

    rm -rf "$srcdir" "$prefix"
    git clone "$MESA_MAIN" --depth=100 -b main "$srcdir"
    cd "$srcdir"
    git config user.email "ci@turnip.builder"
    git config user.name  "Turnip CI"

    info "Merging MR ${MR_A7XX}..."
    git fetch origin "refs/merge-requests/${MR_A7XX}/head" --depth=100
    if ! git merge FETCH_HEAD --no-edit; then
        warn "Conflicts merging MR ${MR_A7XX} — resolving (theirs)..."
        git checkout --theirs . 2>/dev/null || true
        git add -A
        git -c core.editor=true merge --continue || true
    fi
    log "MR ${MR_A7XX} applied"

    info "Applying OneUI patch (8G2 UI glitch fix)..."
    curl -sL "$PATCH_8G2" -o 8g2_ui_glitch.patch
    if patch -p1 < 8g2_ui_glitch.patch; then
        log "8G2 patch applied successfully"
    else
        warn "8G2 patch had rejections — continuing anyway"
    fi

    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' \
        src/freedreno/common/freedreno_devices.py || true

    apply_android_stub_fixes
    setup_toolchain_env
    meson_build_and_install "$prefix"

    package_zip "$prefix" \
        "Turnip-A7xx-OneUI" \
        "Turnip A7xx OneUI" \
        "Mesa Main + MR${MR_A7XX} + No Early Preamble + OneUI/8G2 UI Glitch Fix" \
        "Vulkan 1.4.348"
}

main() {
    check_deps
    prepare_ndk

    build_a8xx
    build_a6xx
    build_a7xx
    build_a7xx_oneui

    title "All builds complete!"
    echo ""
    echo "Zips generated at $workdir:"
    ls -lh "$workdir"/*.zip 2>/dev/null || warn "No zip files found"
}

main
