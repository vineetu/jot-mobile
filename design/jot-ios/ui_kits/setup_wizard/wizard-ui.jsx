/* wizard-ui.jsx — Jot Setup Wizard · tokens, glyphs, brand mark, shared components */

// ── Theme tokens ─────────────────────────────────────────────
function jotTheme(dark) {
  return dark ? {
    dark: true,
    ink:        '#FFFFFF',
    inkSub:     'rgba(233,238,247,0.66)',
    inkCaption: 'rgba(233,238,247,0.42)',
    inkItalic:  'rgba(233,238,247,0.70)',
    chromeFill: 'rgba(255,255,255,0.08)',
    chromeBord: 'rgba(255,255,255,0.16)',
    chromeGlyph:'rgba(255,255,255,0.86)',
    dotDone:    'rgba(255,255,255,0.50)',
    dotTodo:    'rgba(255,255,255,0.20)',
    card:       'rgba(255,255,255,0.06)',
    cardBord:   'rgba(255,255,255,0.11)',
    fieldFill:  'rgba(255,255,255,0.045)',
    fieldBord:  'rgba(255,255,255,0.14)',
    stepCard:   'rgba(255,255,255,0.05)',
    stepBord:   'rgba(255,255,255,0.10)',
    glyphSoft:  'rgba(233,238,247,0.62)',
    kbFill:     '#181F2C',
    kbKey:      'rgba(255,255,255,0.10)',
    kbKeyInk:   '#F2F5FA',
    bg: `radial-gradient(128% 72% at 50% -8%, rgba(64,116,196,0.50) 0%, rgba(40,74,128,0.16) 36%, rgba(18,30,52,0) 60%), radial-gradient(120% 84% at 88% 112%, rgba(120,72,56,0.20) 0%, rgba(120,72,56,0) 52%), linear-gradient(177deg, #1b2c4f 0%, #15233c 32%, #0e1827 72%, #0a1019 100%)`,
  } : {
    dark: false,
    ink:        '#16181D',
    inkSub:     'rgba(54,62,78,0.70)',
    inkCaption: 'rgba(54,62,78,0.48)',
    inkItalic:  'rgba(54,62,78,0.64)',
    chromeFill: 'rgba(255,255,255,0.72)',
    chromeBord: 'rgba(20,30,50,0.08)',
    chromeGlyph:'#3A4252',
    dotDone:    'rgba(54,62,78,0.42)',
    dotTodo:    'rgba(54,62,78,0.18)',
    card:       'rgba(255,255,255,0.78)',
    cardBord:   'rgba(20,30,50,0.07)',
    fieldFill:  'rgba(255,255,255,0.60)',
    fieldBord:  'rgba(20,30,50,0.12)',
    stepCard:   'rgba(255,255,255,0.66)',
    stepBord:   'rgba(20,30,50,0.07)',
    glyphSoft:  'rgba(54,62,78,0.56)',
    kbFill:     '#D2D6DE',
    kbKey:      '#FFFFFF',
    kbKeyInk:   '#1B1E25',
    bg: `radial-gradient(128% 74% at 50% -8%, rgba(150,184,232,0.62) 0%, rgba(150,184,232,0.12) 40%, rgba(150,184,232,0) 62%), radial-gradient(120% 84% at 88% 112%, rgba(222,170,150,0.24) 0%, rgba(222,170,150,0) 52%), linear-gradient(177deg, #E9EEF7 0%, #DEE4EE 44%, #D0D6E0 100%)`,
  };
}

const SERIF = '"Fraunces", Georgia, "Times New Roman", serif';
const SYS   = '-apple-system, "SF Pro Text", system-ui, sans-serif';

// accent ramps (coral = design-system wizard accent · blue = match core app)
const ACCENTS = {
  coral: { grad: 'linear-gradient(180deg, #FF7A63 0%, #F0593D 54%, #E0533F 100%)', solid: '#F0593D', dot: '#FF6B57', glow: 'rgba(240,89,61,0.46)', soft: 'rgba(240,89,61,0.20)' },
  blue:  { grad: 'linear-gradient(180deg, #2E9BFF 0%, #0E7AE6 54%, #0064CC 100%)', solid: '#0E7AE6', dot: '#1A8CFF', glow: 'rgba(26,140,255,0.44)', soft: 'rgba(26,140,255,0.20)' },
};

