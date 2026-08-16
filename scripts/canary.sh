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
# Side effects: one Terminal window opens (~10-20s) and is LEFT OPEN as a dead
# tab — see the cleanup block for why closing it is not worth the hazard.
# Everything that costs something is swept: the probe session's processes, the
# temp directory, and the ~/.claude.json project entry Claude Code registers
# for the throwaway directory (see sweep_leftovers; it runs at start and end,
# so even a killed run leaves at most one entry, healed by the next run).
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

# ── Sweep this canary's own species ──────────────────────────────────────────
# Every probe launch makes Claude Code register a project entry for its
# throwaway /tmp/tb-canary.* directory in ~/.claude.json the moment the trust
# screen renders — even though the session is killed seconds later and never
# writes a transcript (verified 13 Aug: zero bytes under ~/.claude/projects,
# entries only in .claude.json). One ~400-byte entry per deploy is unbounded
# growth for zero benefit, and a bloated .claude.json slows every claude
# startup. So the canary cleans up after its own kind: at START, so a run
# killed mid-flight is healed by the next one, and again at the END, so a
# green run leaves the machine exactly as it found it.
#
# The rewrite is surgical and atomic: only keys matching the canary's own
# /tmp/tb-canary.* namespace are dropped, the previous file is kept at
# ~/.claude.json.tb-canary-bak, and the swap is os.replace. If the file is
# unreadable it is left strictly alone.
sweep_leftovers() {
  rm -rf /tmp/tb-canary.* /private/tmp/tb-canary.* 2>/dev/null || true
  python3 - <<'PY'
import json, os, shutil
p = os.path.expanduser('~/.claude.json')
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    raise SystemExit(0)  # unreadable or absent: never touch it
proj = d.get('projects')
if not isinstance(proj, dict):
    raise SystemExit(0)
doomed = [k for k in proj
          if k.startswith(('/tmp/tb-canary.', '/private/tmp/tb-canary.'))]
if not doomed:
    raise SystemExit(0)
shutil.copy2(p, p + '.tb-canary-bak')
for k in doomed:
    del proj[k]
tmp = p + '.tb-canary-tmp'
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.replace(tmp, p)
n = len(doomed)
print(f"  ⌂ swept {n} tb-canary project entr{'y' if n == 1 else 'ies'} from ~/.claude.json")
PY
}
sweep_leftovers

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

# Cleanup, regardless of verdict: kill whatever runs on the canary tty and
# drop the temp dir. Never leave a stray claude running.
#
# It does NOT close the Terminal window, deliberately (ruled 16 Aug). The
# window is a dead tab costing nothing; the stray PROCESS was always the only
# thing here worth cleaning up, and the tty is the right handle for that
# because a tty names a device with live processes on it.
#
# Closing the window needs a handle on the window, and there isn't one that
# holds up. A tty is recycled the instant a shell exits — four windows were
# measured claiming /dev/ttys007 at once, three dead canaries and one LIVE
# coding session — so the search-and-close this replaced could match somebody
# else's work. That is a real hazard traded for tidiness, and tidiness lost.
# Five other handles were tried and are recorded in docs/open-issues.md #17
# so nobody spends another morning on it.
#
# The windows persist at all because Terminal is configured that way:
# shellExitAction = 2 ("Don't close the window") on every profile here. The
# old cleanup was fighting a user preference from the outside. If they ever
# need to go, the safe mechanism is the inverse — give the canary its own
# Terminal profile set to close on exit and kill only the claude process, so
# the window closes ITSELF and nothing has to go hunting for it.
if [ -n "$TTY_PATH" ] && [ "$TTY_PATH" != "$VERDICT" ]; then
  PIDS=$(ps -t "${TTY_PATH#/dev/}" -o pid= 2>/dev/null || true)
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
fi
rm -rf "$TMPDIR_CANARY"
# Leave the machine as found: the probe session's .claude.json entry dies with
# the run that made it, on every verdict path.
sweep_leftovers

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
