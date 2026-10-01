/* watch-ui.jsx — Jot Watch: tokens, frame, glyphs, shared bits */

const W = {
  bg: '#000000',
  ink: '#FFFFFF',
  sub: 'rgba(235,235,245,0.60)',
  ter: 'rgba(235,235,245,0.32)',
  card: '#161719',
  cardHi: '#1C1D20',
  hair: 'rgba(255,255,255,0.10)',
  blue: '#1A8CFF',
  blueGrad: 'linear-gradient(168deg, #3AA0FF 0%, #1483F2 50%, #0064CC 100%)',
  orange: '#FF9F0A',
  red: '#FF453A',
  green: '#32D74B'
};
const SERIF = '"Fraunces", Georgia, serif';
const SYS = '-apple-system, "SF Pro Text", system-ui, sans-serif';

// 44mm Apple Watch logical screen
const SCREEN_W = 368,SCREEN_H = 448;

// ── j + waveform brand mark (matches iPhone) ─────────────────
function JotMark({ size = 22, color = '#fff', sw = 15 }) {
  const cx = 58,baseY = 24,sp = 11,ch = 18,sh = 10,bw = sw * 0.36;
  const bar = (dx, h) => <line x1={cx + dx} y1={baseY - h / 2} x2={cx + dx} y2={baseY + h / 2} stroke={color} strokeWidth={bw} strokeLinecap="round" />;
  return (
    <svg width={size} height={size * 160 / 116} viewBox="0 0 116 160" fill="none" style={{ overflow: 'visible' }}>
      <g stroke={color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M58 52 L58 116 Q58 138 34 138" />
        {bar(-sp, sh)}{bar(0, ch)}{bar(sp, sh)}
      </g>
    </svg>);

}

function MicGlyph({ size = 30, color = '#fff' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 60 60" fill="none">
      <rect x="23" y="9" width="14" height="26" rx="7" fill={color} />
      <path d="M16 28c0 7.7 6.3 14 14 14s14-6.3 14-14" stroke={color} strokeWidth="3.4" strokeLinecap="round" />
      <path d="M30 42v8M23 51h14" stroke={color} strokeWidth="3.4" strokeLinecap="round" />
    </svg>);

}
function ChevR({ size = 16, color }) {
  return <svg width={size} height={size} viewBox="0 0 16 16" fill="none"><path d="M6 3l5 5-5 5" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}
function ChevL({ size = 18, color }) {
  return <svg width={size} height={size} viewBox="0 0 18 18" fill="none"><path d="M11 3L5 9l6 6" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}
function CloseGlyph({ size = 17, color }) {
  return <svg width={size} height={size} viewBox="0 0 17 17" fill="none"><path d="M2 2l13 13M15 2L2 15" stroke={color} strokeWidth="2.4" strokeLinecap="round" /></svg>;
}
function SyncGlyph({ size = 17, color }) {
  return <svg width={size} height={size} viewBox="0 0 18 18" fill="none"><path d="M2.6 7.5A6.5 6.5 0 0 1 15 6.2M15.4 10.5A6.5 6.5 0 0 1 3 11.8" stroke={color} strokeWidth="1.8" strokeLinecap="round" /><path d="M14.4 2.6l.7 3.4-3.4.5M3.6 15.4l-.7-3.4 3.4-.5" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}
function StethGlyph({ size = 20, color }) {
  return <svg width={size} height={size} viewBox="0 0 22 22" fill="none"><path d="M5 3v5a4 4 0 0 0 8 0V3" stroke={color} strokeWidth="1.8" strokeLinecap="round" /><path d="M9 12v2a4 4 0 0 0 8 0v-2" stroke={color} strokeWidth="1.8" strokeLinecap="round" /><circle cx="17" cy="9" r="2.4" stroke={color} strokeWidth="1.8" /><circle cx="5" cy="3" r="1.2" fill={color} /><circle cx="13" cy="3" r="1.2" fill={color} /></svg>;
}

// status time, top-right (watchOS system convention)
function TimeChip({ children = '6:02', icon }) {
  return (
    <div style={{ position: 'absolute', top: 9, right: 24, display: 'flex', alignItems: 'center', gap: 5, zIndex: 8 }}>
      {icon}
      <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 19, color: W.ink, letterSpacing: '0.2px', fontVariantNumeric: 'tabular-nums' }}>{children}</span>
    </div>);

}