// ── Brand mark · "j + waveform tittle" (locked) ──────────────
// White stroked lowercase j; the dot/tittle is a 3-bar voice waveform.
// viewBox 0 0 116 160. size = rendered width.
function JotWaveMark({ size = 64, color = '#fff', sw = 15 }) {
  const cx = 58, baseY = 24, sp = 11, ch = 18, sh = 10, bw = sw * 0.36;
  const bar = (dx, h) => <line x1={cx + dx} y1={baseY - h / 2} x2={cx + dx} y2={baseY + h / 2} stroke={color} strokeWidth={bw} strokeLinecap="round" />;
  return (
    <svg width={size} height={size * 160 / 116} viewBox="0 0 116 160" fill="none" style={{ overflow: 'visible' }}>
      <g stroke={color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M58 52 L58 116 Q58 138 34 138" />
        {bar(-sp, sh)}{bar(0, ch)}{bar(sp, sh)}
      </g>
    </svg>
  );
}

// ── Brand mark · "J + mic + recording dot" (legacy alt) ──────
// White glyph, sits inside the coral/blue app-icon squircle.
function JotMark({ size = 64, ink = '#fff', dot = '#FF5A4A' }) {
  const s = size / 64;
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none">
      {/* mic capsule = stem of the J */}
      <rect x="24" y="11.5" width="16" height="27" rx="8" fill={ink} />
      {/* cradle arc */}
      <path d="M17.5 31.5a14.5 14.5 0 0 0 29 0" fill="none" stroke={ink} strokeWidth={3.6 * 1} strokeLinecap="round" />
      {/* stand curving into the J hook (to the left) */}
      <path d="M32 46v4.4c0 5.4-3.6 8.4-8 8.4-3.4 0-5.9-1.7-7-4.2"
            fill="none" stroke={ink} strokeWidth="3.6" strokeLinecap="round" />
      {/* recording dot, top-right */}
      <circle cx="43.4" cy="13.6" r="6" fill={dot} stroke={ink} strokeWidth="2.4" />
    </svg>
  );
}

