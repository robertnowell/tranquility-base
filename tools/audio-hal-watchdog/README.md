# audio-hal-watchdog

Detects a wedged `coreaudiod` (Apple's audio daemon) and restarts it, after saving a
spindump that names the thread holding the lock.

## The failure it covers

Three times (28 Aug, 03 Sep, 09 Sep 2026) macOS audio died system-wide while
AirPods Pro were connected and Zoom activated its virtual "share computer sound"
device. The unified log shows the exact moment on 09 Sep:

    09:58:14.818 coreaudiod HALS_MutationItinerary.cpp:41 Negotiate response failed
    09:58:14.820 coreaudiod >>> NEGOTIATE [us.zoom.xos]  devices: AirPods (blue), zoom.us.zoomaudiodevice.001 (virt)

From then on every CoreAudio call from every process timed out at 30 s
(`0x10004003` = `MACH_RCV_TIMED_OUT`). Zoom's picker showed no audio devices,
Tranquility Base lost its microphone and voice, `say -a ?` and `system_profiler`
hung. Nothing recovered by itself; `sudo killall coreaudiod` fixed it in one second.
The daemon and the Bluetooth stack are Apple's; the deadlock cannot be patched from
here. It can be made cheap.

## Install

    bash tools/audio-hal-watchdog/install.sh

Asks for your password once, to write `/etc/sudoers.d/audio-hal-watchdog` (two
commands only: `spindump coreaudiod *` and `killall coreaudiod`). Loads a launchd
agent that probes every 20 s.

## What it does when it fires

1. Probe `say -a ?` with an 8 s timeout. Hung → wait 5 s → probe again. Both hung = wedged.
2. Save `processes.txt`, a 5-minute unified-log slice, and `coreaudiod.spindump.txt`
   under `~/Library/Application Support/VoiceDispatch/audio-watchdog/incidents/<stamp>/`.
3. `killall coreaudiod`. launchd relaunches it in ~1 s. Re-probe, notify.

Detection to recovery: under 20 s. AirPods may need reconnecting afterwards.

## Test without acting

    DRY_RUN=1 PROBE_TIMEOUT=0 bash tools/audio-hal-watchdog/watchdog.sh

## Not a substitute for

Avoiding the trigger. Until Apple or Zoom fix it: share computer sound from the
built-in speakers, or take AirPods off before pressing Share.
