#!/bin/bash
# Keys come from the macOS Keychain via claude-secrets; nothing is written to .env.
# claude-secrets buffers the child's output until exit, so the bot tees its own log.
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
exec claude-secrets run \
  --inject general-compute-api-key=GC_API_KEY \
  --inject gradium-api-key=GRADIUM_API_KEY \
  --inject typesafe-jev-api-key=JEV_API_KEY \
  -- sh -c 'uv run bot.py "$@" 2>&1 | tee -a bot.log' sh "$@"
