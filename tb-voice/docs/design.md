# The hands-free manager: design decisions

Voice AI Hackathon, AGI House SF, 19 September 2026. Track: voice-controlled software.

Tranquility Base turns a fleet of terminal coding agents into a voice loop, but it is
eyes-free, not hands-free: every action is a keyboard chord. This adds one always-listening
manager that drives the same fleet by voice, says nothing until it is addressed, and never
touches the app's own audio path. Every decision below states the alternatives considered
and why they lost. Dated entries are rulings; undated ones are defaults that a measurement
may overturn.

## 1. What it is, and is not

**It is** a second door onto the same targets. `tbase send`, `tbase new` and the
`tranquilitybase://` scheme already exist as scriptable doors into the running app. The
manager is a Pipecat bot that walks through them. The chords keep working.

**It is not** a Claude Code session. It does no engineering work itself; it routes, starts,
invites and summarises. It is a live agent, not a delegation agent.

**It is not** a realtime voice agent in the usual sense. Default mode is silence. The app's
own ruling ("the app is silent and the panel speaks") extends to the manager: it speaks only
for content the user asked for.

## 2. Silence by default: Jev decides, not the LLM

**Decision.** Every finished user turn is sent to TypeSafe's Jev (`jev-latest`, one `noul`
question: "is the speaker addressing Base directly, with a request or question meant for
it?"). Probability >= 0.5 means the turn runs the LLM; below, the turn is appended to the
context silently (`LLMMessagesAppendFrame(run_llm=False)`) so the manager still knows what
you were thinking about when you do address it.

**Measured (19 Sep, 12:50).** Six utterances, first try, no prompt tuning:

| utterance | p(addressed) | ms |
|---|---|---|
| "hmm so the auth bug might be in the middleware, or maybe the session store" | 0.03 | 426 |
| "why does this always break on Fridays" | 0.15 | 234 |
| "Base, what's everyone up to right now?" | 0.98 | 287 |
| "can you tell Kay to run the tests?" | 0.80 | 276 |
| "yeah Alex, I'll grab lunch after this, want anything?" | 0.03 | 388 |
| "the base config is fine, the problem is the reducer" | 0.06 | 434 |

Margin on both sides of 0.5 is wide; 21 output tokens each; $0.042 per million input tokens.

**Alternatives.**
- *Wake phrase only* (`WakePhraseUserTurnStartStrategy`): zero false positives but gates
  turn start, so unaddressed speech never enters context, and "can you tell Kay" without
  the name would be missed. Kept as the fallback if Jev misbehaves in the room.
- *The LLM decides* (MiniMax M2.7 classifier prompt): works, but costs a generative call
  per turn and returns prose it must be told not to speak. Jev is a decision model; it
  cannot generate, so it cannot accidentally talk.
- *Pipecat Flows*: a task-stage state machine, not a per-turn speak/stay-silent gate.

**Rule.** A rhetorical question is not a request. Thinking aloud is not a request. The
manager is named Base; a sentence using "base" for something else is not a request. Jev
holds these as criteria, not the prompt of a generative model.

## 3. Aggressive end-of-turn, patient response

**Decision.** Smart Turn v3 (bundled v3.2, CPU, local) with `SmartTurnParams(stop_secs=1.0)`
and `SileroVADAnalyzer(VADParams(stop_secs=0.2))`. Turns end fast; the gate decides whether
anything happens. Aggressive endpointing is safe *because* the default outcome of a turn is
silence: a turn cut mid-thought is appended as context and the next fragment joins it.

**Alternative.** The STT vendor's server-side turn detection with
`ExternalUserTurnStrategies`. Not chosen on day one: Smart Turn runs locally in 12 ms and
its knobs are documented in source.

**Held fragments.** A turn with no terminal punctuation waits 1.2 s for its continuation
(2.5 s when it names the manager, since that fragment will speak whatever follows). The
first version only held fragments over three words; "Tranquillity, can you" was three,
was judged alone, and spoke a status line before "tell us about your capabilities?" spoke
again (19 Sep, 17:26:12).

