#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This bootstrap requires Linux." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace="$(cd -- "$script_dir/.." && pwd)"
component_root="$(cd -- "$workspace/.." && pwd)"
state_root="$component_root/out/electron-build/linux-arm64"
checkout_root="$state_root/webrtc-standalone"
source_root="$checkout_root/src"
depot_tools="$state_root/depot_tools"
webrtc_revision="$(tr -d '[:space:]' < "$workspace/config/webrtc.ref")"

mkdir -p "$state_root" "$checkout_root"
if [[ ! -x "$depot_tools/gclient" ]]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_tools"
fi
export PATH="$depot_tools:/usr/bin:/bin"
export DEPOT_TOOLS_UPDATE=0
export DEPOT_TOOLS_WIN_TOOLCHAIN=0

cp "$workspace/config/gclient.webrtc.linux.py" "$checkout_root/.gclient"
if [[ ! -d "$source_root/.git" ]]; then
  git init "$source_root"
  git -C "$source_root" remote add origin https://webrtc.googlesource.com/src.git
fi
if ! git -C "$source_root" cat-file -e "$webrtc_revision^{commit}" 2>/dev/null; then
  git -C "$source_root" fetch --depth 1 --no-tags origin "$webrtc_revision"
fi
git -C "$source_root" checkout --detach "$webrtc_revision"

cd "$checkout_root"
gclient sync --force --no-history --revision "src@$webrtc_revision"
python3 "$source_root/build/linux/sysroot_scripts/install-sysroot.py" --arch=arm64
