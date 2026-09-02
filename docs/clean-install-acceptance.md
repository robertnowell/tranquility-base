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

Which Intel Mac matters, because the supported set is now small: macOS 26 Tahoe
runs on exactly four Intel models (Mac Pro 2019, MacBook Pro 16-inch 2019,
MacBook Pro 13-inch 2020 with four Thunderbolt ports, iMac 27-inch 2020), and
macOS 15 Sequoia already dropped the 2018 13-inch MacBook Pro and every Intel
MacBook Air. Our macOS 14 floor is the widest list of the three.

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

## Subscription extension

When accounts exist, add signed-out launch, PKCE browser return, Keychain token
persistence, expired/revoked session, offline grace behavior, quota exhaustion,
logout, and successful paid request with no provider credential present in the
bundle.

Capture the macOS version, hardware, release URL, DMG SHA-256, screenshots,
Gatekeeper outcome, and product health result. Restore the snapshot after each
run so Gatekeeper/TCC caches cannot turn a repeated test into false confidence.
