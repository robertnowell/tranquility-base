# Automated releases

Every commit pushed to `main` is one release. In the normal path each commit is
a merged pull request, so there is no separate version-bump or release PR.

## Contract

The two workflows answer different questions:

1. **Source audit** runs on the pull request's proposed merge commit. It builds,
   runs both Swift test frameworks with count floors, exercises the hermetic tmux
   dispatch path, and runs the repository's static product checks. Make the job
   named `Source audit` a required check on `main`.
2. **Release every merge / build** runs again on the exact commit that reached
   `main`, without Apple credentials. It repeats the source audit, assembles the
   arm64 app with an ad-hoc transfer signature, stamps the full source SHA, and
   passes a one-day artifact to a separate job.
3. **Release every merge / release** is the only job attached to the `release`
   environment. It imports an ephemeral Developer ID identity, verifies the
   prebuilt app's version/build/source identity, then signs it. The app itself
   is notarized and stapled before it enters the signed DMG; the final DMG is
   separately notarized and stapled. The job audits locally, uploads a draft,
   downloads every asset back, requires byte and GitHub-digest equality, audits
   the downloaded copy, and only then publishes.

A failed release remains an unpublished draft. Rerunning the workflow can
replace that draft. Once public, the release path treats the asset as immutable:
a rerun downloads and audits it but never overwrites it.

Runs share `concurrency: release-main` with `queue: max`. GitHub serializes the
signing jobs while retaining up to 100 waiting runs. Ordering is not guaranteed,
so only the job whose SHA is the current `origin/main` receives Latest. A
manually dispatched run with a full main-branch SHA is the recovery path for a
lost event, queue overflow, or repaired operational failure.

Release identity is mechanical. For ancestry count `1024` at source commit
`abcdef123...`, the default is:

```text
version  0.3.1024
tag      v0.3.1024-abcdef123
```

`TBSourceCommit` in the app's Info.plist carries the full source SHA. The tag is
created at that same SHA, not at whichever commit happens to be the tip of main
when a slower notarization finishes.

## One-time repository setup

Create a GitHub Environment named `release`, restrict deployment branches to
`main`, and add four environment secrets:

| Secret | Value |
|---|---|
| `TB_DEVELOPER_ID_P12_BASE64` | Base64 of a password-protected `.p12` containing `Developer ID Application: Robert Nowell (FKE587SZ6H)` and its private key |
| `TB_DEVELOPER_ID_P12_PASSWORD` | The export password for that `.p12` |
| `TB_NOTARY_APPLE_ID` | The Apple ID used for Developer ID notarization |
| `TB_NOTARY_APP_PASSWORD` | An app-specific password for that Apple ID |

Nothing in the repository contains those values. The raw values exist only on
the release step. `ci-release.sh` imports them into a uniquely named temporary
keychain, unsets the raw environment variables, restores the runner's original
keychain search list, and deletes the keychain on every exit path.

Enable **release immutability** under repository Settings → General → Releases
before the first publication. GitHub's scoped workflow token cannot read that
admin-only setting, so setup verifies it separately. The release script asserts
the published release itself is immutable; if it is not, the script immediately
returns the still-mutable release to draft and fails. GitHub then locks the tag
and assets and automatically creates a release attestation.

After the `Source audit` job has appeared on one pull request, protect `main`:

- require a pull request before merging;
- require the `Source audit` status check;
- require branches to be up to date before merging;
- when a second trusted reviewer exists, require code-owner review for
  release-boundary files (a solo author cannot approve their own pull request);
- require conversation resolution and apply the rules to administrators;
- block force pushes and deletion.

Keep squash merge as the only merge method. One merged pull request then maps to
one first-parent commit and therefore one release. If merge queue is enabled,
the existing `merge_group` trigger keeps `Source audit` available to the queue.

GitHub currently gives workflow tokens read-only access by default in this
repository. The release workflow asks narrowly for `contents: write`, which is
required to create its tag, draft, and release asset.

## What remains deliberately local

The live Claude and Codex lifecycle drills require authenticated third-party
CLIs and, for Claude's Terminal canary, interactive Automation permission. A
hosted runner cannot honestly supply those. They remain part of the local
deploy gate; hosted CI skips them explicitly rather than turning “not logged in”
into a flaky product verdict.

## Recovery

- A source-audit failure blocks merge. Fix the pull request.
- A signing or notarization failure creates no public release. Fix the secret or
  Apple-side issue and rerun the workflow.
- A failure after draft upload leaves the draft private. Rerun; the draft asset
  is the only asset the automation is allowed to replace.
- A rerun of a public release audits the published DMG and exits without
  changing it.
- Older merge jobs may finish after newer ones. They still publish, but only a
  job whose source SHA is the current `origin/main` receives the Latest badge.
