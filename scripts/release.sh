#!/bin/bash
#
# Build, audit, sign, notarize, upload, re-download, and publish one release
# for one commit on main.
#
# With no version argument, identity is deterministic:
#   version  0.3.<git ancestry count>
#   tag      v<version>-<short source SHA>
#
# That makes a merge its own release without a version-bump commit or a human
# choosing a number. A rerun finds the same tag. Published releases are audited
# in place and left untouched; failed drafts can be rebuilt and replaced.
#
# Usage: scripts/release.sh [version] [--dry-run]

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/paths.sh
. "$(dirname "$0")/lib/paths.sh"

DRY_RUN=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "usage: scripts/release.sh [version] [--dry-run]"
      exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      [ -z "$VERSION" ] || { echo "only one version may be given" >&2; exit 2; }
      VERSION="$arg" ;;
  esac
done

APP_NAME="Tranquility Base"
BUNDLE_ID="com.robertnowell.voice-dispatch"
TEAM_ID="FKE587SZ6H"
REPO="robertnowell/tranquility-base"
GITHUB_API_VERSION="2026-03-10"

# shellcheck source=lib/sparkle.sh
. "$(dirname "$0")/lib/sparkle.sh"

# Immutable-release endpoints and response fields are versioned additions to
# GitHub's REST API. gh still defaults to an older API version, which makes an
# enabled repository look like a 404 and turns a healthy release into a false
# failure. Keep every release API read on the same explicit schema.
github_api() {
  gh api -H "X-GitHub-Api-Version: $GITHUB_API_VERSION" "$@"
}

release_database_id() {
  gh release view "$TAG" --repo "$REPO" --json databaseId --jq .databaseId
}

# Read the tag back, waiting out the seconds where GitHub does not have it yet.
#
# THE RETRY THAT COULD NOT RETRY. This loop was added deliberately, in "Retry
# tag verification after creation (#240)", against exactly the failure it then
# failed to prevent: a tag is created and the ref API 404s on it for a few
# seconds afterwards. It did not work, and the reason is worth stating because
# it is a shape rather than a typo.
#
# `gh api --jq` prints an error BODY to stdout on a 404 and exits non-zero. The
# loop tested only whether the output was empty, and a 404 body is not empty, so
# it broke out on the first attempt with `{"message":"Not Found",...}` in hand,
# read that whole line into `tag_type`, and reported it as the type of the tag
# object:
#
#   ✗ release tag v0.3.1053-e19341a47 is a {"message":"Not Found", ... } object,
#     expected a commit
#
# Which is how 0.3.1053 died with a signed, notarized, stapled, fully audited
# DMG sitting beside it, one line from being published. A retry loop whose
# success test cannot distinguish an answer from an error is not a retry loop;
# it is a single attempt with extra code. So the test is now the exit status AND
# the shape of what came back, and the wait is a backoff rather than five fixed
# two-second naps.
verify_release_tag() {
  local tag_details="" tag_type tag_target delay=1
  for _ in 1 2 3 4 5 6 7; do
    # `2>/dev/null` on stderr and the exit status on stdout: gh reports the
    # failure both ways and only one of them is trustworthy here.
    if tag_details=$(github_api "repos/$REPO/git/ref/tags/$TAG" \
        --jq '.object.type + "\t" + .object.sha' 2>/dev/null) \
      && [[ "$tag_details" == *$'\t'* ]]; then
      break
    fi
    # Never carry a failed read forward as if it were data. That is the whole
    # bug above, in one assignment.
    tag_details=""
    sleep "$delay"
    delay=$(( delay * 2 ))
  done
  [ -n "$tag_details" ] || fail "release tag $TAG does not exist"
  IFS=$'\t' read -r tag_type tag_target <<<"$tag_details"
  [ "$tag_type" = "commit" ] \
    || fail "release tag $TAG is a $tag_type object, expected a commit"
  [ "$tag_target" = "$TARGET" ] \
    || fail "release tag $TAG points to $tag_target, not $TARGET"
}

ensure_release_tag() {
  if ! github_api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
    # A 422 here is the same eventual consistency read from the other side: the
    # tag exists, the read that just 404ed was stale, and the create is refused
    # as a duplicate. Under `set -e` that aborted a release whose tag was
    # already correct, so the one refusal that means "you already have what you
    # asked for" is tolerated and everything else still fails.
    local created
    if ! created=$(github_api --method POST "repos/$REPO/git/refs" \
        -f ref="refs/tags/$TAG" -f sha="$TARGET" 2>&1); then
      case "$created" in
        *"Reference already exists"*) ;;
        *) fail "could not create release tag $TAG: $created" ;;
      esac
    fi
  fi
  verify_release_tag
}

