# The recap starts with the recap

Ruled 18 Aug 2026, in a voice session, against the measured corpus. The spoken
callsign is dead. It is the last of its jobs to go: the grid took its column on
12 Aug, the hub page took its byline on 16 Aug, and the spoken *hail* died on
10 Aug.

## The ruling, in the user's words

> "Most of my sessions are in the same directory. So that's useless… we have
> typically fewer than 14 sessions live at one time, so the 14 [voices] are
> plenty. I think probably kill it… Let's just drop it. For now, we can bring it
> back. It's too confusing."

## The measurement, not an argument

Both halves of the two-word name were defended on grounds the corpus does not
support.

**The project half names nothing.** Attribution by directory assumes sessions
are spread across directories. They are not: **23 of 127** minted callsigns
begin "promotions", because that is where the work is. A prefix that is the same
word on a fifth of the announcements is not attribution.

**The voice already says who.** `session_voice` assigns round-robin from a
14-voice roster, and fewer than fourteen sessions are ever live at once — so the
voice is a distinct identity per speaker in every case that actually occurs. The
roster's recycling was the argument for keeping the prefix, and it only bites in
a case this user does not have.

## The topic half was indefensible on its own terms

Asked where the second word came from, the honest answer is worse than the
guess. Nothing *chose* it:

1. the summariser writes a topic sentence;
2. `Callsign.candidateTopicWords` drops stopwords, sub-3-letter words, bare
   numbers, and anything already in the directory word;
3. what remains is sorted by **length**, longest first, ties broken by position;
4. the first one that does not collide with a live callsign wins, and is frozen
   for the session's life.

Longest-word-wins, as a proxy for distinctiveness. That is how a session came to
be called "promotions stlth" — STLTH is a vape brand spelled without vowels, and
it was the longest token in that turn's topic.

**And the gate added the same morning does not rescue it.** The vowel check
(issue 19) admits `b6y9z`, and it admits `stealthy` — a real English word, which
no filter can see is a bad name. The operator's reading is the right one and is
worth recording as a rule rather than an anecdote:

> "Most of the time with large language model errors, the answer is not a gate.
> The answer is proper context."

It applies here even though the fault was not the model's: the model wrote
prose, and a heuristic mined it for a token. The mechanism that could have
worked is asking the model for a **name**, told that the name will be said out
loud and must survive TTS — context, not validation. That is not worth building
for a name with no remaining listener, so the name goes instead.

## What changed

`Coordinator.withCallsign` → `Coordinator.strippingModelLabels`.

The prepend is gone; **the strip stays, and it is now the whole job.** The tuned
prompt asks the model to open with the project label and it complies 65 of 71
times, so without the strip the recap would open with a label-like prefix on
most turns — chosen by the model, and wrong on the miss (brand-substitution:
"Kopi:" from a promotions session whose *content* was about Kopi). Prepending is
what stopped. Stripping is what the prepending was hiding.

The session's own stored callsign is stripped alongside the labels: a name
minted before today can still be echoed back by a model that read it in the
transcript, and hearing the dead name is worse than hearing it on purpose.

The restore path (`restoredSummary`) strips the same way, with the two labels it
can reach without a live-session probe.

Minting no longer runs.

## What is deliberately NOT deleted

Reversibility is the point — "for now, we can bring it back":

- `Callsign` mints on demand, gate and all, and its tests still run.
- `session_callsign` keeps every row. It still seeds the recogniser's lexicon,
  and it still names a session in the grid until that session's tab has a title
  (`StateLegend.displayName`). Both are read paths; neither says anything aloud.
- `Announcement.hailText` stays as the one place that still knows how to say a
  session's name, for whoever brings attribution back.
- Migration `v12` (vowelless names, from the same morning) stays. It is a
  tidy-up now rather than a repair: an unsayable name is no better in a lexicon
  than in a voice.

Re-speaking it is one function.

## Evidence

`Phase1bTests.testTheRecapOpensWithTheRecapAndTheModelsLabelIsStripped` —
end-to-end through a real `Coordinator` with a summariser that writes the
`"promotions: …"` prefix. It asserts the recap opens with the recap, that no
label survives in either direction, and that nothing is minted. It replaces
`testAnnouncementOpensWithTheMintedCallsignExactlyOnce`, which pinned the
opposite behaviour and is the reason this ruling could not be a quiet deletion.
