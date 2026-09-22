"""tb-voice: the hands-free manager for Tranquility Base.

Cascade: AssemblyAI STT -> Smart Turn v3 -> AddressedGate (Jev) -> MiniMax M2.7 on General
Compute (tools via tbase) -> ElevenLabs TTS. Design: ../docs/design.md.

Run with keys injected from the Keychain: ./run.sh
"""

import asyncio
import json
import os
import time

from dotenv import load_dotenv

# .env first: manager.py and tools.py read TBASE_BIN and TB_URL_SCHEME at import.
load_dotenv(override=True)

from loguru import logger
from pipecat.audio.turn.smart_turn.base_smart_turn import SmartTurnParams
from pipecat.audio.turn.smart_turn.local_smart_turn_v3 import LocalSmartTurnAnalyzerV3
from pipecat.audio.vad.silero import SileroVADAnalyzer, VADParams
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.runner.types import RunnerArguments, WebSocketRunnerArguments
from pipecat.runner.utils import create_transport
from pipecat.services.assemblyai.stt import AssemblyAISTTService
from pipecat.services.openai.llm import OpenAILLMService
from pipecat.transports.base_transport import BaseTransport, TransportParams
from pipecat.turns.user_start.min_words_user_turn_start_strategy import (
    MinWordsUserTurnStartStrategy,
)
from pipecat.turns.user_stop.speech_timeout_user_turn_stop_strategy import (
    SpeechTimeoutUserTurnStopStrategy,
)
from pipecat.turns.user_stop.turn_analyzer_user_turn_stop_strategy import (
    TurnAnalyzerUserTurnStopStrategy,
)
from pipecat.turns.user_turn_strategies import UserTurnStrategies
from pipecat.workers.runner import WorkerRunner

from echo import EchoGate
from llm import RecordedLLMService
from manager import JevClient, Manager
from mute import WhileBotSpeaksMuteStrategy
from prompt import SYSTEM
from tools import SCHEMAS
from tts import SpokenTTSService


KEYTERMS = [
    "Tranquility", "Tranquility Base", "SambaNova", "General Compute", "Pipecat",
    "Jev", "TypeSafe", "AssemblyAI", "ElevenLabs", "Codex", "Claude", "AGI House",
]


async def keyterms(body: dict | None = None) -> list[str]:
    """The fixed names plus every session's display name. Hosted, the app sends
    them in the session body (wire.py); a fleet read over the wire at startup
    could only wait for a pipeline that does not exist yet, and did, for its
    whole 5 s timeout, on every start (02:15:41, 22 Sep). Local, tbase reads."""
    from tools import TBASE, _run

    names = list(KEYTERMS)
    extra = (body or {}).get("keyterms") if isinstance(body, dict) else None
    if isinstance(extra, list):
        names += [str(n).strip() for n in extra if str(n).strip() and str(n).strip() not in names]
        return names[:100]
    if os.getenv("TB_HOSTED"):
        return names
    try:
        code, out = await _run(TBASE, "targets", "--json", timeout=5.0)
        if code == 0:
            for t in json.loads(out):
                name = (t.get("name") or "").strip()
                if name and name not in names:
                    names.append(name)
    except Exception as e:  # noqa: BLE001
        logger.warning(f"keyterms: fleet names unavailable: {e}")
    return names[:100]