NOTARY_PROFILE="${TB_NOTARY_PROFILE:-AC_PASSWORD}"
NOTARY_KEYCHAIN="${TB_NOTARY_KEYCHAIN:-}"
RELEASE_SERIES="${TB_RELEASE_SERIES:-0.3}"
STAGE=".build/release-stage"
APP_SRC="$(tb_bundle_dir release)/$APP_NAME.app"

step() { echo; echo "── $* ─────────────────────────────────────────"; }
fail() { echo "✗ $*" >&2; exit 1; }

# Stop here when sourced for its functions.
#
# scripts/test-release-tag-verification.sh drives `verify_release_tag` and
# `ensure_release_tag` against a stubbed `github_api`, which is the only way to
# test the retry: the real failure needs GitHub to 404 a tag it has, for a few
# seconds, and nothing can arrange that on demand. One definition, tested and
# shipped, rather than a copy in a test that agrees with the bug.
if [ "${TB_RELEASE_LIB_ONLY:-0}" = "1" ]; then return 0; fi

TOOLING_COMMIT=$(git rev-parse HEAD)
TARGET="${TB_RELEASE_SOURCE_COMMIT:-$TOOLING_COMMIT}"
[[ "$TARGET" =~ ^[0-9a-f]{40}$ ]] \
  || fail "release source must be a full lowercase 40-character SHA"
if [ "$TARGET" != "$TOOLING_COMMIT" ]; then
  [ "${TB_PREBUILT_APP:-0}" = "1" ] \
    || fail "a recovered source commit requires a prebuilt source-stamped app"
  [ "${TB_SKIP_SOURCE_AUDIT:-0}" = "1" ] \
    || fail "a recovered source commit requires the credential-free source audit"
fi
SHORT_TARGET=$(git rev-parse --short=9 "$TARGET")
BUILD_NUMBER=$(git rev-list --count "$TARGET")
VERSION="${VERSION:-$RELEASE_SERIES.$BUILD_NUMBER}"
TAG="${TB_RELEASE_TAG:-v$VERSION-$SHORT_TARGET}"
RELEASE_ID=""
DMG_PATH=".build/TranquilityBase-$VERSION.dmg"
CHECKSUM_PATH=".build/TranquilityBase-$VERSION.sha256"
APP_NOTARY_ARCHIVE=".build/TranquilityBase-$VERSION-app.zip"
APP_NOTARY_RESULT_PATH=".build/TranquilityBase-$VERSION-app-notary-submission.json"
APP_NOTARY_LOG_PATH=".build/TranquilityBase-$VERSION-app-notarization.json"
DMG_NOTARY_RESULT_PATH=".build/TranquilityBase-$VERSION-dmg-notary-submission.json"
DMG_NOTARY_LOG_PATH=".build/TranquilityBase-$VERSION-dmg-notarization.json"

case "$VERSION" in
  *[!0-9.]*|.*|*..*|*.) fail "version must contain only dot-separated numbers: $VERSION" ;;
esac

step "release identity"
echo "→ source:  $TARGET"
echo "→ version: $VERSION (build $BUILD_NUMBER)"
echo "→ tag:     $TAG"

# A clean old merge is releasable after a newer merge has landed: every merge
# gets an artifact, not only the newest one. A feature-branch commit is not.
git fetch -q origin
git merge-base --is-ancestor "$TOOLING_COMMIT" origin/main \
  || fail "$TOOLING_COMMIT contains release tooling outside origin/main"
git merge-base --is-ancestor "$TARGET" origin/main \
  || fail "$TARGET is not contained in origin/main — refusing a branch release"
[ -z "$(git status --porcelain)" ] || {
  git status --short >&2
  fail "working tree is dirty — refusing to release bytes not named by $TARGET"
}

