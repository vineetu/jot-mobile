/* ask-app.jsx — Ask Jot · frame, status bar, lifecycle state machine, tweaks */
const { useState, useEffect, useRef, useCallback } = React;

const ONE_W = 390, ONE_H = 844;

// ── Status bar (matches the source: green continuity link · mic dot) ──
function GreenLink({ size = 22 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M9.5 14.5l5-5M8 13l-1.4 1.4a3.4 3.4 0 0 0 4.8 4.8L12.8 18M16 11l1.4-1.4a3.4 3.4 0 0 0-4.8-4.8L11.2 6"
        stroke="#2ad15f" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}
function StatusBar({ t, listening }) {
  const ink = t.ink;
  return (
    <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 54, zIndex: 60,
      display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 24px 0 32px' }}>
      <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 16, color: ink, letterSpacing: '0.2px' }}>4:29</span>
      <div style={{ position: 'absolute', left: '50%', top: 11, transform: 'translateX(-50%)', width: 122, height: 36, borderRadius: 19, background: '#05070b',
        display: 'flex', alignItems: 'center', paddingLeft: 14 }}>
        <GreenLink size={20} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        {/* mic-in-use privacy dot */}
        <span style={{ width: 9, height: 9, borderRadius: 5, background: '#E8841C',
          opacity: listening ? 1 : 0, transition: 'opacity .3s' }} />
        <svg width="17" height="12" viewBox="0 0 17 12" fill="none"><path d="M8.5 2.4c2.7 0 5.2 1 7 2.8l-1.6 1.7A7.6 7.6 0 0 0 8.5 4.7 7.6 7.6 0 0 0 3.1 6.9L1.5 5.2A9.9 9.9 0 0 1 8.5 2.4z" fill={ink}/><path d="M8.5 6.6c1.5 0 2.9.6 4 1.6L8.5 12 4.5 8.2a5.7 5.7 0 0 1 4-1.6z" fill={ink}/></svg>
        <div style={{ display: 'flex', alignItems: 'center', gap: 2 }}>
          <div style={{ width: 25, height: 12.5, borderRadius: 3.5, border: `1px solid ${ink}`, opacity: 0.45, padding: 1.6 }}>
            <div style={{ width: '26%', height: '100%', borderRadius: 1.5, background: '#2ad15f' }} />
          </div>
          <div style={{ width: 1.5, height: 4.5, borderRadius: 1, background: ink, opacity: 0.45 }} />
        </div>
      </div>
    </div>
  );
}

// ── Sample data ──────────────────────────────────────────────
const SAMPLE_Q = 'what happened on may twenty ninth';
const SAMPLE_Q_FINAL = 'What happened on May 29?';
const ANSWER_SEGS = [
  "On May 29 you worked through how to model channels in the configuration. You decided to skip a dedicated slotting layer and instead treat the channel as a service hub, with a second channel acting as a store — both performing the same function.",
  { cite: 'May 29' },
  "\n\n",
  "From a configuration view that means surfacing three setups: email service, store, and channel cube. Underneath, though, there are only two real capabilities: email and direct.",
  { cite: 'May 28' },
];
function buildTokens(segs) {
  const out = [];
  segs.forEach(s => {
    if (typeof s !== 'string') { out.push(s); return; }
    s.split(/(\n\n)/).forEach(part => {
      if (part === '\n\n') out.push({ br: true });
      else part.split(' ').filter(Boolean).forEach(w => out.push({ w }));
    });
  });
  return out;
}
const ANSWER_TOKENS = buildTokens(ANSWER_SEGS);
const SOURCES = [
  { date: 'May 29', snippet: 'Standup — channel config, service hub vs. slotting layer' },
  { date: 'May 28', snippet: 'Email & direct capabilities; three configurations' },
];