## 4. Brain: MiniMax M2.7 on General Compute

**Decision.** `OpenAILLMService(base_url="https://api.generalcompute.com/v1",
model="minimax-m2.7")` for tool selection and the one-sentence reply.

**Measured (19 Sep, 12:40), same tool-call request, same endpoint.**

| model | tool call | time to first token | tok/s after first | total |
|---|---|---|---|---|
| gemma-4-31B-it | clean | 0.81 s | 165 | 1.05 s |
| minimax-m2.7 | clean | 0.12 s | 383 | 0.34 s |

Gemma was the starter's default. Gemma 4 uses a custom tool-call syntax that needs a parser
and vLLM has an open bug (issue 39468) leaking delimiters into string arguments. General
Compute's wrapper returned clean arguments for both, so the parser is not the reason; the
7x time-to-first-token is. A manager that answers in conversation time needs the 0.12 s.

**Why not Claude or GPT.** The sponsors' endpoint is the point of the day, and M2.7 on
SambaNova silicon is the hardware story. Reasoning tokens (33 in the smoke test) are cheap
at this speed.

## 5. Ears and mouth: AssemblyAI and ElevenLabs (Gradium until 19 Sep, 17:50)

**Decision.** `AssemblyAISTTService` (Universal-Streaming, PCM 16 kHz) with `keyterms_prompt`
set at connect time to the manager's name, the sponsors, and every session's display name
read from `tbase targets --json`; `ElevenLabsTTSService` (`eleven_flash_v2_5`, pcm_24000;
the transport's `audio_out_sample_rate` is 24000). The manager's voice is River
(`SAz9YHcvj6GT2YYXdXww`), overridable with `ELEVENLABS_VOICE_ID`; sessions keep their own
ElevenLabs voices in the app, so the two are never the same voice.

**Why the swap.** Gradium started the day. Its transcripts read "Tranquillity", "Drinkody",
"Sambinova planning", "the speech to Texas", and the name gate can only match a name the
transcriber can spell. The first fix was a misspelling list in the Jev rules; the real fix
is a transcriber that takes a vocabulary. Neither AssemblyAI nor ElevenLabs is a sponsor;
the sponsors' parts (General Compute, Pipecat, Jev) are unchanged.

**What the swap touched.** `bot.py` (service construction, sample rate, key terms), `tts.py`
(base class), `run.sh` (which keys are injected), `pyproject.toml` (extras). Nothing in
`manager.py`'s decisions, the deep links, the app, or the events changed. Both keys were
already in the Keychain; AssemblyAI's streaming endpoint issued a token and ElevenLabs had
31M characters of quota, checked before the swap.

**Echo, removed at the source (same hour).** The aggregator's mute drops transcriptions
only while it is muted, and a streaming STT finalises late: at 17:26:42 Gradium delivered
fifteen seconds of the manager's own speech six seconds after it stopped, past the 0.6 s
tail, and Jev judged it as the developer asking to send a message. `EchoGate` now sits
between the mic and the STT and replaces the audio with zeros while the bot speaks, for a
beat after, and while the app speaks in a session's voice. Zeros, not dropped frames, so the
STT's own endpointing sees continuous audio.

**Alternative.** Route session briefs through the manager's TTS too (read
`tbase brief --json`, speak it in the manager's voice). Rejected for the demo: "each agent
has a voice" is the product; the fallback exists if the app is not running.

## 6. Driving the app: only the doors that exist

| tool | door | exists? |
|---|---|---|
| `send_message(session, text)` | `tbase send <id> <text>`; exit 0 confirmed, 2 not dispatched, 4 ambiguous | yes |
| `start_agent(dir, harness)` | `tbase new [dir] [--codex] --wait-live`; prints `registered: <id>` | yes |
| `invite_to_speak(session)` | `open tranquilitybase://hear?session=<id>` | yes |
| `list_agents()` / `whats_waiting()` | `tbase targets --json`, `tbase status --json` | new flag |
| `brief(session)` | `tbase brief <id> --json` (recap, proposal, ladder rungs; no model call) | new |
| `summarize_work()` | N briefs in one M2.7 call | new, bot-side |
| `teach(question)` | system prompt carries README and the capability list | prompt |

**Decision.** No command spool, no local HTTP server, no XPC. The app's rulings already
name the failure: two routes to one answer is how they start disagreeing. The deep link
"may speak but never record, send, or type" (DeepLink.swift), so speaking goes through the
URL and sending goes through `tbase`, exactly as the app already divides them.

**Swift changes, all additive.** `--json` on `targets`, `status`, `discover`; new
`tbase brief <id> --json`. `replay-log` at main.swift:1507 is the JSON precedent. Codable
structs live in Core so the shape is tested. Optional if time: a speak-only
`tranquilitybase://rung?session=&n=` verb plus one `DeepLinkTests` case.

## 7. Confirm before routing, unless the target was named

**Decision.** If the user names the session ("tell Kay"), `send_message` runs and the exit
code is read back in one clause. If not, the manager asks one question ("Kay or Sol?") and
waits. This mirrors the app's own 4 s undo on typed replies and LangChain's
notify / question / review vocabulary for ambient agents: question is the pattern here.

## 8. Transport

**Decision.** `SmallWebRTCTransport` with the dev playground page; a phone browser over a
hotspot is the honest hands-free story on stage. The maintainer's own macOS reference
(kwindla/macos-local-voice-agents) prefers it over `LocalAudioTransport`.

**Fallback.** `LocalAudioTransport` (`pipecat-ai[local]`, `brew install portaudio`, sample
rates set by hand) if venue wifi drops UDP.

**Audio contention.** TB's Recorder opens the mic only during an ⌥ hold; the bot holds it
through the browser. Both play to the speakers; the manager's silence rule after a speaking
tool is what keeps them apart. ⌥⌥ hands-free lock stays off during the demo.

## 8b. The open message: dictation with a destination (ruled 21 Sep)

**What broke.** 12:58, 21 Sep: "Tranquility, start a Claude Code agent…" followed by
a two-minute brief. Jev said start_agent at 1.00; the start rode the tool-calling model
and was cancelled by the next breath (function calls default to
`cancel_on_interruption=True`); the brief was judged as fourteen commands, each silent,
three of them the same words (AssemblyAI in Pipecat mode ends a turn after 100 ms of
silence and every VAD stop forces an endpoint, re-emitting the overlap).

**What the field does** (research 2026-09-21-long-dictation-voice-agents): nobody detects
the end of a dictated brief from silence. Smart Turn reads 8 s; TurnBench's best is 84.5%
recall on conversation and monologue is untested. Claude Code, Aider, Pipecat's own
push-to-talk example, Wispr, Talon, Apple Voice Control and this app's chord all end long
input on an explicit signal; Siri and Google in-car read a message back and ask before
sending. Silence is a backstop (Claude Code 15 s / 2 min, Apple 30 s, Wispr 20 min).

**Decision.** One piece of state, `OpenMessage {destination, text, since, asked}`
(compose.py), and two rules:

1. *The destination is settled at the door.* "Start a new agent" starts Claude Code now,
   deterministically (`_do_start_agent`), and opens the message to it: "Started Claude
   Code. What would you like to say?" "Tell the U Vape agent…" picks the session by name
   and says "For U Vape report. Go ahead." A wrong pick costs one clause ("no, the other
   one"); no list of eleven is ever read. "Take a note" opens to the Notes agent: a session
   like any other, its id kept in `notes-session.txt` while it is live, started and
   seeded once when it is not, writing notes.md and notes.html in its own hub directory.
   No writer, no format, no new door; an Obsidian connector later is a tool given to that
   one agent.
2. *The read-back only asks one thing.* While open, every word is the message: no intent,
   no action, no speech; overlapping finals are dropped. After 30 s of silence, once:
   "I heard: <20 words>. Send to Claude Code?" Yes sends; no or "wait" holds without a
   second read-back; anything longer is content. A pause never sends.

The certain path is a phrase on a short turn, no model in the way: "send it", "message
complete", "that's it", "yes, send it", "go ahead and send"; a long turn that ends with
one sends the words before it. "Never mind" drops the draft. "Send this to X instead"
re-picks the destination. Jev backs the phrases up (`compose` question, threshold 0.85)
and answers the read-back (`confirm`). The message is sent verbatim; the compose model
stays for one-clause instructions to the stage.

**Wire.** The draft rides the `speaking` event with `voice: draft` (amber, text on the
line) until the app grows a `composing` kind; `quiet` closes it. The chord exits
(⌥ tap, ⌃⌥ commit) are the app's gestures and need the app to write a line to the child:
not built yet, the phrase and the read-back are.

**Enrolment.** The app enrols a session the first time you reply to it (your confirmed
send is the consent); `tbase send` refuses anything unenrolled, and `tbase new` does not
enrol. Naming a destination by voice is the same consent, so the door (and a retarget)
enrols, idempotently. Found 21 Sep: the first live note was refused "not enrolled".

**`tbase new --wait-live` never worked.** The CLI took the first argument that was not
`--codex` as the directory, cd'd into "--wait-live" and died in a second; every
start_agent since 19 Sep failed this way. Fixed in main.swift (flags are not
directories); the bot leaves the flag off, registration is the proof it needs.

**Drill.** `TB_READBACK_SECS=0.3 uv run python drills/compose_drill.py` runs open,
overlap, hold, read-back, yes, phrase, trailing phrase, cancel and retarget with the
doors stubbed.

## 8c. Hosting and credits (ruled 21 Sep)

**Shape.** The bot is hosted, unchanged, as a container; the app streams audio and the
JSON event lines over one WebSocket; local mode (`--local`, `manager.command` in
`hq.json`, your own keys) stays the developer and BYOK door. Pipecat Cloud first; a
`VoiceHost` interface in the Gateway is the only seam that switches to our own machines.
No Python runtime is ever shipped inside the app or bootstrapped on a user's Mac.
Research: 2026-09-21-voice-agent-runtime-shape; audit: hosting-build-vs-buy; plan:
hands-free-execution-plan.

**Identity and money.** A hosted voice session is a managed-credits operation on the
Gateway: the same sign-in, the same DPoP bearer with one more scope (`voice:session`),
the same personal account, the same credit-standing state when the balance runs out.
The bot never holds a bearer, an account, or a user's keys.

**The grant and the price.** Hands-free draws from the same launch grant as summaries.
The voice-minute price is a server-owned pricebook constant, versioned like
`summaryMicros`: a session locks the pricebook version at admission, and a new version
changes the price for sessions started after it, never for one in flight. Tweaking the
value over time is a pricebook release, not a client release. The requirement that
does not move: measure and deduct accurately. Reserve a block at start, extend on
renewal, settle by the host's measured seconds at end; a session the host cannot
report goes to `reconciling` and is never re-executed or re-charged.

## 9. Repository layout

`tb-voice/` at the top level of the fork, beside `tools/` (the existing Python precedent),
managed with `uv`. The Swift package is untouched except the `tbase` flags. The fork stays
public; the design lives here so the judges can read the decisions, not just the demo.

## 10. What we are not building today

- Emotion or tone measurement. Hume dropped out; the "don't yell at your agents" idea is
  packaging for later.
- A rung deep link, unless everything above lands by 4 pm.
- Any change to how sessions are transcribed, summarised or spoken by the app.

## 11. Cut order if late

1. `summarize_work` (the fan-out call).
2. `teach` prompt content.
3. `--json` on `discover` (keep `targets` and `status`).
4. The rung verb.

## Measurements to take before demo

- Jev threshold on five live utterances in the venue, with the room's noise.
- Time from end of speech to first manager audio, addressed case.
- Zero false speaks across a 60 s think-aloud with four pauses.
