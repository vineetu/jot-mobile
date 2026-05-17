// In-app recording hero screens — three philosophies, all in the Comfort palette.

// ─────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────
const RecordingWallpaper = () => (
  <div style={{ position: "absolute", inset: 0, overflow: "hidden", zIndex: 0 }}>
    <div style={{
      position: "absolute", inset: 0,
      background:
        "radial-gradient(ellipse 55% 40% at 15% 5%, rgba(0,122,255,0.22), transparent 70%), " +
        "radial-gradient(ellipse 50% 35% at 95% 95%, rgba(0,122,255,0.18), transparent 70%), " +
        "linear-gradient(180deg, #DCDEE3 0%, #D1D3DA 100%)"
    }} />
    {/* recording tint per Reference v3 spec */}
    <div style={{ position: "absolute", inset: 0, background: "rgba(0,122,255,0.06)" }} />
  </div>
);

// Live-looking waveform: amplitude envelope rises into the present, then a cursor line.
const liveWave = (n = 64, seed = 11) => {
  let s = seed;
  const out = [];
  for (let i = 0; i < n; i++) {
    s = (s * 9301 + 49297) % 233280;
    const r = s / 233280;
    // ramp: low at left (past, decaying), tall in middle, attenuates at right (silence after cursor)
    const t = i / n;
    let env;
    if (t < 0.65) env = 0.3 + Math.pow(t / 0.65, 0.7) * 0.7;        // ramping up to present
    else if (t < 0.72) env = 0.95;                                  // peak around cursor
    else env = Math.max(0.05, 0.95 - (t - 0.72) * 3.5);              // dies out after
    out.push(Math.max(0.08, r * env));
  }
  return out;
};

const LiveWaveform = ({ color, height = 50, width = 320, cursorAt = 0.72 }) => {
  const bars = liveWave(56);
  const bw = width / (bars.length * 1.5);
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ overflow: "visible" }}>
      {bars.map((amp, i) => {
        const h = Math.max(3, amp * height);
        const x = i * (bw * 1.5);
        const y = (height - h) / 2;
        const t = i / bars.length;
        const opacity = t < cursorAt ? 0.85 : 0.35;
        return (
          <rect key={i} x={x} y={y} width={bw} height={h} rx={bw/2}
            fill={color} fillOpacity={opacity} />
        );
      })}
      {/* live cursor */}
      <line x1={cursorAt * width} y1="0" x2={cursorAt * width} y2={height}
        stroke={color} strokeWidth="1.5" opacity="0.55"/>
      <circle cx={cursorAt * width} cy={height/2} r="3.5" fill={color}/>
    </svg>
  );
};

// Recording header — destination + cancel + timer
const RecHeader = ({ palette, dest = "Note to self", timer = "0:14", trailing = "Pause" }) => {
  const p = palette;
  return (
    <div style={{
      display: "flex", alignItems: "center", justifyContent: "space-between",
      padding: "10px 18px 14px"
    }}>
      <div style={{
        padding: "6px 12px", borderRadius: 999,
        background: "rgba(255,255,255,0.55)",
        backdropFilter: "blur(20px)",
        WebkitBackdropFilter: "blur(20px)",
        border: `0.5px solid ${p.card.border}`,
        fontSize: 12, fontWeight: 600, color: p.card.fg
      }}>Cancel</div>
      <div style={{
        display: "flex", alignItems: "center", gap: 6,
        padding: "6px 12px", borderRadius: 999,
        background: "rgba(255,255,255,0.55)",
        backdropFilter: "blur(20px)",
        WebkitBackdropFilter: "blur(20px)",
        border: `0.5px solid ${p.card.border}`
      }}>
        <span style={{
          width: 7, height: 7, borderRadius: 4, background: "#E0173B",
          boxShadow: "0 0 0 3px rgba(224,23,59,0.18)"
        }} />
        <span style={{ fontSize: 12, color: p.card.sub, fontWeight: 500 }}>{dest}</span>
        <span style={{ width: 1, height: 12, background: p.card.separator, margin: "0 4px" }} />
        <span style={{ fontSize: 12, fontWeight: 600, color: p.card.fg, fontFeatureSettings: '"tnum"', letterSpacing: 0.2 }}>{timer}</span>
      </div>
      <div style={{
        padding: "6px 12px", borderRadius: 999,
        background: "rgba(255,255,255,0.55)",
        backdropFilter: "blur(20px)",
        WebkitBackdropFilter: "blur(20px)",
        border: `0.5px solid ${p.card.border}`,
        fontSize: 12, fontWeight: 600, color: p.card.fg
      }}>{trailing}</div>
    </div>
  );
};