async def run_bot(transport: BaseTransport, runner_args: RunnerArguments) -> None:
    logger.info("Starting tb-voice")
    t_start = time.monotonic()

    # Key terms steer the transcriber toward the names it will hear: the
    # manager's own, the sponsors', and every session on the grid. Gradium heard
    # "Tranquillity" and "Sambinova planning"; a name the STT cannot spell is a
    # name the gate cannot match.
    stt = AssemblyAISTTService(
        api_key=os.environ["ASSEMBLYAI_API_KEY"],
        settings=AssemblyAISTTService.Settings(keyterms_prompt=await keyterms(getattr(runner_args, "body", None))),
    )
    # ElevenLabs is asked for pcm_24000 explicitly; the transport runs at the
    # device's native 48 kHz and Pipecat's SOXR resampler bridges the two. A
    # 24 kHz PortAudio stream into a 48 kHz virtual device (LoomAudioDevice was
    # the default output at 18:22) played grainy on two voices; Gradium at
    # 48 kHz on the same path did not.
    tts = SpokenTTSService(
        api_key=os.environ["ELEVENLABS_API_KEY"],
        sample_rate=24000,
        settings=SpokenTTSService.Settings(
            voice=os.getenv("ELEVENLABS_VOICE_ID", "SAz9YHcvj6GT2YYXdXww"),  # River: neutral, calm
        ),
    )
    llm = RecordedLLMService(
        api_key=os.environ["GC_API_KEY"],
        base_url=os.getenv("GC_BASE_URL", "https://api.generalcompute.com/v1"),
        settings=OpenAILLMService.Settings(
            model=os.getenv("GC_MODEL", "minimax-m2.7"),
            system_instruction=SYSTEM,
            max_tokens=200,
        ),
    )

    context = LLMContext(tools=SCHEMAS)
    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=0.2)),
            user_mute_strategies=[WhileBotSpeaksMuteStrategy()],
            # A turn starts on words, not on VAD: in a loud room VAD fired 300 ms into
            # every answer and cancelled it before TTS. Two words of transcript start a
            # turn; noise and one-word backchannels do not.
            user_turn_strategies=UserTurnStrategies(
                start=[
                    MinWordsUserTurnStartStrategy(
                        min_words=int(os.getenv("TB_MIN_WORDS", "2"))
                    )
                ],
                stop=[
                    TurnAnalyzerUserTurnStopStrategy(
                        turn_analyzer=LocalSmartTurnAnalyzerV3(
                            params=SmartTurnParams(
                                stop_secs=float(os.getenv("TB_STOP_SECS", "1.0"))
                            )
                        )
                    ),
                    # A pause ends the turn even when the model is unsure: the
                    # default outcome of a turn is silence, so ending early is cheap.
                    SpeechTimeoutUserTurnStopStrategy(
                        user_speech_timeout=float(os.getenv("TB_SPEECH_TIMEOUT", "1.2"))
                    ),
                ]
            ),
        ),
    )

    gate = Manager(JevClient(os.environ["JEV_API_KEY"]))

    logger.info(f"pipeline built in {time.monotonic() - t_start:.2f}s")

    @user_aggregator.event_handler("on_user_turn_started")
    async def on_user_turn_started(aggregator, *args):
        await gate.hearing()

    pipeline = Pipeline(
        [
            transport.input(),
            EchoGate(),
            stt,
            user_aggregator,
            gate,
            llm,
            tts,
            transport.output(),
            assistant_aggregator,
        ]
    )

    worker = PipelineWorker(
        pipeline,
        params=PipelineParams(enable_metrics=True, enable_usage_metrics=True),
    )
    runner = WorkerRunner(handle_sigint=runner_args.handle_sigint)
    await runner.add_workers(worker)

    if os.getenv("TB_HOST") == "app":
        from events import emit
        from reload import watch

        async def _on_change(files):
            await emit(None, "reloading", text=", ".join(files))

        asyncio.get_event_loop().create_task(watch(_on_change))

    try:
        @transport.event_handler("on_client_connected")
        async def on_client_connected(transport, client):
            logger.info("Client connected; listening. Say the name to be answered.")

        @transport.event_handler("on_client_disconnected")
        async def on_client_disconnected(transport, client):
            logger.info(f"Client disconnected; heard {gate.heard}, addressed {gate.addressed}")
            await runner.cancel()
    except Exception:  # the local transport has no clients; it listens until killed
        pass

    await runner.run()


async def bot(runner_args: RunnerArguments):
    if isinstance(runner_args, WebSocketRunnerArguments):
        # Hosted (Pipecat Cloud or our own machine): the app is on the other end of
        # one WebSocket. Audio both ways as PCM16, events and door requests as JSON
        # lines; see wire.py. TB_HOSTED is set in the deployed image's environment.
        from pipecat.transports.websocket.fastapi import (
            FastAPIWebsocketParams,
            FastAPIWebsocketTransport,
        )
        import wire
        from wire import TBSerializer

        w = wire.bind()  # this session's queue and reply table; see Wire

        transport = FastAPIWebsocketTransport(
            websocket=runner_args.websocket,
            params=FastAPIWebsocketParams(
                audio_in_enabled=True,
                audio_out_enabled=True,
                audio_in_sample_rate=16000,
                audio_out_sample_rate=24000,
                serializer=TBSerializer(w),
                session_timeout=int(os.getenv("TB_SESSION_TIMEOUT", "14400")),
            ),
        )
        await run_bot(transport, runner_args)
        return
    transport_params = {
        "webrtc": lambda: TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_out_sample_rate=48000,
        ),
    }
    transport = await create_transport(runner_args, transport_params)
    await run_bot(transport, runner_args)


async def run_local():
    """Hosted by the app (or `--local`): the Mac's mic and speakers, no browser.
    The runner has no local transport, so this builds one and calls run_bot."""
    import asyncio

    from pipecat.transports.local.audio import LocalAudioTransport, LocalAudioTransportParams

    transport = LocalAudioTransport(
        LocalAudioTransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_in_sample_rate=16000,
            audio_out_sample_rate=48000,  # device native; TTS is resampled up from 24 kHz
        )
    )

    class Args:
        handle_sigint = True
        body = {}
        session_id = "local"

    await run_bot(transport, Args())


if __name__ == "__main__":
    import sys

    if "--local" in sys.argv or os.getenv("TB_HOST") == "app":
        import asyncio

        # The log goes to bot.log here; stdout/stderr are the host's or the envelope's.
        logger.remove()
        logger.add("bot.log", level=os.getenv("TB_LOG", "INFO"))

        asyncio.run(run_local())
    else:
        from pipecat.runner.run import main

        main()
