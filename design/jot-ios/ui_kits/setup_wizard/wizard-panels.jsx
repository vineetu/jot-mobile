/* wizard-panels.jsx — Jot wizard panels (W1 W2 W3 W4 W5 W7) + warm-hold prompt */

function Shell({ t, accent, onBack, onClose, total, current, children }) {
  return (
    <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', paddingTop: 70 }}>
      <Chrome t={t} onBack={onBack} onClose={onClose}
        dots={<ProgressDots total={total} current={current} t={t} accent={accent} />} />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>{children}</div>
    </div>
  );
}
function Footer({ children }) {
  return <div style={{ padding: '0 22px 26px', display: 'flex', flexDirection: 'column', alignItems: 'stretch', gap: 4 }}>{children}</div>;
}
function Stage({ children, top = 56, gap = 26, justify = 'flex-start' }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: justify, padding: '0 26px', minHeight: 0 }}>
      <div style={{ height: top, flexShrink: 0 }} />
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap }}>{children}</div>
    </div>
  );
}

// ── W1 · Welcome ─────────────────────────────────────────────
function W1Welcome({ t, accent, mark, nav, total }) {
  return (
    <Shell t={t} accent={accent} onClose={nav.close} total={total} current={0}>
      <Stage top={84} gap={30}>
        <AppIcon accent={accent} mark={mark} size={126} />
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18 }}>
          <h1 style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontOpticalSizing: 'auto', fontSize: 41, lineHeight: 1.0, letterSpacing: '-0.5px', color: t.ink, textAlign: 'center', margin: 0, whiteSpace: 'nowrap' }}>Welcome to Jot.</h1>
          <p style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 400, fontSize: 20, lineHeight: 1.34, color: t.inkItalic, textAlign: 'center', margin: 0, maxWidth: 290, textWrap: 'balance' }}>
            Voice transcription for fast messaging — dictate into any app.
          </p>
        </div>
      </Stage>
      <Footer><Cta accent={accent} onClick={nav.next}>Get started</Cta></Footer>
    </Shell>
  );
}

// ── W2 · Microphone permission ───────────────────────────────
function W2Mic({ t, accent, nav, total }) {
  return (
    <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={1}>
      <Stage top={76} gap={28}>
        <HeroTile from="#F6A93B" to="#E8841C" glow="rgba(232,132,28,0.5)" size={128}><MicGlyph size={58} /></HeroTile>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18 }}>
          <Title t={t} size={40}>Let Jot hear you</Title>
          <Body t={t} max={328}>Jot needs the mic to transcribe. Audio is processed on your iPhone and discarded.</Body>
        </div>
      </Stage>
      <Footer><Cta accent={accent} onClick={nav.next}>Grant microphone</Cta></Footer>
    </Shell>
  );
}

// ── W3 · Add the keyboard (first-run) / Keyboard ready (return) ──
function W3Keyboard({ t, accent, nav, total, added, onOpenSettings }) {
  const a = ACCENTS[accent];
  if (added) {
    return (
      <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={2}>
        <Stage top={72} gap={26}>
          <HeroTile from="#34C759" to="#27A848" glow="rgba(39,168,72,0.5)" size={120}><CheckGlyph size={58} /></HeroTile>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16 }}>
            <Title t={t} size={31}>Keyboard ready</Title>
            <Body t={t} max={324}>The Jot keyboard is added with Full Access — your dictations can paste into any app.</Body>
          </div>
        </Stage>
        <Footer><Cta accent={accent} onClick={nav.next}>Continue</Cta></Footer>
      </Shell>
    );
  }
  return (
    <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={2}>
      <Stage top={48} gap={22}>
        <HeroTile from="#F4EFE3" to="#DBD2BE" glow="rgba(180,168,140,0.4)" size={104}>
          <KeyboardGlyph size={50} color={t.dark ? '#3A352A' : '#4A4334'} />
        </HeroTile>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
          <Title t={t} size={31}>Add the Jot keyboard</Title>
          <Body t={t} max={326}>Two quick toggles in Settings let Jot paste your dictation into any app.</Body>
        </div>
        <div style={{ width: '100%', marginTop: 2, borderRadius: 18, background: t.card, border: `0.5px solid ${t.cardBord}`, overflow: 'hidden' }}>
          <SetupStep t={t} a={a} n="1" label="Add “Jot” under Keyboards" />
          <div style={{ height: 1, background: t.cardBord, marginLeft: 56 }} />
          <SetupStep t={t} a={a} n="2" label="Turn on Allow Full Access" />
        </div>
      </Stage>
      <Footer>
        <Cta accent={accent} onClick={onOpenSettings}>Open Settings</Cta>
        <TextLink t={t} onClick={nav.next}>I've already added it</TextLink>
      </Footer>
    </Shell>
  );
}
function SetupStep({ t, a, n, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '14px 18px' }}>
      <span style={{ width: 26, height: 26, borderRadius: 13, flexShrink: 0, background: a.soft, color: a.dot,
        display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: SYS, fontWeight: 700, fontSize: 14 }}>{n}</span>
      <span style={{ fontFamily: SYS, fontWeight: 500, fontSize: 16, color: t.ink }}>{label}</span>
    </div>
  );
}

