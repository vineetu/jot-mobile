#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# bootstrap-testflight.sh — portable "fresh machine → TestFlight" setup+deploy
# =============================================================================
#
# Hand this ONE file to a fresh macOS machine (or a cloud build box). It:
#   1. installs the prerequisites (Homebrew, xcodegen),
#   2. verifies a FULL Xcode (not just Command Line Tools) is selected,
#   3. installs your App Store Connect API key + env vars,
#   4. builds a Release archive, exports an IPA, and uploads it to TestFlight,
#   5. verifies the upload actually SUCCEEDED (altool lies with exit 0).
#
# It is written for an xcodegen-based repo (like Jot) but generalizes to any
# app: set the CONFIG block below. For a plain .xcodeproj/.xcworkspace with no
# project.yml, leave PROJECT_YML_DIR empty and point PROJECT at it.
#
# -----------------------------------------------------------------------------
#  ⚠️  SECURITY — READ THIS
# -----------------------------------------------------------------------------
#  The App Store Connect .p8 is a PRIVATE KEY. Anyone who has it + the Key ID +
#  Issuer ID can upload builds and act against your account. Therefore:
#    • DO NOT commit the filled-in copy of this script to git (it's .gitignored
#      below as bootstrap-testflight.local.sh — copy it to that name to fill in).
#    • Move it to the target machine over a private channel (scp / paste in an
#      SSH session), not a public repo, Slack, email, or pastebin.
#    • The Key ID and Issuer ID alone are useless without the .p8 — they're the
#      low-risk identifiers and are pre-filled for convenience. The .p8 is the
#      secret; paste it once, on the target machine.
#    • On any machine you no longer control, REVOKE the key in App Store Connect
#      → Users and Access → Integrations → App Store Connect API.
# =============================================================================


# ============================= CONFIG ========================================
# --- Apple account / signing (identifiers — low sensitivity) -----------------
TEAM_ID="${TEAM_ID:-8VB2ULDN22}"                                  # Apple Developer team ID (paid team, not personal)
ASC_KEY_ID="${ASC_KEY_ID:-4Q5FS536H9}"                            # App Store Connect API Key ID
ASC_ISSUER_ID="${ASC_ISSUER_ID:-69a6de77-cc11-47e3-e053-5b8c7c11a4d1}"  # App Store Connect Issuer ID

# --- The private key (THE SECRET) --------------------------------------------
# Paste the full contents of your AuthKey_<KEYID>.p8 between the EOF markers
# below (it's a short PEM block, "-----BEGIN PRIVATE KEY----- … -----END …").
# Leave it as-is (the placeholder line) if instead you'll scp the .p8 file
# directly to $ASC_KEY_PATH — the script uses the file if the paste is empty.
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8}"
read -r -d '' ASC_KEY_P8 <<'PASTE_P8_HERE' || true
<<< PASTE YOUR AuthKey_4Q5FS536H9.p8 CONTENTS HERE (or leave this line and scp the file to ASC_KEY_PATH) >>>
PASTE_P8_HERE

# --- App / project -----------------------------------------------------------
# REPO_ROOT defaults to this script's parent's parent (…/repo/scripts/x.sh).
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_SCHEME="${APP_SCHEME:-Jot}"                  # xcodebuild scheme
PROJECT_YML_DIR="${PROJECT_YML_DIR:-$REPO_ROOT/Jot}"  # dir holding project.yml for xcodegen; EMPTY to skip generation
PROJECT="${PROJECT:-$PROJECT_YML_DIR/$APP_SCHEME.xcodeproj}"  # .xcodeproj or .xcworkspace to build
# Optional: a script to run BEFORE archiving (e.g. this repo's build.sh, which
# runs xcodegen + patches the local-package back-refs). Leave empty to let this
# script run xcodegen itself.
PREBUILD_HOOK="${PREBUILD_HOOK:-$REPO_ROOT/build.sh}"

