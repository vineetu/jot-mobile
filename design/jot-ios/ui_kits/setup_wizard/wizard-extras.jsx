/* wizard-extras.jsx — §4.6 warm-hold: contextual prompt + in-wizard step + Apple keyboard */

// ── In-wizard "Keep the mic ready" step (default ON · plain-language) ───────
function W6WarmHold({ t, accent, nav, total, current, on, setOn }) {
  return (
    <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={current}>
      <Stage top={62} gap={24}>
        <HeroTile from="#F6A93B" to="#E8841C" glow="rgba(232,132,28,0.5)" size={118}><MicGlyph size={54} /></HeroTile>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16 }}>
          <Title t={t} size={34}>Keep the mic ready</Title>
          <Body t={t} max={330}>After you dictate, Jot stays ready for two minutes — so your next dictation starts instantly, without hopping back to the app. Nothing is recorded until you tap Dictate.</Body>
        </div>
        <ToggleRow t={t} on={on} setOn={setOn} />
      </Stage>
      <Footer><Cta accent={accent} onClick={nav.next}>Continue</Cta></Footer>
    </Shell>
  );
}

function ToggleRow({ t, on, setOn }) {
  return (
    <div style={{ marginTop: 4, width: '100%', borderRadius: 18, background: t.card, border: `0.5px solid ${t.cardBord}`,
      padding: '17px 18px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
      <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 17, color: t.ink }}>Keep mic ready</span>
      <button onClick={() => setOn(!on)} style={{ width: 52, height: 31, borderRadius: 16, border: 'none', cursor: 'pointer', flexShrink: 0,
        background: on ? '#34C759' : (t.dark ? 'rgba(255,255,255,0.18)' : 'rgba(120,120,128,0.32)'),
        position: 'relative', transition: 'background .2s', padding: 0 }}>
        <span style={{ position: 'absolute', top: 2, left: on ? 23 : 2, width: 27, height: 27, borderRadius: 14, background: '#fff', transition: 'left .2s', boxShadow: '0 2px 5px rgba(0,0,0,0.3)' }} />
      </button>
    </div>
  );
}

// ── §4.6 Contextual prompt — appears in-app, behaviour-triggered ──
function WarmHoldPrompt({ t, accent, visible, onKeep, onDismiss }) {
  const a = ACCENTS[accent];
  const appBubble = t.dark ? 'rgba(255,255,255,0.09)' : 'rgba(40,60,96,0.09)';
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 40, pointerEvents: visible ? 'auto' : 'none' }}>
      {/* scrim over the live app */}
      <div onClick={onDismiss} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.42)', backdropFilter: 'blur(2px)', WebkitBackdropFilter: 'blur(2px)', opacity: visible ? 1 : 0, transition: 'opacity .3s' }} />
      {/* bottom-sheet card */}
      <div style={{ position: 'absolute', left: 12, right: 12, bottom: 16, borderRadius: 26,
        background: t.dark ? 'rgba(28,36,52,0.92)' : 'rgba(255,255,255,0.94)',
        backdropFilter: 'blur(28px)', WebkitBackdropFilter: 'blur(28px)',
        border: `0.5px solid ${t.dark ? 'rgba(255,255,255,0.12)' : 'rgba(20,30,50,0.08)'}`,
        boxShadow: '0 24px 60px -16px rgba(0,0,0,0.55)', padding: '24px 22px 22px',
        transform: visible ? 'translateY(0)' : 'translateY(140%)', transition: 'transform .42s cubic-bezier(.32,.72,0,1)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 14 }}>
          <HeroTile from="#F6A93B" to="#E8841C" glow="rgba(232,132,28,0.4)" size={46} radius={0.32}><MicGlyph size={22} /></HeroTile>
          <div style={{ flex: 1 }}>
            <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 600, fontSize: 22, color: t.ink, lineHeight: 1.1 }}>Tired of switching back and forth?</div>
          </div>
        </div>
        <p style={{ fontFamily: SYS, fontSize: 15, lineHeight: 1.4, color: t.inkSub, margin: '0 0 18px' }}>
          Keep the mic ready and Jot starts the next dictation instantly — no waiting between trips.
        </p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <button onClick={onKeep} style={{ height: 52, borderRadius: 26, border: 'none', background: a.grad, color: '#fff',
            fontFamily: SYS, fontWeight: 600, fontSize: 16.5, cursor: 'pointer',
            boxShadow: `0 8px 24px -6px ${a.glow}, inset 0 1px 0 rgba(255,255,255,0.3)` }}>Keep mic ready</button>
          <button onClick={onDismiss} style={{ height: 44, borderRadius: 22, border: 'none', background: 'transparent', color: t.inkSub,
            fontFamily: SYS, fontWeight: 500, fontSize: 16, cursor: 'pointer' }}>Not now</button>
        </div>
        <p style={{ fontFamily: SYS, fontSize: 11.5, color: t.inkCaption, textAlign: 'center', margin: '12px 0 0' }}>
          Shown once — because you've hopped into Jot a few times just now.
        </p>
      </div>
    </div>
  );
}

