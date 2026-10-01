/* ask-states.jsx — Ask Jot · the three lifecycle views + composer variants */

// ── 5-second silence countdown ring ──────────────────────────
function CountdownRing({ t, accent, secs }) {
  const a = ACCENTS[accent];
  const R = 13, C = 2 * Math.PI * R, frac = secs / 5;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
      <div style={{ position: 'relative', width: 32, height: 32 }}>
        <svg width="32" height="32" style={{ transform: 'rotate(-90deg)' }}>
          <circle cx="16" cy="16" r={R} fill="none" stroke={t.dark ? 'rgba(255,255,255,0.14)' : 'rgba(40,54,82,0.14)'} strokeWidth="3" />
          <circle cx="16" cy="16" r={R} fill="none" stroke={a.solid} strokeWidth="3" strokeLinecap="round"
            strokeDasharray={C} strokeDashoffset={C * (1 - frac)} style={{ transition: 'stroke-dashoffset 1s linear' }} />
        </svg>
        <span style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontFamily: SYS, fontWeight: 600, fontSize: 13, color: a.solid }}>{secs}</span>
      </div>
      <span style={{ fontFamily: SYS, fontWeight: 500, fontSize: 15, color: t.inkSub }}>Sending — keep talking to add more</span>
    </div>
  );
}

// status row while listening: "Listening" + live waveform
function ListeningStatus({ t, accent }) {
  const a = ACCENTS[accent];
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
      <span style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        <span style={{ width: 9, height: 9, borderRadius: 5, background: a.dot, animation: 'askPulse 1.4s ease-in-out infinite' }} />
        <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 15.5, color: t.ink }}>Listening</span>
      </span>
      <Waveform color={a.dot} active size={0.62} />
    </div>
  );
}

// ── Listening — voice canvas (default) ───────────────────────
function ListeningCanvas({ t, accent, transcript, countdown, typing, onSend, onType, onInput, inputRef }) {
  const a = ACCENTS[accent];
  const hasWords = transcript.trim().length > 0;
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 84, display: 'flex', flexDirection: 'column' }}>
      {/* hero transcript / prompt */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '0 34px', minHeight: 0 }}>
        {hasWords || typing ? (
          typing ? (
            <textarea ref={inputRef} value={transcript} onChange={e => onInput(e.target.value)} rows={3}
              placeholder="Type your question…"
              style={{ width: '100%', resize: 'none', border: 'none', outline: 'none', background: 'transparent',
                fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontSize: 30, lineHeight: 1.22,
                letterSpacing: '-0.4px', color: t.ink, textAlign: 'center' }} />
          ) : (
            <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontSize: 30, lineHeight: 1.24,
              letterSpacing: '-0.4px', color: t.ink, textAlign: 'center', textWrap: 'pretty', maxHeight: '46%', overflow: 'hidden' }}>
              {transcript}
              <span style={{ display: 'inline-block', width: 2.5, height: 28, marginLeft: 3, verticalAlign: '-4px',
                background: a.solid, borderRadius: 2, animation: 'askCaret 1s step-end infinite' }} />
            </div>
          )
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 22, animation: 'askFade .5s ease' }}>
            <span style={{ animation: 'askPulse 2.4s ease-in-out infinite' }}><Sparkle size={34} color={a.solid} /></span>
            <div style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontSize: 25, color: t.inkSub, textAlign: 'center' }}>
              What do you want to know?
            </div>
            <SuggestionLine t={t} paused={false} />
          </div>
        )}
      </div>

      {/* status zone */}
      <div style={{ height: 40, display: 'flex', alignItems: 'center', justifyContent: 'center', marginBottom: 6 }}>
        {!typing && (countdown != null ? <CountdownRing t={t} accent={accent} secs={countdown} /> : (hasWords ? <ListeningStatus t={t} accent={accent} /> : null))}
        {typing && <span style={{ fontFamily: SYS, fontSize: 14, color: t.inkCaption }}>Voice paused · typing</span>}
      </div>

      {/* dock */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 13, padding: '4px 0 30px' }}>
        <SendStop t={t} accent={accent} ready={hasWords} onSend={onSend} size={60} />
        <button onClick={onType} style={{ display: 'flex', alignItems: 'center', gap: 7, background: 'none', border: 'none',
          cursor: 'pointer', padding: '6px 12px', WebkitTapHighlightColor: 'transparent' }}>
          {typing ? <Waveform color={t.inkSub} active={false} size={0.45} /> : <KbMini color={t.inkSub} size={17} />}
          <span style={{ fontFamily: SYS, fontWeight: 500, fontSize: 14.5, color: t.inkSub }}>{typing ? 'Use voice' : 'Type instead'}</span>
        </button>
      </div>
    </div>
  );
}

