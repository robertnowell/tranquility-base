#!/bin/bash
set -e
cd "$(dirname "$0")"
python3 replay.py --prompt prompts/vnext-a.txt --sample 50 --seed 7 --workers 4 --timeout 240
python3 compare.py actual vnext-a
echo "GENERALIZATION PASS COMPLETE"
