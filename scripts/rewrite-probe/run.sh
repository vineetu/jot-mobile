#!/bin/bash
# Runs Apple's on-device model on this Mac (macOS 27, Apple Intelligence on) with
# the app's REAL rewrite framing (Jot/Shared/LLM/RewriteInstructions.swift) and the
# built-in Cleanup prompt, over a fixed set of dictated questions and requests, and
# prints what the model returns. Use it before changing the framing or a default
# prompt: the model must return a rewrite, never an answer. No pass/fail
# heuristics on purpose — read the outputs.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
cp ../../Jot/Shared/LLM/RewriteInstructions.swift ../../Jot/Shared/LLM/Rewrite.swift main.swift "$OUT/"
swiftc -target arm64-apple-macos27.0 -parse-as-library "$OUT"/RewriteInstructions.swift "$OUT"/Rewrite.swift "$OUT"/main.swift -o "$OUT/probe"
"$OUT/probe" "$(pwd)/cleanup-prompt.txt"
