#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This build requires Linux; the output target is Linux ARM64." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace="$(cd -- "$script_dir/.." && pwd)"
component_root="$(cd -- "$workspace/.." && pwd)"
state_root="$component_root/out/electron-build/linux-arm64"
source_root="${WEBRTC_SOURCE_ROOT:-$state_root/webrtc-standalone/src}"
depot_tools="$state_root/depot_tools"
build_dir="$source_root/out/CantorWebRTCRelease"
stage_dir="$component_root/out/deps/linux-arm64-release/webrtc"
stage_include_dir="$stage_dir/include"
supplemental_targets=(
  "api/video:adapted_video_track_source"
  "api/video_codecs:builtin_video_decoder_factory"
  "media:rtc_internal_video_codecs"
)
package_only=false
if [[ "${1:-}" == "--package-only" ]]; then
  package_only=true
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--package-only]" >&2
  exit 2
fi

if [[ "$package_only" == false ]]; then
  if [[ ! -d "$source_root/build" || ! -x "$depot_tools/gn" ]]; then
    "$script_dir/bootstrap_linux.sh"
  fi

  compat_patch="$workspace/patches/webrtc-linux-libstdcpp10.patch"
  if git -C "$source_root" apply --check "$compat_patch" 2>/dev/null; then
    git -C "$source_root" apply "$compat_patch"
  elif ! git -C "$source_root" apply --reverse --check "$compat_patch" 2>/dev/null; then
    echo "WebRTC source does not match the Linux libstdc++ compatibility patch." >&2
    exit 1
  fi

  export PATH="$depot_tools:/usr/bin:/bin"
  export DEPOT_TOOLS_UPDATE=0
  export DEPOT_TOOLS_WIN_TOOLCHAIN=0
  mkdir -p "$build_dir"
  cp "$workspace/config/args.linux-arm64.gn" "$build_dir/args.gn"

  cd "$source_root"
  gn gen "out/CantorWebRTCRelease"
  autoninja -C "out/CantorWebRTCRelease" webrtc "${supplemental_targets[@]}"
fi

mkdir -p "$stage_dir/lib"

library="$build_dir/obj/libwebrtc.a"
supplemental_libraries=(
  "$build_dir/obj/api/video/libadapted_video_track_source.a"
  "$build_dir/obj/api/video_codecs/libbuiltin_video_decoder_factory.a"
  "$build_dir/obj/media/librtc_internal_video_codecs.a"
)
llvm_ar="$source_root/third_party/llvm-build/Release+Asserts/bin/llvm-ar"
staged_library="$stage_dir/lib/libwebrtc.a"
if [[ ! -f "$library" || ! -x "$llvm_ar" ]]; then
  echo "WebRTC build outputs are incomplete." >&2
  exit 1
fi
cp "$library" "$staged_library.tmp"
for supplemental_library in "${supplemental_libraries[@]}"; do
  if [[ ! -f "$supplemental_library" ]]; then
    echo "Missing supplemental archive: $supplemental_library" >&2
    exit 1
  fi
  while IFS= read -r member; do
    [[ "$member" == /* ]] || member="$source_root/$member"
    "$llvm_ar" q "$staged_library.tmp" "$member"
  done < <("$llvm_ar" t "$supplemental_library")
done
"$llvm_ar" s "$staged_library.tmp"
first_member="$("$llvm_ar" t "$staged_library.tmp" | sed -n '1p')"
first_object="$stage_dir/lib/.webrtc-first-object.o"
"$llvm_ar" p "$staged_library.tmp" "$first_member" > "$first_object"
if ! file "$first_object" | grep -Eq 'ARM aarch64|ARM64'; then
  rm -f "$first_object"
  echo "WebRTC archive does not contain ARM64 Linux objects." >&2
  exit 1
fi
rm -f "$first_object"
mv "$staged_library.tmp" "$staged_library"

rm -rf "$stage_include_dir"
mkdir -p "$stage_include_dir"
(
  cd "$source_root"
  find . -type f \( -name '*.h' -o -name '*.inc' \) \
    -not -path './.git/*' -not -path './out/*' -print | tar -cf - -T -
) | tar -xf - -C "$stage_include_dir"
(
  cd "$build_dir/gen"
  find . -type f \( -name '*.h' -o -name '*.inc' \) -print | tar -cf - -T -
) | tar -xf - -C "$stage_include_dir"
echo "Staged Linux ARM64 WebRTC: $stage_dir/lib/libwebrtc.a"