// 4-point sparkle (the current app icon — alternate via tweak)
function Sparkle({ size = 64, color = '#fff' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none">
      <path d="M32 4c1.6 10.5 4.8 17.6 9.9 22.1C46.6 30.2 53.5 32.4 60 32c-10.5 1.6-17.6 4.8-22.1 9.9C34.2 46.2 32 53.5 32 60c-1.6-10.5-4.8-17.6-9.9-22.1C18 33.8 10.5 31.6 4 32c10.5-1.6 17.6-4.8 22.1-9.9C30.2 17.4 31.6 10.5 32 4z" fill={color}/>
      <path d="M51.5 7c.5 3.4 1.5 5.7 3.2 7.2C56.3 15.7 58.6 16.4 61 16c-3.4.5-5.7 1.5-7.2 3.2C52.2 20.7 51.5 23 52 25c-.5-3.4-1.5-5.7-3.2-7.2C47.2 16.3 44.9 15.6 43 16c3.4-.5 5.7-1.5 7.2-3.2C51.7 11.3 51.1 9 51.5 7z" fill={color} opacity="0.9"/>
    </svg>
  );
}
function MicGlyph({ size = 60, color = '#fff' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 60 60" fill="none">
      <rect x="23" y="9" width="14" height="26" rx="7" fill={color}/>
      <path d="M16 28c0 7.7 6.3 14 14 14s14-6.3 14-14" stroke={color} strokeWidth="3.4" strokeLinecap="round"/>
      <path d="M30 42v8" stroke={color} strokeWidth="3.4" strokeLinecap="round"/>
      <path d="M22.5 51h15" stroke={color} strokeWidth="3.4" strokeLinecap="round"/>
    </svg>
  );
}
function KeyboardGlyph({ size = 60, color = '#2b2b30' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none">
      <rect x="6" y="17" width="52" height="30" rx="7" fill="none" stroke={color} strokeWidth="3.2"/>
      <g fill={color}>
        <rect x="13" y="24" width="5" height="5" rx="1.4"/><rect x="23" y="24" width="5" height="5" rx="1.4"/>
        <rect x="33" y="24" width="5" height="5" rx="1.4"/><rect x="43" y="24" width="5" height="5" rx="1.4"/>
        <rect x="13" y="32" width="5" height="5" rx="1.4"/><rect x="23" y="32" width="5" height="5" rx="1.4"/>
        <rect x="33" y="32" width="5" height="5" rx="1.4"/><rect x="43" y="32" width="5" height="5" rx="1.4"/>
        <rect x="18" y="39.5" width="28" height="4.5" rx="2.2"/>
      </g>
    </svg>
  );
}
function CheckGlyph({ size = 64, color = '#fff' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none">
      <path d="M14 33.5l12.5 12.5L50 19" stroke={color} strokeWidth="7" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}
function ChevLeft({ color }) {
  return <svg width="13" height="22" viewBox="0 0 13 22" fill="none" style={{ marginLeft: -2 }}><path d="M10 2L2 11l8 9" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function CloseX({ color }) {
  return <svg width="16" height="16" viewBox="0 0 17 17" fill="none"><path d="M2 2l13 13M15 2L2 15" stroke={color} strokeWidth="2.4" strokeLinecap="round"/></svg>;
}
function GlobeGlyph({ color, size = 24 }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9.2" stroke={color} strokeWidth="1.7"/><path d="M2.8 12h18.4M12 2.8c2.7 2.5 4.2 5.8 4.2 9.2s-1.5 6.7-4.2 9.2c-2.7-2.5-4.2-5.8-4.2-9.2S9.3 5.3 12 2.8z" stroke={color} strokeWidth="1.7"/></svg>;
}
// Apple Watch silhouette with a tiny live waveform on the face
function WatchGlyph({ size = 46, color = '#fff', wave = '#fff' }) {
  const s = size / 48;
  return (
    <svg width={size} height={size * (60/48)} viewBox="0 0 48 60" fill="none">
      {/* band hints */}
      <path d="M17 8l1.4-3.4A3 3 0 0 1 21.2 3h5.6a3 3 0 0 1 2.8 1.6L31 8M17 52l1.4 3.4A3 3 0 0 0 21.2 57h5.6a3 3 0 0 0 2.8-1.6L31 52" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" opacity="0.5"/>
      {/* case */}
      <rect x="11" y="9" width="26" height="42" rx="9" stroke={color} strokeWidth="2.6"/>
      {/* digital crown */}
      <rect x="37" y="24" width="3.4" height="9" rx="1.7" fill={color}/>
      {/* waveform on the face */}
      <g stroke={wave} strokeWidth="2.4" strokeLinecap="round">
        <line x1="18" y1="27" x2="18" y2="33"/>
        <line x1="22" y1="23.5" x2="22" y2="36.5"/>
        <line x1="26" y1="26" x2="26" y2="34"/>
        <line x1="30" y1="28.5" x2="30" y2="31.5"/>
      </g>
    </svg>
  );
}

// ── App-icon squircle tile ───────────────────────────────────
function AppIcon({ accent, mark = 'jot', size = 132 }) {
  const a = ACCENTS[accent];
  const r = size * 0.245;
  const isBlue = accent === 'blue';
  const grad = isBlue
    ? 'linear-gradient(168deg, #3AA0FF 0%, #1483F2 48%, #0064CC 100%)'
    : a.grad;
  return (
    <div style={{
      width: size, height: size, borderRadius: r,
      background: grad, position: 'relative',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      boxShadow: `inset 0 1.5px 0 rgba(255,255,255,0.45), inset 0 -1px 1px rgba(0,40,100,0.30), inset 0 0 0 0.5px rgba(255,255,255,0.16), 0 ${size * 0.1}px ${size * 0.22}px -${size * 0.06}px ${a.glow}, 0 ${size * 0.03}px ${size * 0.08}px -${size * 0.04}px rgba(0,0,0,0.38)`,
      flexShrink: 0,
    }}>
      <div style={{ position: 'absolute', inset: 0, borderRadius: r, pointerEvents: 'none',
        background: 'linear-gradient(180deg, rgba(255,255,255,0.22) 0%, rgba(255,255,255,0) 38%)' }} />
      {mark === 'sparkle'
        ? <Sparkle size={size * 0.52} />
        : <JotWaveMark size={size * 0.52} sw={15} />}
    </div>
  );
}

// generic gradient tile (mic, keyboard, check)
function HeroTile({ from, to, glow, children, size = 132, radius = 0.30 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: size * radius,
      background: `linear-gradient(180deg, ${from} 0%, ${to} 100%)`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      boxShadow: `inset 0 1.5px 0 rgba(255,255,255,0.38), inset 0 0 0 0.5px rgba(255,255,255,0.14), 0 18px 38px -14px ${glow || to}, 0 6px 14px -8px rgba(0,0,0,0.4)`,
      flexShrink: 0,
    }}>{children}</div>
  );
}

