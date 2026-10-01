#!/bin/bash
# Post-converter step: the guideline cards are @dsCard HTML pages (not .md), so the
# converter's guidelinesGlob can't copy them — add them to ds-bundle/guidelines/ here.
set -e
cd "$(dirname "$0")/.."
mkdir -p ds-bundle/guidelines
cp guidelines/*.html ds-bundle/guidelines/
# The cards link ../styles.css — the bundle's styles.css is at the root, same relative spot.
echo "guidelines: $(ls guidelines/*.html | wc -l | tr -d ' ') cards copied"
