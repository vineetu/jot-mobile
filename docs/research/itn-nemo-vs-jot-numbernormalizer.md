# Number/ITN: FluidAudio NeMo ITN vs jot-shared NumberNormalizer (2026-09-27)

Probe: scratchpad `itncompare` (FluidAudio 0.17.4 `TextNormalizer.normalizeSentence` = NeMo sentence ITN with its
NLTagger masking, vs `JotTextPipeline.NumberNormalizer.normalize`). Input: 89 real sentences with spelled numbers from
the owner's Jot-for-Mac raw transcripts; they disagree on 66.

NeMo errors on real English dictation (none of these from Jot): "sixteen to twenty" → "19:44"; "one to four" →
"03:59"; "three four" → "03:04"; "one and two and" → "12"; "Five Nine Two" → "592"; "and one" / "a one" deleted;
every "one" → "1" ("1 of them"), every "first" → "1st"; "million" → "1000000"; "period," → ".,";
"one thousand five hundred dollars" → "$100500"; "twenty twenty five and one of them" → "2026 of them".
Jot misses: "one fifty dollars" → "one $50" (NeMo: $150); "a dollar fifty" → "a dollar 50" (NeMo same).
Verdict: NeMo sentence ITN is worse for English dictation; keep NumberNormalizer and fix its money-shorthand gap
in jot-shared (with fixtures, shared with Mac/Windows).

Non-English (NeMo `nemo_normalize_sentence_lang`, handful of constructed sentences only — NOT real data):
de/fr/ja dates, money, times, percentages came out right ("fünften März um drei Uhr dreißig" → "5. Mär. um 03:30 Uhr",
"quinze heures trente" → "15 h 30", "三月五日" → "3月5日"); Spanish "y uno de ellos" → "1 de ellos" (dropped "y").
Needs real non-English transcripts before enabling.
Engine-independent: ITN is text-in/text-out, so it applies equally to Apple-engine output
(`applyLanguageCleanup` already runs on Apple stop-pass text).

## Fixes shipped (jot-shared NumberNormalizer, iOS build 318, 2026-09-27) — jot-shared change UNCOMMITTED
1. Money shorthand: "<1–19> <10–99> dollars|bucks" → $XYY ("one fifty dollars" → $150, "twelve fifty dollars" →
   $1,250). Requires the currency word.
2. Phrase-final cents: "<n> dollar(s) <10–99>" and "a dollar <10–99>" → $n.cc only when the cents number ends the
   phrase ("a dollar fifty." → $1.50; "five dollars twenty times" unchanged).
3. Unhyphenated years without a context word: century + two-digit (teen/tens/tens+ones, never bare 1–9) in
   1910–1999 / 2010–2039 → year ("twenty twenty five" → 2025), unless the previous word is a number (counting runs).
New fixtures only (existing fixtures untouched): number_normalizer_money_shorthand.json,
number_normalizer_years_unhyphenated.json; swift test green.
Regression replay, old vs new, on ALL real text: owner's 24,933 phone sentences + 903 Mac raw sentences → changes:
"seven eighty one dollars" 7 $81 → $781 (×2, correct), "just to be honest 20 22" → 2022 (correct), one garbled
"twenty twenty two thousand twenty two" (wrong before and after). A counting-run false positive ("18 1920") was found by
this replay and fixed before shipping.