// ── Chrome: back · dots · close ──────────────────────────────
function ChromeBtn({ t, onClick, children, hidden }) {
  return (
    <button onClick={onClick} style={{
      width: 46, height: 46, borderRadius: 23, flexShrink: 0,
      background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`,
      backdropFilter: 'blur(16px)', WebkitBackdropFilter: 'blur(16px)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      cursor: 'pointer', padding: 0, opacity: hidden ? 0 : 1,
      pointerEvents: hidden ? 'none' : 'auto',
      transition: 'opacity .25s, transform .12s', WebkitTapHighlightColor: 'transparent',
    }} onMouseDown={e => e.currentTarget.style.transform = 'scale(0.9)'}
       onMouseUp={e => e.currentTarget.style.transform = 'scale(1)'}
       onMouseLeave={e => e.currentTarget.style.transform = 'scale(1)'}>
      {children}
    </button>
  );
}

function ProgressDots({ total, current, t, accent }) {
  const a = ACCENTS[accent];
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      {Array.from({ length: total }).map((_, i) => {
        const active = i === current;
        const done = i < current;
        return (
          <span key={i} style={{
            width: active ? 7.5 : 6.5, height: active ? 7.5 : 6.5, borderRadius: 5,
            background: active ? a.dot : (done ? t.dotDone : t.dotTodo),
            transition: 'all .3s ease',
          }} />
        );
      })}
    </div>
  );
}

function Chrome({ t, onBack, onClose, dots }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 20px' }}>
      <ChromeBtn t={t} onClick={onBack} hidden={!onBack}><ChevLeft color={t.chromeGlyph} /></ChromeBtn>
      {dots}
      <ChromeBtn t={t} onClick={onClose}><CloseX color={t.chromeGlyph} /></ChromeBtn>
    </div>
  );
}

// ── Typography ───────────────────────────────────────────────
function Title({ children, t, size = 40 }) {
  return (
    <h1 style={{
      fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontOpticalSizing: 'auto',
      fontSize: size, lineHeight: 1.06, letterSpacing: '-0.5px',
      color: t.ink, textAlign: 'center', margin: 0, whiteSpace: 'nowrap',
    }}>{children}</h1>
  );
}
function Body({ children, t, max = 320 }) {
  return (
    <p style={{
      fontFamily: SYS, fontWeight: 400, fontSize: 17.5, lineHeight: 1.42,
      color: t.inkSub, textAlign: 'center', margin: 0, maxWidth: max, textWrap: 'pretty',
    }}>{children}</p>
  );
}

// ── CTA pill + text link ─────────────────────────────────────
function Cta({ children, onClick, accent }) {
  const a = ACCENTS[accent];
  return (
    <button onClick={onClick} style={{
      width: '100%', height: 62, borderRadius: 31, border: 'none',
      background: a.grad, color: '#fff', cursor: 'pointer',
      fontFamily: SYS, fontWeight: 600, fontSize: 18.5, letterSpacing: '-0.2px',
      boxShadow: `0 10px 32px -6px ${a.glow}, 0 2px 6px rgba(0,0,0,0.26), inset 0 1px 0 rgba(255,255,255,0.34)`,
      transition: 'transform .12s', WebkitTapHighlightColor: 'transparent',
    }} onMouseDown={e => e.currentTarget.style.transform = 'scale(0.975)'}
       onMouseUp={e => e.currentTarget.style.transform = 'scale(1)'}
       onMouseLeave={e => e.currentTarget.style.transform = 'scale(1)'}>
      {children}
    </button>
  );
}
function TextLink({ children, onClick, t }) {
  return (
    <button onClick={onClick} style={{
      background: 'none', border: 'none', cursor: 'pointer',
      fontFamily: SYS, fontWeight: 500, fontSize: 16.5, color: t.inkSub,
      padding: '10px 16px', WebkitTapHighlightColor: 'transparent',
    }}>{children}</button>
  );
}

Object.assign(window, {
  jotTheme, SERIF, SYS, ACCENTS,
  JotWaveMark, JotMark, Sparkle, MicGlyph, KeyboardGlyph, CheckGlyph, ChevLeft, CloseX, GlobeGlyph, WatchGlyph,
  AppIcon, HeroTile, ChromeBtn, ProgressDots, Chrome, Title, Body, Cta, TextLink,
});