const StopButton = ({ palette, timer }) => {
  const p = palette;
  return (
    <div style={{
      position: "absolute", left: "50%", bottom: 36, transform: "translateX(-50%)",
      height: 64, padding: "0 24px", borderRadius: 32,
      background: p.accent.gradient,
      boxShadow: `0 12px 32px -6px ${p.accent.shadow}, 0 0 0 0.5px rgba(255,255,255,0.25) inset`,
      color: p.accent.fg,
      display: "flex", alignItems: "center", gap: 14,
      fontSize: 17, fontWeight: 600, letterSpacing: -0.2
    }}>
      <div style={{
        width: 20, height: 20, borderRadius: 5, background: p.accent.fg
      }} />
      {timer && (
        <span style={{
          fontSize: 17, fontWeight: 500, letterSpacing: 0.4,
          fontFeatureSettings: '"tnum"'
        }}>{timer}</span>
      )}
    </div>
  );
};

const StatusPad = () => <div style={{ height: 54 }} />;

const HomeIndicator = () => (
  <div style={{
    position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
    width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
  }} />
);

const PROSE = "three things today shipped the chrome change talked to priya about onboarding and drafted the AI sheet copy the wizard read is sharper now and vocab help is actually pulling its weight";
const PROSE_TRAIL = "for once tomorrow i want to look at";

// ─────────────────────────────────────────────────────────────
// R1 · Letter — transcript is the hero
// ─────────────────────────────────────────────────────────────
// R1 header — just cancel (right). Timer moved into the stop button.
const RecHeaderMinimal = ({ palette }) => {
  const p = palette;
  return (
    <div style={{
      display: "flex", alignItems: "center", justifyContent: "flex-end",
      padding: "6px 18px 14px"
    }}>
      <div style={{
        padding: "7px 14px", borderRadius: 999,
        background: "rgba(255,255,255,0.55)",
        backdropFilter: "blur(20px)",
        WebkitBackdropFilter: "blur(20px)",
        border: `0.5px solid ${p.card.border}`,
        fontSize: 13, fontWeight: 600, color: p.card.fg
      }}>Cancel</div>
    </div>
  );
};

const RecordLetter = ({ palette }) => {
  const p = palette;
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden" }}>
      <RecordingWallpaper />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
        <StatusPad />
        <RecHeaderMinimal palette={p} />

        {/* Transcript on a Liquid Glass plate — keeps wallpaper alive
            in the margins while giving the text a calm reading surface */}
        <div style={{
          flex: 1, padding: "0 14px",
          display: "flex", flexDirection: "column", minHeight: 0
        }}>
          <div style={{
            flex: 1,
            background: "rgba(255,255,255,0.55)",
            backdropFilter: "blur(40px) saturate(180%)",
            WebkitBackdropFilter: "blur(40px) saturate(180%)",
            border: "0.5px solid rgba(255,255,255,0.4)",
            borderRadius: 24,
            padding: "26px 24px 20px",
            display: "flex", flexDirection: "column",
            boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 20px 50px -28px rgba(15,17,28,0.30)",
            overflow: "hidden"
          }}>
            <div style={{
              flex: 1, overflow: "hidden",
              fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
              fontStyle: "italic", fontSize: 26, lineHeight: 1.32, letterSpacing: -0.4,
              color: p.card.fg, textWrap: "pretty"
            }}>
              <span>{PROSE}</span>
              <span style={{ color: p.card.sub }}> {PROSE_TRAIL}</span>
              <span style={{
                display: "inline-block", width: 2, height: 24,
                background: p.accent.solid, verticalAlign: "text-bottom",
                marginLeft: 3, marginBottom: -2
              }}/>
            </div>

            {/* Waveform ribbon at the bottom of the plate */}
            <div style={{ paddingTop: 18, display: "flex", justifyContent: "center" }}>
              <LiveWaveform color={p.accent.solid} height={36} width={300} />
            </div>
          </div>
        </div>

        <div style={{ height: 130 }} />

        <StopButton palette={p} label="Done" timer="0:14" />
        <HomeIndicator />
      </div>
    </div>
  );
};

