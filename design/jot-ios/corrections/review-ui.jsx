// Review Jot's Corrections — presentational components.
// Loaded via Babel. Depends on window.JOT_REVIEW (review-data.js).

const RV = window.JOT_REVIEW;

// ── glyphs (stroke-based, round caps — SF Symbols equivalents) ──────────────
function GChevronL({ size = 18, color = 'var(--chrome-glyph)' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M14.5 5L7.5 12l7 7" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}
function GChevronR({ size = 14, color = 'var(--ink-caption)' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M9 5l7 7-7 7" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}
function GCheck({ size = 15, color = 'var(--jot-blue-flat)' }) {
  return (
    <svg className="rv-check" width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M4.5 12.5l5 5L19.5 7" stroke={color} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}
function GTrash({ color = 'var(--glyph-soft)' }) {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
      <path d="M4 6.5h16M9.5 6V4.5a1.5 1.5 0 011.5-1.5h2a1.5 1.5 0 011.5 1.5V6M6.5 6.5l1 13a1.6 1.6 0 001.6 1.5h5.8a1.6 1.6 0 001.6-1.5l1-13M10 11v6M14 11v6"
        stroke={color} strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}
function GPencil({ color = 'var(--glyph-soft)' }) {
  return (
    <svg width="21" height="21" viewBox="0 0 24 24" fill="none">
      <path d="M4 20l.9-3.6L16.4 4.9a2 2 0 012.8 0l-.1-.1a2 2 0 010 2.9L7.6 19.1 4 20z"
        stroke={color} strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}
function GCopy({ color = 'var(--glyph-soft)' }) {
  return (
    <svg width="21" height="21" viewBox="0 0 24 24" fill="none">
      <rect x="8.5" y="8.5" width="11" height="12.5" rx="2.5" stroke={color} strokeWidth="1.9"></rect>
      <path d="M5.5 15.5h-1A1.5 1.5 0 013 14V4.5A1.5 1.5 0 014.5 3H12a1.5 1.5 0 011.5 1.5v1"
        stroke={color} strokeWidth="1.9" strokeLinecap="round"></path>
    </svg>
  );
}
function GSparkle({ size = 17, color = '#fff' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M12 2.5c.7 4.6 2.9 6.8 7.5 7.5-4.6.7-6.8 2.9-7.5 7.5-.7-4.6-2.9-6.8-7.5-7.5 4.6-.7 6.8-2.9 7.5-7.5z" fill={color}></path>
      <path d="M19 15.5c.35 2.3 1.45 3.4 3.75 3.75-2.3.35-3.4 1.45-3.75 3.75-.35-2.3-1.45-3.4-3.75-3.75 2.3-.35 3.4-1.45 3.75-3.75z" fill={color} opacity="0.85"></path>
    </svg>
  );
}

// ── learning progress dots ───────────────────────────────────────────────────
function Dots({ count, total }) {
  return (
    <span className="rv-dots" aria-hidden="true">
      {Array.from({ length: total }, (_, i) => (
        <span key={i} className={'rv-dot' + (i < count ? ' on' : '')}></span>
      ))}
    </span>
  );
}

// ── transcript body with inline marks ────────────────────────────────────────
// slotInfo: { [slotId]: { proposal, word, resolved } }
function TranscriptBody({ tokens, slotInfo, marksOn, onWordTap, flashKeys }) {
  return (
    <p className="rv-body">
      {tokens.map((t, i) => {
        if (typeof t === 'string') return <React.Fragment key={i}>{t}</React.Fragment>;
        const info = slotInfo[t.id];
        if (!info) return <span key={t.id}>{t.w}</span>;
        const mark = !marksOn || info.resolved ? 'm-off'
          : info.proposal.outcome === 'applied' ? 'm-applied' : 'm-kept';
        const cls = [
          'rv-word', mark,
          marksOn && !info.resolved ? 'markable' : '',
          flashKeys[t.id] ? 'flash' : '',
        ].join(' ');
        return (
          <span
            key={t.id + (flashKeys[t.id] || '')}
            className={cls}
            onClick={marksOn && !info.resolved ? (e) => onWordTap(info.proposal, t.id, e) : undefined}
          >{info.word}</span>
        );
      })}
    </p>
  );
}

// ── one review row (verdict affordance: pick-the-word) ────────────────────
function ReviewRow({ p, count, verdict, onVerdict, onUndo, onSeeVocab, highlight }) {
  if (verdict) {
    const c = RV.resolvedCopy(p, verdict);
    const conf = RV.confirms(p, verdict);
    const learning = verdict === 'term' && !c.learned;
    return (
      <div className={'rv-row' + (c.learned ? ' rv-learnrow' : '')}>
        <div className="rv-resolved">
          <GCheck></GCheck>
          <span className="rv-resolved-txt">
            <strong>{c.strong}</strong>{c.rest}
            {learning && <React.Fragment>{' '}<Dots count={conf} total={RV.LEARN_AT}></Dots> {conf} of {RV.LEARN_AT}</React.Fragment>}
            {c.learned && <React.Fragment>{' '}<span className="rv-link" onClick={onSeeVocab}>See vocabulary ›</span></React.Fragment>}
            {' '}<span className="rv-undo" onClick={onUndo}>Undo</span>
          </span>
        </div>
      </div>
    );
  }

  const inText = p.outcome === 'applied' ? 'term' : 'original';
  return (
    <div className="rv-row" style={highlight ? { animation: 'rvFlash 1.5s var(--ease-jot)', borderRadius: 12 } : undefined}>
      <div className="rv-row-top">
        <span className={'rv-badge ' + (p.outcome === 'applied' ? 'changed' : 'kept')}>
          {p.outcome === 'applied' ? 'Changed' : 'Kept'}
        </span>
        <span className="rv-row-note">{RV.rowNote(p)}</span>
        {count > 1 && <span className="rv-count">×{count}</span>}
      </div>

      <div className="rv-chips">
        {['original', 'term'].map((side) => (
          <div key={side} className="rv-chip pressable" onClick={() => onVerdict(side)}>
            <span>{side === 'term' ? p.term : p.original}</span>
            {inText === side && <span className="rv-chip-tag">in text</span>}
          </div>
        ))}
      </div>
    </div>
  );
}

// ── the review surface (card or sheet body) ─────────────────────────────────
// rows: [{ key, p, count, verdict }]
function ReviewSurface({ rows, onVerdict, onUndo, onSeeVocab, highlightKey, inSheet }) {
  const [expanded, setExpanded] = React.useState(false);
  const CAP = 4;
  const unresolved = rows.filter((r) => !r.verdict);
  const allDone = unresolved.length === 0;
  const wordCount = unresolved.reduce((s, r) => s + r.count, 0);
  const visible = expanded || rows.length <= CAP + 1 ? rows : rows.slice(0, CAP);

  return (
    <section className={'rv-review' + (inSheet ? ' in-sheet' : '')} data-comment-anchor="review-surface">
      <header className="rv-review-head">
        {allDone ? (
          <React.Fragment>
            <div className="rv-review-title" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <GCheck size={14}></GCheck> All reviewed
            </div>
            <div className="rv-review-sub">
              Jot’s learning your voice — <span className="rv-link" onClick={onSeeVocab}>see what it knows ›</span>
            </div>
          </React.Fragment>
        ) : (
          <React.Fragment>
            <div className="rv-review-title">Jot guessed on {wordCount} {wordCount === 1 ? 'word' : 'words'}.</div>
            <div className="rv-review-sub">
              Tap the word you meant — a few answers and Jot fixes these on its own.
            </div>
          </React.Fragment>
        )}
      </header>

      <div className="rv-rows">
        {visible.map((r) => (
          <ReviewRow
            key={r.key}
            p={r.p}
            count={r.count}
            verdict={r.verdict}
            highlight={highlightKey === r.key}
            onVerdict={(v) => onVerdict(r, v)}
            onUndo={() => onUndo(r)}
            onSeeVocab={onSeeVocab}
          ></ReviewRow>
        ))}
      </div>

      {visible.length < rows.length && (
        <button type="button" className="rv-more" onClick={() => setExpanded(true)}>
          Show {rows.length - visible.length} more
        </button>
      )}
    </section>
  );
}

// ── compact summary row (accordion toggle for the full record) ──────────────
function ReviewSummaryRow({ rows, open, onToggle }) {
  const unresolved = rows.filter((r) => !r.verdict);
  const n = unresolved.reduce((s, r) => s + r.count, 0);
  return (
    <div className={'rv-summary pressable' + (open ? ' open' : '')} onClick={onToggle} data-comment-anchor="review-summary">
      <div style={{ flex: 1 }}>
        {n > 0 ? (
          <React.Fragment>
            <div className="rv-summary-title">Jot guessed on {n} {n === 1 ? 'word' : 'words'}.</div>
            <div className="rv-summary-sub">Tap an underlined word — or review them all here.</div>
          </React.Fragment>
        ) : (
          <div className="rv-summary-title" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <GCheck size={14}></GCheck> All reviewed
          </div>
        )}
      </div>
      <span className="rv-disclose" style={{ display: 'flex' }}><GChevronR></GChevronR></span>
    </div>
  );
}

// ── in-place bubble on a marked word ─────────────────────────────────────────
// anchor: { top, arrowX, above } relative to .rv-screen
function WordBubble({ anchor, row, onVerdict, onClose }) {
  const W = 272;
  const left = Math.max(10, Math.min(anchor.arrowX - W / 2, 393 - W - 10));
  const arrowX = Math.max(16, Math.min(anchor.arrowX - left - 6, W - 28));
  const p = row.p;
  const verdict = row.verdict;
  const pos = anchor.above ? { left, bottom: anchor.bottom } : { left, top: anchor.top };

  return (
    <React.Fragment>
      <div className="rv-bubble-dim" onClick={onClose}></div>
      <div
        className={'rv-bubble' + (anchor.above ? ' above' : '')}
        style={{ ...pos, '--rv-bubble-origin': arrowX + 6 + 'px' }}
        data-comment-anchor="word-bubble"
      >
        <div className="rv-bubble-arrow" style={{ left: arrowX }}></div>
        {verdict ? (
          (() => {
            const c = RV.resolvedCopy(p, verdict);
            const conf = RV.confirms(p, verdict);
            const learning = verdict === 'term' && !c.learned;
            return (
              <div className="rv-resolved">
                <GCheck></GCheck>
                <span className="rv-resolved-txt">
                  <strong>{c.strong}</strong>{c.rest}
                  {learning && <React.Fragment>{' '}<Dots count={conf} total={RV.LEARN_AT}></Dots> {conf} of {RV.LEARN_AT}</React.Fragment>}
                </span>
              </div>
            );
          })()
        ) : (
          <React.Fragment>
            <div className="rv-row-top">
              <span className={'rv-badge ' + (p.outcome === 'applied' ? 'changed' : 'kept')}>
                {p.outcome === 'applied' ? 'Changed' : 'Kept'}
              </span>
              <span className="rv-row-note">{RV.rowNote(p)}</span>
              {row.count > 1 && <span className="rv-count">×{row.count}</span>}
            </div>
            <div className="rv-chips">
              {['original', 'term'].map((side) => (
                <div key={side} className="rv-chip pressable" onClick={() => onVerdict(side)}>
                  <span>{side === 'term' ? p.term : p.original}</span>
                  {(p.outcome === 'applied' ? 'term' : 'original') === side && <span className="rv-chip-tag">in text</span>}
                </div>
              ))}
            </div>
          </React.Fragment>
        )}
      </div>
    </React.Fragment>
  );
}

// ── bottom action bar (visual parity with production) ───────────────────────
function ActionBar() {
  return (
    <div className="rv-actionbar" data-comment-anchor="action-bar">
      <div className="rv-abtn pressable"><GTrash></GTrash></div>
      <div className="rv-abtn pressable"><GPencil></GPencil></div>
      <div className="rv-articulate pressable"><GSparkle></GSparkle>Articulate</div>
      <div className="rv-abtn pressable"><GCopy></GCopy></div>
    </div>
  );
}

Object.assign(window, {
  GChevronL, GChevronR, GCheck, GTrash, GPencil, GCopy, GSparkle, Dots,
  TranscriptBody, ReviewRow, ReviewSurface, ReviewSummaryRow, WordBubble, ActionBar,
});
