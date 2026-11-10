# Saved accounts and pending launch recovery

The launcher exposes saved accounts above the existing backend adapters. An additional subscription account has a stable ID and a native configuration directory. Credentials remain in the native credential store. The original command configuration and default profile remain available as the legacy entry.

New agent chooses a saved target; Continue work with passes its existing source-log/report pointers to a fresh session; resume resolves the conversation's durable account binding. Changing the default does not change an existing conversation's account. Saved profile paths cannot be edited in place. Reconnect retains the observed email and organization, so a different account cannot silently replace the owner of old sessions.

## Entry points

- Menu bar → Saved accounts: create a profile and open native sign-in, or import an existing profile after a native status check.
- New agent: one-click existing behavior with one account; account menu when additional accounts are saved.
- Settings: one tile per account; selecting a tile sets the default target.
- Continue work with: same saved account entries, including the source account.
- `tbase accounts list`, `tbase accounts import NAME PROFILE_DIRECTORY`.
- `tbase new --account=TARGET_ID [DIRECTORY]`.
- `tbase://new?account=TARGET_ID` uses the same resolution as the app button.

Saved subscription entries use the standard executable and launch flags. Arbitrary custom shell commands remain under the original launcher; they are not parsed to infer hidden authentication changes. Account-specific MCP sign-in remains owned by that integration.

## Storage and failure behavior

The support directory contains `saved-accounts.json` (nonsecret account metadata), `session-accounts.json` (conversation provenance), `pending-launches.json` (launch/process receipts and unsent typed instruction), and `pending-fragments.json` (staged fragments, aliases, and uncertain delivery receipts). Writes are atomic and private. Account and launch receipt updates use a file lock across processes. Corrupt stores are not overwritten by mutation paths.

Discovery aggregates registered roots and treats an unreadable or ambiguous registry as an unknown witness. Registration requires account and exact launched tmux session/pane, in addition to cwd and a new native ID. The fallback checks the adapter's real process name, not the wrapper's spelling. Transcript lookup, history scanning, native lineage, first-message readback, trust, and integration installation include the account root.

Before launch, native authentication status must identify a saved subscription login in the expected profile. The check runs in the destination directory, with the same cleaned authentication environment. An observed email/organization mismatch refuses the launch. Status is local credential evidence, not proof of entitlement to the next request. Account setup never stores bearer tokens.

Pending handoff fragments survive timeout, supersession and app restart. Recover pending launch searches the original account/pane and adopts its draft without spawning or sending. A missing acknowledgement retains an uncertain receipt outside the sendable tray; restart does not automatically replay in-flight fragments. Explicit discard remains the tray's existing remove action. Failure to persist prevents dispatch.

## Validation and release boundary

`SavedAccountsTests` exercises profile identity, duplicate roots, metadata checks, durable binding, multi-root ambiguity, simultaneous same-directory registration, draft/alias persistence, uncertain sends and restart recovery. `scripts/test-saved-accounts.sh` exercises actual AppKit account tiles and selection in an isolated process without the live delegate, microphone, account credentials, rules repair or ownership lock. The source audit runs this drill.

A release also needs live two-account acceptance: both accounts launch in the same project, A→B and B→A pointer handoff, correct account after restart/default change, and both accounts' events/pages reaching the shared knowledge base. Background wake/restart and separate-process teammates need explicit identity-inheritance checks. Fixture tests and local auth-status checks do not substitute for those measurements. Do not deploy automatically while those runtime checks are outstanding.
