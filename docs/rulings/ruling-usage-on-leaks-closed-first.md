# Usage telemetry is on, and the leaks close first

Ruled by Robert, 24 Oct 2026: "turn on usage and build the five events, let's
close the leaks first from telemetry, no new first run notice for now."

1. **Usage is on by default.** The Diagnostics toggle still turns usage and
   failure reports off together. Turning it on again now clears an opt-out
   the PostHog SDK persisted on an earlier launch (TelemetryConsent). Before
   this, a Mac that once turned usage off stayed silent after a relaunch,
   with the toggle showing on.
2. **No first-run notice for now.** The README states what is sent and what
   is never sent. A notice is a later decision.
3. **Leaks close before new events.** The leak pass ships first, as its own
   pull request. New events (page_published, session_seen, turn_completed,
   app_alive, hub_opened) follow in a second one.
4. **PostHog IP capture is off.** Robert set this on the project himself on
   24 Oct. It is a project setting, not code.

## What the leak pass closed

- `notice_flashed` sends the notice's phrase only, at most three words before
  the first colon. It sent the whole card, which names tabs and folders.
- A `failure` of kind `notice` leaves the Mac as its phrase, to PostHog and to
  Sentry. The local `failures.jsonl` keeps the whole card.
- Two failure reasons named a user's thing: a launch's tab label and a page's
  slug. Both now name neither.
- `launch_unregistered` sends the screen's line count and which known prompt
  it matched, never the screen. `launch_question_shown` sends the prompt's
  kind, never its text, which named the directory a trust prompt asked about.
  That supersedes the 7 Sep allowance for this one field.

## What still sends prose, and why

These carry the app's, the system's or an agent's own error text, scrubbed
(home path, emails, keys) and cut to 240 characters, under the 7 Sep ruling
that only the person's words are privileged. They are listed so the next pass
can judge each one:

- `failure.reason` for every kind but `notice` (system and provider errors).
- `update_check_result.detail` and `.chain`: the updater's error and its chain.
- `reply_outcome.detail` (dispatch failed), `announcement.detail`,
  `hub_written.detail`: enum and error descriptions.
- `transcription.attempts_detail`: "provider: error" lines, never the
  transcript, which exists only on the success branch.
- `hooks_state.reason`, `skills_state.reason`: why a repair did not apply.
- `claude_health.detail`: the health check's summary and evidence. Evidence
  can include a path under the home directory, scrubbed to `~`.
- `go_to_agent.detail`, `agent_ended.detail`: AppleScript and resume errors.
- `api_key_set.detail`: the key sheet's verdict line.
- `agent_lamp_changed.detail`: the first sentence of the agent's own error.
  This is an agent's words and can quote anything the agent printed. It is
  the most likely of these to carry user content, and is the first candidate
  for a vocabulary instead of prose.
- `app_launched.permissions_missing_names`: the app's names for permissions.