if [ "$DRY_RUN" -eq 0 ]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

  # Rerunning a completed release must be read-only. Secure timestamps make a
  # rebuild byte-different even at the same source commit; replacing a public
  # asset would destroy the artifact the release originally named.
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    RELEASE_ID=$(release_database_id)
    [ -n "$RELEASE_ID" ] || fail "existing release $TAG has no database id"
    IS_DRAFT=$(github_api "repos/$REPO/releases/$RELEASE_ID" --jq .draft)
    if [ "$IS_DRAFT" = "false" ]; then
      IS_IMMUTABLE=$(github_api "repos/$REPO/releases/$RELEASE_ID" --jq .immutable)
      [ "$IS_IMMUTABLE" = "true" ] \
        || fail "published release $TAG is not immutable"
      verify_release_tag
      step "auditing already-published release"
      EXISTING_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tb-existing-release.XXXXXX")
      trap 'rm -rf "$EXISTING_DIR"' EXIT INT TERM
      gh release download "$TAG" --repo "$REPO" --dir "$EXISTING_DIR" \
        --pattern "TranquilityBase-$VERSION.dmg"
      gh release download "$TAG" --repo "$REPO" --dir "$EXISTING_DIR" \
        --pattern "TranquilityBase-$VERSION.sha256"
      (cd "$EXISTING_DIR" && shasum -a 256 -c "TranquilityBase-$VERSION.sha256")
      scripts/audit-release.sh "$EXISTING_DIR/TranquilityBase-$VERSION.dmg" \
        "$VERSION" "$BUILD_NUMBER" "$TARGET"
      echo "✓ $TAG was already public and still passes its artifact audit"
      exit 0
    fi
    DRAFT_TARGET=$(github_api "repos/$REPO/releases/$RELEASE_ID" --jq .target_commitish)
    [ "$DRAFT_TARGET" = "$TARGET" ] \
      || fail "existing draft $TAG targets $DRAFT_TARGET, not $TARGET"
    echo "→ an unpublished draft exists; its asset will be replaced after a clean rebuild"
  fi
fi

# This is the source gate again, on the exact merge commit—not an assumption
# that the pull request's synthetic merge ref was identical. Live third-party
# harness drills need authenticated Claude/Codex installations and remain local
# deploy evidence; the hermetic tmux drill remains a hard gate here.
if [ "${TB_SKIP_SOURCE_AUDIT:-0}" = "1" ]; then
  echo "→ exact-source audit completed in the credential-free build job"
else
  step "source audit"
  TB_SKIP_LIVE_HARNESS_DRILLS=1 scripts/preflight.sh "$TARGET^"
fi

step "building $VERSION (release, universal)"
EXPECTED_IDENTITY="Developer ID Application: Robert Nowell ($TEAM_ID)"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -F "\"$EXPECTED_IDENTITY\"" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
[ "$IDENTITY" = "$EXPECTED_IDENTITY" ] \
  || fail "expected signing identity is unavailable: $EXPECTED_IDENTITY"
echo "→ identity: $IDENTITY"

NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
[ -z "$NOTARY_KEYCHAIN" ] || NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1 \
  || fail "no usable notarization profile '$NOTARY_PROFILE'"

notarize_and_capture() {
  local artifact="$1" result_path="$2" log_path="$3" label="$4"
  local status_path="$result_path.status"
  rm -f "$result_path" "$status_path" "$log_path"
  if ! xcrun notarytool submit "$artifact" \
    "${NOTARY_ARGS[@]}" --output-format json >"$result_path"; then
    [ ! -s "$result_path" ] || cat "$result_path"
    fail "could not submit the $label to Apple's notary service"
  fi
  cat "$result_path"
  local submission_id submission_status
  submission_id=$(/usr/bin/plutil -extract id raw "$result_path" 2>/dev/null || true)
  [ -n "$submission_id" ] || fail "notarytool returned no submission id for the $label"

  # Poll with independent short requests instead of one long --wait HTTP
  # connection. Apple keeps processing through a client deadline; retaining
  # the submission id makes transient network failures resumable and legible.
  submission_status="In Progress"
  for _ in $(seq 1 90); do
    if xcrun notarytool info "$submission_id" \
      "${NOTARY_ARGS[@]}" --output-format json >"$status_path" 2>/dev/null; then
      submission_status=$(/usr/bin/plutil -extract status raw "$status_path" 2>/dev/null || true)
      case "$submission_status" in
        Accepted|Invalid|Rejected) break ;;
      esac
    fi
    sleep 20
  done
  [ ! -s "$status_path" ] || cp "$status_path" "$result_path"
  rm -f "$status_path"
  [ "$submission_status" = "Accepted" ] \
    || fail "Apple notarization status for the $label is $submission_status, not Accepted"
  xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" "$log_path" \
    || fail "could not retrieve Apple's $label notarization log"
  scripts/notary-log-is-clean.sh "$log_path" || {
    cat "$log_path"
    fail "Apple accepted the $label but its notarization log contains issues"
  }
  echo "→ clean $label notarization log: $log_path"
}

