# WebRTC, embedded the way Sparkle is.
#
# LiveKit's build arrives as a prebuilt XCFramework binary target, so SwiftPM
# links it but copies nothing into the bundle: without this the app builds,
# passes its tests, and dies at launch when dyld cannot find
# @rpath/LiveKitWebRTC.framework. Same shape as scripts/lib/sparkle.sh, and for
# the same reason it must run BEFORE the icon step (which executes the bundled
# binary) and BEFORE signing (whose seal covers everything inside Contents).

webrtc_source_framework() {
  local build_dir="$1"
  # SwiftPM lays a binary target's framework beside the products.
  find "$build_dir" -maxdepth 2 -name "LiveKitWebRTC.framework" -type d 2>/dev/null | head -1
}

webrtc_embed() {
  local app_dir="$1" build_dir="$2"
  local source
  source=$(webrtc_source_framework "$build_dir")
  [ -d "$source" ] || { echo "✗ no LiveKitWebRTC.framework under $build_dir (run swift build first)" >&2; return 1; }

  local frameworks="$app_dir/Contents/Frameworks"
  mkdir -p "$frameworks"
  rm -rf "$frameworks/LiveKitWebRTC.framework"
  cp -R "$source" "$frameworks/LiveKitWebRTC.framework"

  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$app_dir/Contents/MacOS/TranquilityApp" 2>/dev/null || true
}

# Inside-out, like Sparkle: the framework binary and its version directory
# before the framework root, because a bundle's seal covers its contents.
webrtc_sign() {
  local app_dir="$1" identity="$2"; shift 2
  local framework="$app_dir/Contents/Frameworks/LiveKitWebRTC.framework"
  [ -d "$framework" ] || return 0
  local versions="$framework/Versions"
  if [ -d "$versions" ]; then
    for version in "$versions"/*; do
      [ -d "$version" ] || continue
      [ "$(basename "$version")" = "Current" ] && continue
      # Fatal, never `|| true`: this binary is the one Apple inspects, and a
      # swallowed failure here left it on the build job's throwaway signature,
      # which notarization rejected on every release from 23 Sep.
      if [ -e "$version/LiveKitWebRTC" ]; then
        codesign --force --sign "$identity" "$@" "$version/LiveKitWebRTC" || return 1
      fi
      codesign --force --sign "$identity" "$@" "$version" || return 1
    done
  fi
  codesign --force --sign "$identity" "$@" "$framework" || return 1
}

# The check that would have caught a missing framework before a release did.
webrtc_verify() {
  local app_dir="$1"
  local framework="$app_dir/Contents/Frameworks/LiveKitWebRTC.framework"
  [ -d "$framework" ] || { echo "✗ LiveKitWebRTC.framework is not in the bundle; hands-free would die at launch" >&2; return 1; }
  otool -L "$app_dir/Contents/MacOS/TranquilityApp" | grep -q "LiveKitWebRTC" \
    || { echo "✗ the binary does not link LiveKitWebRTC" >&2; return 1; }
}