// ─────────────────────────────────────────────────────────────
// R2 · Orb — the voice as a breathing circle
// ─────────────────────────────────────────────────────────────
const VoiceOrb = ({ color, size = 220 }) => {
  // Concentric pulse rings + filled gradient center
  return (
    <div style={{ position: "relative", width: size, height: size }}>
      {[0, 1, 2].map(i => (
        <div key={i} style={{
          position: "absolute", inset: -i * 16,
          borderRadius: "50%",
          border: `1.5px solid ${color}`,
          opacity: 0.18 - i * 0.05
        }} />
      ))}
      <div style={{
        position: "absolute", inset: 0, borderRadius: "50%",
        background: `radial-gradient(circle at 30% 30%, rgba(255,255,255,0.65), rgba(255,255,255,0.10) 45%, ${color} 100%)`,
        boxShadow: `0 24px 60px -12px ${color}66, 0 0 0 0.5px rgba(255,255,255,0.4) inset`
      }} />
      {/* small inner waveform ring */}
      <svg viewBox="0 0 100 100" style={{ position: "absolute", inset: 0 }}>
        {Array.from({ length: 48 }, (_, i) => {
          const a = (i / 48) * Math.PI * 2;
          const r1 = 38;
          const amp = 4 + Math.abs(Math.sin(i * 1.3) * 6 + Math.cos(i * 0.7) * 4);
          const r2 = r1 + amp * 0.8;
          const x1 = 50 + Math.cos(a) * r1;
          const y1 = 50 + Math.sin(a) * r1;
          const x2 = 50 + Math.cos(a) * r2;
          const y2 = 50 + Math.sin(a) * r2;
          return <line key={i} x1={x1} y1={y1} x2={x2} y2={y2}
            stroke="#fff" strokeOpacity="0.75" strokeWidth="1.2" strokeLinecap="round"/>;
        })}
      </svg>
    </div>
  );
};

const RecordOrb = ({ palette }) => {
  const p = palette;
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden" }}>
      <RecordingWallpaper />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
        <StatusPad />
        <RecHeader palette={p} />

        {/* Orb */}
        <div style={{ display: "flex", justifyContent: "center", padding: "32px 0 20px", position: "relative" }}>
          <VoiceOrb color={p.accent.solid} size={210} />
          <div style={{
            position: "absolute", top: "calc(50% - 12px)", left: 0, right: 0,
            textAlign: "center", color: "#fff",
            fontSize: 32, fontWeight: 500, letterSpacing: 0.4,
            fontFeatureSettings: '"tnum"',
            textShadow: "0 1px 2px rgba(0,40,120,0.3)"
          }}>0:14</div>
        </div>

        {/* Live transcript below orb */}
        <div style={{ flex: 1, padding: "12px 28px 0", position: "relative" }}>
          <div style={{
            fontSize: 13, color: p.card.sub, letterSpacing: 1.3, fontWeight: 600,
            textTransform: "uppercase", marginBottom: 10
          }}>Live</div>
          <div style={{
            fontSize: 17, lineHeight: 1.45, color: p.card.fg, letterSpacing: -0.2,
            textWrap: "pretty",
            display: "-webkit-box", WebkitLineClamp: 6, WebkitBoxOrient: "vertical", overflow: "hidden"
          }}>
            <span style={{ color: p.card.sub }}>Three things today — shipped the chrome change, talked to Priya about onboarding, and drafted the AI sheet copy. </span>
            <span>The wizard read is sharper now, and vocab help is actually pulling its weight</span>
            <span style={{
              display: "inline-block", width: 2, height: 16,
              background: p.accent.solid, marginLeft: 2, marginBottom: -2
            }}/>
          </div>
        </div>

        <StopButton palette={p} label="Done" />
        <HomeIndicator />
      </div>
    </div>
  );
};

