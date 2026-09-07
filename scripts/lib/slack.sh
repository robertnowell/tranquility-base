# Post a message to one Slack channel, token from the Keychain via
# claude-secrets, text on stdin so quotes and newlines survive. Shared by
# the deploy path and the watchers; capture-health-alert.sh predates it and
# carries its own copy of the same idea.
#
#   printf 'hello' | tb_slack_post C0BR963MBJ9
#
# Never fails the caller: an alert that cannot be sent is logged to stderr
# and the deploy or the check goes on. The alternative, a deploy that fails
# because Slack was down, is the wrong thing to be loud about.
tb_slack_post() {
  local channel="$1" text secrets
  secrets="$HOME/.claude/plugins/cache/claude-secrets-marketplace/claude-secrets/1.0.0/bin/claude-secrets"
  text=$(cat)
  if [ ! -x "$secrets" ]; then
    echo "(Slack post skipped: claude-secrets not installed)" >&2
    return 0
  fi
  TEXT="$text" CHANNEL="$channel" "$secrets" run --inject SLACK_WRITE_TOKEN=TOK -- \
    python3 - <<'PY' >/dev/null 2>&1 || echo "(Slack post failed)" >&2
import json, os, urllib.request
payload = json.dumps({"channel": os.environ["CHANNEL"], "text": os.environ["TEXT"]}).encode()
req = urllib.request.Request("https://slack.com/api/chat.postMessage", data=payload,
    headers={"Authorization": "Bearer " + os.environ["TOK"],
             "Content-type": "application/json; charset=utf-8"})
ok = json.load(urllib.request.urlopen(req, timeout=10)).get("ok")
raise SystemExit(0 if ok else 1)
PY
}
