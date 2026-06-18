/* tryit-tokens.jsx — Jot "try it" · both-theme tokens, glyphs, waveform, first-run affordances */

const SERIF = '"Fraunces", Georgia, "Times New Roman", serif';
const SYS   = '-apple-system, "SF Pro Text", system-ui, sans-serif';

// Wizard surface tokens (jotTheme, from wizard-ui.jsx) + production keyboard (kb2)
function tok(theme) {
  const dark = theme === 'dark';
  return {
    dark,
    // wizard screen background (layered gradients — never flat)
    bg: dark
      ? 'radial-gradient(128% 72% at 50% -8%, rgba(64,116,196,0.50) 0%, rgba(40,74,128,0.16) 36%, rgba(18,30,52,0) 60%), linear-gradient(177deg, #1b2c4f 0%, #15233c 32%, #0e1827 72%, #0a1019 100%)'
      : 'radial-gradient(128% 74% at 50% -8%, rgba(150,184,232,0.62) 0%, rgba(150,184,232,0.12) 40%, rgba(150,184,232,0) 62%), radial-gradient(120% 84% at 88% 112%, rgba(222,170,150,0.10) 0%, rgba(222,170,150,0) 52%), linear-gradient(177deg, #E9EEF7 0%, #DEE4EE 44%, #D0D6E0 100%)',
    statusInk:    dark ? '#FFFFFF' : '#0B0B0C',
    ink:          dark ? '#FFFFFF' : '#16181D',
    inkSub:       dark ? 'rgba(233,238,247,0.66)' : 'rgba(54,62,78,0.70)',
    inkCap:       dark ? 'rgba(233,238,247,0.42)' : 'rgba(54,62,78,0.48)',
    inkItalic:    dark ? 'rgba(233,238,247,0.70)' : 'rgba(54,62,78,0.62)',
    // glass chrome (back · dots · close)
    chromeFill:   dark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.72)',
    chromeBord:   dark ? 'rgba(255,255,255,0.16)' : 'rgba(20,30,50,0.08)',
    chromeGlyph:  dark ? 'rgba(255,255,255,0.86)' : '#3A4252',
    dotDone:      dark ? 'rgba(255,255,255,0.50)' : 'rgba(54,62,78,0.42)',
    dotTodo:      dark ? 'rgba(255,255,255,0.20)' : 'rgba(54,62,78,0.18)',
    // practice field + cards
    field:        dark ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.62)',
    fieldBord:    dark ? 'rgba(255,255,255,0.14)' : 'rgba(20,30,50,0.12)',
    card:         dark ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.78)',
    cardBord:     dark ? 'rgba(255,255,255,0.11)' : 'rgba(20,30,50,0.07)',
    // Jot keyboard (kb2 production)
    kbTop:        dark ? '#25252A' : '#D5D7DE',
    kbBottom:     dark ? '#1A1A1D' : '#C9CCD3',
    kbAccent:     dark ? '#0A84FF' : '#007AFF',
    stream:       dark ? '#9CB3E5' : '#3C5A99',
    glassFill:    dark ? 'rgba(70,72,82,0.62)' : 'rgba(255,255,255,0.80)',
    glassHair:    dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)',
    keyFill:      dark ? 'rgba(110,114,126,0.42)' : '#FFFFFF',
    keyInk:       dark ? 'rgba(255,255,255,0.92)' : '#1C1C1E',
    kbMute:       dark ? 'rgba(255,255,255,0.52)' : 'rgba(60,60,67,0.55)',
    keyShadow:    dark ? 'none' : '0 1px 1px rgba(20,30,50,0.12)',
    // brand accent (wizard CTA 3-stop) + status
    accentGrad:   'linear-gradient(180deg, #2E9BFF 0%, #0E7AE6 54%, #0064CC 100%)',
    accentGlow:   'rgba(26,140,255,0.44)',
    accentDot:    '#1A8CFF',
    rec:          '#FF3B30',
    recDot:       '#E0173B',
    success:      '#34C759',
    successInk:   dark ? '#34C759' : '#1B8E3E',
  };
}

