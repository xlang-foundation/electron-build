#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This bootstrap requires macOS." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace="$(cd -- "$script_dir/.." && pwd)"
component_root="$(cd -- "$workspace/.." && pwd)"
target_arch="${WEBRTC_MAC_ARCH:-arm64}"
case "$target_arch" in
  arm64) platform=macos-arm64; gn_arch=arm64 ;;
  x86_64|x64) platform=macos-x86; target_arch=x86_64; gn_arch=x64 ;;
  *) echo "Unsupported Mac architecture: $target_arch" >&2; exit 2 ;;
esac
export WEBRTC_MAC_ARCH="$target_arch"
state_root="$component_root/out/electron-build/$platform"
checkout_root="$state_root/webrtc-standalone"
source_root="${WEBRTC_SOURCE_ROOT:-$checkout_root/src}"
checkout_root="$(dirname "$source_root")"
depot_tools="${WEBRTC_DEPOT_TOOLS_ROOT:-$state_root/depot_tools}"
webrtc_revision="$(tr -d '[:space:]' < "$workspace/config/webrtc.ref")"

mkdir -p "$state_root" "$checkout_root"
if [[ ! -x "$depot_tools/gclient" ]]; then
  git clone --depth 1 \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    "$depot_tools"
fi

export PATH="$depot_tools:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DEPOT_TOOLS_UPDATE=0

cp "$workspace/config/gclient.webrtc.py" "$checkout_root/.gclient"
if [[ ! -d "$source_root/.git" ]]; then
  mkdir -p "$source_root"
  git -C "$source_root" init
  git -C "$source_root" remote add origin https://webrtc.googlesource.com/src.git
fi
if ! git -C "$source_root" cat-file -e "$webrtc_revision^{commit}" 2>/dev/null; then
  git -C "$source_root" fetch --depth 1 --no-tags origin "$webrtc_revision"
fi
git -C "$source_root" checkout --detach "$webrtc_revision"

cd "$checkout_root"
gclient sync --force --no-history --revision "src@$webrtc_revision"
echo "Standalone WebRTC source ready: $source_root"
