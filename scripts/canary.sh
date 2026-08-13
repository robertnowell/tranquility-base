#!/bin/bash
#
# Canary for the Claude Code contract (earned 12 Aug 2026, PR #32).
#
# Tiers 1-2 of the coupling ladder rot silently: the trust-prompt watcher's
# "started" sentinel ("? for shortcuts") had been dead for an unknown number
# of Claude Code releases before a human felt it as a 35-second beach ball.
# This drill makes that class of rot fail loudly at deploy time instead of
# silently at click time.
#
# What it asserts, over the SAME transport the app uses — Terminal via
# AppleScript, reading rendered tab contents. Deliberately not a pty scrape:
# a pty stream carries ANSI escapes that can split a literal mid-word, which
# the rendered screen the watcher actually reads never does.
#
#   1. `claude agents --json` still parses          (liveness backbone, tier 2)
#   2. a launch in an untrusted dir renders "Do you trust"   (watcher's accept)
#   3. after one Return, the tab renders "Claude"            (watcher's settle)
#
# A failure here does NOT mean the app build is bad. It means the installed
# Claude Code moved underneath SessionLauncher, and the sentinel strings or
# the agents JSON parsing need re-verifying by hand.
#
# Side effects, small and accepted: one Terminal window opens and closes
# (~10-20s), and ~/.claude.json gains a trust entry for a throwaway
# /tmp/tb-canary.* directory that is deleted immediately after.
#
# Skip in an emergency with TB_SKIP_CANARY=1 (relaunch.sh honours it).

set -euo pipefail

# Locate `claude` the way ClaudeAgentsCLI.resolveBinary does: known install
# locations first, then PATH. A GUI context is not a risk here (this runs from
# a terminal), but the same list keeps the canary honest about what the app
# will find.
resolve_claude() {
  local c
  for c in \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/claude" \
    /opt/homebrew/bin/claude \
    /usr/local/bin/claude \
    "$HOME/.bun/bin/claude" \
    "$HOME/.npm-global/bin/claude"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  command -v claude
}

CLAUDE_BIN=$(resolve_claude) || { echo "✗ canary: no claude binary found" >&2; exit 1; }
echo "→ canary: probing $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo 'version unknown'))"

# ── Probe 1: the liveness backbone still speaks JSON ─────────────────────────
if ! "$CLAUDE_BIN" agents --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "✗ canary: \`claude agents --json\` did not produce parseable JSON." >&2
  echo "  ClaudeAgentsCLI.sessions() will return nil for every caller — the grid," >&2
  echo "  launch registration and revival all degrade. Re-verify DispatchTransport." >&2
  exit 1
fi
echo "  ✓ claude agents --json parses"

# ── Probes 2+3: the watcher's two sentinels, end to end ──────────────────────
# Launch in a brand-new directory so the trust prompt MUST appear, answer it
# with the same bare-Return the watcher sends, and require the same "Claude"
# banner the watcher settles on. Same command shape the app launches.
TMPDIR_CANARY=$(mktemp -d /tmp/tb-canary.XXXXXX)
CMD="$CLAUDE_BIN --dangerously-skip-permissions"

# The probe lives in its own file: bash 3.2 cannot parse a heredoc inside
# command substitution, and the AppleScript is clearer standalone anyway.
VERDICT=$(osascript "$(dirname "$0")/lib/canary-probe.applescript" "$TMPDIR_CANARY" "$CMD" || true)

STATUS="${VERDICT%%|*}"
TTY_PATH="${VERDICT##*|}"

# Cleanup, regardless of verdict: kill whatever runs on the canary tty, close
# its window, drop the temp dir. Never leave a stray claude running.
if [ -n "$TTY_PATH" ] && [ "$TTY_PATH" != "$VERDICT" ]; then
  PIDS=$(ps -t "${TTY_PATH#/dev/}" -o pid= 2>/dev/null || true)
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
  sleep 1
  osascript - "$TTY_PATH" <<'OSA' >/dev/null 2>&1 || true
on run argv
  set theTTY to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if (tty of t) as text is theTTY then
          close w saving no
          return
        end if
      end repeat
    end repeat
  end tell
end run
OSA
fi
rm -rf "$TMPDIR_CANARY"

case "$STATUS" in
  PASS)
    echo "  ✓ trust prompt rendered ('trust this folder' / 'Do you trust'), Return accepted it"
    echo "  ✓ banner rendered ('Claude') — the watcher's settle sentinel holds"
    echo "→ canary: the Claude Code contract holds"
    ;;
  FAIL-TRUST)
    echo "✗ canary: launched in an untrusted dir and 'Do you trust' never rendered." >&2
    echo "  Either the trust prompt's wording changed or launches are broken." >&2
    echo "  SessionLauncher.acceptTrustPromptIfShown can no longer see the prompt." >&2
    exit 1
    ;;
  FAIL-BANNER)
    echo "✗ canary: trust accepted, but 'Claude' never rendered in the tab." >&2
    echo "  The watcher's settle sentinel is dead again — every launch will pay" >&2
    echo "  the full 30s watch (in the background, per #32, but still rot)." >&2
    exit 1
    ;;
  *)
    echo "✗ canary: AppleScript probe failed outright: $VERDICT" >&2
    echo "  Terminal automation permission is the usual suspect." >&2
    exit 1
    ;;
esac
