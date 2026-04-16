name: Build Freedreno KGSL (Winlator GLX)

on:
  workflow_dispatch: # Permite rodar manualmente no painel do GitHub

jobs:
  build:
    runs-on: ubuntu-24.04
    
    env:
      NDK_VER: "android-ndk-r26c" # Use a mesma versão que você usa para o Winlator
      API_LEVEL: "28" # AHardwareBuffer precisa no mínimo da API 26, 28 é seguro
      
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y meson ninja-build flex bison python3-pip curl unzip pkg-config
          pip3 install mako --break-system-packages

      - name: Download and Setup Android NDK
        run: |
          cd $GITHUB_WORKSPACE
          curl -sLO https://dl.google.com/android/repository/${NDK_VER}-linux.zip
          unzip -q ${NDK_VER}-linux.zip
          echo "NDK_HOME=$GITHUB_WORKSPACE/${NDK_VER}" >> $GITHUB_ENV

      - name: Clone Mesa
        run: |
          git clone --depth 1 -b main https://gitlab.freedesktop.org/mesa/mesa.git
          
      - name: Apply KGSL Patch
        run: |
          cd mesa
          # Aplica o patch KGSL que você salvou no seu repositório
          patch -p1 < ../patches/0014-freedreno-kgsl-experimental.patch

      - name: Setup Meson Cross-File
        run: |
          # Cria o arquivo para ensinar o Meson a usar o compilador do Android NDK
          cat <<EOF > mesa/android-aarch64.txt
          [binaries]
          ar = '$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar'
          c = ['ccache', '$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API_LEVEL}-clang']
          cpp = ['ccache', '$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API_LEVEL}-clang++']
          c_ld = 'lld'
          cpp_ld = 'lld'
          strip = '$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip'
          pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$NDK_HOME/pkg-config', '/usr/bin/pkg-config']

          [host_machine]
          system = 'android'
          cpu_family = 'aarch64'
          cpu = 'armv8'
          endian = 'little'
          EOF

      - name: Configure Build (Meson)
        run: |
          cd mesa
          
          # A mágica acontece aqui. Desativamos o X11 e GLX do Mesa,
          # ativamos a plataforma Android (para ter AHardwareBuffer na libEGL)
          # e forçamos o Freedreno a usar o KGSL.
          meson setup build --cross-file android-aarch64.txt \
            -Dbuildtype=release \
            -Dplatforms=android \
            -Dplatform-sdk-version=${API_LEVEL} \
            -Dandroid-stub=true \
            -Dgallium-drivers=freedreno \
            -Dvulkan-drivers= \
            -Dfreedreno-kmds=kgsl \
            -Degl=enabled \
            -Dgles1=disabled \
            -Dgles2=enabled \
            -Dopengl=true \
            -Dglx=disabled \
            -Dgbm=disabled \
            -Dshared-glapi=enabled
            
      - name: Compile
        run: |
          cd mesa
          ninja -C build

      - name: Collect Artifacts
        run: |
          mkdir -p freedreno-libs
          # A libEGL e libGLESv2 são as que o seu JNI (glx_freedreno.c) carrega via dlopen()
          cp mesa/build/src/egl/libEGL_mesa.so freedreno-libs/
          cp mesa/build/src/mapi/es2api/libGLESv2_mesa.so freedreno-libs/
          cp mesa/build/src/mapi/shared-glapi/libglapi.so freedreno-libs/
          # O driver Gallium em si geralmente compila como libgallium_dri.so na pasta de módulos
          find mesa/build -name "*_dri.so" -exec cp {} freedreno-libs/ \;
          
      - name: Upload Artifacts
        uses: actions/upload-artifact@v4
        with:
          name: freedreno-kgsl-libs
          path: freedreno-libs/
