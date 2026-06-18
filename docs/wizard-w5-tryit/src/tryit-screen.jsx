/* tryit-screen.jsx — the wizard "Now try the keyboard" step, 6 micro-states */

const FINAL_TEXT = 'I am awesome at this.';
const STREAM_PARTIAL = 'I am awesome';
const KOAN_LINES = [
  'This is the slow part. It’s the only slow part.',
  'Teaching your iPhone to listen. Rude not to talk back.',
  'First run’s on the house — it gets quicker from here.',
  'Building your voice model. Keep the words coming.',
  'One-time setup. Future you won’t see this screen again.',
];

function Instruction({ t, state }) {
  if (state === 'rise') {
    return <Body t={t}>Say something out loud — like <span style={{ fontFamily: SERIF, fontStyle: 'italic', color: t.ink }}>“I am awesome.”</span></Body>;
  }
  const copy = {
    invite: 'Tap the field below, switch to Jot via the globe key, then tap Jot down.',
    init:   'Just the first time, the model needs a moment to load. Keep talking.',
    stream: 'Model’s ready — your words stream inside the keyboard, not in the field.',
    stop:   'Tap Stop when you’re done, and Jot pastes it into the field.',
    done:   'That’s the whole loop — your words landed in the field.',
  }[state];
  return <Body t={t}>{copy}</Body>;
}

// state: 'invite' | 'rise' | 'stream' | 'init' | 'stop' | 'done' · variant: 'A' | 'C'
function TryItScreen({ theme = 'light', state, variant = 'A', koan }) {
  const t = tok(theme);
  const kbUp = state !== 'invite' && state !== 'done';

  const field = {
    invite: { placeholder: 'Tap to try it', glow: true },
    rise:   { placeholder: '', caret: true },
    stream: { placeholder: '', caret: true },
    init:   { placeholder: '', caret: true },
    stop:   { placeholder: '', caret: true },
    done:   { text: FINAL_TEXT },
  }[state];

  let pane = null, kbProps = {};
  if (state === 'rise') {
    pane = (
      <KbPane t={t} minHeight={76}>
        <div style={{ textAlign: 'center', padding: '4px 0' }}>
          <span style={{ fontFamily: SYS, fontSize: 14.5, color: t.kbMute, lineHeight: 1.4 }}>Tap <b style={{ color: t.keyInk }}>Jot down</b> and start talking.</span>
        </div>
      </KbPane>
    );
    kbProps = { mode: 'idle', recordGlow: true };
  }
  if (state === 'stream') {
    pane = (
      <KbPane t={t} label="We tidy this up when you stop">
        <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontSize: 18, lineHeight: 1.34, color: t.stream }}>{STREAM_PARTIAL}<span className="try-caret" /></div>
      </KbPane>
    );
    kbProps = { mode: 'rec', timer: '0:14' };
  }
  if (state === 'init') {
    pane = (
      <KbPane t={t} label="First-time setup" minHeight={108}>
        <SetupNote t={t} />
      </KbPane>
    );
    kbProps = { mode: 'rec', timer: '0:06' };
  }
  if (state === 'stop') {
    pane = (
      <KbPane t={t} label="We tidy this up when you stop">
        <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontSize: 18, lineHeight: 1.34, color: t.stream }}>{FINAL_TEXT}<span className="try-caret" /></div>
      </KbPane>
    );
    kbProps = { mode: 'rec', timer: '0:20', stopGlow: true };
  }

  return (
    <Frame t={t}>
      <StatusBar t={t} />
      <WizardChrome t={t} current={4} />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '0 26px', minHeight: 0 }}>
        <div style={{ height: kbUp ? 22 : 40, flexShrink: 0 }} />
        <Title t={t}>Now try the keyboard</Title>
        <div style={{ height: 14 }} />
        <Instruction t={t} state={state} />
        <div style={{ height: 26 }} />
        <PracticeField t={t} {...field} />
        <div style={{ height: 16 }} />
        <Helper t={t} state={state} />
        <div style={{ flex: 1 }} />
      </div>

      {kbUp
        ? <JotKeyboard t={t} {...kbProps} pane={pane} />
        : <><Footer t={t}><Cta t={t}>{state === 'done' ? 'Continue' : 'I tried it'}</Cta></Footer><HomeBar t={t} /></>}
    </Frame>
  );
}