// ─────────────────────────────────────────────────────────────
// R3 · Glass Tape — the keyboard's streaming card, blown up
// ─────────────────────────────────────────────────────────────
const RecordTape = ({ palette }) => {
  const p = palette;
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden" }}>
      <RecordingWallpaper />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
        <StatusPad />

        {/* Minimal top nav — cancel only */}
        <div style={{ padding: "8px 18px 0", display: "flex", justifyContent: "space-between" }}>
          <div style={{
            padding: "6px 12px", borderRadius: 999,
            background: "rgba(255,255,255,0.55)",
            backdropFilter: "blur(20px)",
            WebkitBackdropFilter: "blur(20px)",
            border: `0.5px solid ${p.card.border}`,
            fontSize: 12, fontWeight: 600, color: p.card.fg
          }}>Cancel</div>
        </div>

        {/* Big Liquid Glass card */}
        <div style={{ padding: "14px 14px 0", flex: 1 }}>
          <div style={{
            background: "rgba(255,255,255,0.55)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: `0.5px solid ${p.card.border}`,
            borderRadius: 24,
            padding: "20px 22px",
            boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 24px 60px -28px rgba(15,17,28,0.35)",
            display: "flex", flexDirection: "column", gap: 18,
            height: "100%"
          }}>
            {/* Header: timer + dest */}
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{
                  width: 9, height: 9, borderRadius: 5, background: "#E0173B",
                  boxShadow: "0 0 0 4px rgba(224,23,59,0.18)"
                }} />
                <span style={{
                  fontSize: 11, fontWeight: 700, letterSpacing: 1.5,
                  color: p.card.sub, textTransform: "uppercase"
                }}>Recording · Note to self</span>
              </div>
              <span style={{
                fontSize: 22, fontWeight: 500, color: p.card.fg,
                fontFeatureSettings: '"tnum"', letterSpacing: 0.2
              }}>0:14</span>
            </div>

            {/* Waveform tape */}
            <div style={{ margin: "0 -4px" }}>
              <LiveWaveform color={p.accent.solid} height={56} width={340} />
            </div>

            {/* Transcript */}
            <div style={{
              flex: 1, overflow: "hidden",
              fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
              fontSize: 18, lineHeight: 1.42, color: p.card.fg, letterSpacing: -0.2,
              textWrap: "pretty"
            }}>
              <span>{PROSE}</span>
              <span style={{ color: p.card.sub }}> {PROSE_TRAIL}</span>
              <span style={{
                display: "inline-block", width: 2, height: 18,
                background: p.accent.solid, marginLeft: 3, marginBottom: -2
              }}/>
            </div>

            {/* Footer: subtle controls */}
            <div style={{
              display: "flex", alignItems: "center", justifyContent: "space-between",
              paddingTop: 12, borderTop: `0.5px solid ${p.card.separator}`
            }}>
              <span style={{ fontSize: 12, color: p.card.sub }}>Tap to insert punctuation</span>
              <div style={{ display: "flex", gap: 8 }}>
                <div style={{
                  width: 32, height: 32, borderRadius: 16,
                  background: "rgba(255,255,255,0.65)",
                  border: `0.5px solid ${p.card.border}`,
                  display: "flex", alignItems: "center", justifyContent: "center"
                }}>
                  <svg width="11" height="11" viewBox="0 0 11 11">
                    <rect x="1.5" y="1" width="3" height="9" rx="1" fill={p.card.fg}/>
                    <rect x="6.5" y="1" width="3" height="9" rx="1" fill={p.card.fg}/>
                  </svg>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div style={{ height: 120 }} />
        <StopButton palette={p} label="Done" />
        <HomeIndicator />
      </div>
    </div>
  );
};

window.RecordLetter = RecordLetter;
window.RecordOrb = RecordOrb;
window.RecordTape = RecordTape;
