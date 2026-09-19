# tb-voice

A Pipecat AI voice agent built with a cascade pipeline (STT → LLM → TTS).

## Configuration

- **Bot Type**: Web
- **Transport(s)**: SmallWebRTC
- **Pipeline**: Cascade
  - **STT**: Gradium
  - **LLM**: OpenAI
  - **TTS**: Gradium TTS

## Setup

### Server

1. **Navigate to server directory**:

   ```bash
   cd server
   ```

2. **Install dependencies**:

   ```bash
   uv sync
   ```

3. **Configure environment variables**:

   ```bash
   cp .env.example .env
   # Edit .env and add your API keys
   ```

4. **Run the bot**:

   ```bash
   uv run bot.py
   ```

   The runner serves every transport; the caller selects which one (a web/mobile
   client picks its transport when it connects; a telephony provider connects to
   `/ws`).

## Project Structure

```
tb-voice/
├── server/              # Python bot server
│   ├── bot.py           # Main bot implementation
│   ├── pyproject.toml   # Python dependencies
│   ├── .env.example     # Environment variables template
│   ├── .env             # Your API keys (git-ignored)
│   └── ...
├── .gitignore           # Git ignore patterns
└── README.md            # This file
```
## Building with an AI coding agent

Extending this bot with Claude Code, Codex, or another AI coding assistant? Give it live, accurate Pipecat context instead of stale training data with the **Pipecat Context Hub** — a local index of Pipecat docs, examples, and API source your agent queries over MCP:

```bash
# The Context Hub ships with the CLI
uv tool install "pipecat-ai[cli]"
pipecat context-hub install
```

`install` registers the MCP server with each coding agent it finds and builds the index — a few minutes and about 900 MB the first time. MCP servers load at session start, so do this before opening your coding session, and note the server won't start against an empty index. See the [Pipecat Context Hub docs](https://docs.pipecat.ai/api-reference/context-hub) for the full setup.

## Learn More

- [Pipecat Documentation](https://docs.pipecat.ai/)
- [Pipecat GitHub](https://github.com/pipecat-ai/pipecat)
- [Pipecat Examples](https://github.com/pipecat-ai/pipecat-examples)
- [Discord Community](https://discord.gg/pipecat)