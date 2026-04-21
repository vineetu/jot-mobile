# Voice Interaction Patterns for Jot iOS

**Status:** design exploration, not an implementation spec.
**Audience:** whoever is about to pick a direction for Jot's next interaction layer.
**Author:** voice-interaction-designer (jot-mobile team).

---

## Frame

Today Jot on iOS is one gesture: Action Button → Parakeet transcribes → clipboard. Optional LLM cleanup is a binary toggle. Transcription is solved; the product shape is not.

The next layer is a **command language** on top of dictation. The user wants to *do* things with their words. Send. Shorten. Translate. Pipe. Ask. Email.

This document sketches the design space and ends with a recommendation.

---

## The design space

Four axes turn out to matter more than the others.

```
            In-utterance               │             Follow-up invocation
                                       │
   Explicit   "…and clean this up."    │   Tap 2 → "Make it concise."
              Reserved suffix.         │   Acts on previous output.
─────────────────────────────────────── + ───────────────────────────────────────
   Implicit   Model infers intent from │   Long-press Action Button to record
              context. No magic word.  │   a follow-up command on last text.
                                       │
```

The four quadrants are not mutually exclusive — they are **four doors into the same room**. The question is which doors Jot opens, and in what order.

Two additional axes cut across all four quadrants:

- **Predefined vocabulary ↔ Natural language.** Does the user learn five verbs, or can they speak casually and be understood?
- **App-centric ↔ Clipboard-centric.** Is the state a Jot document ("the last recording")? Or is it the system clipboard ("whatever is on the board right now")?

