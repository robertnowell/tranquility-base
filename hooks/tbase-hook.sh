#!/bin/bash
export TB_HOOK_PATH="${BASH_SOURCE[0]:-$0}"
#
# voice-dispatch hook. Runs on Claude Code Stop / Notification, and on the
# Codex events that mean the same things (Stop / PermissionRequest).
#
# ONE script, both harnesses, because the payloads are near-identical: Codex's
# hooks system was modelled on Claude Code's and ships session_id,
# transcript_path, cwd, hook_event_name, permission_mode and
# last_assistant_message under those exact names. The whole semantic gap is one
# field rename and one event rename, and both are normalised below rather than
# taught to every reader downstream. Measured live against codex-cli 0.150.1 on
# 28 Aug, in a real TUI pane launched the way SessionLauncher launches one.
#
# Contract, in order of importance:
#   1. NEVER block. This runs inside a real Claude Code turn.
#   2. NEVER fail. Always exit 0, whatever happens.
#   3. Append one JSON line to the spool. No SQLite, no sockets, no network.
#
# The spool is a write-ahead log: an append-only file the app drains into SQLite.
# A single small write(2) with O_APPEND is atomic, so concurrent sessions cannot
# interleave lines. This is why the hook holds no locks and cannot contend with
# the dozens of sessions that may finish a turn at the same moment.
#
# Install: add to ~/.claude/settings.json under hooks.Stop and hooks.Notification.

set -u

# The same override the app's own code honours (QueueStore.supportDirectory).
# Without it, a drill that runs a real session against a scratch store still
# had that session's hook write to the REAL one: the live-TUI drill put 2,255
# events from 239 fixture sessions into the user's queue by 30 Sep, and the
# hub mirror carried 236 of them into the hub as agents.
SUPPORT_DIR="${VOICE_DISPATCH_SUPPORT_DIR:-$HOME/Library/Application Support/VoiceDispatch}"
SPOOL="$SUPPORT_DIR/spool.jsonl"

# Guard against the summarizer announcing its own output. The summarizer sets this
# on its subprocess; env vars propagate into hook subprocesses (verified).
if [ -n "${VOICE_LOOP_MARKER:-}" ]; then
  exit 0
fi

PAYLOAD=$(cat 2>/dev/null || true)
[ -z "$PAYLOAD" ] && exit 0

mkdir -p "$SUPPORT_DIR" 2>/dev/null || exit 0

# Headless runs — `claude -p` from launchd, cron, or a script — have no controlling
# terminal. There is no tab to open and no session to answer, so an announcement
# about one is pure noise: you cannot act on it and it competes with sessions you
# can. The parent process's tty is `??` exactly in that case.
# Record the controlling terminal; do not act on it here.
#
# Headless runs (claude -p from launchd or cron) have no tty and are not worth
# announcing: no tab to open, no session to answer. But deciding that HERE means
# deciding it in the one place where being wrong is unrecoverable, and two attempts
# were already wrong. $PPID is not reliably claude, so real turns from real
# terminals were dropped silently. Walking the ancestry crosses the session
# boundary, so headless runs looked interactive.
#
# So the hook records what it sees and the app decides. A row that should not have
# been kept costs one filtered query; a row that should have been kept and was
# thrown away at the source is gone, with no trace that it ever existed.
OWN_TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
export VOICE_DISPATCH_TTY="$OWN_TTY"

python3 - "$SPOOL" "$PAYLOAD" <<'PY' 2>/dev/null || true
import json, os, sys, time, uuid

spool_path, raw = sys.argv[1], sys.argv[2]

try:
    p = json.loads(raw)
except Exception:
    sys.exit(0)

event = p.get("hook_event_name")

# Codex's name for "this session is asking you for permission" is its own
# PermissionRequest EVENT; Claude Code's is a Notification whose matcher is
# permission_prompt. Same fact, two vocabularies, so it is renamed HERE and
# nowhere else. Everything downstream (HookEventKind, waitingSessions, the
# announcer, the ladder) keeps one vocabulary and never learns there was a
# second harness. Doing it in the Swift models instead would mean a new
# HookEventKind case, and SpoolRecord.toEvent maps an unknown kind to .stop,
# which would announce a permission request as a finished turn.
if event == "PermissionRequest":
    event = "Notification"
    p["matcher"] = "permission_prompt"

# Only these drive the loop. SubagentStop shares a prompt_id with its parent
# Stop and would double-announce a single turn, so it is dropped at the source.
# UserPromptSubmit is not announced. It is recorded because it is the signal
# that you answered that session yourself, which retires whatever was waiting
# to be read out of it.
if event not in ("Stop", "Notification", "UserPromptSubmit"):
    sys.exit(0)

# idle_prompt fires when you haven't replied for a while. It carries no content —
# no assistant message, nothing to summarize — so announcing it produces a line
# made entirely of the folder name. It is also a nag about a turn whose Stop we
# already announced. Dropped at the source.
matcher = p.get("matcher") or p.get("notification_type")
if event == "Notification" and matcher == "idle_prompt":
    sys.exit(0)

msg = p.get("last_assistant_message")
if isinstance(msg, str) and len(msg) > 4000:
    # Keep spool lines small so appends stay atomic. The summarizer only needs
    # the gist, and the full text remains in the session transcript.
    msg = msg[:4000]

