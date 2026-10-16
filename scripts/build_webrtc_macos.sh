#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build requires macOS." >&2
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
source_root="${WEBRTC_SOURCE_ROOT:-$state_root/webrtc-standalone/src}"
depot_tools="${WEBRTC_DEPOT_TOOLS_ROOT:-$state_root/depot_tools}"
build_name=CantorWebRTCRelease
if [[ "$target_arch" == x86_64 ]]; then build_name=CantorWebRTCRelease-x86_64; fi
build_dir="$source_root/out/$build_name"
stage_dir="$component_root/out/deps/$platform-release/webrtc"
stage_include_dir="$stage_dir/include"
build_target="${WEBRTC_BUILD_TARGET:-webrtc}"
supplemental_targets=(
  "api/video:adapted_video_track_source"
  "api/video_codecs:builtin_video_decoder_factory"
  "media:rtc_internal_video_codecs"
)

if [[ ! -d "$source_root/build" || ! -x "$depot_tools/gn" ]]; then
  "$script_dir/bootstrap_macos.sh"
fi

export PATH="$depot_tools:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DEPOT_TOOLS_UPDATE=0
mkdir -p "$build_dir" "$stage_dir/lib"
cp "$workspace/config/args.mac-$gn_arch.gn" "$build_dir/args.gn"
if [[ -n "${MAC_SDK_PATH:-}" ]]; then
  sdk_path="$MAC_SDK_PATH"
  if [[ "$sdk_path" != "$build_dir/"* ]]; then
    local_sdk="$build_dir/sdk/$(basename "$sdk_path")"
    if [[ ! -d "$local_sdk" ]]; then
      mkdir -p "$build_dir/sdk"
      ditto "$sdk_path" "$local_sdk"
    fi
    sdk_path="$local_sdk"
  fi
  sdk_path="//${sdk_path#"$source_root/"}"
  printf '\nmac_sdk_min = "%s"\nmac_sdk_path = "%s"\n' \
    "${MAC_SDK_MIN:-15}" "$sdk_path" >> "$build_dir/args.gn"
fi

cd "$source_root"
gn gen "out/$build_name"
autoninja -C "out/$build_name" -j "${WEBRTC_BUILD_JOBS:-2}" "$build_target" "${supplemental_targets[@]}"

if [[ "$build_target" == "webrtc" || "$build_target" == ":webrtc" ]]; then
  default_library="$build_dir/obj/libwebrtc.a"
else
  default_library="$build_dir/obj/third_party/webrtc/libwebrtc.a"
fi
library="${WEBRTC_LIBRARY_PATH:-$default_library}"
supplemental_libraries=(
  "$build_dir/obj/api/video/libadapted_video_track_source.a"
  "$build_dir/obj/api/video_codecs/libbuiltin_video_decoder_factory.a"
  "$build_dir/obj/media/librtc_internal_video_codecs.a"
)
if [[ ! -f "$library" ]]; then
  echo "WebRTC archive was not produced at $library" >&2
  exit 1
fi
staged_library="$stage_dir/lib/libwebrtc.a"
cp "$library" "$staged_library.tmp"
llvm_ar="$source_root/third_party/llvm-build/Release+Asserts/bin/llvm-ar"
for supplemental_library in "${supplemental_libraries[@]}"; do
  if [[ ! -f "$supplemental_library" ]]; then
    echo "WebRTC supplemental archive was not produced at $supplemental_library" >&2
    exit 1
  fi
  while IFS= read -r member; do
    if [[ "$member" != /* ]]; then
      member="$source_root/$member"
    fi
    "$llvm_ar" q "$staged_library.tmp" "$member"
  done < <("$llvm_ar" t "$supplemental_library")
done
"$llvm_ar" s "$staged_library.tmp"
if ! lipo "$staged_library.tmp" -verify_arch "$target_arch"; then
  echo "WebRTC archive is not $target_arch: $staged_library.tmp" >&2
  exit 1
fi
mv "$staged_library.tmp" "$staged_library"

rm -rf "$stage_include_dir"
mkdir -p "$stage_include_dir"
(
  cd "$source_root"
  find . -type f \( -name '*.h' -o -name '*.inc' \) \
    -not -path './.git/*' \
    -not -path './out/*' \
    -print | tar -cf - -T -
) | tar -xf - -C "$stage_include_dir"
(
  cd "$build_dir/gen"
  find . -type f \( -name '*.h' -o -name '*.inc' \) -print | tar -cf - -T -
) | tar -xf - -C "$stage_include_dir"
cp "$workspace/config/webrtc.ref" "$stage_dir/webrtc.ref"
echo "Staged Electron WebRTC: $stage_dir/lib/libwebrtc.a"
