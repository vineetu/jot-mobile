/* watch-app.jsx — Jot Watch shell: nav, scaling, review rail */
const { useState, useEffect, useRef } = React;

const SCREENS = [
  { id: 'home', label: 'Home' },
  { id: 'recording', label: 'Recording' },
  { id: 'all', label: 'All notes' },
  { id: 'detail', label: 'Transcript' },
  { id: 'diagnostics', label: 'Diagnostics' },
];

function App() {
  const [screen, setScreen] = useState('home');
  const [note, setNote] = useState(null);
  const go = (s, payload) => { if (s === 'detail') setNote(payload); setScreen(s); };

  const wrapRef = useRef(null);
  useEffect(() => {
    function fit() {
      const Wd = SCREEN_W + 28 + 24, Ht = SCREEN_H + 28 + 24;
      const s = Math.min((window.innerWidth - 240) / Wd, (window.innerHeight - 40) / Ht, 1.25);
      if (wrapRef.current) wrapRef.current.style.transform = `scale(${Math.max(s, 0.4)})`;
    }
    fit(); window.addEventListener('resize', fit); return () => window.removeEventListener('resize', fit);
  }, []);

  function render() {
    switch (screen) {
      case 'recording': return <Recording go={go} />;
      case 'all': return <AllNotes go={go} />;
      case 'detail': return <Detail go={go} note={note} />;
      case 'diagnostics': return <Diagnostics go={go} />;
      default: return <Home go={go} />;
    }
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'radial-gradient(120% 90% at 50% 0%, #14161c 0%, #0a0b0e 60%, #060708 100%)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      {/* review rail (outside the watch, for jumping screens) */}
      <div style={{ position: 'fixed', left: 22, top: '50%', transform: 'translateY(-50%)', display: 'flex', flexDirection: 'column', gap: 8, zIndex: 30 }}>
        <div style={{ fontFamily: '-apple-system, system-ui, sans-serif', fontWeight: 700, fontSize: 10, letterSpacing: '0.12em', color: 'rgba(255,255,255,0.32)', textTransform: 'uppercase', marginBottom: 4, paddingLeft: 2 }}>Screens</div>
        {SCREENS.map(s => (
          <button key={s.id} onClick={() => { if (s.id === 'detail') setNote(NOTES[1]); setScreen(s.id); }} style={{
            textAlign: 'left', padding: '7px 13px', borderRadius: 10, cursor: 'pointer', minWidth: 124,
            border: '1px solid ' + (screen === s.id ? 'rgba(26,140,255,0.5)' : 'rgba(255,255,255,0.08)'),
            background: screen === s.id ? 'rgba(26,140,255,0.16)' : 'rgba(255,255,255,0.03)',
            color: screen === s.id ? '#8CCBFF' : 'rgba(255,255,255,0.6)',
            fontFamily: '-apple-system, system-ui, sans-serif', fontWeight: 600, fontSize: 13, WebkitTapHighlightColor: 'transparent',
          }}>{s.label}</button>
        ))}
      </div>

      <div ref={wrapRef} style={{ transformOrigin: 'center center' }}>
        <WatchFrame>{render()}</WatchFrame>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
