/* ask-ui.jsx — Ask Jot · shared atoms (chrome, waveform, suggestion, send button, citation, source) */

// ── Glyphs specific to Ask ───────────────────────────────────
function ArrowUp({ color = '#fff', size = 22 }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none"><path d="M12 19V5M6 11l6-6 6 6" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function DocGlyph({ color, size = 13 }) {
  return <svg width={size} height={size} viewBox="0 0 16 16" fill="none"><path d="M4 1.6h5L13 5.4V13a1.4 1.4 0 0 1-1.4 1.4H4A1.4 1.4 0 0 1 2.6 13V3A1.4 1.4 0 0 1 4 1.6z" fill={color} opacity="0.16"/><path d="M4 1.6h5L13 5.4V13a1.4 1.4 0 0 1-1.4 1.4H4A1.4 1.4 0 0 1 2.6 13V3A1.4 1.4 0 0 1 4 1.6z" stroke={color} strokeWidth="1.1"/><path d="M9 1.8V5.4h3.6" stroke={color} strokeWidth="1.1" strokelinejoin="round"/></svg>;
}
function ChevR({ color, size = 16 }) {
  return <svg width={size} height={size} viewBox="0 0 16 16" fill="none"><path d="M6 3.5L10.5 8 6 12.5" stroke={color} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function CopyGlyph({ color, size = 19 }) {
  return <svg width={size} height={size} viewBox="0 0 20 20" fill="none"><rect x="6.5" y="6.5" width="10" height="11.5" rx="2.6" stroke={color} strokeWidth="1.7"/><path d="M13.5 6.5V4.4A2.4 2.4 0 0 0 11.1 2H5.4A2.4 2.4 0 0 0 3 4.4v8.2A2.4 2.4 0 0 0 5.4 15" stroke={color} strokeWidth="1.7" strokeLinecap="round"/></svg>;
}
function CheckMini({ color, size = 19 }) {
  return <svg width={size} height={size} viewBox="0 0 20 20" fill="none"><path d="M4 10.5l4 4 8-9" stroke={color} strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function KbMini({ color, size = 19 }) {
  return <svg width={size} height={size} viewBox="0 0 22 22" fill="none"><rect x="2.5" y="6" width="17" height="11" rx="2.6" stroke={color} strokeWidth="1.6"/><g fill={color}><rect x="5.4" y="9" width="2" height="2" rx="0.6"/><rect x="9.6" y="9" width="2" height="2" rx="0.6"/><rect x="13.8" y="9" width="2" height="2" rx="0.6"/><rect x="7.5" y="12.6" width="7" height="2" rx="1"/></g></svg>;
}

// ── Sheet chrome: Done · Ask Jot · BETA ──────────────────────
function AskChrome({ t, accent, onDone }) {
  const a = ACCENTS[accent];
  return (
    <div style={{ position: 'absolute', top: 16, left: 0, right: 0, zIndex: 30, height: 56,
      display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <button onClick={onDone} style={{ position: 'absolute', left: 18, top: 6,
        height: 38, padding: '0 17px', borderRadius: 19,
        background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`,
        backdropFilter: 'blur(16px)', WebkitBackdropFilter: 'blur(16px)',
        color: t.ink, fontFamily: SYS, fontWeight: 500, fontSize: 16.5, cursor: 'pointer',
        WebkitTapHighlightColor: 'transparent' }}>Done</button>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 1 }}>
        <div style={{ fontFamily: SYS, fontWeight: 700, fontSize: 18, color: t.ink, letterSpacing: '-0.2px' }}>Ask Jot</div>
        <div style={{ fontFamily: SYS, fontWeight: 700, fontSize: 9.5, letterSpacing: '2px',
          color: a.solid }}>BETA</div>
      </div>
    </div>
  );
}

// ── Live waveform (reactive bars) ────────────────────────────
function Waveform({ color, active = true, size = 1 }) {
  const bars = [
    { a: 'wv1', d: '0.7s', h: 13 }, { a: 'wv3', d: '0.9s', h: 22 }, { a: 'wv2', d: '0.6s', h: 17 },
    { a: 'wv1', d: '0.8s', h: 26 }, { a: 'wv3', d: '0.7s', h: 15 }, { a: 'wv2', d: '1.0s', h: 21 },
    { a: 'wv1', d: '0.65s', h: 13 },
  ];
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 4 * size, height: 28 * size }}>
      {bars.map((b, i) => (
        <span key={i} style={{ width: 3.5 * size, height: b.h * size, borderRadius: 3, background: color,
          transformOrigin: 'center',
          animation: active ? `${b.a} ${b.d} ease-in-out infinite` : 'none',
          opacity: active ? 1 : 0.4, transform: active ? undefined : 'scaleY(0.3)',
          transition: 'opacity .3s' }} />
      ))}
    </div>
  );
}

// ── Single send-stop control ─────────────────────────────────
// One button: dim when no words yet, accent when ready. Tapping sends AND stops the mic.
function SendStop({ t, accent, ready, onSend, size = 56 }) {
  const a = ACCENTS[accent];
  return (
    <button onClick={ready ? onSend : undefined} aria-disabled={!ready} style={{
      width: size, height: size, borderRadius: size / 2, flexShrink: 0, border: 'none',
      background: ready ? a.grad : (t.dark ? 'rgba(255,255,255,0.10)' : 'rgba(40,54,82,0.10)'),
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      cursor: ready ? 'pointer' : 'default', padding: 0,
      boxShadow: ready ? `0 8px 22px -5px ${a.glow}, inset 0 1px 0 rgba(255,255,255,0.34)` : 'none',
      transition: 'background .3s, box-shadow .3s, transform .12s', WebkitTapHighlightColor: 'transparent',
    }} onMouseDown={e => ready && (e.currentTarget.style.transform = 'scale(0.92)')}
       onMouseUp={e => e.currentTarget.style.transform = 'scale(1)'}
       onMouseLeave={e => e.currentTarget.style.transform = 'scale(1)'}>
      <ArrowUp color={ready ? '#fff' : (t.dark ? 'rgba(255,255,255,0.5)' : 'rgba(40,54,82,0.5)')} size={size * 0.42} />
    </button>
  );
}

// ── Rotating spoken-aloud suggestions (listening, field empty) ─
const ASK_SUGGESTIONS = [
  'Summarize what I recorded today',
  'What did I decide about the launch?',
  'Pull every note that mentions pricing',
  'What were my action items last week?',
  'Connect my notes about the redesign',
];
function SuggestionLine({ t, paused }) {
  const [i, setI] = React.useState(0);
  React.useEffect(() => {
    if (paused) return;
    const id = setInterval(() => setI(v => (v + 1) % ASK_SUGGESTIONS.length), 2800);
    return () => clearInterval(id);
  }, [paused]);
  return (
    <div style={{ height: 26, display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
      <span key={i} style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 400, fontSize: 17,
        color: t.inkCaption, animation: 'askFade .5s ease', textAlign: 'center', whiteSpace: 'nowrap' }}>
        “{ASK_SUGGESTIONS[i]}”
      </span>
    </div>
  );
}

// ── Inline citation chip ─────────────────────────────────────
function CitationChip({ label, t, accent, onClick }) {
  const a = ACCENTS[accent];
  return (
    <button onClick={onClick} style={{
      display: 'inline-flex', alignItems: 'center', gap: 4, verticalAlign: 'baseline',
      transform: 'translateY(1.5px)', margin: '0 1px',
      background: a.soft, border: `0.5px solid ${a.solid}40`, borderRadius: 7,
      padding: '1.5px 7px 1.5px 5px', cursor: 'pointer', WebkitTapHighlightColor: 'transparent',
      fontFamily: SYS, fontWeight: 600, fontSize: 12.5, color: a.solid, lineHeight: 1.2,
    }}><DocGlyph color={a.solid} size={11} />{label}</button>
  );
}

// ── Source row (cited note) ──────────────────────────────────
function SourceRow({ date, title, snippet, t, accent, onClick }) {
  const a = ACCENTS[accent];
  return (
    <button onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%',
      textAlign: 'left', background: 'none', border: 'none', cursor: 'pointer', padding: '11px 4px',
      WebkitTapHighlightColor: 'transparent' }}>
      <span style={{ width: 30, height: 30, borderRadius: 9, flexShrink: 0, background: a.soft,
        display: 'flex', alignItems: 'center', justifyContent: 'center' }}><DocGlyph color={a.solid} size={15} /></span>
      <span style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 1 }}>
        <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 14.5, color: t.ink }}>{date}</span>
        <span style={{ fontFamily: SYS, fontWeight: 400, fontSize: 13, color: t.inkSub,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{snippet}</span>
      </span>
      <ChevR color={t.inkCaption} />
    </button>
  );
}

Object.assign(window, {
  ArrowUp, DocGlyph, ChevR, CopyGlyph, CheckMini, KbMini,
  AskChrome, Waveform, SendStop, SuggestionLine, ASK_SUGGESTIONS, CitationChip, SourceRow,
});
