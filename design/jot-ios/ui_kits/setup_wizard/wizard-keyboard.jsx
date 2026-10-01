/* wizard-keyboard.jsx — interactive Jot keyboard for W5 (streaming + controls) */

function JotKeyboard({ t, accent, up, rec, paused, streamText, onDictate, onStop, onPause, onTrash, onGlobe, rootRef }) {
  const a = ACCENTS[accent];
  const recording = rec;
  return (
    <div ref={rootRef} style={{ position: 'absolute', left: 0, right: 0, bottom: 0, background: t.kbFill,
      transform: up ? 'translateY(0)' : 'translateY(100%)', transition: 'transform .34s cubic-bezier(.32,.72,0,1)', zIndex: 30,
      borderTop: `0.5px solid ${t.dark ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.10)'}` }}>
      {/* native side spacing (~0.4cm) so it doesn't span full width — C4 */}
      <div style={{ padding: '0 15px' }}>
        {/* top info / streaming strip — italic, capped ~3 lines, fading (C1b/§5.3) */}
        <div style={{ paddingTop: 12, paddingBottom: 10, minHeight: 78 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 7 }}>
            <span style={{ width: 8, height: 8, borderRadius: 4, background: recording && !paused ? a.dot : t.dotTodo,
              animation: recording && !paused ? 'jotpulse 1.2s ease-in-out infinite' : 'none' }} />
            <span style={{ fontFamily: SYS, fontSize: 15, fontWeight: 600, color: recording ? t.ink : t.inkCaption, fontVariantNumeric: 'tabular-nums' }}>
              {recording ? (paused ? 'Paused' : 'Recording') : 'Jot'}
            </span>
            <span style={{ flex: 1 }} />
            <span style={{ fontFamily: SYS, fontSize: 13, color: t.inkCaption }}>EN</span>
          </div>
          <div style={{ position: 'relative', height: 50, overflow: 'hidden',
            WebkitMaskImage: 'linear-gradient(180deg, transparent 0%, #000 42%)', maskImage: 'linear-gradient(180deg, transparent 0%, #000 42%)' }}>
            <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0,
              fontFamily: SERIF, fontStyle: 'italic', fontSize: 15.5, lineHeight: 1.32, color: t.inkItalic, textAlign: 'left' }}>
              {recording
                ? (streamText || '\u00A0')
                : <span style={{ fontFamily: SYS, fontStyle: 'normal', fontSize: 14, color: t.inkCaption }}>Tap Dictate, then swipe back to your app.</span>}
            </div>
          </div>
        </div>

        {/* controls — one line: trash(left) · pause · Dictate/Stop (§5.4) */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, paddingBottom: 10 }}>
          <CircBtn t={t} onClick={onTrash} disabled={!recording} title="Cancel">
            <svg width="20" height="20" viewBox="0 0 20 20" fill="none"><path d="M3 5h14M8 5V3.5h4V5M5 5l1 12h8l1-12" stroke={recording ? '#FF453A' : t.glyphSoft} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>
          </CircBtn>
          <CircBtn t={t} onClick={onPause} disabled={!recording} title="Pause">
            {paused
              ? <svg width="20" height="20" viewBox="0 0 20 20" fill="none"><path d="M6 4l11 6-11 6V4z" fill={t.ink}/></svg>
              : <svg width="20" height="20" viewBox="0 0 20 20" fill="none"><rect x="5" y="4" width="3.6" height="12" rx="1.4" fill={recording ? t.ink : t.glyphSoft}/><rect x="11.4" y="4" width="3.6" height="12" rx="1.4" fill={recording ? t.ink : t.glyphSoft}/></svg>}
          </CircBtn>
          <button onClick={recording ? onStop : onDictate} style={{ flex: 1, height: 48, borderRadius: 24, border: 'none', cursor: 'pointer',
            background: recording ? (t.dark ? 'rgba(255,255,255,0.14)' : 'rgba(40,52,74,0.12)') : a.grad,
            color: recording ? t.ink : '#fff', fontFamily: SYS, fontWeight: 600, fontSize: 17,
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 9,
            boxShadow: recording ? 'none' : `0 6px 18px -4px ${a.glow}, inset 0 1px 0 rgba(255,255,255,0.3)` }}>
            {recording
              ? <><svg width="15" height="15" viewBox="0 0 15 15" fill="none"><rect x="3" y="3" width="9" height="9" rx="2" fill={t.ink}/></svg> Stop</>
              : <><span style={{ width: 11, height: 11, borderRadius: 6, background: '#fff' }} /> Dictate</>}
          </button>
        </div>

        {/* bottom system row — Apple's fixed keys stay (C4) */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, paddingBottom: 6 }}>
          <button onClick={onGlobe} style={{ width: 46, height: 38, borderRadius: 8, border: 'none', cursor: 'pointer', background: t.kbKey, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <GlobeGlyph color={t.kbKeyInk} size={21} />
          </button>
          <div style={{ flex: 1, height: 38, borderRadius: 8, background: t.kbKey, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontSize: 14, color: t.inkCaption }}>Jot · dictation only</div>
          <div style={{ width: 46, height: 38, borderRadius: 8, background: t.kbKey, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <svg width="20" height="16" viewBox="0 0 20 16" fill="none"><path d="M6 3h9a3 3 0 0 1 3 3v4a3 3 0 0 1-3 3H6L1 8l5-5z" stroke={t.kbKeyInk} strokeWidth="1.5"/><path d="M9 6l4 4M13 6l-4 4" stroke={t.kbKeyInk} strokeWidth="1.5" strokeLinecap="round"/></svg>
          </div>
        </div>
      </div>
      <div style={{ height: 20, display: 'flex', alignItems: 'flex-end', justifyContent: 'center', paddingBottom: 6 }}>
        <div style={{ width: 134, height: 5, borderRadius: 3, background: t.dark ? 'rgba(255,255,255,0.4)' : 'rgba(0,0,0,0.32)' }} />
      </div>
    </div>
  );
}

function CircBtn({ t, onClick, disabled, children, title }) {
  return (
    <button onClick={disabled ? undefined : onClick} title={title} style={{ width: 48, height: 48, borderRadius: 24, flexShrink: 0,
      background: t.kbKey, border: 'none', cursor: disabled ? 'default' : 'pointer', opacity: disabled ? 0.5 : 1,
      display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 0,
      boxShadow: t.dark ? 'none' : '0 1px 2px rgba(0,0,0,0.12)' }}>{children}</button>
  );
}

window.JotKeyboard = JotKeyboard;