if [ "${TB_PREBUILT_APP:-0}" = "1" ]; then
  [ -d "$APP_SRC" ] || fail "signing job received no app at $APP_SRC"
  PREBUILT_INFO="$APP_SRC/Contents/Info.plist"
  read_prebuilt() { /usr/libexec/PlistBuddy -c "Print :$1" "$PREBUILT_INFO" 2>/dev/null || true; }
  [ "$(read_prebuilt CFBundleShortVersionString)" = "$VERSION" ] \
    || fail "prebuilt app has the wrong version"
  [ "$(read_prebuilt CFBundleVersion)" = "$BUILD_NUMBER" ] \
    || fail "prebuilt app has the wrong build number"
  [ "$(read_prebuilt TBSourceCommit)" = "$TARGET" ] \
    || fail "prebuilt app was not assembled from $TARGET"
  codesign --verify --deep --strict --verbose=2 "$APP_SRC" \
    || fail "prebuilt app's transfer signature is invalid"
  echo "→ verified source-stamped app from credential-free build job"
else
  TB_VERSION="$VERSION" TB_BUILD="$BUILD_NUMBER" TB_SOURCE_COMMIT="$TARGET" \
    VOICE_DISPATCH_SIGN_IDENTITY="$IDENTITY" \
    ./scripts/bundle.sh release >/dev/null
  [ -d "$APP_SRC" ] || fail "bundle.sh produced no app at $APP_SRC"
fi

step "signing with a secure timestamp"
# The build job assembles the app with a throwaway signature, so the embedded
# Sparkle helpers arrive here carrying it. They are re-signed with the real
# Developer ID before the outer bundle is sealed: a Developer ID signature
# wrapped around a foreign-signed helper does not notarize, and the failure
# would otherwise surface an hour into CI at the notarization step.
sparkle_sign "$APP_SRC" "$IDENTITY" --timestamp
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  --entitlements TranquilityBase.entitlements \
  --options runtime --timestamp "$APP_SRC"
codesign --verify --deep --strict --verbose=2 "$APP_SRC"
SIGN_INFO=$(codesign -dv --verbose=4 "$APP_SRC" 2>&1)
case "$SIGN_INFO" in *"Timestamp="*) ;; *) fail "app signature has no secure timestamp" ;; esac
echo "$SIGN_INFO" | grep -E "^(Authority|TeamIdentifier|Timestamp)=" || true

step "notarizing and stapling the installable app"
rm -f "$APP_NOTARY_ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP_SRC" "$APP_NOTARY_ARCHIVE"
notarize_and_capture "$APP_NOTARY_ARCHIVE" \
  "$APP_NOTARY_RESULT_PATH" "$APP_NOTARY_LOG_PATH" "app"
xcrun stapler staple "$APP_SRC"
xcrun stapler validate "$APP_SRC"
/usr/bin/syspolicy_check distribution "$APP_SRC" >/dev/null \
  || fail "stapled app does not pass syspolicy_check distribution"
rm -f "$APP_NOTARY_ARCHIVE"

step "building the disk image"
rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"
cp -R "$APP_SRC" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
echo "→ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

step "notarizing"
rm -f "$CHECKSUM_PATH"
notarize_and_capture "$DMG_PATH" \
  "$DMG_NOTARY_RESULT_PATH" "$DMG_NOTARY_LOG_PATH" "DMG"
xcrun stapler staple "$DMG_PATH"

step "local artifact audit"
scripts/audit-release.sh "$DMG_PATH" "$VERSION" "$BUILD_NUMBER" "$TARGET"
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
printf '%s  %s\n' "$DMG_SHA256" "$(basename "$DMG_PATH")" >"$CHECKSUM_PATH"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "✓ dry run complete — audited, notarized and stapled; nothing published"
  echo "  $DMG_PATH"
  exit 0
fi

step "uploading an unpublished draft"
SUBJECT=$(git log -1 --format=%s "$TARGET")
NOTES="Automated release of main at $TARGET.

$SUBJECT

Requires macOS 14 or later on Apple silicon or Intel, plus a supported coding-agent CLI and tmux. Download the DMG, drag Tranquility Base to Applications, eject the disk image, and open the installed app."

# GitHub refuses to create a release directly against an older commit when
# that commit differs in .github/workflows: GITHUB_TOKEN can never receive the
# separate workflows permission. Creating and verifying the ordinary Git ref
# first lets the release name an existing tag using only contents:write.
ensure_release_tag

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" "$CHECKSUM_PATH" \
    "$APP_NOTARY_LOG_PATH" "$DMG_NOTARY_LOG_PATH" \
    --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "Tranquility Base $VERSION" \
    --notes "$NOTES"
