# TestFlight Runbook

The release path that works for `jot-mobile` as of 2026-09-14 (build 301, Xcode 27.0 on
macOS 27). Use it when an agent or a person needs to push a TestFlight build without
rediscovering the Apple setup. An earlier version of this file described a different owner's
team and bundle IDs; everything below reflects the current project.

## Identifiers

- Main app: `com.vineetu.jot.mobile.Jot`
- Keyboard extension: `com.vineetu.jot.mobile.Jot.Keyboard`
- Share extension: `com.vineetu.jot.mobile.Jot.ShareExtension`
- Watch app / widgets: `com.vineetu.jot.mobile.Jot.watch` / `.watch.widgets`
- App Group: `group.com.vineetu.jot.mobile.shared`
- Apple Developer team: `8VB2ULDN22` (pinned as `DEVELOPMENT_TEAM` in `Jot/project.yml`)

Only the main app has an App Store Connect record; the extensions and the watch app ride
inside it (the watch app is embedded by the `Embed Watch Content` post-build script).

## Credentials (never in the repo)

Uploads authenticate with an **App Store Connect API key**, shared with the Ori app on the
same Mac:

- The `.p8` lives at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8` — `altool`
  finds it there by key ID.
- The key ID, issuer ID and key path are exported by the gitignored env file the Ori
  project uses: `ori-cognitive-health/website/scripts/testflight.env` (sibling repo). Source
  it, or export the same three variables by hand:
  `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_PATH`.
- The same key is passed to `xcodebuild` as `-authenticationKey*`, which is what lets
  `-allowProvisioningUpdates` register the App Group and Increased Memory Limit
  capabilities on the automatic profiles. Without it — e.g. on a Mac where Xcode has no
  signed-in Apple account — the archive fails with "Provisioning profile … doesn't include
  the com.apple.security.application-groups entitlement".

An Apple-ID + app-specific-password upload (`APP_STORE_CONNECT_USERNAME` / `_PASSWORD`)
also works for the upload step, but it does not fix provisioning, so prefer the API key.

## Build outputs must live outside iCloud Drive

`~/Documents` is synced by iCloud Drive on this Mac. Any directory a build creates under
the repo picks up `com.apple.FinderInfo` / `com.apple.fileprovider.*` attributes, and
`codesign` then fails with *"resource fork, Finder information, or similar detritus not
allowed"*. So:

- Point `JOT_DERIVED_DATA_PATH`, `JOT_ARCHIVE_PATH` and `JOT_EXPORT_DIR` somewhere outside
  Documents — `~/Library/Developer/Xcode/{DerivedData,Archives}` works and makes the
  archive show up in Xcode's Organizer.
- If a source resource that is copied verbatim (e.g. `Resources/Settings.bundle`) ever
  picks up Finder attributes, strip them: `xattr -cr Jot/Resources`.

## Standard command

Bump `CURRENT_PROJECT_VERSION` in `Jot/project.yml` first (every upload needs a new, higher
build number; keep the repo in sync), then:

```bash
cd /Users/jamyc3/Documents/projects/jot-mobile
source /Users/jamyc3/Documents/projects/ori-cognitive-health/website/scripts/testflight.env
OUT=$HOME/Library/Developer/Xcode

JOT_DEVELOPMENT_TEAM=8VB2ULDN22 \
JOT_BUILD_NUMBER=<n> \
JOT_ARCHIVE_PATH="$OUT/Archives/Jot-testflight-<n>.xcarchive" \
JOT_EXPORT_DIR="$OUT/Archives/Jot-export-<n>" \
JOT_DERIVED_DATA_PATH="$OUT/DerivedData/Jot-testflight-<n>" \
bash scripts/testflight.sh all
```

`all` = XcodeGen regenerate → Release archive (models excluded by
`EXCLUDED_SOURCE_FILE_NAMES`, guarded by the script) → export with an automatic-signing
`app-store-connect` ExportOptions plist → `xcrun altool --upload-app`. The `archive`,
`export` and `upload` subcommands run the stages individually against the same paths.

## After the upload

- App Store Connect → TestFlight shows the build as "Processing" for ~10–30 minutes, then it
  is installable for internal testers.
- Apple's post-upload metadata scan can still bounce a build a few minutes AFTER `altool`
  reports success — the verdict arrives as an "App Store Connect" email (ITMS-xxxxx). A build
  is only really in TestFlight once it shows there without such an email.

## App Store Connect metadata rules that bounce a build

- App Intent titles/descriptions must not contain "Siri" (build 155) or "Apple" (build 300,
  ITMS-90626). Say "the private cloud built into iOS", not "Apple's Private Cloud Compute".
- `UIBackgroundModes` `processing` requires a `BGTaskSchedulerPermittedIdentifiers` list
  (ITMS-90771). Jot declares only `audio` now.
- Every upload needs a build number higher than anything App Store Connect has ever seen for
  the app, including builds uploaded from other machines (299 was taken).

## Xcode 27 notes

- A fresh Xcode 27 install needs `sudo xcodebuild -runFirstLaunch` before simulators work;
  device archives work without it.
- No package build plug-ins remain in the dependency graph (the MLX stack that needed
  `-skipPackagePluginValidation` is gone), so the script's plain `xcodebuild` invocations
  are enough.
