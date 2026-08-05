#!/bin/bash
set -e
cd "$(dirname "$0")"
python3 replay.py --prompt prompts/vnext-a.txt --sample 25 --seed 42 --workers 4 --timeout 240
python3 compare.py actual vnext-a
python3 compare.py vnext-a-r2 vnext-a
echo "ROUND 3 COMPLETE"
