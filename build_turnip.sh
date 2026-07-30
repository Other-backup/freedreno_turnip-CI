#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3 patch"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"

BUILD_VERSION="${BUILD_VERSION:-1.0}"

# Commit:
# tu/a6xx: Work around D32S8 EARLY_Z_LATE_Z hang
REVERT_COMMIT="a70d2af590db192f87b3af01f83a68b450edb4c3"

run_all() {
    check_deps
    prepare_workdir
    build_variant "A7xx"
    build_variant "A7xx_OneUI"
}

check_deps() {
    echo -e "${green}A verificar dependências...${nocolor}"

    for deps_chk in $deps; do
        if ! command -v "$deps_chk" >/dev/null 2>&1; then
            echo -e "${red}Falta a dependência: $deps_chk${nocolor}"
            exit 1
        fi
    done

    pip install mako --break-system-packages &>/dev/null || true
}

prepare_workdir() {
    echo -e "${green}A preparar ambiente de trabalho...${nocolor}"

    mkdir -p "$workdir"
    cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        echo -e "${green}A baixar Android NDK r29...${nocolor}"

        curl -sL \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            -o "${ndkver}-linux.zip"

        unzip -q "${ndkver}-linux.zip"
    fi
}

revert_d32s8_commit() {
    echo -e "${green}A verificar commit D32S8 EARLY_Z_LATE_Z...${nocolor}"

    if ! git cat-file -e "${REVERT_COMMIT}^{commit}" 2>/dev/null; then
        echo -e "${green}O commit não está no clone raso. A aprofundar histórico...${nocolor}"

        git fetch --deepen=2000 origin main || true
    fi

    if ! git cat-file -e "${REVERT_COMMIT}^{commit}" 2>/dev/null; then
        echo -e "${green}A baixar histórico completo do Mesa...${nocolor}"

        git fetch --unshallow origin main 2>/dev/null ||
            git fetch origin main --depth=100000
    fi

    if ! git cat-file -e "${REVERT_COMMIT}^{commit}" 2>/dev/null; then
        echo -e "${red}Não foi possível encontrar o commit:${nocolor}"
        echo "$REVERT_COMMIT"
        exit 1
    fi

    if ! git merge-base --is-ancestor "$REVERT_COMMIT" HEAD; then
        echo -e "${red}O commit a ser revertido não está presente no checkout atual.${nocolor}"
        echo "HEAD: $(git rev-parse HEAD)"
        echo "Commit: $REVERT_COMMIT"
        exit 1
    fi

    echo -e "${green}A reverter workaround D32S8 EARLY_Z_LATE_Z...${nocolor}"

    if ! git revert --no-commit "$REVERT_COMMIT"; then
        echo -e "${red}Falha ao reverter o commit $REVERT_COMMIT${nocolor}"

        git revert --abort 2>/dev/null || true
        git reset --hard HEAD

        exit 1
    fi

    echo -e "${green}Commit revertido com sucesso.${nocolor}"
}

build_variant() {
    local variant="$1"

    cd "$workdir"
    rm -rf mesa

    echo -e "${green}A clonar Mesa main para $variant...${nocolor}"

    git clone \
        "https://gitlab.freedesktop.org/mesa/mesa.git" \
        --depth=100 \
        --branch main \
        mesa

    cd mesa

    local mesa_commit
    local mesa_commit_short
    local mesa_commit_date

    mesa_commit="$(git rev-parse HEAD)"
    mesa_commit_short="$(git rev-parse --short=12 HEAD)"
    mesa_commit_date="$(git show -s --format=%cs HEAD)"

    echo -e "${green}Mesa selecionado:${nocolor}"
    echo "Commit: $mesa_commit"
    echo "Data:   $mesa_commit_date"
    echo "Título: $(git show -s --format=%s HEAD)"

    revert_d32s8_commit

    echo -e "${green}A aplicar fix has_early_preamble para A7xx...${nocolor}"

    if grep -q 'a7xx_gen1 = GPUProps(' \
        src/freedreno/common/freedreno_devices.py; then

        if ! grep -A20 'a7xx_gen1 = GPUProps(' \
            src/freedreno/common/freedreno_devices.py |
            grep -q 'has_early_preamble = False'; then

            sed -i \
                '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' \
                src/freedreno/common/freedreno_devices.py
        fi
    fi

    if [ "$variant" = "A7xx_OneUI" ]; then
        echo -e "${green}A aplicar Patch 8g2 UI Glitch exclusivo para OneUI...${nocolor}"

        curl -sL \
            "https://raw.githubusercontent.com/Other-backup/freedreno_turnip-CI/normal/8g2_ui_glitch.patch" \
            -o 8g2_ui_glitch.patch

        if ! patch -p1 <8g2_ui_glitch.patch; then
            echo -e "${red}Falha ao aplicar o patch OneUI.${nocolor}"
            exit 1
        fi
    fi

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

    find src/freedreno/vulkan \
        -type f \
        -name "*.c*" \
        -exec sed -i \
        's/"Turnip Adreno (TM) %s[^"]*"/"Turnip Adreno (TM) %s%.0s"/g' {} + ||
        true

    find src/freedreno/vulkan \
        -type f \
        -name "*.c*" \
        -exec sed -i \
        's/"turnip Mesa driver (whitebelyash branch)"/"Turnip"/g' {} + ||
        true

    find src/freedreno/vulkan \
        -type f \
        -name "*.c*" \
        -exec sed -i \
        's/"turnip Mesa driver"/"Turnip"/g' {} + ||
        true

    find src/freedreno/vulkan \
        -type f \
        -name "*.c*" \
        -exec sed -i \
        's/"Mesa " PACKAGE_VERSION MESA_GIT_SHA1/""/g' {} + ||
        true

    echo -e "${green}A configurar compilador...${nocolor}"

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

    if [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ]; then
        echo -e "${red}Compilador Android aarch64 não encontrado no NDK.${nocolor}"
        exit 1
    fi

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

    local output_dir="/tmp/turnip-$variant"
    local build_dir="build-android-aarch64"

    rm -rf "$output_dir" "$build_dir"

    echo -e "${green}A executar Meson para $variant...${nocolor}"

    meson setup "$build_dir" \
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

    echo -e "${green}A compilar $variant com Ninja...${nocolor}"

    ninja -C "$build_dir" install

    if [ ! -f "$output_dir/lib/libvulkan_freedreno.so" ]; then
        echo -e "${red}Falha na compilação do $variant.${nocolor}"
        exit 1
    fi

    cd "$output_dir/lib"

    local desc_text="A7xx Main — revert D32S8 EARLY_Z_LATE_Z"

    if [ "$variant" = "A7xx_OneUI" ]; then
        desc_text="A7xx OneUI Fix Main — revert D32S8 EARLY_Z_LATE_Z"
    fi

    cat >meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "Turnip $variant",
  "description": "$desc_text — Mesa $mesa_commit_short",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    local zip_name="Turnip_${variant}_V${BUILD_VERSION}_${mesa_commit_short}_Revert-D32S8.zip"

    echo -e "${green}A empacotar ZIP para $variant...${nocolor}"

    rm -f "$workdir/$zip_name"

    zip -9 \
        "$workdir/$zip_name" \
        libvulkan_freedreno.so \
        meta.json

    echo -e "${green}Concluído: $workdir/$zip_name${nocolor}"
}

run_all
