#!/bin/bash
# One tuning round: replay both prompts over the fixed 25-record sample, then compare.
set -e
cd "$(dirname "$0")"
python3 replay.py --prompt prompts/current.txt  --sample 25 --seed 42 --workers 4 --timeout 240
python3 replay.py --prompt prompts/vnext-a.txt  --sample 25 --seed 42 --workers 4 --timeout 240
python3 compare.py actual vnext-a
python3 compare.py current vnext-a
echo "ROUND COMPLETE"
