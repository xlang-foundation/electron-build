#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build requires macOS; the output target is Apple Silicon." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace="$(cd -- "$script_dir/.." && pwd)"
component_root="$(cd -- "$workspace/.." && pwd)"
state_root="$component_root/out/electron-build/macos-arm64"
source_root="${WEBRTC_SOURCE_ROOT:-$state_root/webrtc-standalone/src}"
depot_tools="$state_root/depot_tools"
build_dir="$source_root/out/CantorWebRTCRelease"
stage_dir="$component_root/out/deps/macos-arm64-release/webrtc"
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
cp "$workspace/config/args.mac-arm64.gn" "$build_dir/args.gn"
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
gn gen "out/CantorWebRTCRelease"
autoninja -C "out/CantorWebRTCRelease" "$build_target" "${supplemental_targets[@]}"

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
if ! lipo -info "$staged_library.tmp" | grep -q 'arm64'; then
  echo "WebRTC archive is not arm64: $staged_library.tmp" >&2
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
echo "Staged Electron WebRTC: $stage_dir/lib/libwebrtc.a"
