# TestFlight Runbook

This is the exact release path that worked for `jot-mobile` on April 22, 2026.

Use this document when another agent needs to push a new TestFlight build without rediscovering Apple setup, bundle IDs, or the current Xcode packaging issue.

## Repo and Apple identifiers

- Main app bundle ID: `com.jot.mobile.Jot`
- Keyboard extension bundle ID: `com.jot.mobile.Jot.Keyboard`
- Widget extension bundle ID: `com.jot.mobile.Jot.Widget`
- Shared App Group: `group.com.jot.mobile.shared`
- Paid Apple Developer Team ID: `6966SNKBNF`
- Team name in Xcode: `Tejas D Channappa`
- Apple account used in Xcode and upload tooling: `tejastej.dc@gmail.com`
- App Store Connect app Apple ID: `6763163205`

Only the main app has an App Store Connect app record. The keyboard and widget are embedded targets and are uploaded inside the main app.

## What is already configured

- Paid Apple Developer membership is active for team `6966SNKBNF`.
- Xcode on this Mac is signed into `tejastej.dc@gmail.com`.
- The App Store Connect app record already exists for `com.jot.mobile.Jot`.
- The project is wired so app and extensions all inherit versioning from:
  - `MARKETING_VERSION`
  - `CURRENT_PROJECT_VERSION`

## Important Apple flow clarification

There are two different Apple flows that are easy to confuse:

1. `Distribute App` in Xcode means "upload a signed archive to App Store Connect".
2. `Add for Review` in App Store Connect is the public App Store submission flow.

For TestFlight, you only need the upload first. You do not need to complete the public App Store review page in order to get internal TestFlight testing working.

Internal testers can be added once the build finishes processing.

External testers require Beta App Review later.

## One-time credential storage on this Mac

Do not store Apple credentials in `.env` files or commit them to the repo.

The current workflow stores the Apple app-specific password in the macOS login Keychain:

- Keychain service name: `JOT_TESTFLIGHT_UPLOAD`
- Keychain account name: `tejastej.dc@gmail.com`

To overwrite it on this Mac:

```bash
security add-generic-password \
  -U \
  -a 'tejastej.dc@gmail.com' \
  -s 'JOT_TESTFLIGHT_UPLOAD' \
  -w '<APP_SPECIFIC_PASSWORD>'
```

To let Apple tooling read it without prompting:

```bash
xcrun altool ... -u 'tejastej.dc@gmail.com' -p '@keychain:JOT_TESTFLIGHT_UPLOAD'
```

Do not print the secret to logs unless there is a debugging emergency.

## Standard archive command

Use the paid team and bump the build number every upload:

```bash
cd /Users/tejasdc/workspace/jot-mobile

JOT_DEVELOPMENT_TEAM=6966SNKBNF \
JOT_MARKETING_VERSION=0.1.0 \
JOT_BUILD_NUMBER=5 \
JOT_ARCHIVE_PATH=/Users/tejasdc/workspace/jot-mobile/tmp/releases/Jot-testflight-5.xcarchive \
JOT_DERIVED_DATA_PATH=/Users/tejasdc/workspace/jot-mobile/tmp/DerivedData-testflight-5 \
bash scripts/testflight.sh archive
```

Expected result:

- `** ARCHIVE SUCCEEDED **`

## Known Xcode 26 export problem on this Mac

`xcodebuild -exportArchive` fails on macOS 26.0.1 with Xcode 26.3 because Apple’s distribution pipeline invokes `/usr/bin/rsync`, and on this system that binary is `openrsync`, which does not support the flags Xcode expects.

Observed failure in the export logs:

- `rsync: on remote machine: --extended-attributes: unknown option`
- `Step "<IDEDistributionCreateIPAStep ...>" failed with error "Copy failed"`

This affects both:

- `bash scripts/testflight.sh export`
- Organizer GUI upload from Xcode

Do not waste time trying the same export repeatedly unless the OS or Xcode version changed.

## Current working workaround

The workaround is:

1. Let Xcode run the export until it fails.
2. Grab the re-signed distribution payload from the temp `XcodeDistPipeline.*` directory.
3. Zip `Payload` and optional `Symbols` into the final `.ipa`.
4. Upload the `.ipa` with `altool`.

### Force Xcode to prepare the re-signed distribution payload

```bash
cd /Users/tejasdc/workspace/jot-mobile

JOT_DEVELOPMENT_TEAM=6966SNKBNF \
JOT_ARCHIVE_PATH=/Users/tejasdc/workspace/jot-mobile/tmp/releases/Jot-testflight-5.xcarchive \
JOT_EXPORT_DIR=/Users/tejasdc/workspace/jot-mobile/tmp/releases/Jot-export-5 \
bash scripts/testflight.sh export || true
```

After failure, inspect the latest distribution temp directory under:

```bash
ls -td /var/folders/*/*/*/T/XcodeDistPipeline.* | head
```

On April 22, 2026 the successful build `5` payload was here:

```bash
/var/folders/6k/z4pfhlgx0c3c6b30tkdq6mz80000gn/T/XcodeDistPipeline.~~~5MeuGu
```

### Create the manual IPA

```bash
set -euo pipefail

src=/var/folders/6k/z4pfhlgx0c3c6b30tkdq6mz80000gn/T/XcodeDistPipeline.~~~5MeuGu
stage=/Users/tejasdc/workspace/jot-mobile/tmp/releases/manual-upload-5
ipa=/Users/tejasdc/workspace/jot-mobile/tmp/releases/Jot-manual-5.ipa

rm -rf "$stage"
mkdir -p "$stage"
cp -R "$src/Root/Payload" "$stage/"

if [ -d "$src/Symbols" ]; then
  cp -R "$src/Symbols" "$stage/"
fi

rm -f "$ipa"
(cd "$stage" && /usr/bin/zip -qry "$ipa" Payload Symbols)
```

