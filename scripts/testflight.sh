#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/testflight.sh archive
  scripts/testflight.sh export
  scripts/testflight.sh upload
  scripts/testflight.sh all

Commands:
  archive   Generate the Xcode project and create a Release archive.
  export    Export an IPA from an existing archive for App Store Connect.
  upload    Upload an exported IPA with altool.
  all       Archive, export, then upload.

Required environment:
  JOT_DEVELOPMENT_TEAM            Paid Apple Developer team ID to use for TestFlight.

Optional release environment:
  JOT_MARKETING_VERSION           Defaults to MARKETING_VERSION in Jot/project.yml.
  JOT_BUILD_NUMBER                Defaults to CURRENT_PROJECT_VERSION in Jot/project.yml.
  JOT_ARCHIVE_PATH                Defaults to tmp/releases/Jot-<timestamp>.xcarchive.
  JOT_EXPORT_DIR                  Defaults to tmp/releases/Jot-export-<timestamp>.
  JOT_DERIVED_DATA_PATH           Defaults to tmp/DerivedData-testflight-<timestamp>.
  JOT_TESTFLIGHT_INTERNAL_ONLY    Set to 1 to mark the export internal-only.

Optional App Store Connect authentication:
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
  APP_STORE_CONNECT_KEY_PATH

Alternative upload authentication:
  APP_STORE_CONNECT_USERNAME
  APP_STORE_CONNECT_PASSWORD

Examples:
  JOT_DEVELOPMENT_TEAM=ABCDE12345 JOT_BUILD_NUMBER=2 \
    bash scripts/testflight.sh archive

  JOT_DEVELOPMENT_TEAM=ABCDE12345 JOT_BUILD_NUMBER=2 \
  APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
  APP_STORE_CONNECT_ISSUER_ID=11111111-2222-3333-4444-555555555555 \
  APP_STORE_CONNECT_KEY_PATH=$HOME/.appstoreconnect/AuthKey_ABC123DEF4.p8 \
    bash scripts/testflight.sh all
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

command_name="$1"
case "$command_name" in
  archive|export|upload|all)
    ;;
  *)
    usage
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_dir="$repo_root/Jot"
project_spec="$project_dir/project.yml"
project_path="$project_dir/Jot.xcodeproj"
scheme="Jot"
config="Release"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
releases_dir="$repo_root/tmp/releases"

mkdir -p "$releases_dir"

default_marketing_version="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$project_spec")"
default_build_number="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$project_spec")"

team_id="${JOT_DEVELOPMENT_TEAM:-}"
marketing_version="${JOT_MARKETING_VERSION:-$default_marketing_version}"
build_number="${JOT_BUILD_NUMBER:-$default_build_number}"
archive_path="${JOT_ARCHIVE_PATH:-$releases_dir/Jot-$timestamp.xcarchive}"
export_dir="${JOT_EXPORT_DIR:-$releases_dir/Jot-export-$timestamp}"
derived_data_path="${JOT_DERIVED_DATA_PATH:-$repo_root/tmp/DerivedData-testflight-$timestamp}"
export_options_plist="$releases_dir/ExportOptions-$timestamp.plist"

if [[ -z "$team_id" ]]; then
  echo "error: JOT_DEVELOPMENT_TEAM is required for TestFlight releases." >&2
  echo "Set it to your paid Apple Developer team ID, not the local personal team." >&2
  exit 1
fi

declare -a xcode_auth_args=()
if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" || -n "${APP_STORE_CONNECT_ISSUER_ID:-}" || -n "${APP_STORE_CONNECT_KEY_PATH:-}" ]]; then
  if [[ -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" || -z "${APP_STORE_CONNECT_KEY_PATH:-}" ]]; then
    echo "error: APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, and APP_STORE_CONNECT_KEY_PATH must all be set together." >&2
    exit 1
  fi

  xcode_auth_args+=(
    -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH"
    -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID"
    -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
  )
fi

declare -a altool_auth_args=()
if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]]; then
  altool_auth_args+=(
    --api-key "$APP_STORE_CONNECT_KEY_ID"
    --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"
  )
  if [[ -n "${APP_STORE_CONNECT_KEY_PATH:-}" ]]; then
    altool_auth_args+=(--p8-file-path "$APP_STORE_CONNECT_KEY_PATH")
  fi
elif [[ -n "${APP_STORE_CONNECT_USERNAME:-}" || -n "${APP_STORE_CONNECT_PASSWORD:-}" ]]; then
  if [[ -z "${APP_STORE_CONNECT_USERNAME:-}" || -z "${APP_STORE_CONNECT_PASSWORD:-}" ]]; then
    echo "error: APP_STORE_CONNECT_USERNAME and APP_STORE_CONNECT_PASSWORD must both be set for username/password upload." >&2
    exit 1
  fi
  altool_auth_args+=(
    -u "$APP_STORE_CONNECT_USERNAME"
    -p "$APP_STORE_CONNECT_PASSWORD"
  )
fi

archive() {
  bash "$repo_root/build.sh"

  xcodebuild \
    -project "$project_path" \
    -scheme "$scheme" \
    -configuration "$config" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_data_path" \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    "${xcode_auth_args[@]}" \
    DEVELOPMENT_TEAM="$team_id" \
    MARKETING_VERSION="$marketing_version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    archive
}

write_export_options() {
  local internal_only_value="false"
  if [[ "${JOT_TESTFLIGHT_INTERNAL_ONLY:-0}" == "1" ]]; then
    internal_only_value="true"
  fi

  cat >"$export_options_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$team_id</string>
  <key>testFlightInternalTestingOnly</key>
  <$internal_only_value/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF
}

export_ipa() {
  if [[ ! -d "$archive_path" ]]; then
    echo "error: archive not found at $archive_path" >&2
    echo "Set JOT_ARCHIVE_PATH or run the archive command first." >&2
    exit 1
  fi

  write_export_options

  xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options_plist" \
    -allowProvisioningUpdates \
    "${xcode_auth_args[@]}"
}

upload_ipa() {
  if [[ ${#altool_auth_args[@]} -eq 0 ]]; then
    echo "error: upload requires App Store Connect credentials." >&2
    echo "Set API key variables or APP_STORE_CONNECT_USERNAME/APP_STORE_CONNECT_PASSWORD." >&2
    exit 1
  fi

  local ipa_path
  ipa_path="$(find "$export_dir" -maxdepth 1 -name '*.ipa' -print -quit)"
  if [[ -z "$ipa_path" ]]; then
    echo "error: no IPA found in $export_dir" >&2
    echo "Run the export command first or set JOT_EXPORT_DIR." >&2
    exit 1
  fi

  xcrun altool \
    --upload-app \
    -f "$ipa_path" \
    "${altool_auth_args[@]}" \
    --output-format json
}

case "$command_name" in
  archive)
    archive
    ;;
  export)
    export_ipa
    ;;
  upload)
    upload_ipa
    ;;
  all)
    archive
    export_ipa
    upload_ipa
    ;;
esac

cat <<EOF
archive_path=$archive_path
export_dir=$export_dir
marketing_version=$marketing_version
build_number=$build_number
team_id=$team_id
EOF
