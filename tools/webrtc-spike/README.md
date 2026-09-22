# webrtc-spike

The client that proved the WebRTC path, kept because the measurements it made
are the reason the transport is changing and because it is the fastest way to
re-check any of them.

It connects a macOS process to a Pipecat bot over SmallWebRTC, using LiveKit's
WebRTC framework (their build; not their server, room protocol or SDK). What it
established, 22 Sep:

- Pipecat's SmallWebRTC signalling accepts an offer from this build: answer
  applied, audio track received, connected.
- The microphone can be pinned by identity (`MacBook Pro Microphone [117]`),
  which the app's device policy requires. `trySetInputDevice` alone returns
  true and does nothing while the module is recording: the sequence is stop,
  set, start.
- A factory built with no arguments enumerates no devices at all. The module
  has to be `platformDefault`, the one that speaks to the HAL.
- Against the cloud agent, waiting for ICE gathering to finish took 35 s.
  Candidates must trickle to `PATCH /api/offer`; with that it connects in about
  a second.
- Echo cancellation runs in the engine (`software:{active:1}`), and in a live
  acoustic test the bot spoke for eight seconds into an open microphone three
  feet away without hearing itself once.

    swift build
    ./.build/debug/webrtc-spike <offer-url> [bearer]

The offer URL is `http://localhost:7864/api/offer` for a local bot, or
`https://api.pipecat.daily.co/v1/public/<agent>/sessions/<session>/api/offer`
for one on Pipecat Cloud, where the session comes from `POST /start`.