## Upload command that worked

This is the upload shape that succeeded:

```bash
cd /Users/tejasdc/workspace/jot-mobile

xcrun altool \
  --upload-app \
  -f '/Users/tejasdc/workspace/jot-mobile/tmp/releases/Jot-manual-5.ipa' \
  -u 'tejastej.dc@gmail.com' \
  -p '@keychain:JOT_TESTFLIGHT_UPLOAD' \
  --output-format json
```

Successful delivery details from April 22, 2026:

- Delivery UUID: `53935f0f-16cd-4c73-916d-09206d25a522`
- Uploaded file: `tmp/releases/Jot-manual-5.ipa`
- Uploaded build: `0.1.0 (5)`

Replacement upload after the Siri metadata fix:

- Delivery UUID: `4835a52f-16ed-42e2-b5f8-cf75c8ca20c3`
- Uploaded file: `tmp/releases/Jot-manual-6.ipa`
- Uploaded build: `0.1.0 (6)`

## Build status check

Use this to see whether the build is still processing or has entered TestFlight:

```bash
cd /Users/tejasdc/workspace/jot-mobile

xcrun altool \
  --build-status \
  --apple-id 6763163205 \
  --bundle-version 5 \
  --bundle-short-version-string 0.1.0 \
  --platform ios \
  -u 'tejastej.dc@gmail.com' \
  -p '@keychain:JOT_TESTFLIGHT_UPLOAD' \
  --output-format json
```

If you want the command to block until processing finishes:

```bash
xcrun altool \
  --build-status \
  --wait \
  --apple-id 6763163205 \
  --bundle-version 5 \
  --bundle-short-version-string 0.1.0 \
  --platform ios \
  -u 'tejastej.dc@gmail.com' \
  -p '@keychain:JOT_TESTFLIGHT_UPLOAD' \
  --output-format json
```

## Validation issue already found and fixed

The first upload attempt failed because the 1024 App Store icon had an alpha channel:

- file: `Jot/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`
- Apple error: `Invalid large app icon ... can’t be transparent or contain an alpha channel`

That icon was flattened and rebuilt before build `5`.

If this happens again, verify with:

```bash
sips -g hasAlpha Jot/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

Expected output:

- `hasAlpha: no`

## App Intents validation issue already found and fixed

Build `5` uploaded successfully but failed App Store Connect processing with:

- code: `90626`
- error: `Invalid Siri Support`
- reason: the App Intent description contained the word `iPhone`

The failing text was in:

- [Jot/App/Intents/TranscribeAudioFileIntent.swift](/Users/tejasdc/workspace/jot-mobile/Jot/App/Intents/TranscribeAudioFileIntent.swift)

Old text:

```text
Fully local — nothing leaves your iPhone.
```

Fixed text:

```text
Fully local — nothing leaves your device.
```

If Apple rejects another build on Siri/App Intents metadata, inspect App Intent descriptions first before rebuilding.

## App Store Connect UI caveat on this machine

The browser automation path to App Store Connect has been inconsistent:

- The app record was created successfully by hand in the browser.
- The generic `Apps` page sometimes shows `No Apps` even though the app exists.
- `altool` upload is reliable enough to use as the source of truth for delivery success.
- `altool --build-status` is flaky on this machine and can fail with:
  - `The file "Defaults.properties" couldn't be opened.`
  - a crash in JSON output mode

Use App Store Connect manually to confirm final processing state if `altool --build-status` keeps failing.

If you need to navigate manually in the browser, go directly to the app record rather than relying on the list page:

```text
https://appstoreconnect.apple.com/apps/6763163205
```

And TestFlight directly:

```text
https://appstoreconnect.apple.com/apps/6763163205/testflight/ios
```

## Recommended next release procedure

For build `N`:

1. Pick the next unused build number.
2. Run `scripts/testflight.sh archive` with `JOT_DEVELOPMENT_TEAM=6966SNKBNF`.
3. Run the export step once, expecting the `rsync` failure.
4. Package the manual IPA from the newest `XcodeDistPipeline.*` temp directory.
5. Upload with `xcrun altool --upload-app` using `@keychain:JOT_TESTFLIGHT_UPLOAD`.
6. Poll `xcrun altool --build-status` until Apple finishes processing.
7. In App Store Connect, use the `TestFlight` tab to add internal testers.

## Files involved in this workflow

- Script entrypoint: [scripts/testflight.sh](/Users/tejasdc/workspace/jot-mobile/scripts/testflight.sh)
- This runbook: [docs/testflight.md](/Users/tejasdc/workspace/jot-mobile/docs/testflight.md)
- Project config: [Jot/project.yml](/Users/tejasdc/workspace/jot-mobile/Jot/project.yml)
- App icon set: [Jot/Resources/Assets.xcassets/AppIcon.appiconset](/Users/tejasdc/workspace/jot-mobile/Jot/Resources/Assets.xcassets/AppIcon.appiconset)

## What not to do

- Do not use the App Store `Add for Review` checklist as the TestFlight checklist.
- Do not save the app-specific password in `.env`.
- Do not commit any Apple credentials or private keys into this repo.
- Do not assume `scripts/testflight.sh export` alone will produce a valid IPA on this OS/Xcode combination.
