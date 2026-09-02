#!/bin/bash
#
# Embedding and signing Sparkle, in one place, because two callers need it and
# they must not drift.
#
# bundle.sh assembles the app (locally, and in the hosted BUILD job with a
# throwaway signature). release.sh re-signs the prebuilt app with the real
# Developer ID in a separate job that never sees the build. Both have to walk the
# same nested components in the same order, so the walk lives here.
#
# Three facts drive everything below, all verified against Sparkle 2.9.6 rather
# than assumed:
#
#   1. The SPM artifact is a prebuilt XCFramework and is AD-HOC SIGNED:
#      `codesign -dv` reports "Signature=adhoc, TeamIdentifier=not set". A
#      Developer ID signature wrapped around ad-hoc nested code does not
#      notarize, so every nested Mach-O must be re-signed. This is the failure
#      that would otherwise appear only at the notarization step of a release,
#      an hour into CI.
#
#   2. `codesign --deep` must NOT be used. Sparkle says so explicitly, and it is
#      why bundle.sh's outer signature dropped --deep when this arrived: --deep
#      re-signs nested bundles with the OUTER bundle's identifier and
#      entitlements, which corrupts the helper signatures rather than sealing
#      them. Sign inside-out, then seal.
#
#   3. The version directory letter is not stable. Sparkle currently ships
#      Versions/B, and the linker bakes "Versions/B" into the app's load command,
#      but the framework carries a Versions/Current symlink and a future release
#      may move. Resolving Current is one line; a hardcoded letter is a silent
#      break on upgrade.
#
# The XPC services are deleted rather than signed. Sparkle's own sandboxing guide
# says a non-sandboxed app does not need them ("you may choose to remove these
# services in a post install script"), and SUEnableInstallerLauncherService /
# SUEnableDownloaderService both default to NO, so Sparkle falls back to its
# in-process installer with no configuration. Two 2025 CVEs (CVE-2025-10015, a
# TCC bypass, and CVE-2025-10016, a local root escalation) lived in exactly these
# binaries and were reachable from their mere presence in the bundle rather than
# from the app enabling them. Both are fixed in 2.7.2 and we ship far newer, so
# this is defence in depth rather than a fix, but two fewer executables in a
# bundle that already holds the microphone is worth having.

# Absolute path to the framework SwiftPM copied next to the built binary.
sparkle_source_framework() {
  local build_dir="$1"
  printf '%s\n' "$build_dir/Sparkle.framework"
}

# The real (symlink-resolved) versioned directory inside an embedded framework.
sparkle_version_dir() {
  local framework="$1"
  local versions="$framework/Versions"
  [ -d "$versions" ] || { echo "✗ no Versions directory in $framework" >&2; return 1; }

  if [ -L "$versions/Current" ] || [ -e "$versions/Current" ]; then
    ( cd "$versions/Current" && pwd -P )
    return
  fi

  # No Current symlink: accept exactly one version directory, never guess
  # between several.
  local found=()
  local candidate
  for candidate in "$versions"/*; do
    [ -d "$candidate" ] && found+=("$candidate")
  done
  [ "${#found[@]}" -eq 1 ] \
    || { echo "✗ expected one Sparkle version directory, found ${#found[@]}" >&2; return 1; }
  ( cd "${found[0]}" && pwd -P )
}

# Copy the framework into the bundle, drop the XPC services, and teach the
# executable where to find it.
#
# `cp -R` rather than ditto: the framework is a symlink farm (Versions/Current,
# and the top-level Headers/Resources/Sparkle aliases), and dereferencing any of
# them invalidates the code signature.
sparkle_embed() {
  local app_dir="$1" build_dir="$2"
  local source
  source=$(sparkle_source_framework "$build_dir")
  [ -d "$source" ] || { echo "✗ no Sparkle.framework at $source (run swift build first)" >&2; return 1; }

  local frameworks="$app_dir/Contents/Frameworks"
  mkdir -p "$frameworks"
  rm -rf "$frameworks/Sparkle.framework"
  cp -R "$source" "$frameworks/Sparkle.framework"

  local version_dir
  version_dir=$(sparkle_version_dir "$frameworks/Sparkle.framework") || return 1
  rm -rf "$version_dir/XPCServices"

  # The binary links @rpath/Sparkle.framework/..., and SwiftPM only gave it
  # @loader_path, which points at Contents/MacOS. Adding the rpath is what turns
  # "built" into "launches". `|| true` because a second bundle of the same tree
  # would otherwise fail on a duplicate.
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$app_dir/Contents/MacOS/TranquilityApp" 2>/dev/null || true
}

# Sign every nested Mach-O inside the embedded framework, inside-out.
#
# Order matters: a bundle's seal covers its contents, so anything inside it must
# already carry its final signature. Updater.app's executable before Updater.app;
# the framework binary and version directory before the framework root.
#
# Usage: sparkle_sign <app_dir> <identity> [extra codesign args...]
sparkle_sign() {
  local app_dir="$1" identity="$2"
  shift 2
  local framework="$app_dir/Contents/Frameworks/Sparkle.framework"
  [ -d "$framework" ] || { echo "✗ no embedded Sparkle.framework to sign" >&2; return 1; }

  local version_dir
  version_dir=$(sparkle_version_dir "$framework") || return 1

  [ -e "$version_dir/XPCServices" ] \
    && { echo "✗ XPCServices survived embedding; sparkle_embed should have removed them" >&2; return 1; }

  local target
  for target in \
    "$version_dir/Autoupdate" \
    "$version_dir/Updater.app/Contents/MacOS/Updater" \
    "$version_dir/Updater.app" \
    "$version_dir/Sparkle" \
    "$version_dir" \
    "$framework"
  do
    [ -e "$target" ] || { echo "✗ missing Sparkle signing target: $target" >&2; return 1; }
    # No --entitlements: these are Sparkle's helpers, not our app, and they need
    # none of the microphone or Apple Events grants. No --deep, ever (see header).
    codesign --force --sign "$identity" --options runtime "$@" "$target" \
      || { echo "✗ could not sign $target" >&2; return 1; }
  done
}

# Every nested Mach-O an audit should find, relative to the app bundle. One list,
# so audit-release.sh cannot check a different set from the one that got signed.
sparkle_signed_paths() {
  local app_dir="$1"
  local framework="$app_dir/Contents/Frameworks/Sparkle.framework"
  local version_dir
  version_dir=$(sparkle_version_dir "$framework") || return 1
  printf '%s\n' \
    "$version_dir/Autoupdate" \
    "$version_dir/Updater.app" \
    "$framework"
}
