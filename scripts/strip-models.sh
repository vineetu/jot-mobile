#!/usr/bin/env bash
set -euo pipefail

# strip-models.sh — Build B ("strip-all") helper.
#
# ⚠️ RETIRED 2026-07-26 — no longer part of any build. Release builds now
# exclude `Resources/Models` declaratively via `EXCLUDED_SOURCE_FILE_NAMES:
# Models` on the Jot target's Release config (Jot/project.yml), so there is
# nothing to stash and nothing to restore: Debug keeps the models for local
# Cmd+R runs, Release never sees them. `testflight.sh` no longer calls this
# script and asserts the archive is model-free instead.
#
# Kept only as a manual escape hatch (e.g. measuring a bundle-free Debug build).
# If you run it by hand, run `restore` afterwards — an interrupted `stash`
# leaves your working tree without models until you do.
#
# Moves the three bundled model directories out of Jot/Resources/Models so a
# Release archive ships WITHOUT them (~46 MB app), then restores them so the
# working tree is never left mutated. The dirs are gitignored and kept locally;
# this is a pure move-aside, not a delete.
#
#   scripts/strip-models.sh stash     # move the 3 model dirs to .model-stash/
#   scripts/strip-models.sh restore   # move them back into Resources/Models
#   scripts/strip-models.sh status    # show current state
#
# Intended use (from repo root), with a trap so restore ALWAYS runs:
#   trap 'scripts/strip-models.sh restore' EXIT
#   scripts/strip-models.sh stash
#   JOT_BUILD_NUMBER=258 scripts/testflight.sh all   # (invoked per its own contract)
#
# See docs/plans/model-externalization-sub-50mb.md "Build B — strip-all".
# The strip must NOT reach the App Store until the carry-forward build (Build A)
# has soaked >=1 update cycle — this script only makes the build; sequencing is
# the operator's responsibility (memory: project_v2_strip_release_sequencing).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models_root="$repo_root/Jot/Resources/Models"
stash_root="$repo_root/.model-stash"

# Leaf dirs to move, RELATIVE to Jot/Resources/Models. Parent dirs (Parakeet/)
# are intentionally left in place so project.yml's `- path: Resources/Models`
# resource reference stays valid (an empty folder bundles harmlessly).
leaves=(
  "Parakeet/parakeet-tdt-0.6b-v2"
  "Parakeet/parakeet-ctc-110m-coreml"
)

cmd="${1:-}"

case "$cmd" in
  stash)
    mkdir -p "$stash_root"
    moved=0
    for leaf in "${leaves[@]}"; do
      src="$models_root/$leaf"
      dst="$stash_root/$leaf"
      if [[ -d "$src" ]]; then
        if [[ -e "$dst" ]]; then
          echo "error: stash already holds '$leaf' — a prior stash never restored. Run 'restore' first." >&2
          exit 1
        fi
        mkdir -p "$(dirname "$dst")"
        mv "$src" "$dst"
        echo "stashed   $leaf"
        moved=$((moved + 1))
      elif [[ -d "$dst" ]]; then
        echo "already stashed   $leaf"
      else
        echo "error: '$leaf' missing from BOTH tree and stash — cannot build a valid strip." >&2
        exit 1
      fi
    done
    echo "stash complete ($moved moved). Resources/Models now stripped."
    ;;

  restore)
    restored=0
    for leaf in "${leaves[@]}"; do
      src="$stash_root/$leaf"
      dst="$models_root/$leaf"
      if [[ -d "$src" ]]; then
        if [[ -e "$dst" ]]; then
          echo "warn: '$leaf' already present in tree; leaving stash copy at $src" >&2
          continue
        fi
        mkdir -p "$(dirname "$dst")"
        mv "$src" "$dst"
        echo "restored  $leaf"
        restored=$((restored + 1))
      fi
    done
    # Clean up now-empty stash scaffolding (ignore failure if non-empty).
    find "$stash_root" -type d -empty -delete 2>/dev/null || true
    echo "restore complete ($restored restored)."
    ;;

  status)
    for leaf in "${leaves[@]}"; do
      in_tree="no"; in_stash="no"
      [[ -d "$models_root/$leaf" ]] && in_tree="yes"
      [[ -d "$stash_root/$leaf" ]] && in_stash="yes"
      printf "  %-40s tree=%s stash=%s\n" "$leaf" "$in_tree" "$in_stash"
    done
    ;;

  *)
    echo "usage: strip-models.sh {stash|restore|status}" >&2
    exit 1
    ;;
esac
