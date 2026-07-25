# iOS TestFlight release

**This script is the standard, repeatable way to ship *every* TestFlight build — now and going
forward.** It is not a one-off; run it for every release. There is **no fastlane** — releases are
this single script, driven by an App Store Connect API key. If someone asks "how do I push a new
build to testers?", the answer is always: run the script below — locally on a Mac, or remotely via
the GitHub Actions workflow (see "Remote release" below), which runs the exact same script.

## TL;DR — always use this

```bash
cd ios && ./scripts/testflight-release.sh
```

Safe to run any time you want to cut a build; re-runnable and idempotent (it derives the next build
number from TestFlight each time, and attaching/submitting an already-distributed build is a no-op).
It picks the next build number (highest on TestFlight + 1), bumps it, archives, exports with App
Store distribution signing, uploads, waits for processing, and pushes the build to the External
public-link group (+ submits Beta App Review). Then commit the build-number bump:

```bash
git add ios/Kiki.xcodeproj/project.pbxproj && git commit -m "chore(ios): bump build to <N>"
```

## Remote release (GitHub Actions) — ship from anywhere

`.github/workflows/testflight.yml` runs the same `testflight-release.sh` on a GitHub-hosted
`macos-26` runner. Use it when away from the Mac (e.g. Claude Code on the web pushes a fix, then a
build lands on the iPad via the TestFlight app — testers already in the group just get an Update).

- **Trigger (human):** GitHub → repo → Actions → "TestFlight Release" → *Run workflow* (pick the
  branch to build). Works from the iPad/phone browser or the GitHub app. The workflow must exist on
  the default branch for the UI button to appear.
- **Trigger (Claude / git):** push the commit to ship to the dedicated **`testflight-release`**
  branch — `git push origin <commit-or-branch>:testflight-release` (force is fine; the branch is a
  build pointer, not history). Exists because Claude Code web sessions can push git but can't fire
  Actions dispatches (403 on the workflow-dispatch API).
- **One-time setup:** repo Settings → Secrets and variables → Actions → new **secret**
  `ASC_API_KEY_P8` = the full text contents of the App Store Connect API `.p8` key. If using a
  *different* API key than the default (e.g. a freshly minted one), also add repo **variables**
  `ASC_KEY_ID` and `ASC_ISSUER_ID`. (A new key can be minted from any browser: App Store Connect →
  Users and Access → Integrations, role App Manager — useful if the original `.p8` is on the Mac
  and you're not.)
- **Build number:** derived from TestFlight at run time (same `next-build` logic), so CI does NOT
  commit the `CURRENT_PROJECT_VERSION` bump back — the next run (local or CI) re-derives it. Local
  runs should still commit the bump as documented above.
- **Signing on CI:** no certs are stored anywhere — the archive AND export steps both pass the API
  key with `-allowProvisioningUpdates`, so Xcode's cloud-managed distribution signing mints what it
  needs on the clean runner.
- **Cost:** macOS runners bill at 10x minutes on private repos; a release is ~20-40 runner-minutes.
  Negligible per the dev-cost policy, but don't fire builds in a loop.

## Prerequisites

- **Xcode 26+ selected.** Apple rejects any upload not built with the iOS 26 SDK
  (`STATE_ERROR.VALIDATION_ERROR`). Check with `xcodebuild -version`; switch with
  `sudo xcode-select -s /Applications/Xcode.app`. The release script guards on this.
- **App Store Connect API key** `.p8` at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`
  (role App Manager or Admin). The `.p8` is the secret and stays **out of the repo**. Key ID /
  Issuer ID are non-secret identifiers; defaults are in `scripts/asc.mjs` and the shell script,
  overridable via `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH` env vars.
- **Apple agreements active** (one-time): Developer Program License Agreement (developer.apple.com),
  **Free Apps Agreement** (App Store Connect → Business). The **Paid Apps Agreement** is only
  required before the subscription can actually *charge* — not for TestFlight. DSA: the account is
  registered as a **trader** (required because the app has a paid subscription).

## Key facts

- App: **Kiki Draw**, App ID `6762523143`, bundle `com.don.Kiki`, team `TWRWMP45FX`, SKU `kiki-ios-001`.
- Marketing version `1.0`; build number = `CURRENT_PROJECT_VERSION` in `project.pbxproj`
  (`agvtool new-version -all <N>` bumps it; the `../YES` warning is harmless — project uses
  `GENERATE_INFOPLIST_FILE`, no physical Info.plist).
- **No local Distribution certificate** — `-allowProvisioningUpdates` + the API key mint a
  **cloud-managed distribution cert** automatically during export.
- **Export compliance** is baked into the project (`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`,
  exempt — standard HTTPS only), so no per-build "Missing Compliance" prompt.

## Beta groups & how testers update

- **Internal** group: ASC team users only, no Beta App Review, installs immediately. Up to 100.
- **External** group "External": public link **https://testflight.apple.com/join/zKYJuSat**,
  group id `eca625f8-ef7a-4669-8013-74fa0a2f0464`. Tester cap = `publicLinkLimit` (set in ASC or via
  `scripts/asc.mjs`-style PATCH `betaGroups/<id>` with `publicLinkLimit`). External builds need
  Beta App Review, but **Apple auto-approves builds with no significant change** (instant, no wait;
  `submittedDate: null` + `APPROVED` is the auto-approval signature). Significant changes → real
  review, a few hours.
- **Testers never re-use the invite link.** Once joined they stay in the group for all future
  builds. A new build appears in their TestFlight app: auto-installs if they enabled *Automatic
  Updates*, otherwise a one-tap **Update** + notification. No manual re-download.
- Builds **expire 90 days** after upload — ship something within any 90-day window.

## Gotcha: `hasAccessToAllBuilds`

Can't be toggled on an existing external group via the API (settable only at group creation), and
recreating the group would change the public link. So each new build must be **attached to the
External group explicitly** — which `scripts/asc.mjs distribute` does. Don't fight the API flag.

## Manual fallback (if the script breaks)

```bash
cd ios
agvtool new-version -all <N>
xcodebuild -scheme Kiki -destination 'generic/platform=iOS' -archivePath /tmp/Kiki.xcarchive archive
xcodebuild -exportArchive -archivePath /tmp/Kiki.xcarchive -exportPath /tmp/export \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_KKBU3VH69S.p8 \
  -authenticationKeyID KKBU3VH69S -authenticationKeyIssuerID 227d4525-7a03-4792-8d9e-692a2743778c
xcrun altool --upload-app -f /tmp/export/Kiki.ipa -t ios \
  --apiKey KKBU3VH69S --apiIssuer 227d4525-7a03-4792-8d9e-692a2743778c
node scripts/asc.mjs distribute <N>
```
