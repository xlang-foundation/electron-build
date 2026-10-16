#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cd -- "$repo/.." && pwd)"
source_root="$repo/.chromium/src"
sdk_root="${CANTORAI_MACOS_SDK_ROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
electron_root="$source_root/electron"
depot_tools="$root/out/electron-build/macos-arm64/depot_tools"
expected="$(tr -d '[:space:]' < "$repo/config/electron.ref")"
actual="$(git -C "$electron_root" rev-parse HEAD)"
if [[ "$actual" != "$expected" ]]; then
  echo "Electron checkout must match config/electron.ref" >&2
  exit 1
fi
if [[ ! -d /Applications/Xcode.app/Contents/Developer ]]; then
  echo "Install the full Xcode app at /Applications/Xcode.app and finish its first-launch setup." >&2
  exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$depot_tools:/opt/homebrew/bin:$PATH"
export DEPOT_TOOLS_UPDATE=0
if [[ ! -f "$depot_tools/python3_bin_reldir.txt" ]]; then
  source "$depot_tools/bootstrap_python3"
  bootstrap_python3
fi
xcodebuild -checkFirstLaunchStatus
if [[ ! -d "$sdk_root" ]]; then
  echo "Install the macOS 26.5 SDK or set CANTORAI_MACOS_SDK_ROOT to an SDK supported by the pinned Chromium toolchain." >&2
  exit 1
fi
cd "$source_root"
if [[ ! -f build/config/BUILDCONFIG.gn ]]; then
  echo "Electron/Chromium synchronization is not complete." >&2
  exit 1
fi
mkdir -p out/CantorElectronRelease
mkdir -p out/CantorElectronRelease/sdk/custom
ln -sfn "$sdk_root" out/CantorElectronRelease/sdk/custom/MacOSX26.5.sdk
cat > out/CantorElectronRelease/args.gn <<'GN'
import("//electron/build/args/release.gn")
target_cpu = "arm64"
is_component_build = false
symbol_level = 0
use_remoteexec = false
mac_sdk_path = "//out/CantorElectronRelease/sdk/custom/MacOSX26.5.sdk"
GN
gn gen out/CantorElectronRelease
autoninja -C out/CantorElectronRelease -j "${CMAKE_BUILD_PARALLEL_LEVEL:-4}" electron electron:electron_dist_zip
echo "Shared Electron distribution: $source_root/out/CantorElectronRelease/dist.zip"
