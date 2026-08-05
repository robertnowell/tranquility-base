# TTS-summary prompt replay harness

Offline tuning loop for the voice-dispatch summarizer prompt
(`Sources/VoiceDispatchCore/Summarizer.swift`, `AnthropicSummaryProvider`).
Replays REAL historical summarizer inputs through candidate prompts and
compares outputs mechanically, so a prompt rewrite (callsign-first, <15
words, exact parameters, REPORT/REQUEST typing) can be tuned against
history before shipping.

Python 3 stdlib only. Nothing here touches `Sources/` or the live app data
(reads only).

## Data sources (discovered)

| What | Where |
|---|---|
| Model-call log | `~/Library/Application Support/VoiceDispatch/model-calls.jsonl` (path from `ModelCallLog.swift`; one JSON line per Anthropic call: `{at, model, status, elapsedMs, system, user, response}` — full prompts and full response body, nothing truncated) |
| Event/utterance DB | `~/Library/Application Support/VoiceDispatch/queue.sqlite` (GRDB; tables `events` — hookEvent, sessionId, cwd, lastAssistantMessage, summaryText — and `utterances`, `session_cursor`, view `latest_per_session`) |
| Summarizer inputs | `SummaryRequest`: lastAssistantMessage, projectLabel, firstUserMessage (opening ask, framed as stale), gitBranch, hookEvent, notificationMatcher. cwd exists on the request but is NOT interpolated into the prompt and is not in the log. |

The corpus is built from the JSONL log, not the DB — the log records the
prompt exactly as the model received it. The DB's `events` table is useful
for joining cwd/sessionId later if needed (`summaryText` ≈ spoken line).

## Files

```
extract.py            log -> corpus.jsonl (one record per historical call)
replay.py             corpus + prompts/<name>.txt -> runs/<name>/<id>.txt via claude -p
compare.py            two output sets -> reports/<a>-vs-<b>.md
prompts/current.txt   the production prompt, captured verbatim from the log
corpus.jsonl          360 usable records (2026-08-02 .. 2026-08-05), all haiku-4.5, all HTTP 200
runs/<name>/          raw replay outputs (.txt) and failures (.error)
reports/              markdown side-by-side reports
```

## Usage

```sh
cd tools/replay

# 1. (Re)build the corpus from the live log
python3 extract.py

# 2. Write a candidate prompt
cp prompts/current.txt prompts/v2-callsign.txt   # then edit

# 3. Replay — start small, then scale up
python3 replay.py --prompt prompts/v2-callsign.txt --sample 10 --seed 7
python3 replay.py --prompt prompts/v2-callsign.txt --sample 50 --seed 7 --model sonnet

# 4. Compare against history, or against another candidate
python3 compare.py v2-callsign actual
python3 compare.py v2-callsign current --limit 20
```

`replay.py` flags: `--model` (default `haiku`), `--limit`, `--sample N --seed S`,
`--ids r0001 r0042`, `--timeout` (default 120 s). Runs are resumable —
existing `<id>.txt` files are skipped, so re-running the same command
retries only failures.

`compare.py` sides are run-dir names under `runs/`, or the literal `actual`
(historical production output from the corpus).

## Prompt template slots

Templates are the ENTIRE prompt (system + user scaffolding merged, since
`claude -p` takes a single prompt). Slots are literal tokens replaced with
`str.replace` — **not** `str.format` — so the JSON braces in the prompt body
are safe. Slots mirror what `AnthropicSummaryProvider.brief()` interpolates:

| Slot | Value |
|---|---|
| `{project_label}` | e.g. `promotions` |
| `{branch_block}` | `\nBranch: <branch>` or empty (carries its own newline) |
| `{notification_block}` | `\n\nTHIS SESSION IS BLOCKED AND WAITING ON THE USER (<matcher>)…` or empty |
| `{opening_block}` | `\n\nHow this session opened, HOURS AGO…:\n<ask>` or empty |
| `{last_assistant_message}` | the agent's final message this turn |
| `{branch}` / `{opening_ask}` | bare values, for prompts that phrase context their own way |

All 360 corpus records round-trip: rebuilding the user turn from the parsed
slots reproduces the logged prompt byte-for-byte.

## Mechanical checks (rubric preview)

Per record, on the *spoken* text (recap+proposal if the output is
brief-JSON, mirroring `SessionBrief.spokenText()`; otherwise the raw output
line — so a rewritten prompt may emit a bare spoken line instead of JSON):

- **DIGITS?** — speaks a number (digits or spelled zero…thousand) absent
  from the source message/opening ask. Grounding check.
- **CALLSIGN** — the first ~6 words contain the session name (project label
  or the output's own topic). Callsign-first check.
- **ASKS?** — ends with `?`. REQUEST-typing check.

Plus word counts and per-run averages in the report header.

## Known limitations

- Replay uses `claude -p` (with `--dangerously-skip-permissions`), while
  production calls the raw Anthropic API with a system/user split. The CLI
  wraps the prompt in its own system context, so absolute behavior can
  differ slightly; comparisons between two replayed prompts are apples-to-
  apples, comparisons against `actual` are directional.
- `--model haiku/sonnet` aliases resolve to the CLI's current defaults, not
  necessarily `claude-haiku-4-5-20251001` used in production history.
- The corpus only contains calls that reached the API: deterministic-
  fallback summaries and empty-notification short-circuits never hit the
  log.
- Sanitizer clamping (`SpokenTextSanitizer`, word budgets) runs AFTER the
  model in production and is not applied here — historical `actual_spoken`
  is pre-sanitizer too (reconstructed from the logged model reply), so both
  sides are unsanitized and comparable.
- The digit-grounding check is exact-match on canonical digit strings; it
  will false-positive on derived numbers ("two of the four" summed as
  "six") and false-negative on numbers that appear in URLs.

## Known gotcha: nested-session hang (fixed in replay.py)

`claude -p` inherits `CLAUDE*`/`ANTHROPIC*` env vars when run from inside a
Claude Code session (any agent-driven run), and hangs on startup — every call
times out at the limit. `replay.py` scrubs these unconditionally (`child_env()`)
and pins `--strict-mcp-config --mcp-config .empty-mcp.json` so startup is
seconds, not minutes. Real calls run ~45–80s on haiku with full-size inputs;
use `--timeout 240` for safety. Comparator usage: `python3 compare.py actual current`.

## Fast engine (recommended)

`--engine api` calls the Anthropic API directly — 2-4s/record vs 35-160s via the
CLI harness, and MORE production-faithful (the app itself calls the model directly,
not through `claude -p`). Launch with the key injected from the keychain:

    claude-secrets run --inject mirai_anthropic_api_key=ANTHROPIC_API_KEY -- \
      python3 replay.py --prompt prompts/vnext-a.txt --sample 50 --engine api --workers 8

A full 360-record sweep costs roughly a dollar or two in haiku tokens. The cli
engine remains the default for zero-setup/subscription-credit runs.
