/* tryit-keyboard.jsx — the real Jot keyboard (kb2): Jot down / Stop pill + timer */

function KbKey({ t, w = 46, children, onLight }) {
  return (
    <div style={{ width: w, height: 42, borderRadius: 9, flexShrink: 0, background: t.keyFill,
      display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: t.keyShadow }}>{children}</div>
  );
}

// The frosted info pane (recents list / streaming text / first-run setup live here)
function KbPane({ t, label, labelInk, meter, children, minHeight = 88 }) {
  return (
    <div style={{ margin: '10px 10px 0', borderRadius: 16, background: t.glassFill, border: `0.5px solid ${t.glassHair}`,
      backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', padding: '12px 14px', position: 'relative', minHeight }}>
      {(label || meter) && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
          {label && <span style={{ width: 7, height: 7, borderRadius: 4, background: t.kbAccent, flexShrink: 0,
            animation: 'jotpulse 1.3s ease-in-out infinite' }} />}
          {label && <span style={{ fontFamily: SYS, fontSize: 13.5, fontWeight: 600, color: labelInk || t.kbAccent, letterSpacing: '-0.1px' }}>{label}</span>}
          <span style={{ flex: 1 }} />
          {meter}
        </div>
      )}
      {children}
    </div>
  );
}

// mode: 'idle' | 'rec'   ·   timer string   ·   pane is the node inside KbPane (already built)
function JotKeyboard({ t, mode, timer, pane, recordGlow, stopGlow }) {
  const rec = mode === 'rec';
  return (
    <div style={{ flexShrink: 0, position: 'relative', zIndex: 5,
      background: `linear-gradient(180deg, ${t.kbTop} 0%, ${t.kbBottom} 100%)`,
      borderTop: `0.5px solid ${t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.10)'}` }}>
      {pane}

      {/* control row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '12px 10px 8px' }}>
        {rec ? (
          <>
            {/* trash (red) */}
            <div style={{ width: 50, height: 50, borderRadius: 25, flexShrink: 0, background: t.keyFill, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: t.keyShadow }}>
              <TrashGlyph color={t.rec} />
            </div>
            {/* pause */}
            <div style={{ width: 50, height: 50, borderRadius: 25, flexShrink: 0, background: t.keyFill, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: t.keyShadow }}>
              <PauseGlyph color={t.keyInk} />
            </div>
            {/* Stop pill + timer */}
            <button className={stopGlow ? 'try-stopglow' : ''} style={{ flex: 1, height: 50, borderRadius: 25, border: 'none', cursor: 'pointer',
              background: t.accentGrad, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 11,
              boxShadow: `0 6px 20px -4px ${t.accentGlow}, inset 0 1px 0 rgba(255,255,255,0.32)` }}>
              <StopSquare size={17} />
              <span style={{ fontFamily: SYS, fontSize: 18, fontWeight: 600, fontVariantNumeric: 'tabular-nums', letterSpacing: '0.3px' }}>{timer || '0:03'}</span>
            </button>
            {/* return */}
            <KbKey t={t} w={50}><ReturnGlyph color={t.keyInk} /></KbKey>
          </>
        ) : (
          <>
            {/* ... key */}
            <KbKey t={t} w={50}><EllipsisGlyph color={t.keyInk} /></KbKey>
            {/* Jot down pill */}
            <button className={recordGlow ? 'try-dictglow' : ''} style={{ flex: 1, height: 50, borderRadius: 25, border: 'none', cursor: 'pointer',
              background: t.accentGrad, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 9,
              boxShadow: `0 6px 20px -4px ${t.accentGlow}, inset 0 1px 0 rgba(255,255,255,0.32)` }}>
              <MicGlyph size={20} />
              <span style={{ fontFamily: SYS, fontSize: 18, fontWeight: 600 }}>Jot down</span>
            </button>
            {/* return + backspace */}
            <KbKey t={t} w={50}><ReturnGlyph color={t.keyInk} /></KbKey>
            <KbKey t={t} w={50}><BackspaceGlyph color={t.keyInk} /></KbKey>
          </>
        )}
      </div>

      {/* iOS system switcher row */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '2px 22px 4px' }}>
        <GlobeGlyph color={t.keyInk} size={24} />
        <MicGlyph size={20} color={t.keyInk} />
      </div>

      {/* home indicator */}
      <div style={{ height: 22, display: 'flex', alignItems: 'flex-end', justifyContent: 'center', paddingBottom: 7 }}>
        <div style={{ width: 134, height: 5, borderRadius: 3, background: t.dark ? 'rgba(255,255,255,0.5)' : 'rgba(20,30,50,0.34)' }} />
      </div>
    </div>
  );
}

Object.assign(window, { JotKeyboard, KbPane, KbKey });