function App() {
  const [tw, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const t = jotTheme(tw.appearance === 'dark');
  const accent = 'blue'; // locked — blue only, never coral

  const [phase, setPhase] = useState('listening'); // listening | thinking | answer
  const [transcript, setTranscript] = useState('');
  const [typing, setTyping] = useState(false);
  const [countdown, setCountdown] = useState(null);
  const [thinkStep, setThinkStep] = useState(0);
  const [aVisible, setAVisible] = useState(0);
  const [copied, setCopied] = useState(false);
  const [toast, setToast] = useState(null);
  const inputRef = useRef(null);
  const runId = useRef(0); // cancels stale timers across resets

  // ── reset to a fresh listening session ─────────────────────
  const reset = useCallback(() => {
    runId.current++;
    setPhase('listening'); setTranscript(''); setTyping(false);
    setCountdown(null); setThinkStep(0); setAVisible(0); setCopied(false);
  }, []);

  // ── voice dictation demo: stream the sample question ───────
  useEffect(() => {
    if (phase !== 'listening' || typing) return;
    const id = runId.current;
    const words = SAMPLE_Q.split(' ');
    let i = transcript ? transcript.split(' ').length : 0;
    if (i >= words.length) return; // streaming finished -> countdown effect takes over
    const delay = i === 0 ? 700 : 150 + Math.random() * 120;
    const h = setTimeout(() => {
      if (runId.current !== id) return;
      setTranscript(words.slice(0, i + 1).join(' '));
    }, delay);
    return () => clearTimeout(h);
  }, [phase, typing, transcript]);

  // ── 5s silence auto-send once dictation has finished ───────
  useEffect(() => {
    if (phase !== 'listening' || typing) return;
    const finished = transcript.split(' ').length >= SAMPLE_Q.split(' ').length && transcript.length > 0;
    if (!finished) { setCountdown(null); return; }
    const id = runId.current;
    setCountdown(5);
    let n = 5;
    const h = setInterval(() => {
      if (runId.current !== id) { clearInterval(h); return; }
      n -= 1;
      if (n <= 0) { clearInterval(h); send(); }
      else setCountdown(n);
    }, 1000);
    return () => clearInterval(h);
  }, [phase, typing, transcript]);

  // ── send -> thinking -> answer ─────────────────────────────
  function send() {
    if (!transcript.trim()) return;
    runId.current++;
    const id = runId.current;
    setCountdown(null); setPhase('thinking'); setThinkStep(0);
    const t1 = setTimeout(() => runId.current === id && setThinkStep(1), 850);
    const t2 = setTimeout(() => runId.current === id && setThinkStep(2), 1750);
    const t3 = setTimeout(() => { if (runId.current === id) { setPhase('answer'); setAVisible(0); } }, 2550);
  }

  // ── stream the answer tokens ───────────────────────────────
  useEffect(() => {
    if (phase !== 'answer') return;
    if (aVisible >= ANSWER_TOKENS.length) return;
    const id = runId.current;
    const tok = ANSWER_TOKENS[aVisible];
    const d = tok && tok.cite ? 220 : (tok && tok.br ? 180 : 34 + Math.random() * 34);
    const h = setTimeout(() => { if (runId.current === id) setAVisible(v => v + 1); }, d);
    return () => clearTimeout(h);
  }, [phase, aVisible]);

  const questionLabel = typing && transcript ? transcript : SAMPLE_Q_FINAL;

  function onType() {
    runId.current++; // stop the voice demo
    setTyping(v => {
      const nv = !v;
      if (nv) { setCountdown(null); setTimeout(() => inputRef.current && inputRef.current.focus(), 40); }
      else { setTranscript(''); }
      return nv;
    });
  }
  function onCite(label) {
    setToast(`Opening “${label}” note…`);
    setTimeout(() => setToast(null), 1600);
  }
  function onCopy() { setCopied(true); setTimeout(() => setCopied(false), 1400); }

  const ListenView = ListeningCanvas; // locked — canvas layout

  // ── scaling ────────────────────────────────────────────────
  const wrapRef = useRef(null);
  useEffect(() => {
    function fit() {
      const pad = 26, bezel = 13;
      const W = ONE_W + bezel * 2, H = ONE_H + bezel * 2;
      const s = Math.min((window.innerWidth - pad) / W, (window.innerHeight - pad) / H, 1.18);
      if (wrapRef.current) wrapRef.current.style.transform = `scale(${s})`;
    }
    fit(); window.addEventListener('resize', fit); return () => window.removeEventListener('resize', fit);
  }, []);

  const dim = t.dark ? '#080b12' : '#9aa4b4';

  return (
    <div style={{ position: 'fixed', inset: 0, background: t.dark ? '#05070c' : '#aab4c6',
      display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden', transition: 'background .4s' }}>
      <div ref={wrapRef} style={{ transformOrigin: 'center center' }}>
        <div style={{ width: ONE_W + 26, height: ONE_H + 26, borderRadius: 67, background: '#000', padding: 13,
          boxShadow: '0 50px 100px -30px rgba(0,0,0,0.7), 0 0 0 2px rgba(255,255,255,0.06)' }}>
          <div style={{ position: 'relative', width: ONE_W, height: ONE_H, borderRadius: 54, overflow: 'hidden',
            background: dim, transition: 'background .4s' }}>
            <StatusBar t={t} listening={phase === 'listening'} />

            {/* presented sheet */}
            <div style={{ position: 'absolute', top: 44, left: 0, right: 0, bottom: 0, background: t.bg,
              borderRadius: '40px 40px 0 0', overflow: 'hidden', boxShadow: '0 -1px 0 rgba(255,255,255,0.06)',
              transition: 'background .4s' }}>
              <AskChrome t={t} accent={accent} onDone={reset} />

              {phase === 'listening' && (
                <ListenView t={t} accent={accent} transcript={transcript} typing={typing}
                  countdown={countdown} onSend={send} onType={onType}
                  onInput={setTranscript} inputRef={inputRef} />
              )}
              {phase === 'thinking' && (
                <ThinkingView t={t} accent={accent} question={questionLabel} stepIdx={thinkStep} />
              )}
              {phase === 'answer' && (
                <AnswerView t={t} accent={accent} question={questionLabel}
                  tokens={ANSWER_TOKENS} visible={aVisible} done={aVisible >= ANSWER_TOKENS.length}
                  sources={SOURCES} model="Apple Intelligence" searched={9} carded={false}
                  onAskAnother={reset} onCite={onCite} onCopy={onCopy} copied={copied} />
              )}
            </div>

            {/* toast */}
            {toast && (
              <div style={{ position: 'absolute', bottom: 40, left: '50%', transform: 'translateX(-50%)', zIndex: 80,
                background: t.dark ? 'rgba(20,28,44,0.92)' : 'rgba(28,38,58,0.92)', color: '#fff',
                fontFamily: SYS, fontWeight: 500, fontSize: 14, padding: '11px 18px', borderRadius: 16,
                backdropFilter: 'blur(14px)', WebkitBackdropFilter: 'blur(14px)', animation: 'askRise .3s ease',
                boxShadow: '0 12px 30px -8px rgba(0,0,0,0.5)' }}>{toast}</div>
            )}
          </div>
        </div>
      </div>

      <AskTweaks tw={tw} setTweak={setTweak} />
    </div>
  );
}

function AskTweaks({ tw, setTweak }) {
  return (
    <TweaksPanel>
      <TweakSection label="Appearance" />
      <TweakRadio label="Mode" value={tw.appearance} options={['light', 'dark']} onChange={v => setTweak('appearance', v)} />
    </TweaksPanel>
  );
}

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "appearance": "dark"
}/*EDITMODE-END*/;

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
