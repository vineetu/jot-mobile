// Keyboard moment — the post-dictation nudge lives in the Jot keyboard's
// recents strip (no new surface; the strip space is reused for ~10s, then
// returns to recents). Quick review walks ONLY the asks worth asking
// (see selectAsks in review-data.js).

function KbGlobe() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="9" stroke="var(--kb2-key-ink)" strokeWidth="1.6"></circle>
      <path d="M3 12h18M12 3c2.6 2.4 3.9 5.4 3.9 9S14.6 18.6 12 21c-2.6-2.4-3.9-5.4-3.9-9S9.4 5.4 12 3z"
        stroke="var(--kb2-key-ink)" strokeWidth="1.6" strokeLinecap="round"></path>
    </svg>
  );
}
function KbMicOutline() {
  return (
    <svg width="20" height="24" viewBox="0 0 24 28" fill="none">
      <rect x="8" y="2" width="8" height="14" rx="4" stroke="var(--kb2-key-ink)" strokeWidth="1.8"></rect>
      <path d="M4.5 13.5a7.5 7.5 0 0015 0M12 21v4.5" stroke="var(--kb2-key-ink)" strokeWidth="1.8" strokeLinecap="round"></path>
    </svg>
  );
}
function KbDelete() {
  return (
    <svg width="25" height="18" viewBox="0 0 23 17" fill="none">
      <path d="M7 1h13a2 2 0 012 2v11a2 2 0 01-2 2H7l-6-7.5L7 1z" stroke="var(--kb2-key-ink)" strokeWidth="1.6" strokeLinejoin="round"></path>
      <path d="M10 5l7 7M17 5l-7 7" stroke="var(--kb2-key-ink)" strokeWidth="1.6" strokeLinecap="round"></path>
    </svg>
  );
}
function KbReturn() {
  return (
    <svg width="22" height="16" viewBox="0 0 20 14" fill="none">
      <path d="M18 1v6H4m0 0l4-4M4 7l4 4" stroke="var(--kb2-key-ink)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}
function KbDots() {
  return (
    <svg width="20" height="6" viewBox="0 0 22 6">
      <circle cx="3" cy="3" r="2.4" fill="var(--kb2-key-ink)"></circle>
      <circle cx="11" cy="3" r="2.4" fill="var(--kb2-key-ink)"></circle>
      <circle cx="19" cy="3" r="2.4" fill="var(--kb2-key-ink)"></circle>
    </svg>
  );
}
function KbMicSolid() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
      <rect x="9" y="2.5" width="6" height="11" rx="3" fill="#fff"></rect>
      <path d="M5.5 11a6.5 6.5 0 0013 0M12 17.5V21" stroke="#fff" strokeWidth="2" strokeLinecap="round"></path>
    </svg>
  );
}
function KbOpenArrow() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
      <rect x="2.5" y="2.5" width="19" height="19" rx="5.5" stroke="var(--jot-kb-accent)" strokeWidth="1.8"></rect>
      <path d="M9.5 14.5l5-5m0 0H10.7m3.8 0v3.8" stroke="var(--jot-kb-accent)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}

// recents card — exactly the production layout: RECENT / See all › / rows.
// The just-dictated entry is row 1; its guesses are annotated IN the row
// (dashed marks on the words + a compact Review chip) — no banner, no timer.
function KbRecents({ data, slotInfo, totalUnresolved, canReview, onReview }) {
  const preview = data.tokens.map((tok, i) => {
    if (typeof tok === 'string') return <React.Fragment key={i}>{tok}</React.Fragment>;
    const info = slotInfo[tok.id];
    if (!info) return <React.Fragment key={tok.id}>{tok.w}</React.Fragment>;
    return info.resolved
      ? <React.Fragment key={tok.id}>{info.word}</React.Fragment>
      : <span key={tok.id} className="kbm-rword">{info.word}</span>;
  });
  return (
    <div className="kbm-strip">
      <div className="kbm-head">
        <span className="kbm-recents-h">Recent</span>
        <span className="kbm-seeall">See all ›</span>
      </div>
      <div className="kbm-recent" data-comment-anchor="nudge">
        <span className="t">5:22 PM</span>
        <span className="x">{preview}</span>
        {canReview ? (
          <span className="kbm-guess-chip pressable" onClick={onReview}>
            Review {totalUnresolved}
          </span>
        ) : (
          <span className="kbm-open"><KbOpenArrow></KbOpenArrow></span>
        )}
      </div>
      {window.JOT_REVIEW.RECENTS.map((r, i) => (
        <div className="kbm-recent" key={i}>
          <span className="t">{r.time}</span>
          <span className="x">{r.text}</span>
          <span className="kbm-open"><KbOpenArrow></KbOpenArrow></span>
        </div>
      ))}
    </div>
  );
}

