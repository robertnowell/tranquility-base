"""tb-voice: the hands-free manager for Tranquility Base.

Cascade: Gradium STT -> Smart Turn v3 -> AddressedGate (Jev) -> MiniMax M2.7 on General
Compute (tools via tbase) -> Gradium TTS. Design: ../docs/design.md.

Run with keys injected from the Keychain: ./run.sh
"""

import os

from dotenv import load_dotenv
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
from pipecat.runner.types import RunnerArguments
from pipecat.runner.utils import create_transport
from pipecat.services.gradium.stt import GradiumSTTService
from pipecat.services.gradium.tts import GradiumTTSService
from pipecat.services.openai.llm import OpenAILLMService
from pipecat.transports.base_transport import BaseTransport, TransportParams
from pipecat.turns.user_start.min_words_user_turn_start_strategy import (
    MinWordsUserTurnStartStrategy,
)
from pipecat.turns.user_stop.turn_analyzer_user_turn_stop_strategy import (
    TurnAnalyzerUserTurnStopStrategy,
)
from pipecat.turns.user_turn_strategies import UserTurnStrategies
from pipecat.workers.runner import WorkerRunner

from gate import AddressedGate, JevClient
from prompt import SYSTEM
from tools import SCHEMAS

load_dotenv(override=True)


async def run_bot(transport: BaseTransport, runner_args: RunnerArguments) -> None:
    logger.info("Starting tb-voice")

    stt = GradiumSTTService(api_key=os.environ["GRADIUM_API_KEY"])
    tts = GradiumTTSService(
        api_key=os.environ["GRADIUM_API_KEY"],
        settings=GradiumTTSService.Settings(voice=os.getenv("GRADIUM_VOICE_ID") or None),
    )
    llm = OpenAILLMService(
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
            vad_analyzer=SileroVADAnalyzer(
                params=VADParams(stop_secs=0.2, confidence=0.8, min_volume=0.7)
            ),
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
                    )
                ]
            ),
        ),
    )

    gate = AddressedGate(JevClient(os.environ["JEV_API_KEY"]))

    pipeline = Pipeline(
        [
            transport.input(),
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

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        logger.info("Client connected; listening. Say the name to be answered.")

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info(f"Client disconnected; heard {gate.heard}, addressed {gate.addressed}")
        await runner.cancel()

    await runner.run()


async def bot(runner_args: RunnerArguments):
    transport_params = {
        "webrtc": lambda: TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            audio_out_sample_rate=48000,
        ),
    }
    transport = await create_transport(runner_args, transport_params)
    await run_bot(transport, runner_args)


if __name__ == "__main__":
    from pipecat.runner.run import main

    main()
