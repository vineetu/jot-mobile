/* watch-screens.jsx — Jot Watch · elevated redesign (watchOS-native, brand blue, true black) */

const NOTES = [
  { t: 'Also, the home screen redesign', d: 'Today · 9:04', body: 'Also, the home screen redesign needs another pass — the recent list feels cramped at the top. Let me move the sync row up.', synced: true },
  { t: 'Running late', d: 'Today · 8:57', body: "Running late — traffic on the bridge is backed up past the tunnel. I'll be there in about ten minutes.", synced: true },
  { t: 'Pick up oat milk', d: 'Yesterday · 18:12', body: 'Pick up oat milk and the dry cleaning on the way home.', synced: true },
  { t: 'Idea for the cold open', d: 'Yesterday · 14:40', body: 'Idea for the cold open: start on the watch face, raise to speak, cut to the transcript landing on the phone.', synced: false },
  { t: 'Reschedule the dentist', d: 'Mon · 11:20', body: 'Reschedule the dentist for sometime after the 15th.', synced: true },
];

const CARD = {
  background: 'linear-gradient(180deg, rgba(255,255,255,0.075) 0%, rgba(255,255,255,0.035) 100%)',
  border: '0.5px solid rgba(255,255,255,0.09)',
  boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.10)',
  borderRadius: 22,
};

function NoteCell({ n, onClick, i = 0 }) {
  return (
    <button onClick={onClick} style={{
      display: 'block', width: '100%', textAlign: 'left', border: 'none', cursor: 'pointer',
      ...CARD, padding: '13px 16px', marginBottom: 8, WebkitTapHighlightColor: 'transparent',
    }}>
      <div style={{ fontFamily: SYS, fontWeight: 600, fontSize: 17.5, lineHeight: 1.15, color: W.ink, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', letterSpacing: '-0.2px' }}>{n.t}</div>
      <div style={{ fontFamily: SYS, fontWeight: 400, fontSize: 13.5, color: W.sub, marginTop: 3 }}>{n.d}</div>
    </button>
  );
}
function SectionLabel({ children, right }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', margin: '20px 4px 10px' }}>
      <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 14, color: W.sub, letterSpacing: '0.01em' }}>{children}</span>
      {right}
    </div>
  );
}

// ── Home — hero Dictate ──────────────────────────────────────
// Brand lockup: the full "jot" as ONE cohesive monoline stroked wordmark (the logo-lab
// version) — j, o, t all the same thin stroke, with the waveform tittle on the j.
function BrandHeader() {
  return (
    <div style={{ marginLeft: 3, marginBottom: 9 }}>
      <svg height="30" viewBox="6 6 192 150" fill="none" style={{ display: 'block', overflow: 'visible' }}>
        <g stroke={W.blue} strokeWidth="12" strokeLinecap="round" strokeLinejoin="round" fill="none">
          <path d="M42 52 L42 116 Q42 138 18 138" />
          <circle cx="100" cy="78" r="30" />
          <path d="M160 32 L160 99 Q160 108 172 107" />
          <path d="M139 57 L183 57" />
        </g>
        <g stroke={W.blue} strokeWidth="5" strokeLinecap="round">
          <line x1="31" y1="19" x2="31" y2="29" /><line x1="42" y1="15" x2="42" y2="33" /><line x1="53" y1="19" x2="53" y2="29" />
        </g>
      </svg>
    </div>
  );
}