# --- Release knobs (optional) ------------------------------------------------
# Leave MARKETING_VERSION / BUILD_NUMBER empty to use whatever the project sets.
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
RELEASES_KEEP="${RELEASES_KEEP:-1}"              # how many old archive/export/derived-data sets to keep
INTERNAL_ONLY="${INTERNAL_ONLY:-0}"             # 1 = mark export internal-testing-only
# =============================================================================


# ----------------------------- helpers ---------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
log()  { printf '%s→ %s%s\n' "$c_dim" "$*" "$c_rst"; }
ok()   { printf '%s✓ %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s! %s%s\n' "$c_yel" "$*" "$c_rst"; }
die()  { printf '%serror: %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
releases_dir="$REPO_ROOT/tmp/releases"

# ----------------------------- prerequisites ---------------------------------
ensure_prereqs() {
  log "Checking prerequisites…"

  [[ "$(uname -s)" == "Darwin" ]] || die "TestFlight uploads require macOS (need Xcode)."

  # Full Xcode, not just Command Line Tools — archiving needs the full toolchain.
  if ! xcode-select -p >/dev/null 2>&1; then
    die "No developer dir selected. Install Xcode from the App Store (or 'xcodes install --latest'), then: sudo xcode-select -s /Applications/Xcode.app"
  fi
  local dev_dir; dev_dir="$(xcode-select -p)"
  if [[ "$dev_dir" != *"Xcode.app"* ]]; then
    die "Selected developer dir is '$dev_dir' (Command Line Tools only). A FULL Xcode is required: sudo xcode-select -s /Applications/Xcode.app"
  fi
  xcodebuild -version >/dev/null 2>&1 || die "xcodebuild not runnable — open Xcode once to finish first-launch install, or run: sudo xcodebuild -runFirstLaunch"
  ok "Xcode: $(xcodebuild -version | head -1) ($dev_dir)"

  # Homebrew (for xcodegen).
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found — installing (non-interactive)…"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Make brew available on this shell (Apple Silicon vs Intel paths).
    if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)";
    elif [[ -x /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
  fi
  command -v brew >/dev/null 2>&1 || die "Homebrew install failed — install it manually then re-run."
  ok "Homebrew: $(brew --version | head -1)"

  # xcodegen (only needed if we generate the project from project.yml).
  if [[ -n "$PROJECT_YML_DIR" ]]; then
    command -v xcodegen >/dev/null 2>&1 || { log "Installing xcodegen…"; brew install xcodegen; }
    ok "xcodegen: $(xcodegen --version 2>&1 | tr -d '\n')"
  fi

  command -v python3 >/dev/null 2>&1 || ok "python3: (only needed if your prebuild hook uses it)"
}

# ----------------------------- credentials -----------------------------------
install_credentials() {
  log "Installing App Store Connect credentials…"
  [[ -n "$TEAM_ID" ]]        || die "TEAM_ID is empty — set it in the CONFIG block."
  [[ -n "$ASC_KEY_ID" ]]     || die "ASC_KEY_ID is empty — set it in the CONFIG block."
  [[ -n "$ASC_ISSUER_ID" ]]  || die "ASC_ISSUER_ID is empty — set it in the CONFIG block."

  mkdir -p "$(dirname "$ASC_KEY_PATH")"
  chmod 700 "$(dirname "$ASC_KEY_PATH")" 2>/dev/null || true

  local pasted_real=1
  case "$ASC_KEY_P8" in
    *"PASTE YOUR"*|"") pasted_real=0 ;;
  esac

  if [[ "$pasted_real" -eq 1 ]]; then
    printf '%s\n' "$ASC_KEY_P8" > "$ASC_KEY_PATH"
    chmod 600 "$ASC_KEY_PATH"
    ok "Wrote private key → $ASC_KEY_PATH (chmod 600)"
  elif [[ -f "$ASC_KEY_PATH" ]]; then
    chmod 600 "$ASC_KEY_PATH" 2>/dev/null || true
    ok "Using existing private key at $ASC_KEY_PATH (no paste in CONFIG)"
  else
    die "No .p8 key. Either paste it into the ASC_KEY_P8 block in CONFIG, or scp your AuthKey_${ASC_KEY_ID}.p8 to $ASC_KEY_PATH, then re-run."
  fi

  # Sanity: a real .p8 is a PEM private key.
  grep -q "BEGIN PRIVATE KEY" "$ASC_KEY_PATH" 2>/dev/null \
    || warn "Key at $ASC_KEY_PATH doesn't look like a PEM private key — double-check it."

  # Export for this process (archive/export/upload below read these).
  export JOT_DEVELOPMENT_TEAM="$TEAM_ID"
  export APP_STORE_CONNECT_KEY_ID="$ASC_KEY_ID"
  export APP_STORE_CONNECT_ISSUER_ID="$ASC_ISSUER_ID"
  export APP_STORE_CONNECT_KEY_PATH="$ASC_KEY_PATH"

  # Optional: persist to a sourceable file so future shells / CI steps inherit
  # them without re-running setup. NOT committed; contains identifiers only
  # (the secret stays in the .p8 file, referenced by path).
  local env_file="$REPO_ROOT/.testflight.env"
  cat > "$env_file" <<EOF
# Sourced by deploys; identifiers only — the secret lives in the .p8 file.
export JOT_DEVELOPMENT_TEAM="$TEAM_ID"
export APP_STORE_CONNECT_KEY_ID="$ASC_KEY_ID"
export APP_STORE_CONNECT_ISSUER_ID="$ASC_ISSUER_ID"
export APP_STORE_CONNECT_KEY_PATH="$ASC_KEY_PATH"
EOF
  chmod 600 "$env_file"
  ok "Env written → $env_file (source it in future shells)"
}

# ----------------------------- project gen -----------------------------------
generate_project() {
  if [[ -n "$PREBUILD_HOOK" && -f "$PREBUILD_HOOK" ]]; then
    log "Running prebuild hook: $PREBUILD_HOOK"
    bash "$PREBUILD_HOOK"
  elif [[ -n "$PROJECT_YML_DIR" && -f "$PROJECT_YML_DIR/project.yml" ]]; then
    log "Generating Xcode project with xcodegen in $PROJECT_YML_DIR"
    ( cd "$PROJECT_YML_DIR" && xcodegen )
  else
    log "No project.yml / prebuild hook — using existing $PROJECT as-is"
  fi
  [[ -e "$PROJECT" ]] || die "Project not found at $PROJECT — set PROJECT in CONFIG."
}

# ----------------------------- build args ------------------------------------
project_flag() { case "$PROJECT" in *.xcworkspace) echo "-workspace";; *) echo "-project";; esac; }

