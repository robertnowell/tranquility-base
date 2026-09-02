#!/bin/bash
#
# Where the assembled .app lives. One definition, because eight scripts and a
# workflow need it and a disagreement between any two of them is silent.
#
# The .app used to be assembled into .build/<config>, which looks like the
# obvious place and is in fact the one directory it must never live in.
# .build/<config> belongs to SwiftPM, and SwiftPM does two things with it that
# no caller is warned about. Both were measured on 02 Sep 2026 rather than
# reasoned about, while working out what Intel support would cost:
#
#   1. IT DELETES A REAL DIRECTORY OF THAT NAME. If .build/release exists as a
#      directory, the next `swift build` replaces it with a symlink and takes
#      the contents with it. Exit code 0, no warning, nothing on stderr:
#
#        $ mkdir -p .build/release
#        $ echo CANARY > .build/release/canary.txt
#        $ swift build -c release --product tbase-test-target
#        Build of product 'tbase-test-target' complete! (0.20s)
#        $ ls -ld .build/release
#        lrwxr-xr-x  .build/release -> arm64-apple-macosx/release
#        $ ls .build/release/canary.txt
#        (gone)
#
#      This matters now because a universal build writes to
#      .build/apple/Products/<Config> and does NOT create the .build/<config>
#      symlink, so the tempting patch is `mkdir -p .build/release` first. That
#      patch means the release app is deleted by the next preflight.sh,
#      test.sh, relaunch.sh, or any ordinary local build.
#
#   2. THE SYMLINK FOLLOWS WHICHEVER ARCHITECTURE BUILT LAST. One
#      `swift build --arch x86_64` was enough to leave .build/debug pointing at
#      x86_64-apple-macosx/debug. Every script below reads the .app through
#      that path, so in that state all of them would have handed back an Intel
#      binary running under Rosetta on Apple Silicon, and nothing on screen
#      would have said so.
#
# So the bundle goes somewhere SwiftPM has no opinion about. .build/ is still
# the right parent, being already gitignored and already understood to be
# disposable, but the leaf is ours.
#
# Usage:
#   . "$(dirname "$0")/lib/paths.sh"
#   tb_bundle_dir debug                      # .build/bundle/debug
#   tb_bundle_dir release /private/tmp/foo   # /private/tmp/foo/.build/bundle/release

# Directory that holds the assembled .app for one configuration.
#
#   $1  configuration: debug (default) or release
#   $2  repository root the build happened in (default: the current directory)
tb_bundle_dir() {
  local config="${1:-debug}" root="${2:-}"
  # No root given means "relative to here". Emitting a bare .build/... rather
  # than ./.build/... keeps these paths identical to the ones they replace,
  # which matters because several of them are echoed at the user.
  [ -z "$root" ] && { printf '%s\n' ".build/bundle/$config"; return; }
  printf '%s\n' "${root%/}/.build/bundle/$config"
}
