#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
nocolor='\033[0m'

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3 patch"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
BUILD_VERSION="${BUILD_VERSION:-1.0}"

run_all(){
    check_deps
    prepare_workdir
    build_a7xx
}

check_deps(){
    echo -e "${green}A verificar dependências...${nocolor}"
    for deps_chk in $deps; do
        if ! command -v "$deps_chk" >/dev/null 2>&1 ; then
            echo "Falta a dependência: $deps_chk"
            exit 1
        fi
    done
    pip install mako --break-system-packages &> /dev/null || true
}

prepare_workdir(){
    echo -e "${green}A preparar ambiente de trabalho...${nocolor}"
    mkdir -p "$workdir" && cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip" &> /dev/null
        unzip -q "${ndkver}-linux.zip" &> /dev/null
    fi
}

build_a7xx(){
    cd "$workdir"
    rm -rf mesa

    echo -e "${green}A clonar Mesa (Main)...${nocolor}"
    git clone "https://gitlab.freedesktop.org/mesa/mesa.git" --depth=100 -b main mesa
    cd mesa

    echo -e "${green}A aplicar MR 39751 via Patch...${nocolor}"
    curl -sL "https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/39751.patch" | patch -p1 --no-backup-if-mismatch || true

    echo -e "${green}A corrigir escopo e extensões GNU do KGSL...${nocolor}"
    cat << 'EOF_PYTHON' > fix_kgsl.py
import re
import sys

file_path = 'src/freedreno/vulkan/tu_knl_kgsl.cc'
try:
    with open(file_path, 'r') as f:
        code = f.read()

    # 1. Substitui a extensao GNU alignof(...) por alinhamento padrao seguro (8 bytes)
    code = re.sub(r'alignof\s*\(\s*\*profiling->[a-zA-Z0-9_]+\s*\)', '8', code)

    # 2. Injeta a declaracao no TOPO da funcao, resolvendo o problema do laco (loop)
    match = re.search(r'(kgsl_queue_submit\s*\([^{;]+?\)\s*\{)', code)
    if match:
        func_start = match.end()
        if 'kgsl_profiling_alloc(&profiling' not in code[func_start:func_start+300]:
            injection = "\n   struct kgsl_profiling profiling = {0};\n   kgsl_profiling_alloc(&profiling, queue, u_trace_submission_data);\n"
            code = code[:func_start] + injection + code[func_start:]

    with open(file_path, 'w') as f:
        f.write(code)
    print("Fixes aplicados com sucesso!")
except Exception as e:
    print(f"Erro no script Python: {e}")
    sys.exit(1)
EOF_PYTHON
    python3 fix_kgsl.py

    echo -e "${green}A aplicar fix has_early_preamble para A7xx...${nocolor}"
    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true

    echo -e "${green}A corrigir Android Stubs...${nocolor}"
    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true
    sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true

    echo -e "${green}A limpar nomes do driver...${nocolor}"
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"Turnip Adreno (TM) %s[^"]*"/"Turnip Adreno (TM) %s%.0s"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"turnip Mesa driver (whitebelyash branch)"/"Turnip"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"turnip Mesa driver"/"Turnip"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i 's/"Mesa " PACKAGE_VERSION MESA_GIT_SHA1/""/g' {} + || true

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

    echo -e "${green}A executar Meson...${nocolor}"
    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/turnip-A7xx" \
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

    if [ ! -f "/tmp/turnip-A7xx/lib/libvulkan_freedreno.so" ]; then
        echo "Falha na compilação!"
        exit 1
    fi

    cd "/tmp/turnip-A7xx/lib"
    
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip A7xx Main",
  "description": "A7xx com MR 39751 (KGSL Profiling)",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    echo -e "${green}A empacotar ZIP...${nocolor}"
    zip -9 "/tmp/Turnip_A7xx_V${BUILD_VERSION}.zip" libvulkan_freedreno.so meta.json
    cp "/tmp/Turnip_A7xx_V${BUILD_VERSION}.zip" "$workdir/"
    
    echo -e "${green}Concluído! Turnip_A7xx_V${BUILD_VERSION}.zip criado em $workdir${nocolor}"
}

run_all