// ── Microcopy & notes reference card ─────────────────────────
function Row({ t, k, children }) {
  return (
    <div style={{ display: 'flex', gap: 16, padding: '12px 0', borderBottom: `0.5px solid ${t.cardBord}` }}>
      <div style={{ width: 134, flexShrink: 0, fontFamily: SYS, fontSize: 11, fontWeight: 700, letterSpacing: '0.06em', color: t.inkCap, textTransform: 'uppercase', paddingTop: 2 }}>{k}</div>
      <div style={{ flex: 1, fontFamily: SYS, fontSize: 14.5, lineHeight: 1.5, color: t.ink }}>{children}</div>
    </div>
  );
}
function MicrocopyCard({ theme = 'light' }) {
  const t = tok(theme);
  const Mute = ({ children }) => <span style={{ color: t.inkSub }}>{children}</span>;
  const I = ({ children }) => <span style={{ fontFamily: SERIF, fontStyle: 'italic' }}>{children}</span>;
  return (
    <div style={{ width: 620, height: 844, background: t.dark ? '#141c2b' : '#FBFCFE', padding: '40px 44px', boxSizing: 'border-box', fontFamily: SYS, color: t.ink, overflow: 'hidden' }}>
      <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontSize: 30, letterSpacing: '-0.5px' }}>Now try the keyboard.</div>
      <div style={{ fontFamily: SYS, fontSize: 13.5, color: t.inkSub, marginTop: 6, marginBottom: 12 }}>Wizard step 5 of 7, in Jot’s voice. Title stays constant; only the instruction changes. Spoken = italic serif.</div>
      <Row t={t} k="1 · Invite"><Mute>“Tap the field below, switch to Jot via the globe key, then tap Jot down.”</Mute> · field shimmers with <b>“Tap to try it”</b></Row>
      <Row t={t} k="2 · Jot down">“Say something out loud — like <I>I am awesome.</I>” · keyboard: <Mute>“Tap Jot down and start talking.”</Mute></Row>
      <Row t={t} k="3 · First-time setup">Label <b>“First-time setup”</b> (blinking dot — the only motion) · <I>“This is the slow part. It’s the only slow part.”</I> · caption <Mute>“Only happens once. Keep talking.”</Mute> — no waveform, no fill bar.</Row>
      <Row t={t} k="4 · Streaming">Model’s ready → words appear. <Mute>“Your words stream inside the keyboard — not in the field.”</Mute> · pane <b>“We tidy this up when you stop”</b> · <I>“I am awesome”</I></Row>
      <Row t={t} k="5 · Stop glows"><Mute>“Tap Stop when you’re done, and Jot pastes it into the field.”</Mute> · after a few seconds the <b>Stop</b> button glows · <I>“I am awesome at this.”</I></Row>
      <Row t={t} k="6 · It works">Field fills · helper <span style={{ color: t.accentDot, fontWeight: 600 }}>“Pasted from Jot ✓”</span> · CTA <b>“Continue”</b> <Mute>(no auto-advance)</Mute></Row>
      <div style={{ marginTop: 16, fontFamily: SYS, fontSize: 12.5, color: t.inkSub, lineHeight: 1.45 }}>
        <b style={{ color: t.ink }}>Motion rule:</b> during recording and setup the only animated element is the single pulsing dot — no waveform, no fill bar.
      </div>
    </div>
  );
}

Object.assign(window, { TryItScreen, MicrocopyCard, KOAN_LINES, FINAL_TEXT });
