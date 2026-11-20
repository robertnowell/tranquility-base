#!/bin/sh
# run-chapter.sh <slug> <num> "<title>" : build, structure-check, archive+fetch+verify+write, publish, shoot the head
set -e
H=/Users/robertnowell/Documents/agents/360cebe8-e728-4fb4-857e-7d0f6e45c42a
cd "$H/_work/chapters"
python3 -I build-chapter.py "$1" "$2" "$3"
python3 -I ../chapter-type/chapter-audit.py "$H/_drafts/$1.html" --archive --fetch --verify=sonnet --write > "/private/tmp/claude-501/-Users-robertnowell-Documents-tranquility-base/360cebe8-e728-4fb4-857e-7d0f6e45c42a/scratchpad/audit-$1.txt" 2>&1 || true
grep -E "^(ERROR|verdicts|wrote)|NOT FOUND" "/private/tmp/claude-501/-Users-robertnowell-Documents-tranquility-base/360cebe8-e728-4fb4-857e-7d0f6e45c42a/scratchpad/audit-$1.txt"
