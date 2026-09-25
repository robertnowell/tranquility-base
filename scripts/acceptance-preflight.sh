#!/bin/bash
# Is this machine actually a stranger?
#
# The managed-credits acceptance is only worth running as SOMEBODY ELSE. A
# dry run on 23 Sep found that it is very easy to believe you are a stranger
# and not be one: a fresh profile directory is not a fresh identity, because
# the things that carry identity on this Mac live OUTSIDE any profile.
#
#   - the hub device token in the login Keychain, service "voice-dispatch"
#   - the same token in ~/Library/Application Support/hq/token, which the app
#     adopts into the Keychain the first time it sees it
#   - the provider keys, which would let a "managed" run quietly spend on BYOK
#     and prove nothing about credits at all
#
# Without this, a run that looks clean exercises the owner's own account and
# reports a pass. That is the worst outcome available: not a failure, a false
# acceptance. So this refuses rather than warns, and it is a CHECK rather than
# a step in a document, because a step can be skipped and remembered wrongly.
#
# It needs no network and asserts no identity. A pristine machine simply has
# none of these, which is a stronger and simpler thing to check than asking
# who a token belongs to.
#
#   scripts/acceptance-preflight.sh              # refuse if this Mac is not clean
#   scripts/acceptance-preflight.sh --stash      # move what it finds aside first
#   scripts/acceptance-preflight.sh --restore D  # put a stash back afterwards

set -uo pipefail

SERVICE="voice-dispatch"
LEGACY="$HOME/Library/Application Support/hq/token"
SUPPORT="${VOICE_DISPATCH_SUPPORT_DIR:-$HOME/Library/Application Support/voice-dispatch}"
HQ_JSON="$HOME/.claude/hq.json"
STASH="$HOME/.tranquility-acceptance-stash/$(date -u +%Y%m%dT%H%M%SZ)"
IDENTITY_KEYS=(hub-token device-key)
PROVIDER_KEYS=(anthropic-api-key elevenlabs-api-key assemblyai-api-key openai-api-key)

stash=0
[[ "${1:-}" == "--stash" ]] && stash=1

# Putting it back matters as much as moving it aside: the stash holds this
# person's real provider keys and their Mac's hub token, and an acceptance run
# that ends by leaving them in a dated folder nobody remembers is a way to
# lose them.
if [[ "${1:-}" == "--restore" ]]; then
  from="${2:-}"
  [[ -d "$from" ]] || { echo "usage: $0 --restore <stash directory>"; exit 2; }
  for f in "$from"/*; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    case "$name" in
      hq-token) mkdir -p "$(dirname "$LEGACY")"; mv "$f" "$LEGACY"; echo "  restored $LEGACY" ;;
      support)  mv "$f" "$SUPPORT"; echo "  restored $SUPPORT" ;;
      *)        security add-generic-password -U -s "$SERVICE" -a "$name" -w "$(cat "$f")" \
                  && rm -f "$f" && echo "  restored keychain $name" ;;
    esac
  done
  rmdir "$from" 2>/dev/null && echo "  stash emptied"
  exit 0
fi

found=()
note() { printf '  %-46s %s\n' "$1" "$2"; }

echo "Looking for anything that would make this Mac somebody who is already known."
echo

for key in "${IDENTITY_KEYS[@]}" "${PROVIDER_KEYS[@]}"; do
  if security find-generic-password -s "$SERVICE" -a "$key" >/dev/null 2>&1; then
    found+=("keychain:$key")
    note "keychain $SERVICE / $key" "PRESENT"
    if (( stash )); then
      mkdir -p "$STASH"
      # Copied out before deleting, because this is somebody's real credential
      # and an acceptance run is not a reason to lose it.
      security find-generic-password -s "$SERVICE" -a "$key" -w > "$STASH/$key" 2>/dev/null \
        && security delete-generic-password -s "$SERVICE" -a "$key" >/dev/null 2>&1 \
        && note "  -> stashed to $STASH/$key" "moved aside"
    fi
  else
    note "keychain $SERVICE / $key" "absent"
  fi
done

if [[ -s "$LEGACY" ]]; then
  found+=("file:hq/token")
  note "$LEGACY" "PRESENT"
  if (( stash )); then
    mkdir -p "$STASH"; mv "$LEGACY" "$STASH/hq-token" && note "  -> stashed" "moved aside"
  fi
else
  note "~/Library/Application Support/hq/token" "absent"
fi

if [[ -e "$SUPPORT" ]]; then
  found+=("dir:support")
  note "$SUPPORT" "PRESENT"
  if (( stash )); then
    mkdir -p "$STASH"; mv "$SUPPORT" "$STASH/support" && note "  -> stashed" "moved aside"
  fi
else
  note "app support directory" "absent"
fi

# Not stashed, only reported: hq.json is this machine's pointer at a hub, and
# an acceptance run wants to see the app ask for one rather than find one.
[[ -e "$HQ_JSON" ]] && note "$HQ_JSON" "PRESENT (not moved; reported only)"

echo
if (( stash )); then
  echo "Stashed under $STASH"
  echo "Put it back with: $0 --restore $STASH"
  echo
fi

if (( ${#found[@]} && ! stash )); then
  echo "REFUSING: this Mac is already somebody. ${#found[@]} thing(s) found above."
  echo "A run from here would exercise that account and report a pass it did not earn."
  echo "Re-run with --stash to move them aside, or use a machine that has never seen this app."
  exit 1
fi

if (( stash )); then
  echo "Moved aside. Re-run without --stash to confirm nothing is left."
  exit 0
fi

echo "This Mac is a stranger. The acceptance run will be somebody new."
