/* wizard-app.jsx — frame, status bar, state machine, tweaks */
const { useState, useEffect, useRef } = React;

const FONE_W = 390, FONE_H = 844;

// ── Status bar ───────────────────────────────────────────────
function StatusBar({ t, recording }) {
  const ink = t.ink;
  return (
    <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 54, zIndex: 50,
      display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 30px 0 34px' }}>
      <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 16, color: ink, letterSpacing: '0.2px' }}>6:31</span>
      {/* dynamic island */}
      <div style={{ position: 'absolute', left: '50%', top: 11, transform: 'translateX(-50%)', width: 124, height: 36, borderRadius: 19, background: '#05070b',
        display: 'flex', alignItems: 'center', justifyContent: 'flex-end', paddingRight: 13 }}>
        <span style={{ width: 9, height: 9, borderRadius: 5, background: recording ? '#FF6B57' : '#E8841C',
          animation: recording ? 'jotpulse 1.2s ease-in-out infinite' : 'none' }} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        {/* cellular */}
        <svg width="18" height="12" viewBox="0 0 18 12" fill="none"><rect x="0" y="8" width="3" height="4" rx="1" fill={ink}/><rect x="5" y="5.5" width="3" height="6.5" rx="1" fill={ink}/><rect x="10" y="3" width="3" height="9" rx="1" fill={ink} opacity="0.4"/><rect x="15" y="0.5" width="3" height="11.5" rx="1" fill={ink} opacity="0.4"/></svg>
        {/* wifi */}
        <svg width="17" height="12" viewBox="0 0 17 12" fill="none"><path d="M8.5 2.4c2.7 0 5.2 1 7 2.8l-1.6 1.7A7.6 7.6 0 0 0 8.5 4.7 7.6 7.6 0 0 0 3.1 6.9L1.5 5.2A9.9 9.9 0 0 1 8.5 2.4z" fill={ink}/><path d="M8.5 6.6c1.5 0 2.9.6 4 1.6L8.5 12 4.5 8.2a5.7 5.7 0 0 1 4-1.6z" fill={ink}/></svg>
        {/* battery */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 2 }}>
          <div style={{ width: 25, height: 12.5, borderRadius: 3.5, border: `1px solid ${ink}`, opacity: 0.5, padding: 1.6 }}>
            <div style={{ width: '78%', height: '100%', borderRadius: 1.5, background: ink }} />
          </div>
          <div style={{ width: 1.5, height: 4.5, borderRadius: 1, background: ink, opacity: 0.5 }} />
        </div>
      </div>
    </div>
  );
}

const STREAM_WORDS = "running late — traffic on the bridge is backed up past the tunnel, i'll be there in about ten minutes".split(' ');
const FINAL_TEXT = "Running late — traffic on the bridge is backed up past the tunnel. I'll be there in about ten minutes.";