version_overrides() {
  local args=()
  [[ -n "$MARKETING_VERSION" ]] && args+=(MARKETING_VERSION="$MARKETING_VERSION")
  [[ -n "$BUILD_NUMBER" ]]      && args+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
  printf '%s\n' "${args[@]+"${args[@]}"}"
}

auth_xcode=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

archive_path="$releases_dir/${APP_SCHEME}-$timestamp.xcarchive"
export_dir="$releases_dir/${APP_SCHEME}-export-$timestamp"
derived_data="$REPO_ROOT/tmp/DerivedData-testflight-$timestamp"
export_plist="$releases_dir/ExportOptions-$timestamp.plist"

prune_old() {
  local keep="$RELEASES_KEEP"
  _prune() {
    local glob="$1" label="$2" i=0 item
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      i=$((i+1))
      # Use `if` (not `(( … )) && { … }`): under `set -e`, a false `(( … ))`
      # returns exit status 1, and when it is the loop's last command (i.e.
      # the kept item, with i <= keep) it makes the while loop — and thus
      # `_prune` — return 1, killing the whole deploy before it archives.
      # This only triggered when exactly `keep` releases remained, so it
      # surfaced intermittently. `if` returns 0 on a false condition.
      if (( i > keep )); then
        echo "  prune old $label: $item"
        rm -rf "$item"
      fi
    done < <(eval "ls -td $glob 2>/dev/null")
    return 0
  }
  mkdir -p "$releases_dir"
  _prune "$releases_dir/${APP_SCHEME}-*.xcarchive" archive
  _prune "$releases_dir/${APP_SCHEME}-export-*" export
  _prune "$releases_dir/ExportOptions-*.plist" export-options
  _prune "$REPO_ROOT/tmp/DerivedData-testflight-*" derived-data
}