Alexa [chose predefined](https://developer.amazon.com/en-US/docs/alexa/custom-skills/understanding-how-users-invoke-custom-skills.html): `[wake] [launch] [invocation name] [connecting] [utterance]` — rigid grammar users learn. Apple's [App Shortcuts](https://developer.apple.com/design/human-interface-guidelines/siri/overview/shortcuts-and-suggestions/) require developers to enumerate synonyms by hand. Both chose determinism because voice has no undo and false positives are expensive.

Jot has an advantage those systems didn't: a fast on-device LLM layer. That lets us pick a different point — **natural language with a small invariant vocabulary at the edges**, not rigid phrase-matching through the middle.

---

## Six interaction patterns

Each is described as a flow + example + detection method + failure mode + prior art.

### 1. Suffix commands (explicit, in-utterance)

**Flow.** User dictates. At the end, they say a reserved phrase (`"…clean this up"`, `"…send to Sarah"`). Jot separates the dictation body from the command suffix and executes.

**Example.**
> "Hey Sarah, running late to the standup, be there in ten. **Send to Sarah on iMessage.**"
>
> → Sends "Hey Sarah, running late to the standup, be there in ten." via Messages to Sarah.

**Detection.** A small regex over the last 1–3 seconds of transcript, anchored by a reserved verb set: `clean up`, `tighten`, `send to`, `email to`, `ask ChatGPT`, `translate to X`. Match wins only if the verb appears in the *final clause*, preceded by a natural break (pause, "and," "then," or "okay"). If ambiguous, show a confirmation pill instead of acting.

**Failure mode.** User literally dictates "…and then clean this up, I said to the janitor." The regex fires; user is annoyed. Degrade by: (a) suffix must be the last clause with no trailing words, (b) 2-second Undo in the status pill, (c) **"literal: clean this up"** as an escape hatch.

**Prior art.** [Alexa's launch word + invocation name + utterance](https://developer.amazon.com/en-US/docs/alexa/custom-skills/understanding-how-users-invoke-custom-skills.html) — reserved grammar, learned vocabulary. Raycast's `?` prefix for help, `>` prefix for commands. Slack's `/` slash commands at end of line.

---

### 2. Chained follow-ups (explicit, post-invocation)

**Flow.** Tap 1 records raw → clipboard. Tap 2 records a command utterance; Jot treats it as an instruction on the current clipboard contents. Tap N continues piping.

**Example.**
> Tap 1: *"Dear team, I want to propose we move the all-hands to Thursdays…"* → clipboard has 300 words of draft.
> Tap 2: *"Make it three bullets, keep the call-to-action at the end."* → clipboard replaced with tightened version.
> Tap 3: *"Translate to Spanish."* → clipboard replaced with Spanish version.

**Detection.** Jot keeps a tiny session state: `lastTranscript`, `lastTimestamp`. If the Action Button fires within a short window (say 120s) AND the utterance parses as an **instruction** rather than prose, treat it as a follow-up. An LLM classifier ("is this an instruction on prior text, or a new dictation?") makes the call — Jot already [calls a classifier for its macOS Rewrite branch](./../../CLAUDE.md). Reuse that pattern.

**Failure mode.** User intends fresh dictation, Jot treats it as a follow-up. Mitigate with: explicit visual signal in the status pill ("CHAINING" vs "DICTATING"), and a two-tap escape ("double-tap to start fresh"). Also: if the new utterance is longer than ~12 words, bias toward fresh dictation — instructions are almost always short.

**Prior art.** [Unix pipes](https://en.wikipedia.org/wiki/Pipeline_(Unix)). McIlroy's 1964 formulation: *"We should have some ways of connecting programs like [a] garden hose — screw in another segment when it becomes necessary to massage data in another way"* ([Kleppmann, *DDIA*](https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/)). Also: Photoshop's non-destructive filter stack; Figma's action history.

---

### 3. Press-and-hold (walkie-talkie)

**Flow.** Hold Action Button → recording while held. Release → recording stops immediately, transcription runs.

**Example.** User holds button, says "remind me to buy milk," releases. Done.

**Detection.** Native — hardware already distinguishes hold from tap. No language processing involved.

**Failure mode.** User holds too briefly, nothing recorded. Mitigate with a 300ms minimum-hold floor (below which treat as accidental tap). User holds then forgets to release — recording stops on timeout (60s) with a haptic.

**Prior art.** [Every push-to-talk system since Motorola 1941](https://en.wikipedia.org/wiki/Push-to-talk). [Leor Grebler's analysis of tap-and-talk vs push-to-talk](https://medium.com/@grebler/tap-and-talk-vs-push-to-talk-3ce14919372b) lands on a useful dichotomy: tap is easier on the body but needs endpointing signals; hold is decisive (the button IS the endpoint signal) and produces cleaner audio. Voxer, Zello, Apple Watch Walkie-Talkie.

**The decision Jot has to make.** Is press-and-hold a *third input mode* (alongside tap-to-record), or is it specifically a *chain-on-previous command*? My recommendation: **make it the command mode.**

- **Tap** = dictation (fresh or chained, same affordance).
- **Hold** = command-on-previous. Release-triggered. Short by design. Distinct haptic. Distinct pill color.

This binds press-and-hold to a meaningful semantic difference (not just ergonomics) and gives Jot a discoverable second channel without adding a third gesture.

---

### 4. Implicit routing (no reserved word)

**Flow.** User speaks. Jot's classifier decides on its own whether the utterance is pure dictation, cleanup-worthy, or routing-worthy.

**Example.**
> "Text Marcus that I can't make lunch."
>
> → Jot infers: this is a *message to compose*, not a memo to dictate. Opens Messages with Marcus selected, "I can't make lunch" in the composer.

**Detection.** Post-transcription LLM classifier with a tiny schema:
```
{kind: "dictate" | "clean" | "route", target?: contact|app, body?: string}
```

**Failure mode.** Huge. The user dictated a memo that *happened to start with "text Marcus"* ("Text Marcus that I can't make lunch — note to self, finish the deck first"). Wrong classification destroys intent. Mitigate with (a) **always** route through a confirmation pill for `kind: route`, (b) a strong prior toward `kind: dictate` when the utterance is long, (c) a per-user calibration — first week is conservative, relaxes as false positives stay low.

**Prior art.** [Stephen Wolfram's observation](https://writings.stephenwolfram.com/2023/02/what-is-chatgpt-doing-and-why-does-it-work/) that for "human-like tasks," end-to-end neural training beats hand-engineered pipelines. Conversely, [Anthropic's "Building Effective Agents"](https://www.anthropic.com/engineering/building-effective-agents) argues: *"Maintain simplicity in your agent's design. Prioritize transparency by explicitly showing the agent's planning steps."* Implicit routing violates the latter principle — the user can't see the plan. That's the cost.

**Designer's intuition:** implicit routing sounds magical in demo and feels hostile in daily use. Ship it last, behind a flag, with a big "Undo" affordance.

---

### 5. Voice slash commands (explicit, prefix)

**Flow.** User prefixes the utterance with a reserved opener: `"Jot command: send to Sarah, 'running late'"` or `"slash email: Sarah, running late to standup"`.

**Example.**
> *"Slash email to product-team: heads up, the onboarding deck has a typo on slide 4, fixing now."*
>
> → Composes email, subject inferred, body = the rest.

**Detection.** Literal prefix match at the start of the utterance. No LLM needed for detection itself. The LLM only does the downstream parsing (parse "to product-team" into recipients, generate a subject line, etc.).

**Failure mode.** Low. The prefix is unambiguous. The cost is user effort: they have to remember the prefix exists.

**Prior art.** Slack's `/remind`, `/poll`, `/call`. Discord bots. [Raycast commands](https://manual.raycast.com/). VS Code command palette (`⌘⇧P`). These all work because users *learn the palette* — but they learn it because the palette is *visible*. A voice palette that users can't see is a memorability gamble.

---

### 6. In-utterance metacommands (parenthetical)

**Flow.** The user interjects a formatting or routing instruction mid-dictation, parenthetically, and Jot strips it from the body and applies it.

**Example.**
> *"Dear team, — **new paragraph** — I want to propose — **open quote** — moving the all-hands — **close quote** — to Thursdays. **Dash dash, send this to the whole team.**"*

**Detection.** Reserved tokens for typography (`new paragraph`, `open quote`, `period`, `question mark`) are resolved inline during transcription post-processing — this is how macOS dictation has worked for 15 years. Routing metacommands (`send this to…`) at the end get the Pattern 1 treatment.

**Failure mode.** Same as Pattern 1 — literal usage of a reserved phrase. Recovery is the same. The typography commands are a very mature space; copy macOS/iOS dictation's rules verbatim.

**Prior art.** [iOS/macOS Dictation's punctuation commands](https://support.apple.com/en-us/111946). Dragon NaturallySpeaking (20+ years of exactly this). Court stenography conventions.

---

## Command grammar sketch

A small verb-noun vocabulary Jot can commit to, extend, and teach.

| Verb class | Words | Noun it acts on |
|---|---|---|
| **Refine** | `clean`, `tighten`, `summarize`, `expand`, `bullet`, `translate to X` | current clipboard / last transcript |
| **Route** | `send to X`, `email to X`, `text X`, `post to Slack` | current clipboard |
| **Ask** | `ask ChatGPT`, `ask Claude`, `ask Gemini` | current clipboard (as prompt) |
| **Meta** | `undo`, `redo`, `literal`, `cancel` | interaction state |

Christina Engelbart's OHS framework describes this exactly: *"a Command Meta Language describes users' available operations (verbs) on classes of objects (nouns) in grammatical descriptions of tools"* ([OHS Framework](https://dougengelbart.org/content/view/110/460/)). This is older than UNIX and it still holds. Jot's vocabulary is a Command Meta Language. Ship four verbs first. Don't ship ten.

**Discoverability** is the hard part. Voice interfaces fail the [Don Norman signifier test](https://jnd.org/affordances-and-design/) — you can't see the affordance. Three options:

1. **In-app cheat sheet.** A Help tab lists the vocabulary. Users who pull it up once remember most of it.
2. **Help-in-context.** Say *"what can I say?"* → Jot shows the grammar overlay.
3. **Progressive disclosure via the status pill.** After dictation, a subtle ghost-text hint: *"say 'clean up' to refine"*. Fades after 3 uses.

Recommend all three, layered: option 2 is the floor (one voice command that never fails is a lifeline), option 3 is the teaching surface, option 1 is the reference.

---

## The zen master section

The deepest insight is older than voice UI and it came up three times independently during research.

> **Dictation and manipulation are the same act.**

Everything you can dictate, you can manipulate. Everything you can manipulate, you dictate the manipulation. The current Jot model splits them: transcription is one button-press, cleanup is a toggle buried in settings. That split is arbitrary. Text enters the system through the microphone, and text mutates through the microphone, and the only difference is which verb the user chose.

Three consequences:

- **No "settings toggle" for cleanup.** Cleanup is a command you invoke on text. The toggle was a frozen default nobody wanted.
- **Integrations are not a separate feature.** *"Send to Sarah"* is a verb in the same vocabulary as *"tighten"*. Email, ChatGPT, Slack, Linear — each adds a verb, not a new mode.
- **Press-and-hold is the command channel, not a new gesture.** Tap writes, hold commands.

This descends from two traditions: the Unix pipeline (McIlroy's garden hose, Kleppmann's uniform interface — every stage reads text, writes text, composes) and Engelbart's Command Meta Language (verbs on nouns, in grammar, across tools). Nielsen's *"reify deep principles about the world in the interface"* makes it concrete: the principle is that **text is liquid**. It flows from voice, through verbs, out to places. The interface should make that flow visible.

The clipboard is not incidental. **The clipboard is the state machine.** Everything is a transform on clipboard contents. Even dictation is "transform silence into text, write to clipboard." Once you see this, the rest of the design falls out.

---

## Recommended path forward

Ship two patterns first, in this order:

**(1) Chained follow-ups (Pattern 2) on tap.** This is the lowest-risk, highest-leverage move. The current Jot already has one-tap dictation; extend it so a second tap within 120 seconds routes the utterance through the classifier as an instruction on the last transcript. No new gesture, no new screen. The pill state changes from `DICTATING` to `CHAINING`. Prototype cost: low. User value: the "clean up" toggle retires itself.

**(2) Press-and-hold as dedicated command mode (Pattern 3).** Once chained follow-ups work, give commands a dedicated affordance. Hold = "I'm about to issue a command on the current clipboard." Release = execute. This gives the verb vocabulary a physical home and makes the tap/hold distinction semantic, not ergonomic.

**Not first:** implicit routing (Pattern 4) and in-utterance suffix commands (Pattern 1). Both have non-trivial failure modes and benefit from the learnings of 1 and 2. Ship them as v2.

**Never:** voice slash commands (Pattern 5) as a standalone. They're a fallback on the other patterns — if the classifier misses, the user can always say `"slash ..."` to force a command interpretation. Keep as a safety net, not a headline feature.

---

## Open questions

- **Session window for chaining.** 120s is a guess; real data will say.
- **Classifier latency.** Apple Foundation Models is fast enough. Cloud providers add 300–1200ms between utterance-end and execution — is that acceptable?
- **Undo horizon.** Probably 3 transforms back. Deeper than that and the user is starting over.
- **Contact resolution.** "Send to Sarah" — which Sarah? This is where voice UIs always get ugly. Needs its own design pass.

---

## What I read to get here

Readwise library (user's own):
- [Engelbart/OHS Framework](https://readwise.io/open/964570731) — Command Meta Language, verbs on nouns.
- [Kleppmann / McIlroy's pipes](https://readwise.io/open/845588623) — the garden hose, uniform interface.
- [Nielsen, *Thought as a Technology*](https://readwise.io/open/926422929) — reify deep principles.
- [Appleton, *The Expanding Dark Forest*](https://readwise.io/open/581946448) — la langue vs la parole; formal vocabulary vs speech of everyday life.
- [Wolfram on end-to-end speech](https://readwise.io/open/862367872) — don't over-engineer the pipeline.
- [Anthropic, *Building Effective Agents*](https://readwise.io/open/845150844) — simplicity, transparency, agent-computer interface.
- [Boris Cherny, Claude Code `/voice`](https://read.readwise.io/read/01kn0s20vm30qkde6mzzw7pvam) — modern voice-coding UX.

Web prior art:
- [Alexa invocation model](https://developer.amazon.com/en-US/docs/alexa/custom-skills/understanding-how-users-invoke-custom-skills.html).
- [Apple App Shortcuts phrase design (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/10169/).
- [Leor Grebler on tap vs push-to-talk](https://medium.com/@grebler/tap-and-talk-vs-push-to-talk-3ce14919372b).
- [Norman on affordances and signifiers](https://jnd.org/affordances-and-design/).
- Superwhisper / Granola / Otter landscape — [2025 comparisons](https://willowvoice.com/blog/superwhisper-vs-otter-ai-comparison-2025) and [Granola's "amplify not replace" stance](https://pjaicontentmastery.wordpress.com/2026/02/16/showdown-otter-ai-vs-granola-stop-transcribing-start-synthesizing/).

Labeled as "designer's intuition" and not established practice:
- 120s session window for chained follow-ups.
- The 12-word heuristic for distinguishing instructions from fresh dictation.
- The claim that implicit routing (Pattern 4) feels hostile in daily use — this is an inference from analogous systems, not a validated user test.
