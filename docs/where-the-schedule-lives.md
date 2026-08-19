# Where the capture-health schedule lives

`scripts/capture-health-alert.sh` runs on a schedule, and the schedule is not in
this repo — it is two launchd agents in `~/Library/LaunchAgents`. Written down
here because a job outside the tree is invisible to `git log`, and the next
person to wonder why Slack went quiet should not have to guess.

| Label | When | What it does |
|---|---|---|
| `com.tranquilitybase.capture-health` | every 2h (`StartInterval 7200`) | alerts `#alerts-tranquility-base` (`C0BR963MBJ9`) on a NEW dead press or unrouted launch |
| `com.tranquilitybase.capture-health-heartbeat` | Mondays 09:00 | posts the week's rates even when nothing is wrong |

    launchctl list | grep tranquilitybase                     # is it loaded
    launchctl kickstart -k gui/$UID/com.tranquilitybase.capture-health   # run it now
    launchctl bootout gui/$UID/com.tranquilitybase.capture-health        # stop it

**Not cron.** `crontab` hangs on this machine — macOS wants Full Disk Access for
`cron` and the install never returns. launchd is the supported path and needed
no permission grant, because the agent runs inside the user's own session.

**State and ledgers.** Today's already-alerted counts live in
`~/Library/Application Support/VoiceDispatch/capture-health.state` (beside the
log it reads, not in the repo, because it is machine state rather than source).
Delete it to make the next run re-alert — that is also how the alert path was
verified. Every run appends to `logs/capture-health.log`; launchd's own stdout
goes to `logs/capture-health-cron.log`. Both are gitignored.

**Credentials.** The Slack post uses `SLACK_WRITE_TOKEN` (the m3-tracker bot,
`chat:write`) out of the Keychain via `claude-secrets`. The bot was joined to
the channel with `conversations.join`; without that a post fails
`not_in_channel`. Keychain access from a launchd job is the part most likely to
break silently on a machine change, so it is what the kickstart above exercises.