// ── iOS keyboard mock for W5 (system row stays · C4) ─────────
const KB_ROWS = [['Q','W','E','R','T','Y','U','I','O','P'], ['A','S','D','F','G','H','J','K','L'], ['Z','X','C','V','B','N','M']];
function AppleKeyboard({ t, accent, up, rootRef }) {
  const a = ACCENTS[accent];
  const Key = ({ ch, w }) => (
    <div style={{ flex: w || 1, height: 42, borderRadius: 6, background: t.kbKey, color: t.kbKeyInk,
      display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontSize: 20, fontWeight: 400,
      boxShadow: '0 1px 0 rgba(0,0,0,0.28)' }}>{ch}</div>
  );
  return (
    <div ref={rootRef} style={{ position: 'absolute', left: 0, right: 0, bottom: 0, background: t.kbFill, paddingBottom: 4,
      transform: up ? 'translateY(0)' : 'translateY(100%)', transition: 'transform .34s cubic-bezier(.32,.72,0,1)', zIndex: 30 }}>
      {/* predictive strip */}
      <div style={{ display: 'flex', height: 44, alignItems: 'stretch', borderBottom: `0.5px solid ${t.dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.10)'}` }}>
        {['I', 'The', 'I\u2019m'].map((s, i) => (
          <div key={i} style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontSize: 16, color: t.ink, borderRight: i < 2 ? `0.5px solid ${t.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.10)'}` : 'none' }}>{s}</div>
        ))}
      </div>
      <div style={{ padding: '7px 3px 0', display: 'flex', flexDirection: 'column', gap: 8 }}>
        {KB_ROWS.map((row, ri) => (
          <div key={ri} style={{ display: 'flex', gap: 5, padding: ri === 1 ? '0 18px' : '0 3px', justifyContent: 'center' }}>
            {ri === 2 && <div style={{ flex: 1.4, height: 42, borderRadius: 6, background: t.kbKey, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <svg width="18" height="18" viewBox="0 0 18 18" fill="none"><path d="M9 2L3 8h3v6h6V8h3L9 2z" fill={t.kbKeyInk}/></svg></div>}
            {row.map(ch => <Key key={ch} ch={ch} />)}
            {ri === 2 && <div style={{ flex: 1.4, height: 42, borderRadius: 6, background: t.kbKey, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <svg width="20" height="16" viewBox="0 0 20 16" fill="none"><path d="M6 3h9a3 3 0 0 1 3 3v4a3 3 0 0 1-3 3H6L1 8l5-5z" stroke={t.kbKeyInk} strokeWidth="1.5"/><path d="M9 6l4 4M13 6l-4 4" stroke={t.kbKeyInk} strokeWidth="1.5" strokeLinecap="round"/></svg></div>}
          </div>
        ))}
        {/* bottom system row — Apple's fixed keys stay (C4) */}
        <div style={{ display: 'flex', gap: 5, padding: '0 3px', alignItems: 'stretch' }}>
          <div style={{ flex: 1.3, height: 42, borderRadius: 6, background: t.kbKey, color: t.kbKeyInk, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontSize: 15, fontWeight: 500 }}>123</div>
          <div style={{ width: 44, height: 42, borderRadius: 6, background: t.kbKey, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><GlobeGlyph color={t.kbKeyInk} size={22} /></div>
          <div style={{ flex: 1, height: 42, borderRadius: 6, background: t.kbKey, color: t.kbKeyInk, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontSize: 15 }}>space</div>
          {/* adaptive Enter key (C4/§5.1) */}
          <div style={{ flex: 1.3, height: 42, borderRadius: 6, background: a.grad, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontSize: 15, fontWeight: 600 }}>return</div>
        </div>
      </div>
      <div style={{ height: 22, display: 'flex', alignItems: 'flex-end', justifyContent: 'center', paddingBottom: 6 }}>
        <div style={{ width: 134, height: 5, borderRadius: 3, background: t.dark ? 'rgba(255,255,255,0.4)' : 'rgba(0,0,0,0.32)' }} />
      </div>
    </div>
  );
}

// ── Simulated iOS Settings sheet for W3 (add keyboard + Full Access) ──
function KeyboardSetupSheet({ t, accent, open, onClose, onComplete }) {
  const a = ACCENTS[accent];
  const [installed, setInstalled] = React.useState(false);
  const [fullAccess, setFullAccess] = React.useState(false);
  React.useEffect(() => { if (!open) { setInstalled(false); setFullAccess(false); } }, [open]);
  const done = installed && fullAccess;

  // iOS Settings palette (independent of the wizard's themed bg)
  const settingsBg = t.dark ? '#000000' : '#EFEFF4';
  const groupBg = t.dark ? '#1C1C1E' : '#FFFFFF';
  const sep = t.dark ? 'rgba(255,255,255,0.10)' : 'rgba(60,60,67,0.13)';
  const label = t.dark ? '#FFFFFF' : '#000000';
  const sub = t.dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const groupHdr = t.dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const iosBlue = '#0A84FF';

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 60, pointerEvents: open ? 'auto' : 'none' }}>
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.4)', opacity: open ? 1 : 0, transition: 'opacity .3s' }} />
      <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: '88%', background: settingsBg,
        borderRadius: '32px 32px 0 0', overflow: 'hidden', boxShadow: '0 -10px 40px rgba(0,0,0,0.4)',
        transform: open ? 'translateY(0)' : 'translateY(101%)', transition: 'transform .42s cubic-bezier(.32,.72,0,1)',
        display: 'flex', flexDirection: 'column' }}>
        {/* grabber */}
        <div style={{ display: 'flex', justifyContent: 'center', paddingTop: 8 }}>
          <div style={{ width: 38, height: 5, borderRadius: 3, background: t.dark ? 'rgba(255,255,255,0.28)' : 'rgba(0,0,0,0.2)' }} />
        </div>
        {/* nav bar */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 16px 12px' }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 2, color: iosBlue, fontFamily: SYS, fontSize: 17 }}>
            <svg width="11" height="18" viewBox="0 0 11 18" fill="none"><path d="M9 2L2 9l7 7" stroke={iosBlue} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/></svg>
            Keyboard
          </span>
          <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 17, color: label }}>Keyboards</span>
          <button onClick={done ? onComplete : undefined} disabled={!done} style={{ background: 'none', border: 'none', cursor: done ? 'pointer' : 'default',
            fontFamily: SYS, fontWeight: 600, fontSize: 17, color: done ? iosBlue : sub, opacity: done ? 1 : 0.5, padding: 0 }}>Done</button>
        </div>

        <div style={{ flex: 1, overflowY: 'auto', padding: '8px 16px 24px' }}>
          {/* Step 1: add keyboard */}
          <div style={{ fontFamily: SYS, fontSize: 13, color: groupHdr, padding: '14px 16px 7px', textTransform: 'uppercase', letterSpacing: '0.02em' }}>Add a Keyboard</div>
          <div style={{ background: groupBg, borderRadius: 11, overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '13px 16px' }}>
              <span style={{ fontFamily: SYS, fontSize: 17, color: label }}>Jot</span>
              {installed
                ? <span style={{ display: 'flex', alignItems: 'center', gap: 6, fontFamily: SYS, fontSize: 15, color: sub }}>
                    Added <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8.4l3 3L13 4.5" stroke="#34C759" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                  </span>
                : <button onClick={() => setInstalled(true)} style={{ background: 'none', border: 'none', color: iosBlue, fontFamily: SYS, fontSize: 17, cursor: 'pointer', padding: 0 }}>Add</button>}
            </div>
          </div>

          {/* Step 2: full access — appears after adding */}
          <div style={{ maxHeight: installed ? 200 : 0, opacity: installed ? 1 : 0, overflow: 'hidden', transition: 'all .35s ease' }}>
            <div style={{ fontFamily: SYS, fontSize: 13, color: groupHdr, padding: '20px 16px 7px', textTransform: 'uppercase', letterSpacing: '0.02em' }}>Jot</div>
            <div style={{ background: groupBg, borderRadius: 11, overflow: 'hidden' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '11px 16px' }}>
                <span style={{ fontFamily: SYS, fontSize: 17, color: label }}>Allow Full Access</span>
                <button onClick={() => setFullAccess(v => !v)} style={{ width: 51, height: 31, borderRadius: 16, border: 'none', cursor: 'pointer',
                  background: fullAccess ? '#34C759' : (t.dark ? 'rgba(120,120,128,0.32)' : 'rgba(120,120,128,0.16)'),
                  position: 'relative', transition: 'background .2s', padding: 0 }}>
                  <span style={{ position: 'absolute', top: 2, left: fullAccess ? 22 : 2, width: 27, height: 27, borderRadius: 14, background: '#fff', transition: 'left .2s', boxShadow: '0 2px 6px rgba(0,0,0,0.3)' }} />
                </button>
              </div>
            </div>
            <div style={{ fontFamily: SYS, fontSize: 13, lineHeight: 1.36, color: groupHdr, padding: '7px 16px' }}>
              Full Access lets Jot send your dictated text to the app you're typing in. Audio is processed on your iPhone.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { W6WarmHold, ToggleRow, WarmHoldPrompt, AppleKeyboard, KeyboardSetupSheet });
