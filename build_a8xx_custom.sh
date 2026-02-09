#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
nocolor='\033[0m'

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3 patch"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r28"
target_sdk="36" 

check_deps(){
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then echo "Missing: $dep"; exit 1; fi
	done
	pip install meson mako --break-system-packages &> /dev/null || true
}

prepare_ndk(){
	mkdir -p "$workdir" && cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

compile_mesa() {
    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="main"
    # Tag: RobClark Merge + NoConcuBin (Sem UBWC Hack)
    local build_name="Turnip-A8xx-RobClark-KGSL"
    local output_tag="V78-A8xx-KGSL"

    cd "$workdir"
    if [ -d mesa ]; then rm -rf mesa; fi
    
    # Clone deeper to allow merging history
    git clone --depth 500 -b "$branch" "$repo_url" mesa
    cd mesa
    git config user.email "ci@turnip.builder" && git config user.name "Turnip CI Builder"

    # --- STEP 1: MERGE ROB CLARK'S BRANCH ---
    echo -e "${green}Fetching & Merging Rob Clark (tu/gen8-kgsl)...${nocolor}"
    git remote add robclark https://gitlab.freedesktop.org/robclark/mesa.git || true
    git fetch robclark
    
    # Tenta o merge. Se der conflito leve, tenta continuar.
    # Isso é arriscado com o tu_gen8.patch depois, mas é o solicitado.
    git merge --no-edit robclark/tu/gen8-kgsl || echo -e "${green}WARNING: Merge conflicts detected. Proceeding best-effort...${nocolor}"

    # --- STEP 2: APPLY USER PATCH ---
    local patch_file="$workdir/../tu_gen8.patch"
    if [ ! -f "$patch_file" ]; then patch_file="tu_gen8.patch"; fi
    
    if [ -f "$patch_file" ]; then
        echo -e "${green}Applying tu_gen8.patch...${nocolor}"
        # Fuzz alto para tentar aplicar mesmo com o merge do Rob Clark
        patch -p1 --fuzz=4 --ignore-whitespace < "$patch_file" || echo "Warning: Patch had conflicts (expected due to merge)"
        
        echo -e "${green}Reverting Timeline & Version Hacks...${nocolor}"
        
        # 1. REVERTER Patch 11 (Timeline Semaphore) - CRÍTICO
        sed -n '/^Subject: \[PATCH 11\/22\]/,/^From /p' "$patch_file" | head -n -1 | patch -p1 -R || echo "Failed Revert 11"
        
        # 2. REVERTER Patch 16 (Limpeza de versão)
        sed -n '/^Subject: \[PATCH 16\/22\]/,/^From /p' "$patch_file" | head -n -1 | patch -p1 -R || echo "Failed Revert 16"
        
        # Patch 21 (Disable Flushall) é MANTIDO para performance.
    else
        echo "Error: tu_gen8.patch not found."
        exit 1
    fi

    echo -e "${green}Injecting Light Stability (NoConcurrentBinning ONLY)...${nocolor}"
    
    # Removido: TU_DEBUG_NOUBWC, TU_DEBUG_FORCE_CLEARS
    # Mantido: TU_DEBUG_NO_CONCURRENT_BINNING (Essencial para não dar crash na A8xx)
    find src/freedreno/vulkan -name "tu_device.cc" -exec sed -i 's/tu_env.debug |= TU_DEBUG_NOLRZ;/tu_env.debug |= TU_DEBUG_NOLRZ | TU_DEBUG_NO_CONCURRENT_BINNING;/g' {} +

    echo -e "${green}Building...${nocolor}"
    
    mkdir -p subprojects && cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..

    local build_dir="$workdir/mesa/build"
    rm -rf "$build_dir"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cver="35"
    [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF > android-cross.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
[built-in options]
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF
    
    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    meson setup "$build_dir" --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=36 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dvulkan-beta=true \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers
    
    ninja -C "$build_dir"

    local lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib" ]; then echo "Build Failed"; exit 1; fi
    
    local pkg_dir="$workdir/pkg_$output_tag"
    mkdir -p "$pkg_dir"
    cp "$lib" "$pkg_dir/vulkan.ad07XX.so"
    cd "$pkg_dir"
    patchelf --set-soname "vulkan.adreno.so" vulkan.ad07XX.so
    
    echo "{
  \"schemaVersion\": 1,
  \"name\": \"$build_name\",
  \"description\": \"Mesa A8xx (RobClark Merge + NoConcuBin)\",
  \"author\": \"StevenMX\",
  \"packageVersion\": \"1\",
  \"vendor\": \"Mesa\",
  \"driverVersion\": \"$output_tag\",
  \"minApi\": 28,
  \"libraryName\": \"vulkan.ad07XX.so\"
}" > meta.json
    
    zip -9 "$workdir/Turnip-${output_tag}.zip" vulkan.ad07XX.so meta.json
    echo -e "${green}Done: Turnip-${output_tag}.zip${nocolor}"
}

check_deps
prepare_ndk
compile_mesa