// ── W4 · How it works (redesigned · animated · §4.4) ─────────
function W4How({ t, accent, mark, nav, total }) {
  const a = ACCENTS[accent];
  return (
    <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={3}>
      <Stage top={26} gap={20} justify="flex-start">
        <h1 style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontOpticalSizing: 'auto', fontSize: 35, lineHeight: 1.0, letterSpacing: '-0.4px', color: t.ink, textAlign: 'center', margin: 0, whiteSpace: 'nowrap' }}>How it works</h1>
        {/* animated mini-phone scene */}
        <HowScene t={t} accent={accent} mark={mark} />
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, marginTop: 2 }}>
          <p style={{ fontFamily: SYS, fontWeight: 400, fontSize: 18, lineHeight: 1.36, color: t.inkSub, textAlign: 'center', margin: 0, maxWidth: 300, textWrap: 'balance' }}>
            Tap Dictate, then <span style={{ color: a.dot, fontWeight: 700 }}>swipe back to your app.</span> Stop from the keyboard when you're done.
          </p>
          <p style={{ fontFamily: SYS, fontWeight: 400, fontSize: 12.5, lineHeight: 1.42, color: t.inkCaption, textAlign: 'center', margin: 0, maxWidth: 300 }}>
            We'd skip this step if we could. Apple doesn't let keyboards use the mic directly — so Jot hops back to capture. If that ever changes, this goes away.
          </p>
        </div>
      </Stage>
      <Footer><Cta accent={accent} onClick={nav.next}>Got it</Cta></Footer>
    </Shell>
  );
}

// Mini phone illustration: keyboard slides away, the user's app slides in,
// the record dot keeps pulsing, and a one-time "swipe back" arrow sweeps across.
function HowScene({ t, accent, mark }) {
  const a = ACCENTS[accent];
  const phoneBg = t.dark ? '#0C1422' : '#EAEFF7';
  const barInk = t.dark ? 'rgba(255,255,255,0.5)' : 'rgba(40,52,74,0.45)';
  const bubble = t.dark ? 'rgba(255,255,255,0.10)' : 'rgba(40,60,96,0.10)';
  return (
    <div className="how-stage" style={{ position: 'relative', width: 168, height: 248, borderRadius: 30, background: phoneBg,
      border: `1px solid ${t.dark ? 'rgba(255,255,255,0.12)' : 'rgba(20,30,50,0.10)'}`,
      boxShadow: `0 24px 48px -18px rgba(0,0,0,0.5), inset 0 0 0 0.5px rgba(255,255,255,0.05)`, overflow: 'hidden' }}>
      {/* dynamic island with pulsing record dot */}
      <div style={{ position: 'absolute', top: 9, left: '50%', transform: 'translateX(-50%)', width: 58, height: 17, borderRadius: 10, background: '#05080d', display: 'flex', alignItems: 'center', justifyContent: 'flex-end', paddingRight: 7, zIndex: 5 }}>
        <span className="how-recdot" style={{ width: 7, height: 7, borderRadius: 4, background: a.dot }} />
      </div>

      {/* the user's app (a message thread) — slides in on swipe-back */}
      <div className="how-app" style={{ position: 'absolute', inset: 0, paddingTop: 34, display: 'flex', flexDirection: 'column', gap: 8, alignItems: 'stretch', padding: '34px 12px 0' }}>
        <div style={{ alignSelf: 'flex-start', width: '62%', height: 16, borderRadius: 9, background: bubble }} />
        <div style={{ alignSelf: 'flex-end', width: '54%', height: 16, borderRadius: 9, background: a.soft }} />
        <div style={{ alignSelf: 'flex-start', width: '46%', height: 16, borderRadius: 9, background: bubble }} />
        {/* the dictated text appearing */}
        <div className="how-typed" style={{ alignSelf: 'flex-end', width: '72%', height: 30, borderRadius: 9, background: a.grad, opacity: 0 }} />
      </div>

      {/* the Jot keyboard — slides down on swipe-back */}
      <div className="how-kb" style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: 118, background: t.kbFill, borderTop: `1px solid ${t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.06)'}`, padding: '10px 12px', display: 'flex', flexDirection: 'column', gap: 9 }}>
        <div style={{ height: 11, width: '70%', borderRadius: 6, background: barInk, opacity: 0.4, fontStyle: 'italic' }} />
        <div style={{ flex: 1 }} />
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <div style={{ width: 30, height: 30, borderRadius: 15, background: t.kbKey }} />
          <div className="how-dictate" style={{ flex: 1, height: 34, borderRadius: 17, background: a.grad, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <span style={{ width: 9, height: 9, borderRadius: 5, background: '#fff' }} />
          </div>
          <div style={{ width: 30, height: 30, borderRadius: 15, background: t.kbKey }} />
        </div>
      </div>

      {/* one-time swipe-back arrow — along the bottom home-indicator edge (iOS) */}
      <div className="how-swipe" style={{ position: 'absolute', bottom: 15, left: 0, display: 'flex', alignItems: 'center', gap: 6, zIndex: 7, opacity: 0 }}>
        <svg width="40" height="20" viewBox="0 0 40 20" fill="none"><path d="M38 10H6M14 3L5 10l9 7" stroke={a.dot} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/></svg>
        <span style={{ fontFamily: SYS, fontWeight: 800, fontSize: 9.5, letterSpacing: '0.12em', color: a.dot }}>SWIPE</span>
      </div>

      {/* home indicator bar */}
      <div style={{ position: 'absolute', bottom: 7, left: '50%', transform: 'translateX(-50%)', width: 64, height: 4, borderRadius: 3, background: t.dark ? 'rgba(255,255,255,0.55)' : 'rgba(20,30,50,0.4)', zIndex: 8 }} />
    </div>
  );
}

