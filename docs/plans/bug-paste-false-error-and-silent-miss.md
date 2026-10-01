# Paste: false error banner over a landed paste, and silent misses (open, 2026-09-26)

**Owner report:** most pastes are fine; sometimes nothing pastes; sometimes the text lands AND an error shows.
**Status:** evidence gathering. No behaviour change until a real failing case is captured (no guessed thresholds).
Build 312: the per-flush `pasteSkipNoPayload` entry (6+ per dictation, evicting the 100-entry ring) now logs to
os_log only, and the three silent give-ups now reach Diagnostics as `pasteSkipOther` "Gave up on paste — …".

## Candidate false-error paths (from the code audit, `JotKeyboardViewController.swift`)
1. `settled-shrank` on a long paste: the settled read is the host's limited context window, so
   `before + paste` longer than the window reads as "shrank"; partial evidence never counts as survival
   (~2380-2400) → red "Couldn't paste here". Fingerprint: `branch=settled-shrank settledEvidence=partial
   settledOverlap==settledLen hasText=true`.
2. `hasText=false` while the context ends with the paste (web fields) → red. Fingerprint `stillEndsWith=true hasText=false`.
3. Host returns `""` instead of nil during a re-mount → counted as shrank, not disconnect. `settledLen=0`.
4. Host edits the tail (autocorrect/smart punctuation) → no-shrink rescue fails.
5. Caret moved after insert.
6. Disconnect after landing with weak immediate evidence → "Also saved to clipboard…" (reads as an error).
7. A stale `lastDictationStatusMessage` re-shown by `viewWillAppear` on a later good paste.

## Candidate silent-miss paths
1. `pasteSkipProxyDisconnected` on the final `.idle` flush → kept pending with no later trigger; expires at 30 s.
2. Cold start and the user returns > 30 s after publish.
3. Ghost keyboard controllers (no active-controller gate on the insert path) inserting into a dead proxy.
4. Session-ID mismatch / app-side pending clears (os_log only, `cross-process-recording`).
5. Teardown inside the verify window logs `pasteSuccess` unverified.

## How to diagnose a reported case
Pull Diagnostics via devicectl (App Group plist) and the device log (`sudo log collect --device-udid …`), follow one
session ID: `sessionStopRequested → publishResolved → publishCompleted → pasteReconnectPoll → outcome`, and match
the outcome row's metadata to the fingerprints above.

## Resolution (build 315, 2026-09-26)
Real case captured (build 313, session F5FCEDE4, 339 chars into a field holding 104): immediate read 443 (full),
settled read 104 = the pre-paste context, overlap 0, `settled-shrank` → red "Couldn't paste here". The owner saw the
text land and stay. That is the SAME fingerprint the Claude Code investigation used to mean "the host never took the
paste" (§5 table, "settledLen drops back"), so the settled read carries no information about landing in these hosts.
Fix: the settled read is logged (`pasteRevertedAfterLanding`, "treated as landed") and never shown as a failure; an
insert into a connected field is delivered. `PasteFallbackCopy` / `fallbackToClipboardWithBanner` removed. The
transcript remains on the clipboard from publish and tops the Recents card. Trade-off, stated: a host that truly
drops a paste now shows no banner (owner: pastes always land in practice).
