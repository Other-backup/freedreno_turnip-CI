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

inject_feature_unlocker() {
    echo -e "${green}Injecting Vulkan 1.1/1.2/1.3/1.4 Feature Unlocker...${nocolor}"
    
    cat << 'EOF_PYTHON' > unlock_features.py
import sys
import re

file_path = "src/freedreno/vulkan/tu_device.cc"

# List of all features to force enabled
features_1_1 = [
    "storageBuffer16BitAccess", "uniformAndStorageBuffer16BitAccess", "storagePushConstant16",
    "storageInputOutput16", "multiview", "multiviewGeometryShader", "multiviewTessellationShader",
    "variablePointersStorageBuffer", "variablePointers", "protectedMemory", "samplerYcbcrConversion",
    "shaderDrawParameters"
]

features_1_2 = [
    "samplerMirrorClampToEdge", "drawIndirectCount", "storageBuffer8BitAccess", "uniformAndStorageBuffer8BitAccess",
    "storagePushConstant8", "shaderBufferInt64Atomics", "shaderSharedInt64Atomics", "shaderFloat16",
    "shaderInt8", "descriptorIndexing", "shaderInputAttachmentArrayDynamicIndexing",
    "shaderUniformTexelBufferArrayDynamicIndexing", "shaderStorageTexelBufferArrayDynamicIndexing",
    "shaderUniformBufferArrayNonUniformIndexing", "shaderSampledImageArrayNonUniformIndexing",
    "shaderStorageBufferArrayNonUniformIndexing", "shaderStorageImageArrayNonUniformIndexing",
    "shaderInputAttachmentArrayNonUniformIndexing", "shaderUniformTexelBufferArrayNonUniformIndexing",
    "shaderStorageTexelBufferArrayNonUniformIndexing", "descriptorBindingUniformBufferUpdateAfterBind",
    "descriptorBindingSampledImageUpdateAfterBind", "descriptorBindingStorageImageUpdateAfterBind",
    "descriptorBindingStorageBufferUpdateAfterBind", "descriptorBindingUniformTexelBufferUpdateAfterBind",
    "descriptorBindingStorageTexelBufferUpdateAfterBind", "descriptorBindingUpdateUnusedWhilePending",
    "descriptorBindingPartiallyBound", "descriptorBindingVariableDescriptorCount", "runtimeDescriptorArray",
    "samplerFilterMinmax", "scalarBlockLayout", "imagelessFramebuffer", "uniformBufferStandardLayout",
    "shaderSubgroupExtendedTypes", "separateDepthStencilLayouts", "hostQueryReset", "timelineSemaphore",
    "bufferDeviceAddress", "bufferDeviceAddressCaptureReplay", "bufferDeviceAddressMultiDevice",
    "vulkanMemoryModel", "vulkanMemoryModelDeviceScope", "vulkanMemoryModelAvailabilityVisibilityChains",
    "shaderOutputViewportIndex", "shaderOutputLayer", "subgroupBroadcastDynamicId"
]

features_1_3 = [
    "robustImageAccess", "inlineUniformBlock", "descriptorBindingInlineUniformBlockUpdateAfterBind",
    "pipelineCreationCacheControl", "privateData", "shaderDemoteToHelperInvocation", "shaderTerminateInvocation",
    "subgroupSizeControl", "computeFullSubgroups", "synchronization2", "textureCompressionASTC_HDR",
    "shaderZeroInitializeWorkgroupMemory", "dynamicRendering", "shaderIntegerDotProduct", "maintenance4"
]

# Create code blocks
code_1_1 = "".join([f"      f->{feat} = VK_TRUE;\n" for feat in features_1_1])
code_1_2 = "".join([f"      f->{feat} = VK_TRUE;\n" for feat in features_1_2])
code_1_3 = "".join([f"      f->{feat} = VK_TRUE;\n" for feat in features_1_3])

with open(file_path, 'r') as f:
    content = f.read()

# Pattern to find the switch statement in tu_GetPhysicalDeviceFeatures2
# We look for the case statements and inject our forcing code before the break

# Inject 1.1
if "VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES" in content:
    pattern = r"(case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:[\s\S]*?)(\s+break;)"
    replacement = f"\\1\n      VkPhysicalDeviceVulkan11Features *f = (VkPhysicalDeviceVulkan11Features *)ext;\n{code_1_1}\\2"
    content = re.sub(pattern, replacement, content, count=1)

# Inject 1.2
if "VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES" in content:
    pattern = r"(case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:[\s\S]*?)(\s+break;)"
    replacement = f"\\1\n      VkPhysicalDeviceVulkan12Features *f = (VkPhysicalDeviceVulkan12Features *)ext;\n{code_1_2}\\2"
    content = re.sub(pattern, replacement, content, count=1)

# Inject 1.3
if "VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES" in content:
    pattern = r"(case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES:[\s\S]*?)(\s+break;)"
    replacement = f"\\1\n      VkPhysicalDeviceVulkan13Features *f = (VkPhysicalDeviceVulkan13Features *)ext;\n{code_1_3}\\2"
    content = re.sub(pattern, replacement, content, count=1)

with open(file_path, 'w') as f:
    f.write(content)
EOF_PYTHON
    
    python3 unlock_features.py
}

compile_mesa() {
    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="main"
    local build_name="Turnip-A8xx-Ultimate"
    local output_tag="V76-A8xx-Ult-VK1.4"

    echo -e "${green}Cloning Mesa Main...${nocolor}"
    
    cd "$workdir"
    if [ -d mesa ]; then rm -rf mesa; fi
    
    git clone --depth 100 -b "$branch" "$repo_url" mesa
    cd mesa
    git config user.email "ci@turnip.builder" && git config user.name "Turnip CI Builder"

    # 1. APPLY A8XX PATCH
    if [ -f "$workdir/../tu_gen8.patch" ]; then
        echo -e "${green}Applying tu_gen8.patch...${nocolor}"
        patch -p1 --fuzz=4 --ignore-whitespace < "$workdir/../tu_gen8.patch" || echo "Warning: Patch had loose matches"
    elif [ -f "tu_gen8.patch" ]; then
         echo -e "${green}Applying tu_gen8.patch...${nocolor}"
         patch -p1 --fuzz=4 --ignore-whitespace < "tu_gen8.patch" || echo "Warning: Patch had loose matches"
    else
        echo "Error: tu_gen8.patch not found."
        exit 1
    fi

    # 2. FORCE VK 1.4.340
    echo -e "${green}Setting Driver Version to Vulkan 1.4.340...${nocolor}"
    sed -i 's/VK_MAKE_VERSION(1, 3, [0-9]*)/VK_MAKE_VERSION(1, 4, 340)/g' src/freedreno/vulkan/tu_device.cc || true
    sed -i 's/VK_MAKE_VERSION(1, 4, [0-9]*)/VK_MAKE_VERSION(1, 4, 340)/g' src/freedreno/vulkan/tu_device.cc || true
    sed -i 's/VK_MAKE_VERSION(1, 3, [0-9]*)/VK_MAKE_VERSION(1, 4, 340)/g' src/freedreno/vulkan/tu_physical_device.cc || true
    sed -i 's/VK_MAKE_VERSION(1, 4, [0-9]*)/VK_MAKE_VERSION(1, 4, 340)/g' src/freedreno/vulkan/tu_physical_device.cc || true

    # 3. UNLOCK ALL FEATURES (1.1, 1.2, 1.3)
    inject_feature_unlocker

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
  \"description\": \"Mesa Main + A8xx + VK1.4.340 + All Features Unlocked\",
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
