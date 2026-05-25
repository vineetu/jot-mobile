#!/usr/bin/env bash
# check-backup-attributes.sh — verify iCloud Backup invariants for Jot.
#
# What this checks:
#   1. The SwiftData store config in code points to the App Group container
#      (cross-process access for keyboard + any future extension).
#   2. The Qwen rewrite weight cache path is under `Library/Caches/` — iOS
#      unconditionally excludes Caches/ from backup, so this is how we
#      avoid bloating the user's iCloud backup by ~2.5 GB.
#   3. No surprise `isExcludedFromBackup` calls have been added to the
#      transcript / prompt / vocab persistence paths.
#
# This is a static-source audit, not a runtime check. Run it before each
# release and as part of CI.
#
# Usage:
#   ./scripts/check-backup-attributes.sh
# Exit code 0 = pass. Non-zero = at least one invariant failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

red()    { printf "\033[31m%s\033[0m\n" "$1"; }
green()  { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

fails=0

# ---- 1. SwiftData store lives in App Group container ----------------------
echo "[1/3] SwiftData store config…"
if grep -q "groupContainer: \.identifier(AppGroup.identifier)" \
    Jot/Shared/TranscriptStore.swift; then
    green "  OK — TranscriptStore uses App Group container."
else
    red   "  FAIL — TranscriptStore config doesn't reference AppGroup container."
    red   "  This breaks the documented backup-eligible storage location and"
    red   "  breaks keyboard / future extension access. Restore the config."
    fails=$((fails + 1))
fi

# ---- 2. Qwen weight cache path under Library/Caches/ ----------------------
echo "[2/3] Qwen weight cache path…"
if grep -q "URL\.cachesDirectory" Jot/App/LLM/Qwen35Client.swift; then
    green "  OK — Qwen weights live under Library/Caches/ (auto-excluded by iOS)."
else
    red   "  FAIL — Qwen weight cache path no longer uses URL.cachesDirectory."
    red   "  iOS only auto-excludes Library/Caches/. If we moved the weights"
    red   "  somewhere else (Documents/, App Group, etc.), they will start"
    red   "  bloating user backups by ~2.5 GB. Restore or explicitly set"
    red   "  isExcludedFromBackup."
    fails=$((fails + 1))
fi

# ---- 3. No surprise backup exclusions on user data paths ------------------
echo "[3/4] No surprise isExcludedFromBackup calls on user data…"
# We do NOT want anyone setting isExcludedFromBackup on the SwiftData store,
# saved prompts, vocab, or the mirror — those need to be in the backup.
surprise=$(grep -rln "isExcludedFromBackup" \
    Jot/Shared/TranscriptStore.swift \
    Jot/Shared/SavedPromptStore.swift \
    Jot/Shared/TranscriptHistoryMirror.swift 2>/dev/null || true)
if [ -z "$surprise" ]; then
    green "  OK — no exclusion attrs on user data stores."
else
    red   "  FAIL — found isExcludedFromBackup in user-data store(s):"
    red   "    $surprise"
    red   "  User data must stay backup-eligible. Remove these flags."
    fails=$((fails + 1))
fi

# ---- 4. FluidAudio model weights ARE explicitly excluded ------------------
echo "[4/4] FluidAudio speech-model weights backup exclusion…"
# Parakeet weights live at Library/Application Support/FluidAudio/Models/
# — INCLUDED in iOS Device Backup by default. Without an explicit
# exclusion, the ~2 GB of 600M v2 weights bloat the user's iCloud backup.
# `BackupExclusion.excludeFluidAudioModels()` runs per-launch from
# JotApp.init to set isExcludedFromBackup on the parent directory.
if grep -q "BackupExclusion.excludeFluidAudioModels" Jot/App/JotApp.swift; then
    green "  OK — JotApp.init calls BackupExclusion.excludeFluidAudioModels()."
else
    red   "  FAIL — JotApp.init no longer calls BackupExclusion.excludeFluidAudioModels()."
    red   "  Without this per-launch call, downloaded speech model weights"
    red   "  get included in iCloud Device Backup (the user's backup grows"
    red   "  by ~2 GB for every variant downloaded). Restore the call."
    fails=$((fails + 1))
fi

echo ""
if [ "$fails" -eq 0 ]; then
    green "All backup invariants pass ✓"
    exit 0
else
    red "$fails invariant(s) failed."
    exit 1
fi