function App() {
  const [tw, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const t = jotTheme(tw.appearance === 'dark');
  const accent = 'blue';
  const mark = tw.brandMark;

  const steps = tw.warmHold === 'inwizard'
    ? ['w1', 'w2', 'w3', 'w4', 'w5', 'w6', 'w7']
    : ['w1', 'w2', 'w3', 'w4', 'w5', 'w7'];
  const total = steps.length;

  const [view, setView] = useState('wizard'); // wizard | app
  const [step, setStep] = useState(0);
  const [warmOn, setWarmOn] = useState(true);

  // W3 keyboard setup
  const [kbAddedManual, setKbAdded] = useState(false);
  const [kbSheet, setKbSheet] = useState(false);
  const kbAdded = tw.kbDetected === 'returning' || kbAddedManual;

  // W5 interaction
  const [kbUp, setKbUp] = useState(false);
  const [kbMode, setKbMode] = useState('apple'); // apple | jot
  const [rec, setRec] = useState(false);
  const [paused, setPaused] = useState(false);
  const [stream, setStream] = useState('');
  const [field, setField] = useState('');
  const [tried, setTried] = useState(false);
  const [kbH, setKbH] = useState(0);
  const kbRef = useRef(null);

  // app-view warm-hold contextual prompt
  const [promptOn, setPromptOn] = useState(false);

  const clampStep = (s) => Math.max(0, Math.min(total - 1, s));
  const cur = steps[clampStep(step)];

  function resetW5() { setKbUp(false); setKbMode('apple'); setRec(false); setPaused(false); setStream(''); setField(''); setTried(false); }
  function goWizard() { setView('wizard'); setStep(0); resetW5(); setPromptOn(false); }
  function finish() {
    setView('app'); resetW5();
    if (tw.warmHold !== 'inwizard') { setTimeout(() => setPromptOn(true), 950); }
  }
  const nav = {
    next: () => { if (clampStep(step) >= total - 1) finish(); else { setStep(s => clampStep(s + 1)); resetW5(); } },
    back: () => { setStep(s => clampStep(s - 1)); resetW5(); },
    close: finish,
  };

  // measure keyboard height for floating CTA
  useEffect(() => {
    if (kbUp && kbRef.current) setKbH(kbRef.current.offsetHeight);
    else setKbH(0);
  }, [kbUp, kbMode, rec, tried, tw.appearance]);

  // streaming animation
  useEffect(() => {
    if (!rec || paused) return;
    let i = stream ? stream.split(' ').length : 0;
    if (i >= STREAM_WORDS.length) { const id = setTimeout(stopDictation, 900); return () => clearTimeout(id); }
    const id = setTimeout(() => {
      setStream(STREAM_WORDS.slice(0, i + 1).join(' '));
    }, i === 0 ? 120 : 135);
    return () => clearTimeout(id);
  }, [rec, paused, stream]);

  function startDictation() { setRec(true); setPaused(false); setStream(''); }
  function stopDictation() { setRec(false); setPaused(false); setStream(''); setField(FINAL_TEXT); setTried(true); }
  function trashDictation() { setRec(false); setPaused(false); setStream(''); }

  // scaling
  const wrapRef = useRef(null);
  useEffect(() => {
    function fit() {
      const pad = 28, bezel = 13;
      const W = FONE_W + bezel * 2, H = FONE_H + bezel * 2;
      const s = Math.min((window.innerWidth - pad) / W, (window.innerHeight - pad) / H, 1.15);
      if (wrapRef.current) wrapRef.current.style.transform = `scale(${s})`;
    }
    fit(); window.addEventListener('resize', fit); return () => window.removeEventListener('resize', fit);
  }, []);

  // panel router
  function Panel() {
    const common = { t, accent, mark, nav, total };
    switch (cur) {
      case 'w1': return <W1Welcome {...common} />;
      case 'w2': return <W2Mic {...common} />;
      case 'w3': return <W3Keyboard {...common} added={kbAdded} onOpenSettings={() => setKbSheet(true)} />;
      case 'w4': return <W4How {...common} />;
      case 'w5': return <W5Try {...common} tried={tried} field={field} kbUp={kbUp}
                    onTry={() => { if (!kbUp) { setKbUp(true); setKbMode('apple'); } }} />;
      case 'w6': return <W6WarmHold {...common} current={5} on={warmOn} setOn={setWarmOn} />;
      case 'w7': return <W7Ready {...common} />;
      default: return null;
    }
  }

  const showFloatCta = cur === 'w5' && kbUp;

  return (
    <div style={{ position: 'fixed', inset: 0, background: t.dark ? '#05070c' : '#aab4c6',
      display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden',
      transition: 'background .4s' }}>
      <div ref={wrapRef} style={{ transformOrigin: 'center center' }}>
        {/* bezel */}
        <div style={{ width: FONE_W + 26, height: FONE_H + 26, borderRadius: 67, background: '#000',
          padding: 13, boxShadow: '0 50px 100px -30px rgba(0,0,0,0.7), 0 0 0 2px rgba(255,255,255,0.06)' }}>
          {/* screen */}
          <div style={{ position: 'relative', width: FONE_W, height: FONE_H, borderRadius: 54, overflow: 'hidden', background: t.bg, transition: 'background .4s' }}>
            <StatusBar t={t} recording={rec && view === 'wizard'} />

            {view === 'wizard' && <Panel />}

            {/* W3 simulated Settings sheet */}
            {view === 'wizard' && cur === 'w3' && (
              <KeyboardSetupSheet t={t} accent={accent} open={kbSheet}
                onClose={() => setKbSheet(false)}
                onComplete={() => { setKbAdded(true); setKbSheet(false); }} />
            )}

            {/* faux app after finishing */}
            {view === 'app' && <FauxApp t={t} accent={accent} mark={mark} onReplay={goWizard} />}

            {/* W5 keyboard overlay */}
            {view === 'wizard' && cur === 'w5' && (
              <React.Fragment>
                {kbMode === 'apple'
                  ? <AppleKeyboard t={t} accent={accent} up={kbUp} rootRef={kbRef} />
                  : <JotKeyboard t={t} accent={accent} up={kbUp} rec={rec} paused={paused} streamText={stream}
                      onDictate={startDictation} onStop={stopDictation} onPause={() => setPaused(p => !p)}
                      onTrash={trashDictation} onGlobe={() => { setKbMode('apple'); }} rootRef={kbRef} />}
                {/* globe hint when on apple kb */}
                {kbMode === 'apple' && kbUp && <GlobeHint t={t} accent={accent} onSwitch={() => setKbMode('jot')} />}
              </React.Fragment>
            )}

            {/* floating CTA above keyboard on W5 */}
            {showFloatCta && (
              <div style={{ position: 'absolute', left: 22, right: 22, bottom: kbH + 14, zIndex: 35 }}>
                <Cta accent={accent} onClick={nav.next}>{tried ? 'Continue' : 'I tried it'}</Cta>
              </div>
            )}

            {/* §4.6 contextual warm-hold prompt (app view) */}
            {view === 'app' && tw.warmHold !== 'inwizard' &&
              <WarmHoldPrompt t={t} accent={accent} visible={promptOn} onKeep={() => setPromptOn(false)} onDismiss={() => setPromptOn(false)} />}
          </div>
        </div>
      </div>

      <WizardTweaks tw={tw} setTweak={setTweak} />
    </div>
  );
}

// little floating hint pointing at the globe key on the Apple keyboard
function GlobeHint({ t, accent, onSwitch }) {
  const a = ACCENTS[accent];
  return (
    <button onClick={onSwitch} style={{ position: 'absolute', left: 16, bottom: 92, zIndex: 36,
      background: a.grad, color: '#fff', border: 'none', borderRadius: 14, padding: '9px 13px', cursor: 'pointer',
      fontFamily: SYS, fontWeight: 600, fontSize: 13, display: 'flex', alignItems: 'center', gap: 7,
      boxShadow: `0 8px 20px -4px ${a.glow}` }}>
      <GlobeGlyph color="#fff" size={16} /> Switch to Jot
      <span style={{ position: 'absolute', left: 22, bottom: -6, width: 12, height: 12, background: a.solid, transform: 'rotate(45deg)' }} />
    </button>
  );
}

function FauxApp({ t, accent, mark, onReplay }) {
  const a = ACCENTS[accent];
  const bubble = t.dark ? 'rgba(255,255,255,0.08)' : 'rgba(40,60,96,0.08)';
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 72 }}>
      <div style={{ padding: '0 22px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 600, fontSize: 30, color: t.ink }}>Messages</div>
        <div style={{ width: 38, height: 38, borderRadius: 19, background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none"><path d="M10 1.5l2 2.2 3-.4.6 3 2.7 1.4-1.4 2.7 1.4 2.7-2.7 1.4-.6 3-3-.4-2 2.2-2-2.2-3 .4-.6-3L1.4 14l1.4-2.7L1.4 8.6l2.7-1.4.6-3 3 .4 2-2.2z" stroke={t.glyphSoft} strokeWidth="1.3"/><circle cx="10" cy="10" r="3" stroke={t.glyphSoft} strokeWidth="1.3"/></svg>
        </div>
      </div>
      <div style={{ padding: '22px 22px 0', display: 'flex', flexDirection: 'column', gap: 12 }}>
        {[58, 44, 66, 40].map((w, i) => (
          <div key={i} style={{ alignSelf: i % 2 ? 'flex-end' : 'flex-start', width: w + '%', height: 36, borderRadius: 18, background: i % 2 ? a.soft : bubble }} />
        ))}
      </div>
      <button onClick={onReplay} style={{ position: 'absolute', bottom: 40, left: '50%', transform: 'translateX(-50%)',
        background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`, backdropFilter: 'blur(14px)', WebkitBackdropFilter: 'blur(14px)',
        color: t.inkSub, borderRadius: 22, padding: '11px 20px', cursor: 'pointer', fontFamily: SYS, fontWeight: 600, fontSize: 14,
        display: 'flex', alignItems: 'center', gap: 8 }}>
        <svg width="15" height="15" viewBox="0 0 15 15" fill="none"><path d="M2 7.5a5.5 5.5 0 1 1 1.6 3.9M2 11.5V8h3.5" stroke={t.inkSub} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
        Replay onboarding
      </button>
    </div>
  );
}

function WizardTweaks({ tw, setTweak }) {
  return (
    <TweaksPanel>
      <TweakSection label="Appearance" />
      <TweakRadio label="Mode" value={tw.appearance} options={['dark', 'light']} onChange={v => setTweak('appearance', v)} />
      <TweakSection label="Brand mark (C2)" />
      <TweakRadio label="App icon" value={tw.brandMark} options={['jot', 'sparkle']} onChange={v => setTweak('brandMark', v)} />
      <TweakSection label="Keyboard step (W3)" />
      <TweakRadio label="State" value={tw.kbDetected} options={['firstrun', 'returning']} onChange={v => setTweak('kbDetected', v)} />
      <TweakSection label="Warm hold (§4.6)" />
      <TweakRadio label="Warm-hold" value={tw.warmHold} options={['contextual', 'inwizard']} onChange={v => setTweak('warmHold', v)} />
    </TweaksPanel>
  );
}

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "appearance": "dark",
  "brandMark": "jot",
  "kbDetected": "firstrun",
  "warmHold": "inwizard"
}/*EDITMODE-END*/;

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
