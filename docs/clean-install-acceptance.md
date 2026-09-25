# Clean-install acceptance

Run this on a pristine Apple-silicon macOS VM snapshot or a Mac/user account
that has never seen Tranquility Base. Use the exact public-candidate DMG; do not
copy a build-machine artifact into the guest.

**Run it a second time on an Intel Mac.** The app ships universal, and the
Intel slice is gated in CI on a native x86_64 runner, but CI runs `swift test`
and never opens the app. Everything this document actually checks (the TCC
grant dance, the panel, the earcons, first-run timing) has only ever been
observed on Apple Silicon. Rosetta is not a substitute here: it runs on Apple
Silicon hardware, so it reproduces the code path and not the machine. No source
found in the 02 Sep 2026 research even establishes whether TCC behaves
identically for a translated process, which is precisely what this document
spends most of its steps on.

Which Intel Mac matters, because the supported set is now small. Checked
against Apple's own compatibility pages, not from memory:

- **macOS 26 Tahoe** runs on exactly four Intel models: Mac Pro (2019),
  MacBook Pro (16-inch, 2019), MacBook Pro (13-inch, 2020, four Thunderbolt 3
  ports), iMac (27-inch, 2020). It is the last macOS to support Intel at all.
- **macOS 15 Sequoia** dropped the 2018 and 2019 MacBook Airs, and nothing
  else that we support. Every Sonoma-capable MacBook Pro, iMac, iMac Pro,
  Mac mini and Mac Pro is also Sequoia-capable.
- **macOS 14 Sonoma**, our floor, is the widest list, and the two Retina
  MacBook Airs (2018, 2019) sit on it and can go no higher.

Two of the supported models have NO BUILT-IN MICROPHONE: Mac mini (2018) and
Mac Pro (2019). For a voice-first app that is a hardware prerequisite, not a
preference, and the checklist should say so before a tester wonders why
nothing is heard.

## Fresh install

1. Restore the pristine snapshot and sign in as a standard, non-admin user.
2. Download the candidate DMG through Safari from its GitHub release.
3. Confirm the downloaded DMG has a `com.apple.quarantine` extended attribute.
4. Disconnect the guest network. This proves the stapled app and DMG do not
   depend on an online notarization lookup.
5. Open the DMG, drag Tranquility Base to Applications, and eject the image.
6. Open the installed app through Finder. The ordinary identified-developer
   confirmation is acceptable; needing **Open Anyway** is a failure.
7. Confirm the menu-bar item and onboarding checklist appear without a crash.
8. Exercise deny, grant, and relaunch behavior for microphone, speech
   recognition, Input Monitoring, Accessibility, and Terminal Automation.
9. Install or repair the Claude/Codex hooks through the app, start a supported
   agent, receive one spoken response, and send one dictated reply.
10. Quit and relaunch. Confirm the permissions and working setup persist.

## Translocation and upgrade

1. Restore the snapshot again. Launch the app directly from the downloaded DMG
   before moving it. Its bundled sounds, icon, and hooks must still resolve.
   Record any App Translocation path as evidence, not as a supported API.
2. Install the previous public release, complete onboarding, then install the
   candidate over it. Confirm permissions, app data, both deep-link schemes,
   and any Keychain credentials persist.
3. Keep old and new copies in different folders and verify the user can
   distinguish the build/source identity shown by each.

## Managed credits

The accounts exist now, so this is no longer a sketch. What it proves is one
thing: **somebody who has never pasted a provider key can sign in once and use
all five paid products, and the money behaves.** Everything else here is in
service of that sentence.

Run `scripts/acceptance-preflight.sh` first, and do not skip it.

A dry run on 23 Sep found that it is very easy to believe you are a stranger
and not be one. Identity on a Mac does not live in a profile directory: the
hub's device token sits in the login Keychain under the service
`voice-dispatch`, and a copy sits in `~/Library/Application Support/hq/token`,
which the app adopts into the Keychain the first time it sees it. A fresh
profile picks both of them up. So does a fresh install. The run then exercises
the owner's own funded account and reports a pass — not a failure, a FALSE
ACCEPTANCE, which is the worst outcome available here.

The preflight refuses rather than warns, because a step in a document can be
skipped and a check cannot. `--stash` moves what it finds aside, keeping a
dated copy; `--restore` puts it back, which matters because the stash holds
real provider keys.

1. Sign in from signed out: PKCE in the browser, back to the app, token in the
   Keychain. Quit and relaunch; it is still signed in.
2. Confirm the welcome credit arrived and is visible, and that no card was
   asked for to get it.
3. Use all five paid products on managed credit, with **no provider key
   present anywhere on the machine** — a summary, a spoken reply, live
   listening, a recovered recording, and a hands-free session. Each should
   work without a single vendor credential in the bundle, the Keychain, or the
   environment. That absence is the claim; verify it rather than assume it.
4. Watch the balance fall as they are used, and confirm what the billing page
   says matches what the app shows.
5. Add a card and let the balance fall below the floor. Confirm an unattended
   top-up happens, and that the activity list says what was bought.
6. Spend to zero. Confirm the app says so in an app-level, visually distinct
   way — out of credit is a state, not an error dialog — and that premium
   voice is not silently downgraded without saying why.
7. Sign out. Confirm the token is gone from the Keychain and nothing paid
   works afterwards.
8. Revoke the device from the hub while the app is running. Confirm it stops
   being able to spend, and says so.
9. Take the network away mid-session and confirm the failure is legible and
   nothing is charged for work that did not happen.

Record the user id, the starting and ending balance, and the ledger entries
for each product. `scripts/reconcile-cash.mjs` in hq-app should agree
afterwards; if it does not, the acceptance failed whatever the app looked like.

## Older subscription notes

PKCE browser return, expired/revoked session, offline grace behavior, quota
exhaustion, and logout are covered above; keep testing that a successful paid
request carries no provider credential in the bundle.

Capture the macOS version, hardware, release URL, DMG SHA-256, screenshots,
Gatekeeper outcome, and product health result. Restore the snapshot after each
run so Gatekeeper/TCC caches cannot turn a repeated test into false confidence.