// ── Listening — composer bar (variation) ─────────────────────
function ListeningComposer({ t, accent, transcript, countdown, typing, onSend, onType, onInput, inputRef }) {
  const a = ACCENTS[accent];
  const hasWords = transcript.trim().length > 0;
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 82, display: 'flex', flexDirection: 'column' }}>
      {/* field */}
      <div style={{ padding: '0 18px' }}>
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 10, padding: '12px 12px 12px 16px',
          background: t.fieldFill, border: `0.5px solid ${t.fieldBord}`, borderRadius: 26,
          backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', minHeight: 56 }}>
          <span style={{ marginBottom: 4, flexShrink: 0 }}><Sparkle size={19} color={a.solid} /></span>
          <div style={{ flex: 1, minWidth: 0, paddingBottom: 2 }}>
            {typing ? (
              <textarea ref={inputRef} value={transcript} onChange={e => onInput(e.target.value)} rows={1}
                placeholder="Ask anything about your notes…"
                style={{ width: '100%', resize: 'none', border: 'none', outline: 'none', background: 'transparent',
                  fontFamily: SYS, fontWeight: 400, fontSize: 17, lineHeight: 1.35, color: t.ink }} />
            ) : hasWords ? (
              <span style={{ fontFamily: SYS, fontWeight: 400, fontSize: 17, lineHeight: 1.35, color: t.ink }}>
                {transcript}
                <span style={{ display: 'inline-block', width: 2, height: 17, marginLeft: 2, verticalAlign: '-3px',
                  background: a.solid, animation: 'askCaret 1s step-end infinite' }} />
              </span>
            ) : (
              <span onClick={onType} style={{ fontFamily: SYS, fontWeight: 400, fontSize: 17, color: t.inkCaption, cursor: 'text' }}>
                Listening… or tap to type
              </span>
            )}
          </div>
          <SendStop t={t} accent={accent} ready={hasWords} onSend={onSend} size={44} />
        </div>
      </div>

      {/* status under field */}
      <div style={{ height: 30, display: 'flex', alignItems: 'center', padding: '8px 26px 0' }}>
        {!typing && (countdown != null ? <CountdownRing t={t} accent={accent} secs={countdown} /> :
          (hasWords ? <ListeningStatus t={t} accent={accent} /> : <ListeningStatus t={t} accent={accent} />))}
      </div>

      {/* calm look-away space */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 16, paddingBottom: 60 }}>
        {!hasWords && !typing && (
          <React.Fragment>
            <span style={{ animation: 'askPulse 2.4s ease-in-out infinite' }}><Sparkle size={30} color={a.soft.replace('0.20', '0.5')} /></span>
            <SuggestionLine t={t} paused={false} />
          </React.Fragment>
        )}
      </div>
    </div>
  );
}

// ── Thinking ─────────────────────────────────────────────────
const THINK_STEPS = ['Searching your notes…', 'Reading 9 notes…', 'Writing your answer…'];
function ThinkingView({ t, accent, question, stepIdx }) {
  const a = ACCENTS[accent];
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 84, display: 'flex', flexDirection: 'column' }}>
      <QuestionHeader t={t} accent={accent} question={question} />
      <div style={{ padding: '22px 26px 0', display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ width: 9, height: 9, borderRadius: 5, background: a.dot, animation: 'askPulse 1.1s ease-in-out infinite' }} />
          <span key={stepIdx} style={{ fontFamily: SYS, fontWeight: 500, fontSize: 16, color: t.inkSub, animation: 'askFade .4s ease' }}>
            {THINK_STEPS[stepIdx]}
          </span>
        </div>
        {/* shimmer skeleton */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 11, marginTop: 4 }}>
          {[100, 96, 88, 70].map((w, i) => <ShimmerLine key={i} t={t} w={w} />)}
        </div>
      </div>
    </div>
  );
}
function ShimmerLine({ t, w }) {
  const base = t.dark ? 'rgba(255,255,255,0.07)' : 'rgba(40,54,82,0.07)';
  const hi = t.dark ? 'rgba(255,255,255,0.14)' : 'rgba(40,54,82,0.13)';
  return <div style={{ height: 15, width: w + '%', borderRadius: 7,
    background: `linear-gradient(90deg, ${base} 0%, ${hi} 50%, ${base} 100%)`,
    backgroundSize: '220px 100%', animation: 'askShimmer 1.3s linear infinite' }} />;
}