// watchOS 10 large navigation title (first view) — bold, key color, top-left, scrolls with content
function NavTitle({ children, color = W.blue }) {
  return (
    <div style={{ fontFamily: SYS, fontWeight: 700, fontSize: 25, letterSpacing: '-0.4px', color, lineHeight: 1, marginBottom: 14, marginTop: 2 }}>
      {children}
    </div>);

}

// subview header — back button (top-left corner) + small inline title (no large title on subviews)
function SubNav({ title, onBack }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 11, marginBottom: 14, marginTop: 0 }}>
      <RoundBtn onClick={onBack}><ChevL size={18} color="#fff" /></RoundBtn>
      <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 18, color: W.ink, letterSpacing: '-0.2px' }}>{title}</span>
    </div>);

}

// blue brand pill
function Pill({ children, onClick, height = 56, style }) {
  return (
    <button onClick={onClick} style={{
      width: '100%', height, border: 'none', borderRadius: height / 2, background: W.blueGrad, color: '#fff', cursor: 'pointer',
      fontFamily: SYS, fontWeight: 600, fontSize: 19, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 9,
      boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.35), 0 6px 16px -6px rgba(20,131,242,0.6)', WebkitTapHighlightColor: 'transparent', ...style
    }} onMouseDown={(e) => e.currentTarget.style.transform = 'scale(0.97)'} onMouseUp={(e) => e.currentTarget.style.transform = 'scale(1)'} onMouseLeave={(e) => e.currentTarget.style.transform = 'scale(1)'}>
      {children}
    </button>);

}

// circular chrome button (back / close)
function RoundBtn({ children, onClick }) {
  return (
    <button onClick={onClick} style={{
      width: 38, height: 38, borderRadius: 19, border: 'none', background: 'rgba(255,255,255,0.14)', cursor: 'pointer',
      display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 0, WebkitTapHighlightColor: 'transparent'
    }}>{children}</button>);

}

// ── Watch device frame (44mm) ────────────────────────────────
function WatchFrame({ children }) {
  const bezel = 14;
  return (
    <div style={{ position: 'relative', width: SCREEN_W + bezel * 2, height: SCREEN_H + bezel * 2 }}>
      {/* digital crown */}
      <div style={{ position: 'absolute', right: -8, top: '34%', width: 12, height: 46, borderRadius: 6,
        background: 'linear-gradient(90deg,#3a3a3c,#6a6a6e,#2a2a2c)', boxShadow: '0 1px 2px rgba(0,0,0,0.6)' }} />
      {/* side button */}
      <div style={{ position: 'absolute', right: -5, top: '54%', width: 7, height: 64, borderRadius: 4,
        background: 'linear-gradient(90deg,#2a2a2c,#4a4a4e,#222)' }} />
      {/* case */}
      <div style={{
        position: 'absolute', inset: 0, borderRadius: 84,
        background: 'linear-gradient(155deg, #2a2c30 0%, #131416 60%, #050506 100%)',
        boxShadow: '0 30px 70px -20px rgba(0,0,0,0.85), inset 0 1px 0 rgba(255,255,255,0.10)',
        padding: bezel
      }}>
        {/* screen */}
        <div style={{
          position: 'relative', width: SCREEN_W, height: SCREEN_H, borderRadius: 70, overflow: 'hidden',
          background: W.bg, boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.04)'
        }}>
          {children}
        </div>
      </div>
    </div>);

}

// content scroll area with consistent padding + top time inset
function Screen({ children, pad = 13, top = 36 }) {
  return (
    <div style={{ position: 'absolute', inset: 0, overflowY: 'auto', WebkitOverflowScrolling: 'touch' }}>
      <div style={{ padding: `${top}px ${pad}px 28px`, minHeight: '100%' }} data-comment-anchor="205dfa0eae-div-129-7">{children}</div>
    </div>);

}

Object.assign(window, {
  W, SERIF, SYS, SCREEN_W, SCREEN_H,
  JotMark, MicGlyph, ChevR, ChevL, CloseGlyph, SyncGlyph, StethGlyph,
  TimeChip, NavTitle, SubNav, Pill, RoundBtn, WatchFrame, Screen
});