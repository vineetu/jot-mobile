// Review Jot's Corrections — sample data + verdict copy logic.
// Plain JS (no JSX). Exposes window.JOT_REVIEW.

window.JOT_REVIEW = (() => {

  // tokens: strings, or { id, w } word slots the gate touched.
  // proposals: outcome 'applied' (Jot wrote `term`) | 'kept' (Jot left `original`).
  //   slots = occurrences in this transcript. prior = confirmations from earlier
  //   transcripts (graduates to automatic at 3).

  const SCENARIOS = {
    typical: {
      meta: '2 hours ago · 64 words · 0:31',
      tokens: [
        'Quick note before standup — ping ', { id: 'w_jamy', w: 'Jamy' },
        ' about the review queue, and ask if ', { id: 'w_show', w: 'show' },
        ' can make it. The gate changes are in ', { id: 'w_cc', w: 'claude code' },
        ' now, so the ', { id: 'w_n1', w: 'name' },
        ' detection should improve. If the ', { id: 'w_n2', w: 'name' },
        ' still slips through, lower the margin a touch. And check whether the ',
        { id: 'w_n3', w: 'name' }, ' list needs another pass before Friday.',
      ],
      proposals: [
        { id: 'p1', outcome: 'applied', original: 'Jamie', term: 'Jamy', slots: ['w_jamy'], prior: 2 },
        { id: 'p2', outcome: 'applied', original: 'cloud code', term: 'claude code', slots: ['w_cc'], prior: 0 },
        { id: 'p3', outcome: 'kept', original: 'show', term: 'Sho', slots: ['w_show'], prior: 1 },
        { id: 'p4', outcome: 'kept', original: 'name', term: 'Jamy', slots: ['w_n1', 'w_n2', 'w_n3'], prior: 0, unsure: true },
      ],
    },

    heavy: {
      meta: '12 minutes ago · 118 words · 1:04',
      tokens: [
        'Quick note before standup — ping ', { id: 'h_j1', w: 'Jamy' },
        ' about the review queue, and ask if ', { id: 'h_show', w: 'show' },
        ' can make it. The gate changes are in ', { id: 'h_cc1', w: 'claude code' },
        ' now, so the ', { id: 'h_n1', w: 'name' },
        ' detection should improve. If the ', { id: 'h_n2', w: 'name' },
        ' still slips through, lower the margin, and check whether the ',
        { id: 'h_n3', w: 'name' }, ' list needs another pass. Separately — ',
        { id: 'h_j2', w: 'Jamy' }, ' wants the ', { id: 'h_mir', w: 'mirror' },
        ' board cleaned up before Friday, and ', { id: 'h_ren', w: 'Renat' },
        ' asked for a ', { id: 'h_cc2', w: 'claude code' },
        ' walkthrough after lunch. The ', { id: 'h_n4', w: 'name' },
        ' matching is the long pole here; if the ', { id: 'h_n5', w: 'name' },
        ' mapping holds through the week, we ship.',
      ],
      proposals: [
        { id: 'q1', outcome: 'applied', original: 'Jamie', term: 'Jamy', slots: ['h_j1', 'h_j2'], prior: 2 },
        { id: 'q2', outcome: 'applied', original: 'cloud code', term: 'claude code', slots: ['h_cc1', 'h_cc2'], prior: 0 },
        { id: 'q3', outcome: 'applied', original: 'renata', term: 'Renat', slots: ['h_ren'], prior: 1 },
        { id: 'q4', outcome: 'kept', original: 'show', term: 'Sho', slots: ['h_show'], prior: 1 },
        { id: 'q5', outcome: 'kept', original: 'name', term: 'Jamy', slots: ['h_n1', 'h_n2', 'h_n3', 'h_n4', 'h_n5'], prior: 0, unsure: true },
        { id: 'q6', outcome: 'kept', original: 'mirror', term: 'Miro', slots: ['h_mir'], prior: 0, unsure: true },
      ],
    },

    clean: {
      meta: 'Yesterday · 38 words · 0:19',
      tokens: [
        'Remember to move the dentist appointment to Thursday morning, and pick up the dry cleaning on the way back. ',
        'Also: the kitchen tap is still dripping — call the plumber if it gets worse over the weekend.',
      ],
      proposals: [],
    },
  };

  // vocabulary terms shown on the Vocabulary screen, per scenario
  const VOCAB_TERMS = {
    typical: ['Jamy', 'claude code', 'Sho', 'Miro'],
    heavy: ['Jamy', 'claude code', 'Sho', 'Miro', 'Renat'],
    clean: ['Jamy', 'claude code', 'Sho', 'Miro'],
  };

  const LEARN_AT = 3; // confirmations before a mapping goes automatic

  // ── verdict semantics ─────────────────────────────────────────────
  // verdict: 'term' (I meant the vocab term) | 'original' (I meant what I said)

  // does this verdict edit the visible text? (only when the word appears exactly once)
  function editsText(p, verdict) {
    if (p.slots.length !== 1) return false;
    if (p.outcome === 'applied' && verdict === 'original') return true;  // revert
    if (p.outcome === 'kept' && verdict === 'term') return true;         // apply now
    return false;
  }

  // word displayed in a slot given the verdict (null verdict = as transcribed)
  function slotWord(p, verdict) {
    const base = p.outcome === 'applied' ? p.term : p.original;
    if (!verdict) return base;
    if (editsText(p, verdict)) return verdict === 'term' ? p.term : p.original;
    return base;
  }

  function confirms(p, verdict) {
    return p.prior + (verdict === 'term' ? 1 : 0);
  }

  function graduated(p, verdict) {
    return verdict === 'term' && confirms(p, verdict) >= LEARN_AT;
  }

  // resolved-row copy. Returns { strong, rest, learned }
  function resolvedCopy(p, verdict) {
    const n = p.slots.length;
    if (verdict === 'term') {
      if (graduated(p, verdict)) {
        return {
          strong: 'Learned',
          rest: ` — “${p.original}” becomes ${p.term} automatically from now on.`,
          learned: true,
        };
      }
      if (p.outcome === 'applied') {
        return { strong: p.term, rest: ' confirmed — Jot keeps fixing this.' };
      }
      // kept + meant term
      if (n === 1) {
        return { strong: p.term, rest: ' — updated here, and Jot’s learning it.' };
      }
      return {
        strong: p.term,
        rest: ` — learned for next time. “${p.original}” appears ${n} times here, so Jot left the text alone.`,
      };
    }
    // verdict === 'original'
    if (p.outcome === 'applied') {
      if (n === 1) {
        return { strong: p.original, rest: ' restored — Jot will leave it alone.' };
      }
      return {
        strong: p.original,
        rest: ` is your word — Jot will stop changing it. It changed ${n} spots here; edit the text if needed.`,
      };
    }
    return { strong: p.original, rest: ' kept — Jot will stop asking.' };
  }

  // microcopy for the unresolved row, per verdict style
  function rowNote(p) {
    return p.outcome === 'applied'
      ? `Jot wrote this for “${p.original}”`
      : `Jot heard “${p.original}” and left it`;
  }

  // ── keyboard ask policy ───────────────────────────────────────────
  // The keyboard only asks about guesses worth asking: mappings already
  // part-way to automatic (closest first), then low-margin ('unsure')
  // decisions. Confident one-off decisions wait on the transcript.
  // Hard cap of 3 — the keyboard is never a wall.
  function selectAsks(proposals, verdictOf) {
    return proposals
      .filter((p) => !verdictOf(p) && (p.prior > 0 || p.unsure))
      .sort((a, b) => b.prior - a.prior)
      .slice(0, 3);
  }

  // context snippet around a slot: { before, after } (trimmed, with ellipses)
  function contextFor(tokens, slotId) {
    const i = tokens.findIndex((t) => typeof t !== 'string' && t.id === slotId);
    if (i < 0) return { before: '…', after: '…' };
    const str = (t) => (typeof t === 'string' ? t : t.w);
    let before = tokens.slice(0, i).map(str).join('');
    let after = tokens.slice(i + 1).map(str).join('');
    if (before.length > 19) before = '…' + before.slice(-19).replace(/^\S*\s/, '');
    if (after.length > 19) after = after.slice(0, 19).replace(/\s\S*$/, '') + '…';
    return { before, after };
  }

  // keyboard recents strip — idle rows (newest first; row 1 is filled in live)
  const RECENTS = [
    { time: '2:02 PM', text: 'I think it’s a good idea.' },
    { time: '1:56 PM', text: 'What are you waiting for me for? Go ahead…' },
  ];

  return { SCENARIOS, VOCAB_TERMS, LEARN_AT, RECENTS, editsText, slotWord, confirms, graduated, resolvedCopy, rowNote, selectAsks, contextFor };
})();