// ── Question header (shared by thinking + answer) ────────────
function QuestionHeader({ t, accent, question, onAskAnother }) {
  const a = ACCENTS[accent];
  return (
    <div style={{ padding: '0 22px', display: 'flex', alignItems: 'flex-start', gap: 12 }}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
        <span style={{ fontFamily: SYS, fontWeight: 600, fontSize: 11, letterSpacing: '1.4px',
          color: t.inkCaption, textTransform: 'uppercase' }}>You asked</span>
        <span style={{ fontFamily: SERIF, fontStyle: 'italic', fontWeight: 500, fontSize: 22, lineHeight: 1.18,
          letterSpacing: '-0.3px', color: t.ink }}>{question}</span>
      </div>
      {onAskAnother && (
        <button onClick={onAskAnother} style={{ flexShrink: 0, marginTop: 14, height: 34, padding: '0 14px', borderRadius: 17,
          background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`, color: a.solid, cursor: 'pointer',
          fontFamily: SYS, fontWeight: 600, fontSize: 14, WebkitTapHighlightColor: 'transparent',
          backdropFilter: 'blur(14px)', WebkitBackdropFilter: 'blur(14px)' }}>Ask another</button>
      )}
    </div>
  );
}

// ── Answer ───────────────────────────────────────────────────
function AnswerView({ t, accent, question, tokens, visible, done, sources, model, searched, carded, onAskAnother, onCite, onCopy, copied }) {
  const a = ACCENTS[accent];
  const shown = tokens.slice(0, visible);
  const answerBody = (
    <div style={{ fontFamily: SYS, fontWeight: 400, fontSize: 17.5, lineHeight: 1.56, color: t.ink, letterSpacing: '-0.1px' }}>
      {shown.map((tok, i) => {
        if (tok.br) return <span key={i} style={{ display: 'block', height: 12 }} />;
        if (tok.cite) return <CitationChip key={i} label={tok.cite} t={t} accent={accent} onClick={() => onCite(tok.cite)} />;
        return <span key={i}>{tok.w + ' '}</span>;
      })}
      {!done && <span style={{ display: 'inline-block', width: 8, height: 18, marginLeft: 1, verticalAlign: '-3px',
        borderRadius: 2, background: a.solid, animation: 'askCaret 1s step-end infinite' }} />}
    </div>
  );
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 84, display: 'flex', flexDirection: 'column' }}>
      <QuestionHeader t={t} accent={accent} question={question} onAskAnother={onAskAnother} />
      <div className="ask-scroll" style={{ flex: 1, overflowY: 'auto', padding: '20px 22px 20px', minHeight: 0 }}>
        {carded ? (
          <div style={{ background: t.card, border: `0.5px solid ${t.cardBord}`, borderRadius: 20, padding: '18px 18px' }}>{answerBody}</div>
        ) : answerBody}

        {done && (
          <div style={{ animation: 'askRise .4s ease', marginTop: 26 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <span style={{ fontFamily: SYS, fontWeight: 700, fontSize: 11, letterSpacing: '1.4px', color: t.inkCaption }}>SOURCES</span>
              <span style={{ flex: 1, height: 1, background: t.cardBord }} />
            </div>
            <div style={{ display: 'flex', flexDirection: 'column' }}>
              {sources.map((s, i) => (
                <React.Fragment key={i}>
                  {i > 0 && <span style={{ height: 0.5, background: t.cardBord, margin: '0 4px' }} />}
                  <SourceRow t={t} accent={accent} date={s.date} snippet={s.snippet} onClick={() => onCite(s.date)} />
                </React.Fragment>
              ))}
            </div>
            <div style={{ marginTop: 12, fontFamily: SYS, fontWeight: 400, fontSize: 13, color: t.inkCaption, textAlign: 'center' }}>
              Answered with {model} · {searched} notes searched · on-device
            </div>
          </div>
        )}
      </div>

      {/* action dock */}
      {done && (
        <div style={{ display: 'flex', gap: 11, padding: '10px 18px 28px', animation: 'askRise .4s ease' }}>
          <button onClick={onAskAnother} style={{ flex: 1, height: 54, borderRadius: 27, border: 'none', background: a.grad,
            color: '#fff', fontFamily: SYS, fontWeight: 600, fontSize: 17, cursor: 'pointer',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 9,
            boxShadow: `0 8px 24px -6px ${a.glow}, inset 0 1px 0 rgba(255,255,255,0.3)`, WebkitTapHighlightColor: 'transparent' }}>
            <Sparkle size={18} color="#fff" /> Ask another
          </button>
          <button onClick={onCopy} style={{ width: 54, height: 54, borderRadius: 27, flexShrink: 0,
            background: t.chromeFill, border: `0.5px solid ${t.chromeBord}`, cursor: 'pointer',
            backdropFilter: 'blur(14px)', WebkitBackdropFilter: 'blur(14px)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', WebkitTapHighlightColor: 'transparent' }}>
            {copied ? <CheckMini color={a.solid} /> : <CopyGlyph color={t.chromeGlyph} />}
          </button>
        </div>
      )}
    </div>
  );
}

Object.assign(window, {
  CountdownRing, ListeningStatus, ListeningCanvas, ListeningComposer,
  ThinkingView, THINK_STEPS, QuestionHeader, AnswerView,
});