// ── W5 · Try the keyboard ────────────────────────────────────
function W5Try({ t, accent, nav, total, tried, field, kbUp, onTry }) {
  const a = ACCENTS[accent];
  return (
    <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={4}>
      <Stage top={26} gap={20}>
        <Title t={t} size={33}>Now try the keyboard</Title>
        <Body t={t} max={330}>Tap the field below, switch to Jot via the globe key, then tap Dictate.</Body>
        <div onClick={onTry} style={{ marginTop: 4, width: '100%', minHeight: 90, borderRadius: 18, background: t.fieldFill,
          border: `1.5px solid ${(kbUp || tried) ? a.dot : t.fieldBord}`, boxShadow: (kbUp || tried) ? `0 0 0 4px ${a.soft}` : 'none',
          padding: '16px 18px', cursor: 'text', transition: 'all .25s', display: 'flex', flexDirection: 'column', justifyContent: 'flex-start' }}>
          {field
            ? <span style={{ fontFamily: SYS, fontSize: 16.5, color: t.ink, lineHeight: 1.42 }}>{field}</span>
            : <span style={{ fontFamily: SYS, fontSize: 16.5, color: t.inkCaption }}>Tap here, then switch to the Jot keyboard…</span>}
        </div>
        {/* italic = streaming/live only (C1b) */}
        <div style={{ height: 22, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {tried
            ? <span style={{ fontFamily: SYS, fontSize: 14, color: a.dot, fontWeight: 600, display: 'flex', alignItems: 'center', gap: 7 }}>
                <CheckMini color={a.dot} /> Pasted from Jot
              </span>
            : <span style={{ fontFamily: SERIF, fontStyle: 'italic', fontSize: 16, color: t.inkItalic }}>Listening for your text…</span>}
        </div>
      </Stage>
      {!kbUp && <Footer><Cta accent={accent} onClick={nav.next}>{tried ? 'Continue' : 'I tried it'}</Cta></Footer>}
    </Shell>
  );
}
function CheckMini({ color }) {
  return <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M3 7.4l2.8 2.8L11 4" stroke={color} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}

// ── W7 · You're ready (+ Watch "one more thing") ─────────────
function W7Ready({ t, accent, nav, total }) {
  const a = ACCENTS[accent];
  return (
    <Shell t={t} accent={accent} onBack={nav.back} onClose={nav.close} total={total} current={total - 1}>
      <Stage top={62} gap={24}>
        <HeroTile from="#34C759" to="#27A848" glow="rgba(39,168,72,0.5)" size={112}><CheckGlyph size={56} /></HeroTile>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
          <Title t={t} size={42}>You're ready.</Title>
          <Body t={t} max={300}>Jot works now — start dictating in any app, any time.</Body>
        </div>
        {/* one more thing — Apple Watch */}
        <div style={{ width: '100%', marginTop: 8, borderRadius: 20, background: t.card, border: `0.5px solid ${t.cardBord}`,
          padding: '16px 18px', display: 'flex', alignItems: 'center', gap: 15 }}>
          <div style={{ width: 52, height: 52, borderRadius: 15, flexShrink: 0, background: a.soft,
            display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <WatchGlyph size={32} color={a.dot} wave={a.dot} />
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
            <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 16, color: t.ink, letterSpacing: '-0.2px' }}>It's on your wrist, too</span>
            <span style={{ fontFamily: SYS, fontWeight: 400, fontSize: 13.5, lineHeight: 1.36, color: t.inkSub, textWrap: 'pretty' }}>
              Caught an idea without your phone? Tap the Jot complication and speak — it syncs back automatically.
            </span>
          </div>
        </div>
      </Stage>
      <Footer><Cta accent={accent} onClick={nav.close}>Start dictating</Cta></Footer>
    </Shell>
  );
}

Object.assign(window, { Shell, Footer, Stage, W1Welcome, W2Mic, W3Keyboard, SetupStep, W4How, HowScene, W5Try, W7Ready });
