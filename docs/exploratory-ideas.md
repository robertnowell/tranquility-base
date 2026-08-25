# Exploratory ideas — captured, not committed

Robert, 06 Aug 2026, verbatim intent: "I want you to capture these ideas, not
necessarily act on them. That doesn't mean they're good ideas. They're just
ideas." Nothing here is ruled. Nothing here is scheduled. When one graduates,
it moves to `docs/log/open-issues.md` or the program board with a real design.

## 1. New agent opens a tab, not a window

Creating a new agent session opens a fresh terminal *window*. Preferred: a new
*tab* in the most recently active terminal window.

## 2. New agent should ask which directory

The working directory is an important decision, currently not offered at
creation time. Some picker — recent projects, or a path prompt — belongs in
the flow.

## 3 & 4. New agent stalls on the folder-trust prompt

The spawned session sits waiting on Claude Code's "do you trust this folder?"
prompt in the terminal. Ruling-adjacent (Robert: "I thought we already kind of
agreed on that"): if the folder is one we launched into deliberately, the
launcher should pre-trust it / auto-answer so the agent starts working
immediately instead of waiting on a prompt nobody can see from the HUD.

## 5. Change a session's voice while listening

Per-session voice reassignment, likely from the settings gear *while in* a
conversation. Acknowledged cost, in Robert's words: settings becoming
contextual — "if I'm in an agent conversation and hitting settings does
something different than if I'm at the home screen" — is a state machine
within settings, "not the worst thing," but it is A Thing and should be
entered with eyes open.

## 6. Connectors: dictation dump into other apps

Voice notes fired straight into an Obsidian vault or a Sublime/text folder —
the mic as a general dictation outbox, not only a reply channel. "Powerful,
but we would need to make sure it stays simple." Relates to the A6
micDestination router (destinations are about to be a first-class concept).
