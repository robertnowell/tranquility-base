# Diagnosing a capture

A blank transcript alone does not show whether the person spoke. Read the
provider observations and the input evidence separately. Signal amplitude,
audio duration and buffer counts show what reached the capture pipeline;
they do not identify human speech.

## Join and order

`capture_id` is an installation-salted hash of the recording's random ID.
It joins `capture_started`, `capture_audio_closed`, streaming and recovery
`transcription_attempt` events, `transcription`, processing completion and
application delivery outcomes. A retry keeps its capture ID but gets its own
`attempt_id`. The raw capture ID is kept locally with the durable utterance;
remote events and failure attachments contain only the hash.
Saved-audio retries update the latest diagnostic outcome and emit a final
`transcription` event with `trigger=manual_retry` or `trigger=retry_failed`.
Older recordings without a capture ID remain uncorrelated rather than borrowing
the ID of an unrelated active capture.

Each accepted product event also contains `event_process_id`, a monotonically
increasing `event_sequence` within that process, and `source_time_ms`.
PostHog receives the original event timestamp, including events buffered before
SDK startup. Once ingestion has settled, sequence gaps identify missing
accepted events between received records. They do not prove a missing tail,
prove delivery after a crash, or replace an acknowledgement protocol.

`capture_audio_closed` records audio bytes/duration, microphone-open duration,
delivered/retained buffer counts, peak level, and whether the write-ahead file
closed successfully. `capture_refused` distinguishes `too_short` from
`below_signal_threshold`; neither is evidence that a spoken message was lost.
`capture_processing_finished` says whether the result still belonged to the
current capture generation or was superseded. A transcription result and a
successful delivery are different events.

## Provider evidence

A `transcription_attempt` records provider, phase, configured state, attempt
number, outcome and a bounded error code. Recovery duration and streaming
finish-wait duration have separate fields. Streaming records bytes fed and
maximum partial/final character counts, never the words themselves. A received
partial is evidence that a recognizer found text, not independent ground truth.

File-transcription requests record the provider's request ID, so its server
record can be inspected directly. HTTP errors preserve both stage and status;
an unauthorized poll now exits immediately rather than being treated as an
unfinished job for ten minutes. Temporary poll errors (408, 429 and 5xx) retain
the existing job and record `transcription_poll` observations instead of
immediately re-uploading the recording. Repeated identical poll errors are
coalesced until a successful poll or different status arrives.
Other detailed local error strings remain local
because they can contain transcript fragments, URLs or credentials.

A live silent-WAV probe on 9 September also returned a terminal file-job
error saying `language_detection cannot be performed on files with no spoken audio.`
That specific provider observation maps to `no_speech_detected` without retrying
the same provider. Other language-detection errors remain service failures.

The final `transcription.outcome` is:

- `completed`: usable nonempty text was returned.
- `no_speech_detected`: all executed recovery providers reported no speech,
  no recovery attempt was cancelled, and no streaming text was observed.
  This is their observation, not a claim about what the person did. The UI
  returns to the grid with a notice and keeps the audio without reporting an
  error card.
- `provider_error`: a configuration/service/transport error prevents classifying
  the result as a clean no-speech observation. This does not prove lost speech.
- `cancelled`: the work was cancelled.
- `unresolved`: there is insufficient evidence to classify the empty result,
  including streaming text followed by empty recovery results. This keeps the
  visible failure path and audio; it cannot quietly dismiss recognized speech.

Older records labelled `failed` cannot be reclassified from their empty output.
Do not count them as confirmed lost spoken messages. An existing retryable
utterance status is retained internally; `transcriptionOutcome` persists the
more precise observation without discarding the audio or changing recovery.

The default provider order is unchanged: the live stream is tried first; file
recovery tries the configured cloud providers and then on-device speech.

## Release diagnostics

The build artifact contains both the app and its matching dSYM. Every architecture's
UUID must match. The signing job installs `sentry-cli` and consumes the
`SENTRY_AUTH_TOKEN` release-environment secret. Publishing requires a successful
`debug-files upload --wait`, so a missing token, missing symbols or failed upload
stops the release. Symbols name code locations; they do not contain user audio.

These changes improve future records. They cannot reconstruct missing provider
reasons or supply the matching symbols for a historical binary rebuilt differently.

## Verification

`scripts/test.sh` runs both test frameworks. The transcription diagnostics tests
cover silence versus service failure, cancellation, conflicting streaming text,
fallback after an empty response, durable audio/diagnosis, saved-audio retries,
privacy and concurrent correlation. Transport fixtures exercise empty completion,
rejected creation, unauthorized/missing-job polling, and recovery from temporary
poll errors without creating a second job. These fixtures make no network calls.
`scripts/test-debug-symbols.sh` checks mismatches, missing inputs and upload failure.
The `--selftest-capture-diagnostics` executable mode runs the no-speech UI drill
without registering the normal app delegate, hotkey, microphone or instance lock;
use isolated `VOICE_DISPATCH_SUPPORT_DIR` and `TB_AGENTS_ROOT` directories.
