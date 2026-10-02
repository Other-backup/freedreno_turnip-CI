#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
nocolor='\033[0m'

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"
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
    local build_name="Turnip-Main-MR39751"
    local output_tag="V71-Main-NativeTimeline"

    echo -e "${green}Cloning Mesa Main...${nocolor}"
    
    cd "$workdir"
    if [ -d mesa ]; then rm -rf mesa; fi
    
    git clone --depth 100 -b "$branch" "$repo_url" mesa
    cd mesa
    git config user.email "ci@turnip.builder" && git config user.name "Turnip CI Builder"

    echo -e "${green}Fetching and Merging MR 39751 (Native Timeline Sync)...${nocolor}"
    # Fetch the specific Merge Request head
    git fetch origin refs/merge-requests/39751/head:mr-39751
    # Merge into main
    git merge mr-39751 --no-edit

    # Revert the D32S8 EARLY_Z_LATE_Z workaround used by A7xx.\n    # Keep the existing A8xx MR39751/native-timeline pipeline unchanged otherwise.\n    local revert_commit="a70d2af590db192f87b3af01f83a68b450edb4c3"\n    echo -e "${green}Reverting D32S8 EARLY_Z_LATE_Z workaround for A8xx...${nocolor}"\n\n    if ! git cat-file -e "$revert_commit^{commit}" 2>/dev/null; then\n        git fetch --deepen=2000 origin main || true\n    fi\n\n    if ! git cat-file -e "$revert_commit^{commit}" 2>/dev/null; then\n        git fetch --unshallow origin main 2>/dev/null ||\n            git fetch origin main --depth=100000\n    fi\n\n    if ! git cat-file -e "$revert_commit^{commit}" 2>/dev/null; then\n        echo "Could not find commit to revert: $revert_commit"\n        exit 1\n    fi\n\n    if ! git merge-base --is-ancestor "$revert_commit" HEAD; then\n        echo "D32S8 commit is not an ancestor of the merged A8xx checkout."\n        echo "HEAD: $(git rev-parse HEAD)"\n        exit 1\n    fi\n\n    if ! git revert --no-commit "$revert_commit"; then\n        git revert --abort 2>/dev/null || true\n        git reset --hard HEAD\n        echo "Failed to revert $revert_commit"\n        exit 1\n    fi\n\n    echo -e "${green}D32S8 workaround reverted successfully.${nocolor}"\n
    echo -e "${green}Building: $build_name${nocolor}"
    
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
  \"description\": \"Mesa Main merged with MR 39751 (Native KGSL Timeline)\",
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
