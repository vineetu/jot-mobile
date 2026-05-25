#!/usr/bin/env bash
# check-schema-frozen.sh — enforce the Flyway "frozen migration" rule.
#
# Rule: once a `JotSchemaVN.swift` file is in a shipped build, that file
# is FROZEN. New fields ship as `JotSchemaV(N+1).swift` + a new
# `MigrationStage` in `JotMigrationPlan.swift`. NEVER edit a previously-
# shipped VersionedSchema in-place.
#
# This script blocks PRs that violate the rule. It compares the working
# tree (or staged diff) against `origin/main` and fails if any
# `Jot/Shared/Schema/JotSchemaV*.swift` file is touched whose N is not
# the maximum N present.
#
# Usage:
#   ./scripts/check-schema-frozen.sh           # check vs origin/main
#   BASE_REF=HEAD~1 ./scripts/check-schema-frozen.sh  # check vs other ref
# Exit 0 = pass. Non-zero = violation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BASE_REF="${BASE_REF:-origin/main}"

red()    { printf "\033[31m%s\033[0m\n" "$1"; }
green()  { printf "\033[32m%s\033[0m\n" "$1"; }

# Find the highest N in the working tree. If only V1 exists, max = 1.
schema_dir="Jot/Shared/Schema"
if [ ! -d "$schema_dir" ]; then
    red "FAIL — $schema_dir doesn't exist. Run from repo root."
    exit 1
fi

max_n=$(ls "$schema_dir" 2>/dev/null \
    | grep -oE 'JotSchemaV[0-9]+\.swift' \
    | grep -oE '[0-9]+' \
    | sort -n | tail -1 || echo 0)

if [ -z "$max_n" ] || [ "$max_n" -eq 0 ]; then
    green "OK — no JotSchemaVN.swift files yet; nothing to enforce."
    exit 0
fi

# Find any JotSchemaVN.swift files modified vs BASE_REF where N != max.
# `|| true` on the grep handles the no-match case under set -e + pipefail.
#
# NOTE on local pre-commit use: `git diff --name-only` skips UNTRACKED
# files. If a contributor creates a new JotSchemaV(N+1).swift but hasn't
# `git add`-ed it yet, this script will pass even if they also edited
# the older VN file. The CI / merge-time invocation (PR diff) sees both
# files correctly because the PR has them staged. For local pre-commit
# hooks, run `git add Jot/Shared/Schema/` before running this script to
# get the same coverage.
changed_files=$(git diff --name-only "$BASE_REF" -- "$schema_dir" 2>/dev/null \
    | grep -oE 'JotSchemaV[0-9]+\.swift' || true)

violations=""
if [ -n "$changed_files" ]; then
    while IFS= read -r f; do
        n=$(echo "$f" | grep -oE '[0-9]+')
        if [ "$n" -ne "$max_n" ]; then
            violations+="$f (V$n, but max is V$max_n)"$'\n'
        fi
    done <<< "$changed_files"
fi

if [ -n "$violations" ]; then
    red "FAIL — frozen schema file(s) modified:"
    echo "$violations" | sed 's/^/  /'
    red ""
    red "Once a JotSchemaVN.swift file is in a shipped build, it must"
    red "never be edited. Add fields by creating JotSchemaV(N+1).swift"
    red "and a new MigrationStage in JotMigrationPlan.swift."
    red "See docs/schema-migrations.md."
    exit 1
fi

green "OK — no frozen schema files modified (max version: V$max_n)."
exit 0
