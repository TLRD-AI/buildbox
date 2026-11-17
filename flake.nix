{
  description = "Exemplar cross-platform Nix devShell (Fedora Atomic Linux + Apple Silicon macOS + Devcontainer + CI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # nixpkgs 26.11+ drops Intel macOS (x86_64-darwin); target Linux x86_64/arm64 + Apple Silicon.
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        isLinux = pkgs.stdenv.hostPlatform.isLinux;

        # On macOS (Darwin), use mkShellNoCC so Nix does not inject its own Apple
        # clang-wrapper, DEVELOPER_DIR, or SDKROOT over host /Applications/Xcode.app.
        mkDevShell = if isLinux then pkgs.mkShell else pkgs.mkShellNoCC;

        # Shared C/native libraries needed by Python PDF/imaging/DB wheels
        # (e.g., WeasyPrint, Pillow, psycopg) exposed via LD_LIBRARY_PATH / DYLD_FALLBACK_LIBRARY_PATH.
        nativeLibs = with pkgs; [
          pango
          cairo
          gdk-pixbuf
          harfbuzz
          fontconfig
          glib
          libffi
          openssl
          zlib
          libjpeg
          postgresql.lib
        ] ++ pkgs.lib.optionals isLinux [
          # Prebuilt manylinux Python wheels frequently link against libstdc++.so.6
          stdenv.cc.cc.lib
        ];

        # Wrap nixpkgs Chromium on Linux so non-NixOS GPU hosts (such as Fedora Atomic
        # with proprietary NVIDIA drivers) expose ONLY host NVIDIA GL/EGL vendor libraries
        # without leaking host glibc into LD_LIBRARY_PATH, while GPU-less containers
        # and CI runners fall back cleanly to SwiftShader software WebGL.
        buildboxChromium = pkgs.writeShellScriptBin "chromium" ''
          set -euo pipefail
          real_chromium="${pkgs.chromium}/bin/chromium"

          # NixOS hosts already expose drivers at /run/opengl-driver/lib
          if [ -e /run/opengl-driver/lib ]; then
            exec "$real_chromium" "$@"
          fi

          # Probe standard Linux GLVND vendor locations for NVIDIA user-space libs
          has_nvidia_egl=0
          nvidia_lib_dir=""
          if [ -r /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
            for dir in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
              if [ -r "$dir/libEGL_nvidia.so.0" ] && [ -r "$dir/libGLX_nvidia.so.0" ]; then
                has_nvidia_egl=1
                nvidia_lib_dir="$dir"
                break
              fi
            done
          fi

          # Allow forcing software WebGL via BUILDBOX_CHROME_SOFTWARE_GL=1
          force_sw="''${BUILDBOX_CHROME_SOFTWARE_GL:-''${TLRD_CHROME_SOFTWARE_GL:-0}}"

          if [ "$has_nvidia_egl" -eq 1 ] && [ "$force_sw" != "1" ]; then
            # Symlink only NVIDIA GL/EGL libraries into an isolated cache directory so
            # host libc.so.6 / libstdc++ never override Nix's /nix/store glibc.
            cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}/buildbox-nix-gl"
            mkdir -p "$cache_root"
            target_id="$(readlink -f "$nvidia_lib_dir/libEGL_nvidia.so.0" 2>/dev/null || echo "$nvidia_lib_dir/libEGL_nvidia.so.0")"
            stamp_file="$cache_root/.stamp"
            if [ ! -f "$stamp_file" ] || [ "$(cat "$stamp_file" 2>/dev/null || true)" != "$target_id" ]; then
              for pattern in 'lib*nvidia*.so*' 'libEGL_nvidia*.so*' 'libGLX_nvidia*.so*' 'libGLESv2_nvidia*.so*'; do
                for lib in "$nvidia_lib_dir"/$pattern; do
                  [ -e "$lib" ] && ln -sfn "$lib" "$cache_root/"
                done
              done
              printf '%s\n' "$target_id" > "$stamp_file"
            fi
            export __EGL_VENDOR_LIBRARY_FILENAMES="/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
            export __GLX_VENDOR_LIBRARY_NAME="nvidia"
            if [ -r /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json ]; then
              export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json"
            elif [ -r /etc/vulkan/icd.d/nvidia_icd.x86_64.json ]; then
              export VK_ICD_FILENAMES="/etc/vulkan/icd.d/nvidia_icd.x86_64.json"
            fi
            export LD_LIBRARY_PATH="$cache_root''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            exec "$real_chromium" "$@"
          fi

          # Headless / container / CI fallback: swap ANGLE GL for SwiftShader when no GPU
          # render node is present or software GL was explicitly requested.
          if [ "$force_sw" = "1" ] || { [ ! -e /dev/nvidia0 ] && ! ls /dev/dri/renderD* >/dev/null 2>&1; }; then
            for arg in "$@"; do
              if [ "$arg" = "--use-angle=gl" ]; then
                exec "$real_chromium" "$@" --use-angle=swiftshader --enable-unsafe-swiftshader
              fi
            done
          fi

          exec "$real_chromium" "$@"
        '';
      in {
        devShells.default = mkDevShell {
          packages = with pkgs; [
            python315
            uv
            nodejs_22
            flutter
            brotli
            gzip
            ripgrep
            fd
            binaryen
            jq
            shellcheck
            docker-client
            docker-compose
            docker-buildx
          ] ++ nativeLibs ++ pkgs.lib.optionals isLinux [
            buildboxChromium
          ];

          shellHook = ''
            # Enable Python 3.15 experimental copy-and-patch JIT and skip duplicate Puppeteer downloads
            export PYTHON_JIT="''${PYTHON_JIT:-1}"
            export PUPPETEER_SKIP_DOWNLOAD="''${PUPPETEER_SKIP_DOWNLOAD:-1}"
            export PUB_CACHE="''${PUB_CACHE:-$HOME/.cache/pub-cache}"

            # Derive parallel worker count dynamically unless overridden (e.g., on 8 GB hosts)
            export DJANGO_TEST_PARALLEL="''${DJANGO_TEST_PARALLEL:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

            ${pkgs.lib.optionalString isLinux ''
              export CHROME_BIN="${buildboxChromium}/bin/chromium"
              # Route `docker` CLI to rootless Podman socket when active and DOCKER_HOST is unset
              if [ -z "''${DOCKER_HOST:-}" ] && [ -S "/run/user/$(id -u)/podman/podman.sock" ]; then
                export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
              fi
              # Rootless Podman's Docker-compat socket builds natively via Buildah;
              # disabling BuildKit/Bake avoids crun oom_score_adj EACCES in buildkit containers
              # and Buildx Bake fs-entitlement errors on @devcontainers/cli temp Dockerfiles.
              case "''${DOCKER_HOST:-}" in
                *podman/podman.sock*)
                  export DOCKER_BUILDKIT="''${DOCKER_BUILDKIT:-0}"
                  export COMPOSE_BAKE="''${COMPOSE_BAKE:-false}"
                  ;;
              esac
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath nativeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            ''}

            ${pkgs.lib.optionalString (!isLinux) ''
              # Prevent Nix wrapper env vars from shadowing /Applications/Xcode.app on macOS
              unset DEVELOPER_DIR SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS
              # Required when Python multiprocessing uses fork() after macOS Obj-C runtime init
              export OBJC_DISABLE_INITIALIZE_FORK_SAFETY="''${OBJC_DISABLE_INITIALIZE_FORK_SAFETY:-YES}"
              # Note: run scripts via Nix's `bash` rather than `/usr/bin/env bash` so Apple SIP
              # does not strip DYLD_FALLBACK_LIBRARY_PATH.
              export DYLD_FALLBACK_LIBRARY_PATH="${pkgs.lib.makeLibraryPath nativeLibs}''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
            ''}
          '';
        };
      });
}
