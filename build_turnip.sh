#!/usr/bin/env bash
set -euo pipefail

green='\033[0;32m'
yellow='\033[0;33m'
nocolor='\033[0m'

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3 patch pkg-config"

workdir="$(pwd)/turnip_workdir"
mesa_dir="$workdir/mesa"

ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"

START_DATE="2026-07-09"
END_DATE="2026-07-15"
TURNIP_COUNT=5

check_deps() {
    echo -e "${green}A verificar dependências...${nocolor}"

    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Falta a dependência: $dep"
            exit 1
        fi
    done

    pip install mako --break-system-packages >/dev/null 2>&1 || true
}

prepare_workdir() {
    echo -e "${green}A preparar ambiente...${nocolor}"

    mkdir -p "$workdir"
    cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        curl -L \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            -o "${ndkver}-linux.zip"

        unzip -q "${ndkver}-linux.zip"
    fi

    if [ ! -d "$mesa_dir/.git" ]; then
        echo -e "${green}A clonar o Mesa...${nocolor}"

        git clone \
            --branch main \
            --shallow-since="${START_DATE} 00:00:00" \
            "https://gitlab.freedesktop.org/mesa/mesa.git" \
            "$mesa_dir"
    else
        echo -e "${green}A atualizar o Mesa...${nocolor}"

        git -C "$mesa_dir" reset --hard
        git -C "$mesa_dir" clean -fd
        git -C "$mesa_dir" checkout main

        git -C "$mesa_dir" fetch \
            origin main \
            --shallow-since="${START_DATE} 00:00:00"

        git -C "$mesa_dir" reset --hard origin/main
    fi
}

select_commits() {
    cd "$mesa_dir"

    mapfile -t all_commits < <(
        git rev-list \
            --reverse \
            --since="${START_DATE} 00:00:00" \
            --until="${END_DATE} 23:59:59" \
            origin/main
    )

    local total="${#all_commits[@]}"

    if [ "$total" -eq 0 ]; then
        echo "Nenhum commit encontrado entre $START_DATE e $END_DATE."
        exit 1
    fi

    if [ "$total" -le "$TURNIP_COUNT" ]; then
        selected_commits=("${all_commits[@]}")
        return
    fi

    selected_commits=()

    for ((i = 0; i < TURNIP_COUNT; i++)); do
        local index=$((i * (total - 1) / (TURNIP_COUNT - 1)))
        selected_commits+=("${all_commits[$index]}")
    done
}

configure_compiler() {
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
}

apply_patches() {
    echo -e "${green}A aplicar fix has_early_preamble...${nocolor}"

    sed -i \
        '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' \
        src/freedreno/common/freedreno_devices.py || true

    echo -e "${green}A corrigir Android Stubs...${nocolor}"

    sed -i \
        's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' \
        include/android_stub/cutils/native_handle.h || true

    sed -i \
        's/, hnd->handle/, (void \*)hnd->handle/g' \
        src/util/u_gralloc/u_gralloc_fallback.c || true

    sed -i \
        's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' \
        src/vulkan/runtime/vk_android.c || true

    sed -i \
        's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' \
        src/vulkan/runtime/vk_android.c || true

    echo -e "${green}A limpar nomes do driver...${nocolor}"

    find src/freedreno/vulkan -type f -name "*.c*" \
        -exec sed -i \
        's/"Turnip Adreno (TM) %s[^"]*"/"Turnip Adreno (TM) %s%.0s"/g' {} + || true

    find src/freedreno/vulkan -type f -name "*.c*" \
        -exec sed -i \
        's/"turnip Mesa driver (whitebelyash branch)"/"Turnip"/g' {} + || true

    find src/freedreno/vulkan -type f -name "*.c*" \
        -exec sed -i \
        's/"turnip Mesa driver"/"Turnip"/g' {} + || true

    find src/freedreno/vulkan -type f -name "*.c*" \
        -exec sed -i \
        's/"Mesa " PACKAGE_VERSION MESA_GIT_SHA1/""/g' {} + || true
}

create_cross_files() {
    local cver="36"

    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat >android-aarch64.txt <<EOF
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

    cat >native.txt <<EOF
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
}

build_commit() {
    local commit="$1"

    cd "$mesa_dir"

    git reset --hard
    git clean -fd
    git checkout --detach "$commit"

    local short_commit
    local commit_date
    local output_dir
    local zip_name

    short_commit="$(git rev-parse --short=10 HEAD)"
    commit_date="$(git show -s --format=%cs HEAD)"

    output_dir="/tmp/turnip-${short_commit}"
    zip_name="Turnip_A7xx_${commit_date}_${short_commit}.zip"

    echo
    echo -e "${yellow}========================================${nocolor}"
    echo -e "${yellow}Data:   $commit_date${nocolor}"
    echo -e "${yellow}Commit: $short_commit${nocolor}"
    git show -s --format='Título: %s'
    echo -e "${yellow}========================================${nocolor}"
    echo

    apply_patches
    create_cross_files

    rm -rf build-android-aarch64 "$output_dir"

    echo -e "${green}A executar Meson...${nocolor}"

    meson setup build-android-aarch64 \
        --cross-file android-aarch64.txt \
        --native-file native.txt \
        --prefix "$output_dir" \
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

    echo -e "${green}A compilar com Ninja...${nocolor}"

    ninja -C build-android-aarch64 install

    if [ ! -f "$output_dir/lib/libvulkan_freedreno.so" ]; then
        echo "Falha ao compilar o commit $short_commit."
        exit 1
    fi

    cd "$output_dir/lib"

    cat >meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "Turnip A7xx",
  "description": "A7xx Mesa ${commit_date} ${short_commit}",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    zip -9 "$workdir/$zip_name" \
        libvulkan_freedreno.so \
        meta.json

    echo -e "${green}Criado: $workdir/$zip_name${nocolor}"
}

run_all() {
    check_deps
    prepare_workdir
    configure_compiler
    select_commits

    echo
    echo "Serão compilados ${#selected_commits[@]} Turnips:"
    echo

    for commit in "${selected_commits[@]}"; do
        git -C "$mesa_dir" show \
            -s \
            --format='%cs  %h  %s' \
            "$commit"
    done

    echo

    for commit in "${selected_commits[@]}"; do
        build_commit "$commit"
    done

    git -C "$mesa_dir" reset --hard
    git -C "$mesa_dir" checkout main

    echo
    echo -e "${green}Todas as compilações foram concluídas.${nocolor}"
    echo -e "${green}Arquivos em: $workdir${nocolor}"
}

run_all