record = {
    "id": str(uuid.uuid4()),
    "createdAtMs": int(time.time() * 1000),
    "hookEvent": event,
    "sessionId": p.get("session_id") or "",
    # Claude Code calls it prompt_id, Codex calls it turn_id, and both mean
    # "which turn is this". The dedupe index is (sessionId, promptId), so the
    # alias is what makes a Codex turn dedupe at all rather than every event
    # looking like a new one.
    "promptId": p.get("prompt_id") or p.get("turn_id"),
    "cwd": p.get("cwd"),
    "transcriptPath": p.get("transcript_path"),
    "lastAssistantMessage": msg,
    "notificationMatcher": p.get("matcher") or p.get("notification_type"),
    "tty": os.environ.get("VOICE_DISPATCH_TTY") or None,
}

if not record["sessionId"]:
    sys.exit(0)

# A RUNNING SESSION GETS NEW RULES AT ITS NEXT PROMPT, IN ANY HARNESS.
#
# Measured 26 Sep: every old-style page came from a session started before a
# rule changed; on 30 Sep a MacBook session started 24 Sep was still following
# August's rules. SessionStart text reaches a session once, so on each prompt
# this compares the rules version the session was given (recorded per session
# by visual-output-hook.sh) with the current one, and when they differ hands it
# the whole current text, from the same hook, once per change.
#
# This replaces a transcript grep for one sentence ("Artifacts are not
# boxes"): a rule change that kept that sentence never arrived, and Codex's
# events carry no transcript to grep. A per-session record works for both.
# The hub lookup is skipped here so the refresh fits the hook's 5 s budget.
if event == "UserPromptSubmit":
    prompt_context = []
    try:
        import subprocess
        hook_path = os.environ.get("TB_HOOK_PATH") or sys.argv[0] or ""
        if os.path.islink(hook_path):
            hook_path = os.path.realpath(hook_path)
        vo = os.path.join(os.path.dirname(os.path.abspath(hook_path)), "visual-output-hook.sh")
        sid = record["sessionId"]
        if os.path.exists(vo) and all(c in "0123456789abcdef-" for c in sid.lower()) and len(sid) <= 64:
            env = dict(os.environ, TB_RULES_VERSION_ONLY="1")
            current = subprocess.run(["/bin/bash", vo], input="", env=env, capture_output=True,
                                     text=True, timeout=3).stdout.strip()
            seen_path = os.path.expanduser(
                "~/Library/Application Support/VoiceDispatch/rules/seen/" + sid)
            try:
                with open(seen_path) as fh:
                    seen = fh.read().strip()
            except Exception:
                seen = ""
            if current and seen != current:
                env = dict(os.environ, TB_SKIP_HUBLINES="1")
                env.pop("TB_RULES_VERSION_ONLY", None)
                out = subprocess.run(["/bin/bash", vo], env=env, capture_output=True, text=True, timeout=4,
                                     input=json.dumps({"session_id": sid, "hook_event_name": "SessionStart",
                                                       "source": "refresh"})).stdout
                ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
                prompt_context.append(
                        "The rules for pages have changed since this session was told them "
                        "(or it started before they were versioned). The current rules follow "
                        "and replace any earlier version.\n\n" + ctx)
    except Exception:
        pass

    # A PAGE THE HUB REFUSED IS NEWS FOR THE AGENT THAT WROTE IT (1 Oct 2026).
    # The app's mirror leaves a note per refused page; the agent hears it at
    # its next prompt, once, with the reason, so it can make the page fit.
    # Before this a 15.6 MB report was refused for two hours and its agent,
    # and the person pressing Open Report, learned nothing.
    try:
        sid = record["sessionId"]
        if all(c in "0123456789abcdef-" for c in sid.lower()) and len(sid) <= 64:
            support = os.environ.get("VOICE_DISPATCH_SUPPORT_DIR") or os.path.expanduser(
                "~/Library/Application Support/VoiceDispatch")
            rpath = os.path.join(support, "hub-refused", sid + ".json")
            if os.path.exists(rpath):
                with open(rpath) as fh:
                    notes = json.load(fh)
                fresh = {k: v for k, v in notes.items() if isinstance(v, dict) and not v.get("told")}
                if fresh:
                    lines = ["- %s (%s): %s" % (k, v.get("path", ""), v.get("reason", "refused")) for k, v in fresh.items()]
                    prompt_context.append(
                        "A PAGE YOU WROTE DID NOT REACH THE HUB, so the person pressing Open Report "
                        "sees a 'not on the hub yet' notice instead of your report:\n" + "\n".join(lines) +
                        "\nMake it fit: inline images are moved out automatically, so what is left is "
                        "the page's own HTML, scripts, fonts or data. Rewrite the file at the same path "
                        "and it is sent again on the next pass. Tell the person if you cannot.")
                    for k in fresh:
                        notes[k]["told"] = True
                    tmp = rpath + ".tmp"
                    with open(tmp, "w") as fh:
                        json.dump(notes, fh, sort_keys=True)
                    os.replace(tmp, rpath)
    except Exception:
        pass

    if prompt_context:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": "\n\n".join(prompt_context)}}))

line = json.dumps(record, ensure_ascii=True) + "\n"

# O_APPEND + a single write() keeps concurrent writers from interleaving.
fd = os.open(spool_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
try:
    os.write(fd, line.encode("utf-8"))
finally:
    os.close(fd)
PY

exit 0
