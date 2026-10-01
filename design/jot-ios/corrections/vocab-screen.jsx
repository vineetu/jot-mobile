// Vocabulary screen — the ledger where review verdicts are stored.
// "What Jot's learned": one row per mapping with its confirmation score.

function vocabMappingState(p, verdict) {
  const conf = window.JOT_REVIEW.confirms(p, verdict || null);
  if (verdict === 'term' && conf >= window.JOT_REVIEW.LEARN_AT) return 'learned';
  if (verdict === 'original') return 'stopped';
  if (conf > 0) return 'learning';
  return 'watching';
}

function LedgerRow({ p, verdict }) {
  const RVd = window.JOT_REVIEW;
  const state = vocabMappingState(p, verdict);
  const conf = RVd.confirms(p, verdict || null);

  return (
    <div className="rv-vrow">
      <div className="rv-led-map">
        <span>{p.original}</span>
        <span className="arr">→</span>
        <span>{p.term}</span>
      </div>
      {state === 'learned' && (
        <div className="rv-led-status">
          <span className="rv-led-badge">Automatic</span>
          <span>{conf} confirmations — Jot fixes it without asking</span>
        </div>
      )}
      {state === 'learning' && (
        <div className="rv-led-status">
          <Dots count={conf} total={RVd.LEARN_AT}></Dots>
          <span>{conf} of {RVd.LEARN_AT} confirmations — automatic at {RVd.LEARN_AT}</span>
        </div>
      )}
      {state === 'stopped' && (
        <div className="rv-led-status">
          <span style={{ color: 'var(--ink-caption)' }}>—</span>
          <span>
            {p.outcome === 'applied'
              ? `Stopped — “${p.original}” stays your word`
              : `Stopped asking — “${p.original}” was right`}
          </span>
        </div>
      )}
      {state === 'watching' && (
        <div className="rv-led-status">
          <Dots count={0} total={RVd.LEARN_AT}></Dots>
          <span>No confirmations yet — asks when it comes up</span>
        </div>
      )}
    </div>
  );
}

function VocabScreen({ scenario, proposals, verdictOf, onBack }) {
  const terms = window.JOT_REVIEW.VOCAB_TERMS[scenario] || [];
  const byTerm = {};
  proposals.forEach((p) => {
    (byTerm[p.term] = byTerm[p.term] || []).push(p);
  });

  return (
    <div className="rv-scroll" data-screen-label="Vocabulary">
      <div className="rv-topbar">
        <div className="rv-back pressable" onClick={onBack} aria-label="Back">
          <GChevronL></GChevronL>
        </div>
      </div>

      <h1 className="rv-vtitle">Vocabulary.</h1>
      <p className="rv-vsub">
        Words Jot listens for. Reviews on your transcripts score each fix — three
        confirmations and it goes automatic.
      </p>

      <div className="rv-vcard">
        <div className="rv-vrow" style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ flex: 1 }}>
            <div className="rv-vterm">Vocabulary boost</div>
            <div className="rv-vempty">A small on-device model listens for your terms.</div>
          </div>
          <div className="rv-toggle"></div>
        </div>
      </div>

      <div className="rv-vcaps">What Jot’s learned</div>
      <div className="rv-vcard" data-comment-anchor="learned-mappings">
        {proposals.map((p) => (
          <LedgerRow key={p.id} p={p} verdict={verdictOf(p)}></LedgerRow>
        ))}
        {proposals.length === 0 && (
          <div className="rv-vrow rv-vempty">Nothing yet — Jot scores its guesses as you review transcripts.</div>
        )}
      </div>

      <div className="rv-vcaps">Terms</div>
      <div className="rv-vcard">
        {terms.map((term) => {
          const maps = byTerm[term] || [];
          const auto = maps.filter((p) => vocabMappingState(p, verdictOf(p)) === 'learned').length;
          return (
            <div className="rv-vrow" key={term} style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
              <div className="rv-vterm" style={{ flex: 1 }}>{term}</div>
              <div className="rv-vempty" style={{ marginTop: 0 }}>
                {auto > 0 ? `${auto} automatic ${auto === 1 ? 'fix' : 'fixes'}` : maps.length > 0 ? 'learning' : '—'}
              </div>
            </div>
          );
        })}
      </div>

      <p className="rv-vfoot">
        Scores live on this iPhone, nowhere else. Undo any fix by reviewing a transcript
        where it appears.
      </p>
    </div>
  );
}

Object.assign(window, { VocabScreen });
