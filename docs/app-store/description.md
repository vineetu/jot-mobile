# Jot — App Store Listing

## Research findings

Apple's [product page guidance](https://developer.apple.com/app-store/product-page/) sets the hard limits: Name 30, Subtitle 30, Promotional Text 170, Description 4000, Keywords 100 (comma-separated, no spaces between commas). Subtitle must *summarize* — not repeat the name. Promotional Text sits above the description, is editable without a build, and does **not** affect search ranking. The Description's *first sentence* is the single most-read line — it's all that shows before the "more" cut at ~170 chars / 3 lines.

The 2025 ASO consensus ([ASOMobile](https://asomobile.net/en/blog/lesson-3-text-optimization-for-the-app-store/), [Apptweak](https://www.apptweak.com/en/aso-blog/app-store-description-best-practices), [SplitMetrics](https://splitmetrics.com/blog/app-store-description-guide/), [Adapty](https://adapty.io/blog/app-store-description/)) agrees: on iOS the description is **not indexed**, so write it for humans and conversion, not keywords. The recurring structure: hook (1–2 sentences) → 1–3-sentence paragraphs → ALL-CAPS section anchors → text-based bullets.

Real indie descriptions confirm it. [Drafts](https://apps.apple.com/us/app/drafts/id1236254471) opens with the tagline "Where text starts" then one promise sentence, then ALL-CAPS headers (CAPTURE EVERYWHERE / USE YOUR WORDS). [Bear](https://apps.apple.com/us/app/bear-markdown-notes/id1016366447) leads with audience naming. [Superwhisper](https://apps.apple.com/us/app/superwhisper/id6471464415) — the closest dictation competitor — opens with the core mechanic ("Hold to record. Release to paste."). None lead with adjectives; all lead with what the app physically *is*. Two patterns Jot should avoid: Superwhisper's "5x faster" headline (gives up the ground we own — privacy + system-wide keyboard) and Wispr Flow's AI-polish lead (Jot's AI is opt-in, 2.5 GB).

## Recommended structure rationale

The three use cases from `HelpView.swift`'s "What it's for" section already do the conversion work — situational, not feature-listy, mapping to moments a buyer recognizes. The description uses them as the spine under ALL-CAPS anchors. The opening sentence describes the physical mechanic (a keyboard you switch to with the globe key) so the first-3-lines viewer instantly grasps what Jot *is* — the thing that distinguishes it from every in-app voice recorder. Privacy gets its own band because it's a buying decision and the marketing site treats it as peer content.

---

## App Name
Jot — Dictation Keyboard (24 / 30)

## Subtitle
Dictate in any app. On device. (30 / 30)

## Promotional Text
v0.9.5 — better paragraph breaks, smarter numbers ("twenty-five dollars" becomes "$25"), and an in-app feedback form. No account. On device. (140 / 170)

## Description
A dictation keyboard for iPhone. Switch to Jot from any app — Messages, Mail, Slack — tap Dictate, and your voice goes into the text field you're in.

No account. No cloud. Nothing leaves your iPhone.

SPEAK INSTEAD OF TYPING, IN ANY APP

You're in Messages, Mail, Slack, your browser — anywhere you'd normally type. Tap the globe key on your iPhone keyboard to switch to Jot, tap Dictate, and speak. Your voice goes straight into the text field you're already in.

KEEP GOING WHEN LIFE INTERRUPTS

Your phone rings mid-sentence. Someone hands you something. You jump into Calendar to check a date. Come back, and Jot's microphone is still warm — up to five minutes, ready to pick up where you left off.

What you'd already said is saved as you said it. Even if everything drops, the part you'd already dictated is safe and waiting in the text field.

POLISH WHAT YOU SAID INTO WHAT YOU MEANT

You dictated something long and meandering. Open it in Jot and tap a built-in prompt:

· Articulate — cleans up the prose
· Action Items — pulls out the tasks
· Email — formats it for sending

Or write your own prompt — with your voice. "Turn this into bullet points." "Translate to French." "Make it sound more formal." Save it once, run it on any transcript with a tap.

WHAT'S INSIDE

· System-wide custom keyboard — works in any text field on iPhone
· Recents strip — last 10 dictations one tap away to re-insert
· Five-minute warm microphone across app switches and calls
· On-device transcription using Apple's speech models, plus optional Parakeet 600M
· On-device AI rewrite (optional 2.5 GB download)
· Custom rewrite prompts you write once and reuse
· Vocabulary list for names and technical terms
· Action Button support and a "Transcribe Audio with Jot" Shortcuts action

YOUR DATA

· Transcription runs on device. Audio never leaves your iPhone.
· AI rewrites run on device too.
· No account. No sign-in. No cloud sync. No analytics. No third-party SDKs.
· Transcripts live in the app, on your phone, until you delete them.

REQUIREMENTS

· iOS 26 or later. iPhone with A14 chip or newer.
· Optional AI rewrite: iPhone 15 Pro and later, 2.5 GB download.
· English at launch. More languages to follow.

Free to download. No subscription. No ads. No upsell.

Made on-device, made for you.

(2332 / 4000)

## Keywords
dictation,voice,keyboard,transcribe,speech,text,mic,notes,memo,offline,private,whisper,parakeet (98 / 100)

## What's New in This Version (v0.9.5)

Better paragraph breaks. The segmenter now reads 1.4-second pauses and discourse markers ("so", "anyway", "next") as paragraph cues, so long dictations land in shaped paragraphs instead of one wall.

Smarter numbers. "Twenty-five dollars" becomes "$25." "Five thirty" becomes "5:30." AP-style numerals throughout. Idioms ("once in a lifetime") stay as words.

In-app feedback. Settings → Help → Send feedback. We read every message.

Smaller fixes:
· Recents swipe-to-delete and Mail-style bulk select
· Keyboard dictate path: every silent-drop site now surfaces an error
· Warm-hold reliability tightened around the 60s edge
· Rewriting pill color fix in dark mode

(665 / 4000)

---

## Alternates / variants to consider

**Subtitle alternates:**
· "Voice keyboard. Any app." (24 / 30) — punchier, drops the privacy beat
· "Dictate anywhere, on device." (29 / 30) — leads with privacy
· "Speak in any app. Privately." (28 / 30) — combines both

**Opening hook alternates** (the first sentence is the single most-read line; worth A/B'ing):
1. *Mechanic-first* (current): "A dictation keyboard for iPhone. Switch to Jot from any app — Messages, Mail, Slack — tap Dictate, and your voice goes into the text field you're in."
2. *Promise-first*: "Speak in any app on your iPhone. Jot is a dictation keyboard — switch to it with the globe key, tap Dictate, and your words land in the text field you're already in."
3. *Privacy-first*: "Dictate in any app on your iPhone, with nothing leaving the device. Jot is a system-wide dictation keyboard — switch to it, tap Dictate, speak."

**Name alternates:**
· "Jot" (3 / 30) — current; pure brand, weakest for search
· "Jot — Dictation Keyboard" (24 / 30) — recommended; clarifies the category in the storefront tile
· "Jot: Voice Keyboard" (19 / 30) — slightly more conversational