function Home({ go }) {
  return (
    <Screen top={28} pad={13}>
      <TimeChip />

      {/* hero dictate — record-sized circle, gentle breathe + glow */}
      <div style={{ position: 'relative', width: 132, height: 132, margin: '16px auto 0' }}>
        {/* radial glow behind */}
        <div style={{ position: 'absolute', inset: -32, borderRadius: '50%', background: 'radial-gradient(circle, rgba(26,140,255,0.30) 0%, rgba(26,140,255,0) 64%)', filter: 'blur(6px)' }} />
        {/* record button */}
        <button onClick={() => go('recording')} style={{
          position: 'absolute', inset: 0, borderRadius: '50%', border: 'none', cursor: 'pointer',
          background: 'radial-gradient(circle at 50% 30%, #5BB4FF 0%, #1B86F0 52%, #0061C8 100%)',
          boxShadow: 'inset 0 2px 1px rgba(255,255,255,0.55), inset 0 -8px 18px rgba(0,40,110,0.45), 0 0 44px -10px rgba(26,140,255,0.85), 0 12px 26px -12px rgba(0,0,0,0.6)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', animation: 'breathe 4.5s ease-in-out infinite', WebkitTapHighlightColor: 'transparent',
        }} onMouseDown={e => e.currentTarget.style.transform = 'scale(0.95)'} onMouseUp={e => e.currentTarget.style.transform = 'scale(1)'} onMouseLeave={e => e.currentTarget.style.transform = 'scale(1)'}>
          <MicGlyph size={46} />
        </button>
      </div>
      <div style={{ fontFamily: SYS, fontWeight: 600, fontSize: 17, color: W.ink, textAlign: 'center', marginTop: 26, letterSpacing: '-0.2px' }}>Tap to dictate</div>

      <SectionLabel right={<button onClick={() => go('all')} style={{ background: 'none', border: 'none', cursor: 'pointer', fontFamily: SYS, fontWeight: 600, fontSize: 14, color: W.blue, padding: 0 }}>All 10</button>}>Recent</SectionLabel>
      {NOTES.slice(0, 3).map((n, i) => <NoteCell key={i} n={n} i={i} onClick={() => go('detail', n)} />)}
    </Screen>
  );
}

// ── Recording ────────────────────────────────────────────────
function Recording({ go }) {
  const wave = '#FF6B57'; // coral, matching the record dot
  const [secs, setSecs] = React.useState(0);
  const [bars, setBars] = React.useState(() => Array.from({ length: 21 }, () => 0.3));
  React.useEffect(() => {
    const t = setInterval(() => setSecs(s => s + 1), 1000);
    const w = setInterval(() => setBars(Array.from({ length: 21 }, (_, i) => {
      const env = 1 - Math.abs(i - 10) / 11;            // center-weighted envelope
      return 0.12 + Math.random() * (0.35 + env * 0.65);
    })), 110);
    return () => { clearInterval(t); clearInterval(w); };
  }, []);
  const mm = String(Math.floor(secs / 60)).padStart(2, '0');
  const ss = String(secs % 60).padStart(2, '0');
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      {/* coral glow behind the stop circle */}
      <div style={{ position: 'absolute', top: 70, left: '50%', transform: 'translateX(-50%)', width: 240, height: 240, borderRadius: '50%', background: 'radial-gradient(circle, rgba(255,107,87,0.32) 0%, rgba(255,107,87,0) 66%)', filter: 'blur(10px)' }} />

      <TimeChip icon={<svg width="13" height="17" viewBox="0 0 13 17" fill="none"><rect x="4" y="1.5" width="5" height="9" rx="2.5" fill={W.orange} /><path d="M2 8.5a4.5 4.5 0 0 0 9 0M6.5 13v2.5" stroke={W.orange} strokeWidth="1.5" strokeLinecap="round" /></svg>}>6:02</TimeChip>
      <div style={{ position: 'absolute', top: 12, left: 16, zIndex: 8 }}><RoundBtn onClick={() => go('home')}><CloseGlyph size={16} color="#fff" /></RoundBtn></div>

      {/* STOP = same place/size as the Dictate circle, with the time inside it */}
      <div style={{ position: 'absolute', top: 78, left: 0, right: 0, display: 'flex', justifyContent: 'center' }}>
        <button onClick={() => go('home')} style={{
          width: 132, height: 132, borderRadius: '50%', border: 'none', cursor: 'pointer',
          background: 'radial-gradient(circle at 50% 30%, #FF8E7A 0%, #FF6B57 52%, #E0533F 100%)',
          boxShadow: 'inset 0 2px 1px rgba(255,255,255,0.5), inset 0 -8px 18px rgba(120,30,20,0.4), 0 0 44px -10px rgba(255,107,87,0.85), 0 12px 26px -12px rgba(0,0,0,0.6)',
          display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', animation: 'breathe 4.5s ease-in-out infinite', WebkitTapHighlightColor: 'transparent',
        }}>
          <span style={{ fontFamily: SYS, fontWeight: 700, fontSize: 34, color: '#fff', fontVariantNumeric: 'tabular-nums', letterSpacing: '0.5px' }}>{mm}:{ss}</span>
        </button>
      </div>

      {/* live waveform below the circle */}
      <div style={{ position: 'absolute', top: 256, left: 0, right: 0, height: 80, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 4 }}>
        {bars.map((h, i) => (
          <span key={i} style={{
            width: 5, height: `${Math.max(h * 74, 5)}px`, borderRadius: 3,
            background: `linear-gradient(180deg, rgba(255,255,255,0.5) 0%, ${wave} 70%)`,
            boxShadow: `0 0 8px ${wave}80`, transition: 'height .1s ease',
          }} />
        ))}
      </div>

      <div style={{ position: 'absolute', top: 350, left: 0, right: 0, fontFamily: SYS, fontWeight: 500, fontSize: 14.5, color: W.sub, textAlign: 'center' }}>Tap to stop</div>
    </div>
  );
}