do_archive() {
  generate_project
  log "Archiving (Release)…"
  # shellcheck disable=SC2046
  xcodebuild $(project_flag) "$PROJECT" -scheme "$APP_SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath "$derived_data" \
    -archivePath "$archive_path" -allowProvisioningUpdates "${auth_xcode[@]}" \
    DEVELOPMENT_TEAM="$TEAM_ID" $(version_overrides) archive
  ok "Archived → $archive_path"
}

do_export() {
  [[ -d "$archive_path" ]] || archive_path="$(ls -td "$releases_dir/${APP_SCHEME}-"*.xcarchive 2>/dev/null | head -1)"
  [[ -d "$archive_path" ]] || die "No archive to export — run archive first."
  local internal="false"; [[ "$INTERNAL_ONLY" == "1" ]] && internal="true"
  cat > "$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>destination</key><string>export</string>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>uploadSymbols</key><true/>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>testFlightInternalTestingOnly</key><$internal/>
</dict></plist>
EOF
  log "Exporting IPA…"
  xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_dir" \
    -exportOptionsPlist "$export_plist" -allowProvisioningUpdates "${auth_xcode[@]}"
  ok "Exported → $export_dir"
}

do_upload() {
  [[ -d "$export_dir" ]] || export_dir="$(ls -td "$releases_dir/${APP_SCHEME}-export-"* 2>/dev/null | head -1)"
  local ipa; ipa="$(find "$export_dir" -maxdepth 1 -name '*.ipa' -print -quit 2>/dev/null || true)"
  [[ -n "$ipa" ]] || die "No IPA in $export_dir — run export first."
  log "Uploading $ipa …"
  local out; out="$(mktemp)"
  set +e
  xcrun altool --upload-app -f "$ipa" --type ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json | tee "$out"
  set -e
  verify_upload "$out"
  rm -f "$out"
}

# altool exits 0 on real failures — verify against the authoritative
# ContentDelivery log (and the JSON it just printed).
verify_upload() {
  local out="$1"
  if grep -q '"product-errors"' "$out" 2>/dev/null; then
    die "Upload FAILED — altool reported product-errors (see JSON above)."
  fi
  local log_dir="$HOME/Library/Logs/ContentDelivery/com.apple.itunes.altool"
  local latest; latest="$(ls -t "$log_dir"/*.txt 2>/dev/null | head -1 || true)"
  if [[ -n "$latest" ]] && grep -q "UPLOAD SUCCEEDED" "$latest"; then
    ok "UPLOAD SUCCEEDED — $(grep -m1 'Delivery UUID' "$latest" || true)"
    echo "  log: $latest"
  else
    warn "Could not confirm 'UPLOAD SUCCEEDED' in the altool log — check App Store Connect → TestFlight before trusting this."
  fi
}

# ----------------------------- dispatch --------------------------------------
usage() {
  cat <<EOF
Usage: bash $(basename "$0") <command>

  doctor    Check prerequisites only (no changes).
  setup     Install prereqs + write credentials (run once per machine).
  deploy    Generate project, archive, export, upload, verify.
  all       setup + deploy (the one-shot fresh-machine path).   [default]

Edit the CONFIG block at the top first. The .p8 private key goes in the
ASC_KEY_P8 paste slot (or scp the file to: $ASC_KEY_PATH).
EOF
}

case "${1:-all}" in
  doctor) ensure_prereqs ;;
  setup)  ensure_prereqs; install_credentials ;;
  deploy) install_credentials; prune_old; do_archive; do_export; do_upload ;;
  all)    ensure_prereqs; install_credentials; prune_old; do_archive; do_export; do_upload ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