// stages: 'idle' (recents + chip on the fresh row) → 'review' → 'done' (2.2s) → 'idle'
function KeyboardStrip({ data, slotInfo, asks, totalUnresolved, onVerdict, restartNonce }) {
  const RVd = window.JOT_REVIEW;
  const [stage, setStage] = React.useState('idle');
  const [idx, setIdx] = React.useState(0);
  const [feedback, setFeedback] = React.useState(null);
  const timer = React.useRef(null);
  const doneTimer = React.useRef(null);

  React.useEffect(() => {
    setStage('idle');
    setIdx(0);
    setFeedback(null);
    return () => { clearTimeout(timer.current); clearTimeout(doneTimer.current); };
  }, [restartNonce]); // eslint-disable-line

  React.useEffect(() => {
    clearTimeout(doneTimer.current);
    if (stage === 'done') doneTimer.current = setTimeout(() => setStage('idle'), 2200);
    return () => clearTimeout(doneTimer.current);
  }, [stage]);

  const queue = React.useRef(asks);
  if (stage !== 'review') queue.current = asks;

  const advance = () => {
    setFeedback(null);
    setIdx((i) => {
      if (i + 1 >= queue.current.length) { setStage('done'); return i; }
      return i + 1;
    });
  };

  const answer = (p, v) => {
    onVerdict(p, v);
    const c = RVd.resolvedCopy(p, v);
    setFeedback(c);
    clearTimeout(timer.current);
    timer.current = setTimeout(advance, c.learned ? 1600 : 950);
  };

  if (stage === 'idle') {
    return (
      <KbRecents
        data={data} slotInfo={slotInfo}
        totalUnresolved={totalUnresolved}
        canReview={asks.length > 0}
        onReview={() => { setIdx(0); setStage('review'); }}
      ></KbRecents>
    );
  }

  if (stage === 'done') {
    return (
      <div className="kbm-strip centered">
        <div className="kbm-strip-row">
          <GCheck size={15}></GCheck>
          <span className="kbm-strip-title">Done — Jot’s learning your voice.</span>
        </div>
        {totalUnresolved > 0 && (
          <div className="kbm-strip-sub">
            {totalUnresolved} more {totalUnresolved === 1 ? 'guess is' : 'guesses are'} on the transcript in Jot.
          </div>
        )}
      </div>
    );
  }

  // quick review — one ask at a time
  const p = queue.current[Math.min(idx, queue.current.length - 1)];
  if (!p) return null;
  const ctx = RVd.contextFor(data.tokens, p.slots[0]);
  const inTextWord = p.outcome === 'applied' ? p.term : p.original;

  return (
    <div className="kbm-strip centered" data-comment-anchor="quick-review">
      {feedback ? (
        <div className="kbm-feedback">
          <GCheck size={14}></GCheck>
          <span><strong>{feedback.strong}</strong>{feedback.rest}</span>
        </div>
      ) : (
        <React.Fragment>
          <div className="kbm-context">
            {ctx.before}<span className="kbm-word">{inTextWord}</span>{ctx.after}
          </div>
          <div className="kbm-chips">
            {['original', 'term'].map((side) => (
              <div key={side} className="kbm-chip-btn pressable" onClick={() => answer(p, side)}>
                {side === 'term' ? p.term : p.original}
              </div>
            ))}
            <span className="kbm-meta">
              <span className="kbm-skip" onClick={advance}>Skip</span>
              {idx + 1} of {queue.current.length}
            </span>
          </div>
        </React.Fragment>
      )}
    </div>
  );
}

function KeyboardMoment({ data, text, slotInfo, asks, totalUnresolved, onVerdict, restartNonce }) {
  return (
    <div className="kbm-host" data-screen-label="Keyboard after dictation">
      <div className="kbm-app-title">New note</div>
      <div className="kbm-field">{text}<span className="kbm-caret"></span></div>
      <div className="kbm-kb">
        <KeyboardStrip
          data={data} slotInfo={slotInfo} asks={asks} totalUnresolved={totalUnresolved}
          onVerdict={onVerdict} restartNonce={restartNonce}
        ></KeyboardStrip>
        <div className="kbm-actionrow">
          <div className="kbm-key sm pressable"><KbDots></KbDots></div>
          <div className="kbm-jotdown pressable"><KbMicSolid></KbMicSolid>Jot down</div>
          <div className="kbm-key md pressable"><KbReturn></KbReturn></div>
          <div className="kbm-key sm pressable"><KbDelete></KbDelete></div>
        </div>
        <div className="kbm-sysrow">
          <KbGlobe></KbGlobe>
          <KbMicOutline></KbMicOutline>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { KeyboardMoment });