// ── Glyphs ───────────────────────────────────────────────────
function MicGlyph({ size = 20, color = '#fff' }) {
  return <svg width={size} height={size} viewBox="0 0 22 22" fill="none">
    <rect x="8" y="2.5" width="6" height="11" rx="3" fill={color}/>
    <path d="M5.4 10.2a5.6 5.6 0 0 0 11.2 0" stroke={color} strokeWidth="1.8" strokeLinecap="round"/>
    <path d="M11 15.8v3.4M8 19.2h6" stroke={color} strokeWidth="1.8" strokeLinecap="round"/>
  </svg>;
}
function StopSquare({ size = 17, color = '#fff' }) {
  return <svg width={size} height={size} viewBox="0 0 18 18" fill="none"><rect x="3" y="3" width="12" height="12" rx="3.4" fill={color}/></svg>;
}
function PauseGlyph({ color }) {
  return <svg width="18" height="18" viewBox="0 0 18 18" fill="none"><rect x="4.6" y="3.4" width="3.2" height="11.2" rx="1.5" fill={color}/><rect x="10.2" y="3.4" width="3.2" height="11.2" rx="1.5" fill={color}/></svg>;
}
function TrashGlyph({ color }) {
  return <svg width="19" height="19" viewBox="0 0 20 20" fill="none"><path d="M3.4 5.4h13.2M7.8 5.4V3.9h4.4v1.5M5.5 5.4l.85 11h7.3l.85-11" stroke={color} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function ReturnGlyph({ color }) {
  return <svg width="20" height="20" viewBox="0 0 22 22" fill="none"><path d="M18 5v5a3 3 0 0 1-3 3H5" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M8.5 9.5L5 13l3.5 3.5" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function BackspaceGlyph({ color }) {
  return <svg width="22" height="17" viewBox="0 0 22 17" fill="none"><path d="M7 2.6h11a2.4 2.4 0 0 1 2.4 2.4v7a2.4 2.4 0 0 1-2.4 2.4H7L1.6 8.5 7 2.6z" stroke={color} strokeWidth="1.5"/><path d="M10.4 6l4 4M14.4 6l-4 4" stroke={color} strokeWidth="1.5" strokeLinecap="round"/></svg>;
}
function GlobeGlyph({ color, size = 22 }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9.2" stroke={color} strokeWidth="1.6"/><path d="M2.8 12h18.4M12 2.8c2.7 2.5 4.2 5.8 4.2 9.2s-1.5 6.7-4.2 9.2c-2.7-2.5-4.2-5.8-4.2-9.2S9.3 5.3 12 2.8z" stroke={color} strokeWidth="1.6"/></svg>;
}
function EllipsisGlyph({ color }) {
  return <svg width="22" height="22" viewBox="0 0 22 22" fill="none"><circle cx="5" cy="11" r="1.7" fill={color}/><circle cx="11" cy="11" r="1.7" fill={color}/><circle cx="17" cy="11" r="1.7" fill={color}/></svg>;
}
function SendUp({ size = 22, color = '#fff' }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none"><path d="M12 19V6M6 12l6-6 6 6" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function PlusGlyph({ color }) {
  return <svg width="22" height="22" viewBox="0 0 22 22" fill="none"><path d="M11 5v12M5 11h12" stroke={color} strokeWidth="2" strokeLinecap="round"/></svg>;
}
function ChevLeft({ color, size = 22 }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none"><path d="M15 4l-8 8 8 8" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function CheckGlyph({ size = 18, color = '#fff' }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none"><path d="M5 12.5l4.5 4.5L19 7" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
// tiny "j" badge (in-app identity mark)
function JBadge({ size = 30 }) {
  return <div style={{ width: size, height: size, borderRadius: size / 2, background: 'linear-gradient(168deg,#3AA0FF,#1483F2 48%,#0064CC)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.4)' }}>
    <span style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 600, fontSize: size * 0.52, color: '#fff', lineHeight: 1, marginTop: size * 0.04 }}>j</span>
  </div>;
}

// ── Live waveform meter (the blue bars) ──────────────────────
function WaveMeter({ color, n = 5, h = 16, cls = 'try-meter', gap = 3, w = 3 }) {
  return <div className={cls} style={{ display: 'flex', alignItems: 'center', gap, height: h }}>
    {Array.from({ length: n }).map((_, i) => (
      <span key={i} className="try-bar" style={{ width: w, height: h, borderRadius: w, background: color, transformOrigin: 'center' }} />
    ))}
  </div>;
}

// ── First-run model warm-up (inside the keyboard pane) ───────
// Text only — NO waveform. The single blinking element is the pane's recording dot.
function SetupNote({ t }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 9, padding: '14px 0 10px', textAlign: 'center' }}>
      <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontSize: 18.5, color: t.ink, lineHeight: 1.3, maxWidth: 290 }}>This is the slow part. It’s the only slow part.</div>
    </div>
  );
}

Object.assign(window, {
  SERIF, SYS, tok,
  MicGlyph, StopSquare, PauseGlyph, TrashGlyph, ReturnGlyph, BackspaceGlyph, GlobeGlyph,
  EllipsisGlyph, SendUp, PlusGlyph, ChevLeft, CheckGlyph, JBadge,
  WaveMeter, SetupNote,
});