- For a missed trigger or repaired release-tooling failure, choose **Release
  every merge → Run workflow** and enter the full 40-character SHA. The build
  job checks out and audits that source SHA; the signing job keeps the current
  default-branch tooling and accepts only the source-stamped prebuilt app. The
  script independently requires both commits to be contained in `origin/main`.
- `queue: max` retains 100 pending releases. More than 100 is an explicit
  reconciliation event, not a silently supported backlog.

Each release carries four immutable evidence assets: the DMG, its SHA-256 file,
the clean app notarization log, and the clean DMG notarization log.

## The update feed

A release is bytes plus an advertisement, and they are deliberately separate
steps in that order. `release.sh` publishes the immutable DMG, re-downloads it,
audits the downloaded copy, confirms GitHub made the release immutable, and only
then runs `publish-appcast.sh`. If the feed step fails, installed copies stay on
the previous advertised build: a delayed update rather than a broken one.

The feed is one signed `appcast.xml` at `https://updates.tranquilitybase.to/`,
served by GitHub Pages from the `gh-pages` branch, with the DMG enclosure
pointing back at the GitHub release. Pages carries a documented soft limit of
100 GB of bandwidth a month; release assets carry no documented bandwidth limit
at all, so the small file goes on Pages and the large one does not.

`SUFeedURL` names a domain we own rather than a `github.io` address. That string
is compiled into every copy a user installs and is the one piece of
configuration that can never be changed remotely, because an installed copy only
learns about a new feed through the feed it already has. Hosting can therefore
move to our own backend later as a DNS change, with no bootstrap release and
nobody stranded.

**Do not put the feed behind an authenticated endpoint.** The update path is how
a broken client gets repaired. Coupling it to login, billing, entitlements or an
API deploy means an outage in any of those blocks the fix for that outage. A
backend may reject an obsolete client and tell it to update; it must never be
the thing that serves the update.

The feed lives on `gh-pages`, never on `main`, because every commit to `main` is
a release and a feed-only commit would cut an entire new build.

A fifth environment secret carries the signing key:

| Secret | Value |
|---|---|
| `TB_SPARKLE_EDDSA_PRIVATE_KEY` | The ed25519 private key from Sparkle's `generate_keys`, whose public half is pinned as `SUPublicEDKey` |

`ci-release.sh` deliberately does not unset it the way it unsets the other four:
they have been consumed by then (imported into a keychain, stored as a notary
profile), while the Sparkle key is piped into `sign_update` at the very end of
the run and never written to disk.

Losing that key is survivable but not free. Sparkle verifies both the Apple code
signature and its own, so one can bootstrap a rotation of the other: ship a
build signed with the existing Developer ID certificate carrying a new
`SUPublicEDKey`. Anyone who never takes that update is stranded on the old key.
Back it up with the same discipline as the `.p12`.

`audit-release.sh` asserts the feed URL, the public key, both signed-feed
settings, the embedded framework, the absence of the XPC services, and a
Developer ID signature with a secure timestamp on every nested Sparkle helper.
That block guards the one unrecoverable mistake in this path: a published build
with the wrong feed URL or a mismatched key can never be reached by any update,
and the only remedy is asking every user to install by hand a second time.

## Clean-install acceptance

The hosted artifact audit is a hard publication gate, but Apple explicitly says
command-line checks are less accurate than a quarantined fresh-machine install.
It proves signatures, tickets, policy admission, architecture, bundle identity,
resources, and source traceability; it does not claim to reproduce Safari,
Gatekeeper's first-launch UI, App Translocation, TCC prompts, or a new user's
desktop session.

Before calling the channel ready for an outside user, run
[`clean-install-acceptance.md`](clean-install-acceptance.md) against the exact
GitHub-downloaded DMG on a pristine Apple-silicon macOS snapshot. Repeat it for
the minimum supported macOS and current macOS before broad rollout. A future
self-hosted Mac VM appliance should hold the release as a draft until this gate
passes; GitHub-hosted runners cannot provide nested macOS virtualization or a
fully offline interactive guest.

## Future subscription plan

A subscription does not change the DMG, Developer ID, notarization, or direct
distribution path. Keep one app for BYOK and subscription users. The backend is
the authority for Stripe customer mapping, webhook-driven entitlements, usage,
and credits; model-provider and Stripe secrets never enter the app bundle.

Use browser OAuth with Authorization Code + PKCE, validate a dedicated callback
scheme/path/state, and keep only an app session or refresh credential in a new,
permanently named Keychain service. The existing bundle ID, Developer ID team,
`tranquilitybase` and legacy `voicedispatch` URL schemes, and application-support
directory remain stable across updates. A Mac App Store edition would be a
separate project because this app is intentionally unsandboxed and automates
Terminal; it would also introduce StoreKit/App Review commerce requirements.