// ── Diagnostics ──────────────────────────────────────────────
function Diagnostics({ go }) {
  return (
    <Screen top={11}>
      <TimeChip />
      <SubNav title="Diagnostics" onBack={() => go('home')} />
      <div style={{ ...CARD, padding: '15px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ width: 22, height: 22, borderRadius: 11, background: W.green, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: '0 0 12px -2px rgba(50,215,75,0.7)' }}>
            <svg width="13" height="13" viewBox="0 0 13 13" fill="none"><path d="M2.5 7l3 3L11 3.5" stroke="#000" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
          </span>
          <span style={{ fontFamily: SYS, fontWeight: 700, fontSize: 19, color: W.ink, letterSpacing: '-0.3px' }}>Connected</span>
        </div>
        <div style={{ fontFamily: SYS, fontWeight: 500, fontSize: 15.5, color: W.orange, marginTop: 8, marginLeft: 1 }}>2 waiting to sync</div>
      </div>
      <div style={{ marginTop: 10 }}>
        <Pill height={56} onClick={() => go('home')}>Reset sync</Pill>
      </div>
      <div style={{ fontFamily: SYS, fontWeight: 400, fontSize: 13, lineHeight: 1.4, color: W.ter, textAlign: 'center', marginTop: 12, padding: '0 8px' }}>
        Resets the queue and re-sends pending notes to your iPhone.
      </div>
    </Screen>
  );
}

// ── All notes ────────────────────────────────────────────────
function AllNotes({ go }) {
  return (
    <Screen top={11}>
      <TimeChip />
      <SubNav title="Recents" onBack={() => go('home')} />
      {NOTES.map((n, i) => <NoteCell key={i} n={n} i={i} onClick={() => go('detail', n)} />)}
    </Screen>
  );
}

// ── Transcript detail ────────────────────────────────────────
function Detail({ go, note }) {
  const n = note || NOTES[0];
  return (
    <Screen top={11}>
      <TimeChip />
      <SubNav title={n.d} onBack={() => go('home')} />
      <div style={{ fontFamily: SYS, fontWeight: 500, fontSize: 21, lineHeight: 1.35, color: W.ink, padding: '2px 2px 18px', letterSpacing: '-0.2px' }}>
        {n.body}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '0 2px' }}>
        <span style={{ width: 17, height: 17, borderRadius: 9, background: n.synced ? W.green : 'rgba(255,255,255,0.18)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {n.synced && <svg width="10" height="10" viewBox="0 0 13 13" fill="none"><path d="M2.5 7l3 3L11 3.5" stroke="#000" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>}
        </span>
        <span style={{ fontFamily: SYS, fontWeight: 500, fontSize: 14.5, color: n.synced ? W.sub : W.orange }}>{n.synced ? 'Synced to iPhone' : 'Waiting to sync'}</span>
      </div>
    </Screen>
  );
}

Object.assign(window, { NOTES, Home, Recording, Diagnostics, AllNotes, Detail });
