#!/bin/bash -e
set -o pipefail

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3 patch"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
BUILD_VERSION="${BUILD_VERSION:-1.0}"

run_all(){
    check_deps
    prepare_workdir
    build_variant "A8xx"
    build_variant "A7xx"
    build_variant "A7xx_OneUI"
}

check_deps(){
    for deps_chk in $deps; do
        if ! command -v "$deps_chk" >/dev/null 2>&1 ; then
            exit 1
        fi
    done
    pip install mako --break-system-packages &> /dev/null || true
}

prepare_workdir(){
    mkdir -p "$workdir" && cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip" &> /dev/null
        unzip -q "${ndkver}-linux.zip" &> /dev/null
    fi
}

build_variant(){
    local variant=$1
    cd "$workdir"
    rm -rf mesa

    if [ "$variant" == "A8xx" ]; then
        git clone "https://github.com/whitebelyash/mesa-unified.git" --depth=100 --no-single-branch mesa
        cd mesa
        git checkout origin/turnip/gen8
        git config user.email "build@turnip.com"
        git config user.name "Builder"
        git revert -n 60a14d62acb992ac343caf43de8b0e1efb41af6 || true
        echo "#define TUGEN8_DRV_VERSION \"\"" > ./src/freedreno/vulkan/tu_version.h

    elif [ "$variant" == "A7xx" ]; then
        git clone "https://gitlab.freedesktop.org/mesa/mesa.git" --depth=100 -b main mesa
        cd mesa
        git config user.email "build@turnip.com"
        git config user.name "Builder"
        git fetch origin refs/merge-requests/41451/head:mr
        git merge --no-edit mr
        sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true

    elif [ "$variant" == "A7xx_OneUI" ]; then
        git clone "https://gitlab.freedesktop.org/mesa/mesa.git" --depth=100 -b main mesa
        cd mesa
        git config user.email "build@turnip.com"
        git config user.name "Builder"
        git fetch origin refs/merge-requests/41451/head:mr
        git merge --no-edit mr
        curl -sL "https://raw.githubusercontent.com/Other-backup/freedreno_turnip-CI/normal/8g2_ui_glitch.patch" -o 8g2_ui_glitch.patch
        patch -p1 < 8g2_ui_glitch.patch || true
        sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true
    fi

    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true
    sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true

    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"Turnip Adreno (TM) %s[^"]*"/"Turnip Adreno (TM) %s%.0s"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"turnip Mesa driver (whitebelyash branch)"/"Turnip"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"turnip Mesa driver"/"Turnip"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"Mesa " PACKAGE_VERSION MESA_GIT_SHA1/""/g' {} + || true

    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang" "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"

    local cver="36"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android${cver}-clang']
cpp = ['$ndk/aarch64-linux-android${cver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c = ['clang']
cpp = ['clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/turnip-$variant" \
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

    if [ ! -f "/tmp/turnip-$variant/lib/libvulkan_freedreno.so" ]; then
        exit 1
    fi

    cd "/tmp/turnip-$variant/lib"
    
    if [ "$variant" == "A8xx" ]; then
        cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip Gen8 V29",
  "description": "A8xx support",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.348",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
    else
        cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip $variant",
  "description": "Compiled variant: $variant",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
    fi

    zip -9 "/tmp/Turnip_${variant}_V${BUILD_VERSION}.zip" libvulkan_freedreno.so meta.json
    cp "/tmp/Turnip_${variant}_V${BUILD_VERSION}.zip" "$workdir/"
}

run_all
