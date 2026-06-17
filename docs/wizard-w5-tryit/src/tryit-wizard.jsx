/* tryit-wizard.jsx — the wizard shell: gradient bg, chrome (back · dots · close), editorial type, practice field */

function Frame({ t, children }) {
  return (
    <div style={{ width: 390, height: 844, position: 'relative', background: t.bg, overflow: 'hidden',
      display: 'flex', flexDirection: 'column', fontFamily: SYS }}>
      {children}
    </div>
  );
}

function StatusBar({ t }) {
  return (
    <div style={{ height: 54, flexShrink: 0, position: 'relative', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 30px 0 34px', zIndex: 4 }}>
      <span style={{ fontFamily: SYS, fontSize: 15.5, fontWeight: 600, color: t.statusInk, letterSpacing: 0.3 }}>9:41</span>
      <div style={{ position: 'absolute', top: 11, left: '50%', transform: 'translateX(-50%)', width: 122, height: 36, borderRadius: 19, background: '#000' }} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        <svg width="18" height="12" viewBox="0 0 18 12" fill="none"><rect x="0" y="8" width="3" height="4" rx="1" fill={t.statusInk}/><rect x="5" y="5.5" width="3" height="6.5" rx="1" fill={t.statusInk}/><rect x="10" y="3" width="3" height="9" rx="1" fill={t.statusInk}/><rect x="15" y="0.5" width="3" height="11.5" rx="1" fill={t.statusInk}/></svg>
        <svg width="17" height="12" viewBox="0 0 17 12" fill="none"><path d="M8.5 2.4c2.7 0 5.2 1 7.1 2.7M8.5 6.1c1.7 0 3.3.6 4.5 1.7M3 4.9C4.7 3.5 6.5 2.4 8.5 2.4" stroke={t.statusInk} strokeWidth="1.5" strokeLinecap="round"/><circle cx="8.5" cy="10" r="1.3" fill={t.statusInk}/></svg>
        <svg width="26" height="13" viewBox="0 0 26 13" fill="none"><rect x="0.5" y="1" width="21" height="11" rx="3" stroke={t.statusInk} strokeOpacity="0.4" strokeWidth="1"/><rect x="2" y="2.5" width="16" height="8" rx="1.8" fill={t.statusInk}/><rect x="23" y="4.5" width="1.8" height="4" rx="0.9" fill={t.statusInk} fillOpacity="0.4"/></svg>
      </div>
    </div>
  );
}

function GlassCircle({ t, children }) {
  return (
    <div style={{ width: 46, height: 46, borderRadius: 23, flexShrink: 0, background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`,
      backdropFilter: 'blur(16px)', WebkitBackdropFilter: 'blur(16px)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{children}</div>
  );
}
function CloseX({ color }) {
  return <svg width="16" height="16" viewBox="0 0 17 17" fill="none"><path d="M2 2l13 13M15 2L2 15" stroke={color} strokeWidth="2.4" strokeLinecap="round"/></svg>;
}
function Dots({ t, total = 7, current = 4 }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      {Array.from({ length: total }).map((_, i) => {
        const active = i === current, done = i < current;
        return <span key={i} style={{ width: active ? 7.5 : 6.5, height: active ? 7.5 : 6.5, borderRadius: 5,
          background: active ? t.accentDot : (done ? t.dotDone : t.dotTodo) }} />;
      })}
    </div>
  );
}
function WizardChrome({ t, current = 4 }) {
  return (
    <div style={{ flexShrink: 0, position: 'relative', zIndex: 4, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 20px 0' }}>
      <GlassCircle t={t}><ChevLeft color={t.chromeGlyph} size={20} /></GlassCircle>
      <Dots t={t} current={current} />
      <GlassCircle t={t}><CloseX color={t.chromeGlyph} /></GlassCircle>
    </div>
  );
}

function Title({ t, children, size = 29 }) {
  return <h1 style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontOpticalSizing: 'auto',
    fontSize: size, lineHeight: 1.05, letterSpacing: '-0.5px', color: t.ink, textAlign: 'center', margin: 0, whiteSpace: 'nowrap' }}>{children}</h1>;
}
function Body({ t, children, max = 330 }) {
  return <p style={{ fontFamily: SYS, fontWeight: 400, fontSize: 17, lineHeight: 1.42, color: t.inkSub,
    textAlign: 'center', margin: '0 auto', maxWidth: max, textWrap: 'pretty' }}>{children}</p>;
}

// The practice text field — the "chat-style input box" inside the wizard
function PracticeField({ t, text, placeholder, glow, caret }) {
  return (
    <div className={glow ? 'try-glow' : ''} style={{ position: 'relative', width: '100%', minHeight: 104, borderRadius: 18,
      background: t.field, border: `1.5px solid ${glow ? t.accentDot : t.fieldBord}`,
      backdropFilter: 'blur(14px)', WebkitBackdropFilter: 'blur(14px)', padding: '16px 18px', overflow: 'hidden', display: 'flex' }}>
      {glow && <span className="try-sheen" />}
      <div style={{ display: 'flex', alignItems: 'flex-start', minWidth: 0 }}>
        {text
          ? <span style={{ fontFamily: SYS, fontSize: 16.5, lineHeight: 1.42, color: t.ink }}>{text}</span>
          : <span style={{ fontFamily: SYS, fontSize: 16.5, lineHeight: 1.42, color: glow ? t.accentDot : t.inkCap, fontWeight: glow ? 600 : 400 }}>
              {placeholder}{caret && <span className="try-caret" style={{ color: t.accentDot }} />}
            </span>}
      </div>
    </div>
  );
}

// Warm, slightly playful nudges — what to say if you're stuck.
const SUGGESTIONS = [
  'I am awesome.',
  'I believe in myself.',
  'Today is going to be a good day.',
  'I’ve got this.',
  'Hello from my new keyboard.',
];

function Helper({ t, state }) {
  if (state === 'done') {
    return (
      <div style={{ height: 24, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7 }}>
        <svg width="15" height="15" viewBox="0 0 14 14" fill="none"><path d="M3 7.4l2.8 2.8L11 4" stroke={t.accentDot} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>
        <span style={{ fontFamily: SYS, fontSize: 14, fontWeight: 600, color: t.accentDot }}>Pasted from Jot</span>
      </div>
    );
  }
  // Suggest a phrase while the field is still empty (don't nag once words are flowing).
  const idx = { invite: 1, rise: 0, init: 2 }[state];
  if (idx === undefined) return <div style={{ height: 24 }} />;
  return (
    <div style={{ height: 24, display: 'flex', alignItems: 'baseline', justifyContent: 'center', gap: 7, flexWrap: 'wrap' }}>
      <span style={{ fontFamily: SYS, fontSize: 13.5, color: t.inkCap }}>Try saying</span>
      <span style={{ fontFamily: SERIF, fontStyle: 'italic', fontSize: 16, color: t.inkItalic }}>“{SUGGESTIONS[idx]}”</span>
    </div>
  );
}

function Cta({ t, children }) {
  return (
    <button style={{ width: '100%', height: 62, borderRadius: 31, border: 'none', cursor: 'pointer', background: t.accentGrad, color: '#fff',
      fontFamily: SYS, fontWeight: 600, fontSize: 18.5, letterSpacing: '-0.2px',
      boxShadow: `0 10px 32px -6px ${t.accentGlow}, 0 2px 6px rgba(0,0,0,0.26), inset 0 1px 0 rgba(255,255,255,0.34)` }}>{children}</button>
  );
}
function Footer({ t, children }) {
  return <div style={{ flexShrink: 0, padding: '0 24px 14px', position: 'relative', zIndex: 4 }}>{children}</div>;
}
function HomeBar({ t }) {
  return (
    <div style={{ height: 24, flexShrink: 0, display: 'flex', alignItems: 'flex-end', justifyContent: 'center', paddingBottom: 9 }}>
      <div style={{ width: 134, height: 5, borderRadius: 3, background: t.dark ? 'rgba(233,238,247,0.3)' : 'rgba(22,32,52,0.26)' }} />
    </div>
  );
}

Object.assign(window, { Frame, StatusBar, WizardChrome, GlassCircle, CloseX, Dots, Title, Body, PracticeField, Helper, Cta, Footer, HomeBar });