else
  gh release create "$TAG" "$DMG_PATH" "$CHECKSUM_PATH" \
    "$APP_NOTARY_LOG_PATH" "$DMG_NOTARY_LOG_PATH" --repo "$REPO" \
    --verify-tag --title "Tranquility Base $VERSION" \
    --notes "$NOTES" --draft --latest=false
fi
[ -n "$RELEASE_ID" ] || RELEASE_ID=$(release_database_id)
[ -n "$RELEASE_ID" ] || fail "draft release $TAG has no database id"
verify_release_tag

# The public object, not the upload command, gets the final word. The draft
# stays private on any failure below and can be safely replaced by a rerun.
step "re-downloading the uploaded bytes"
DOWNLOAD_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tb-published-audit.XXXXXX")
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT INT TERM
gh release download "$TAG" --repo "$REPO" --dir "$DOWNLOAD_DIR" \
  --pattern "$(basename "$DMG_PATH")"
gh release download "$TAG" --repo "$REPO" --dir "$DOWNLOAD_DIR" \
  --pattern "$(basename "$CHECKSUM_PATH")"
gh release download "$TAG" --repo "$REPO" --dir "$DOWNLOAD_DIR" \
  --pattern "$(basename "$APP_NOTARY_LOG_PATH")"
gh release download "$TAG" --repo "$REPO" --dir "$DOWNLOAD_DIR" \
  --pattern "$(basename "$DMG_NOTARY_LOG_PATH")"
DOWNLOADED="$DOWNLOAD_DIR/$(basename "$DMG_PATH")"
cmp -s "$DMG_PATH" "$DOWNLOADED" || fail "downloaded asset differs from the audited upload"
cmp -s "$CHECKSUM_PATH" "$DOWNLOAD_DIR/$(basename "$CHECKSUM_PATH")" \
  || fail "downloaded checksum differs from the uploaded checksum"
cmp -s "$APP_NOTARY_LOG_PATH" "$DOWNLOAD_DIR/$(basename "$APP_NOTARY_LOG_PATH")" \
  || fail "downloaded app notarization log differs from Apple's retrieved log"
cmp -s "$DMG_NOTARY_LOG_PATH" "$DOWNLOAD_DIR/$(basename "$DMG_NOTARY_LOG_PATH")" \
  || fail "downloaded DMG notarization log differs from Apple's retrieved log"
(cd "$DOWNLOAD_DIR" && shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")
REMOTE_DIGEST=$(github_api "repos/$REPO/releases/$RELEASE_ID" \
  --jq ".assets[] | select(.name == \"$(basename "$DMG_PATH")\") | .digest")
[ "$REMOTE_DIGEST" = "sha256:$DMG_SHA256" ] \
  || fail "GitHub asset digest $REMOTE_DIGEST differs from sha256:$DMG_SHA256"
scripts/audit-release.sh "$DOWNLOADED" "$VERSION" "$BUILD_NUMBER" "$TARGET"

step "publishing"
git fetch -q origin main
if [ "$(git rev-parse origin/main)" = "$TARGET" ]; then
  gh release edit "$TAG" --repo "$REPO" --draft=false --latest
else
  # An older merge can finish after a newer one. Publish it, but never let it
  # steal the Latest badge from the actual tip of main.
  gh release edit "$TAG" --repo "$REPO" --draft=false --latest=false
fi
IS_IMMUTABLE=""
for _ in 1 2 3 4 5; do
  IS_IMMUTABLE=$(github_api "repos/$REPO/releases/$RELEASE_ID" \
    --jq .immutable 2>/dev/null || true)
  [ "$IS_IMMUTABLE" != "true" ] || break
  sleep 2
done
if [ "$IS_IMMUTABLE" != "true" ]; then
  # GITHUB_TOKEN deliberately has no repository-administration scope, so it
  # cannot read the setting before publication. If an administrator disabled
  # immutability after setup, retract the still-mutable release immediately.
  gh release edit "$TAG" --repo "$REPO" --draft --latest=false \
    >/dev/null 2>&1 || true
  fail "GitHub published $TAG without making it immutable; returned it to draft"
fi

# The bytes are public, immutable and audited. Only now does the feed say so.
# Deliberately last, and deliberately allowed to fail on its own: if this step
# breaks, installed copies stay on the previous advertised build, which is a
# delayed update rather than a broken one.
step "advertising the release"
scripts/publish-appcast.sh "$DOWNLOADED" "$VERSION" "$BUILD_NUMBER" "$TAG"

echo
echo "✓ released $TAG from $TARGET"
echo "  https://github.com/$REPO/releases/tag/$TAG"
