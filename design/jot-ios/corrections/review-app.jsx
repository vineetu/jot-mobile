// Review Jot's Corrections — app shell, state machine, tweaks wiring.

const RVD = window.JOT_REVIEW;

const RV_TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "Light",
  "moment": "In the app",
  "groupRepeats": false
}/*EDITMODE-END*/;

// Locked design decisions (were tweaks, now final):
// placement = marks + summary row · verdict = pick-the-word · scenario = typical
const RV_SCENARIO = 'typical';

function loadVerdicts() {
  try { return JSON.parse(localStorage.getItem('jot-corrections-verdicts')) || {}; }
  catch (e) { return {}; }
}

function CorrectionsApp() {
  const [t, setTweak] = useTweaks(RV_TWEAK_DEFAULTS);
  const theme = t.theme === 'Dark' ? 'dark' : 'light';
  const moment = t.moment === 'Keyboard' ? 'keyboard' : 'app';
  const scenario = RV_SCENARIO;
  const grouped = !!t.groupRepeats;

  const data = RVD.SCENARIOS[scenario];
  const [allVerdicts, setAllVerdicts] = React.useState(loadVerdicts);
  const verdicts = allVerdicts[scenario] || {};

  const [screen, setScreen] = React.useState('detail');
  const [flashKeys, setFlashKeys] = React.useState({});
  const [highlightKey, setHighlightKey] = React.useState(null);
  const [bubble, setBubble] = React.useState(null); // { key, anchor }
  const [summaryOpen, setSummaryOpen] = React.useState(false);
  const [kbNonce, setKbNonce] = React.useState(0);

  const scrollRef = React.useRef(null);
  const screenRef = React.useRef(null);
  const reviewRef = React.useRef(null);
  const bubbleTimer = React.useRef(null);

  React.useEffect(() => {
    localStorage.setItem('jot-corrections-verdicts', JSON.stringify(allVerdicts));
  }, [allVerdicts]);

  React.useEffect(() => {
    setScreen('detail');
    setBubble(null);
    setSummaryOpen(false);
  }, [scenario, moment]);

  // ── derived rows ──
  const rowVerdict = (key, pid) => verdicts[key] || verdicts[pid] || null;
  const rows = React.useMemo(() => {
    if (grouped) {
      return data.proposals.map((p) => ({ key: p.id, p, count: p.slots.length, verdict: rowVerdict(p.id, p.id) }));
    }
    return data.proposals.flatMap((p) =>
      p.slots.map((s, i) => ({ key: p.id + ':' + i, p, count: 1, verdict: rowVerdict(p.id + ':' + i, p.id) }))
    );
  }, [data, grouped, verdicts]);

  const unresolvedCount = rows.filter((r) => !r.verdict).reduce((s, r) => s + r.count, 0);

  // proposal-level verdict (drives text + vocab + keyboard)
  const verdictOf = React.useCallback((p) => {
    if (verdicts[p.id]) return verdicts[p.id];
    for (let i = 0; i < p.slots.length; i++) {
      if (verdicts[p.id + ':' + i]) return verdicts[p.id + ':' + i];
    }
    return null;
  }, [verdicts]);

  const slotInfo = React.useMemo(() => {
    const m = {};
    data.proposals.forEach((p) => {
      const pv = verdictOf(p);
      const word = RVD.slotWord(p, pv);
      p.slots.forEach((sid, i) => {
        const rv = grouped ? rowVerdict(p.id, p.id) : rowVerdict(p.id + ':' + i, p.id);
        m[sid] = { proposal: p, word, resolved: !!rv };
      });
    });
    return m;
  }, [data, verdictOf, verdicts, grouped]);

  const hostText = React.useMemo(
    () => data.tokens.map((tok) => (typeof tok === 'string' ? tok : (slotInfo[tok.id] ? slotInfo[tok.id].word : tok.w))).join(''),
    [data, slotInfo]
  );

  // ── actions ──
  const flash = (sid) => {
    setFlashKeys((f) => ({ ...f, [sid]: (f[sid] || 0) + 1 }));
    setTimeout(() => setFlashKeys((f) => { const c = { ...f }; delete c[sid]; return c; }), 1600);
  };

  const writeVerdict = (key, p, v) => {
    const changesText = RVD.editsText(p, v) && RVD.slotWord(p, verdictOf(p)) !== RVD.slotWord(p, v);
    setAllVerdicts((av) => ({ ...av, [scenario]: { ...(av[scenario] || {}), [key]: v } }));
    if (changesText) flash(p.slots[0]);
  };

  const setVerdict = (row, v) => writeVerdict(row.key, row.p, v);
  const setVerdictKb = (p, v) => writeVerdict(p.id, p, v);

  const undoVerdict = (row) => {
    const had = row.verdict;
    const wasEdit = had && RVD.editsText(row.p, had);
    setAllVerdicts((av) => {
      const sc = { ...(av[scenario] || {}) };
      delete sc[row.key];
      delete sc[row.p.id];
      return { ...av, [scenario]: sc };
    });
    if (wasEdit) flash(row.p.slots[0]);
  };

  const resetVerdicts = () => {
    setAllVerdicts((av) => ({ ...av, [scenario]: {} }));
    setBubble(null);
    setKbNonce((n) => n + 1);
  };

  // word tap → in-place bubble
  const onWordTap = (p, slotId, e) => {
    const screenEl = screenRef.current;
    if (!screenEl) return;
    const r = e.target.getBoundingClientRect();
    const s = screenEl.getBoundingClientRect();
    const arrowX = r.left + r.width / 2 - s.left;
    const above = r.bottom - s.top > s.height * 0.55;
    const anchor = above
      ? { arrowX, above: true, bottom: s.height - (r.top - s.top) + 10 }
      : { arrowX, above: false, top: r.bottom - s.top + 10 };
    let row = rows.find((x) => x.p.id === p.id && !x.verdict && (grouped || x.key === p.id + ':' + p.slots.indexOf(slotId)))
      || rows.find((x) => x.p.id === p.id && !x.verdict)
      || rows.find((x) => x.p.id === p.id);
    if (!row) return;
    clearTimeout(bubbleTimer.current);
    setBubble({ key: row.key, anchor });
  };

  const bubbleRow = bubble ? rows.find((r) => r.key === bubble.key) : null;
  const onBubbleVerdict = (v) => {
    if (!bubbleRow) return;
    setVerdict(bubbleRow, v);
    clearTimeout(bubbleTimer.current);
    bubbleTimer.current = setTimeout(() => setBubble(null), 1300);
  };

  const goVocab = () => { setBubble(null); setScreen('vocab'); };

  const hasReview = data.proposals.length > 0;
  const asks = RVD.selectAsks(data.proposals, verdictOf);

  // ── render ──
  return (
    <div className={'rv-page' + (theme === 'dark' ? ' dark' : '')} data-theme={theme}>
      <IOSDevice dark={theme === 'dark'}>
        <div className="rv-screen" data-theme={theme} ref={screenRef}>
          <div className="rv-stage">

            {moment === 'keyboard' ? (
              <KeyboardMoment
                data={data} text={hostText} slotInfo={slotInfo} asks={asks}
                totalUnresolved={unresolvedCount}
                onVerdict={setVerdictKb} restartNonce={kbNonce + scenario}
              ></KeyboardMoment>
            ) : (
              <React.Fragment>
                {/* ── transcript detail ── */}
                <div className={'rv-panel ' + (screen === 'vocab' ? 'under' : 'onscreen')} data-screen-label="Transcript detail">
                  <div className="rv-scroll" ref={scrollRef} onScroll={() => setBubble(null)}>
                    <div className="rv-topbar">
                      <div className="rv-back pressable" aria-label="Back"><GChevronL></GChevronL></div>
                    </div>
                    <div className="rv-meta">{data.meta}</div>

                    <div className="rv-card" data-comment-anchor="transcript-card">
                      <TranscriptBody
                        tokens={data.tokens}
                        slotInfo={slotInfo}
                        marksOn={hasReview}
                        onWordTap={onWordTap}
                        flashKeys={flashKeys}
                      ></TranscriptBody>
                    </div>

                    {hasReview && (
                      <React.Fragment>
                        <ReviewSummaryRow rows={rows} open={summaryOpen} onToggle={() => setSummaryOpen(!summaryOpen)}></ReviewSummaryRow>
                        {summaryOpen && (
                          <div ref={reviewRef}>
                            <ReviewSurface
                              rows={rows}
                              onVerdict={setVerdict} onUndo={undoVerdict}
                              onSeeVocab={goVocab} highlightKey={highlightKey}
                            ></ReviewSurface>
                          </div>
                        )}
                      </React.Fragment>
                    )}
                  </div>

                  <ActionBar></ActionBar>

                  {bubble && bubbleRow && (
                    <WordBubble
                      anchor={bubble.anchor} row={bubbleRow}
                      onVerdict={onBubbleVerdict} onClose={() => setBubble(null)}
                    ></WordBubble>
                  )}
                </div>

                {/* ── vocabulary ── */}
                <div className={'rv-panel ' + (screen === 'vocab' ? 'onscreen' : 'offright')}>
                  {screen === 'vocab' && (
                    <VocabScreen
                      scenario={scenario}
                      proposals={data.proposals}
                      verdictOf={verdictOf}
                      onBack={() => setScreen('detail')}
                    ></VocabScreen>
                  )}
                </div>
              </React.Fragment>
            )}
          </div>
        </div>
      </IOSDevice>

      <TweaksPanel>
        <TweakSection label="Moment"></TweakSection>
        <TweakRadio label="Where" value={t.moment} options={['In the app', 'Keyboard']}
          onChange={(v) => setTweak('moment', v)}></TweakRadio>
        {moment === 'keyboard' && (
          <TweakButton label="Restart keyboard moment" onClick={() => setKbNonce((n) => n + 1)}></TweakButton>
        )}
        {moment === 'app' && (
          <TweakButton label="Open vocabulary screen" onClick={goVocab}></TweakButton>
        )}
        <TweakButton label="Reset verdicts" secondary onClick={resetVerdicts}></TweakButton>

        <TweakSection label="Options"></TweakSection>
        <TweakRadio label="Theme" value={t.theme} options={['Light', 'Dark']}
          onChange={(v) => setTweak('theme', v)}></TweakRadio>
        <TweakToggle label="Group repeats" value={grouped}
          onChange={(v) => setTweak('groupRepeats', v)}></TweakToggle>
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<CorrectionsApp></CorrectionsApp>);
