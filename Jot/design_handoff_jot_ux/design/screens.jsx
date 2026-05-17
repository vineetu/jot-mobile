// Recents screen, palette-driven so we can A/B color directions.
// Palette shape:
// {
//   name, dark,
//   page: {bg, gradient?, fg, fgMuted, fgFaint, sectionLabel},
//   nav: {bg, fg, sub, pill},
//   card: {bg, border, shadow, fg, sub, separator},
//   chip: {bg, fg, activeBg, activeFg},
//   accent: {solid, gradient, fg, soft},
//   tab: {bg, fg, active, indicator}
// }

const Avatar = ({ initials, bg, fg, ring }) => (
  <div style={{
    width: 36, height: 36, borderRadius: 18,
    background: bg, color: fg,
    display: "flex", alignItems: "center", justifyContent: "center",
    fontSize: 13, fontWeight: 600, letterSpacing: -0.2,
    boxShadow: ring ? `0 0 0 1px ${ring}` : "none",
    flexShrink: 0
  }}>{initials}</div>
);

// Tiny logo for nav/header
const JotMark = ({ color = "#007AFF", size = 22 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
    <path d="M14.5 3.5h3.2c.55 0 1 .45 1 1v11.4c0 2.9-2.35 5.25-5.25 5.25-2.55 0-4.7-1.83-5.15-4.25-.09-.49.31-.9.81-.9h1.65c.42 0 .76.3.86.71.27 1.1 1.26 1.93 2.43 1.93 1.38 0 2.5-1.12 2.5-2.5V4.5c0-.55.45-1 1-1z" fill={color}/>
    <circle cx="6.4" cy="5.6" r="1.6" fill={color}/>
  </svg>
);

const MicIcon = ({ size = 22, color = "#fff" }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
    <rect x="9" y="3" width="6" height="12" rx="3" fill={color}/>
    <path d="M6 11a6 6 0 0012 0M12 17v3M9 20.5h6" stroke={color} strokeWidth="1.8" strokeLinecap="round"/>
  </svg>
);

// Inferred from textDocumentProxy.keyboardType / returnKeyType / context.
// We never claim the host app's name — Apple won't tell us. We just label the kind of field.
const FieldKind = ({ kind, color }) => (
  <span style={{
    fontSize: 11, color, letterSpacing: 0.2, fontWeight: 500,
    display: "inline-flex", alignItems: "center", gap: 4
  }}>
    <svg width="9" height="9" viewBox="0 0 9 9" fill="none">
      <path d="M1.5 4.5L4 7l3.5-5.5" stroke={color} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
    {kind}
  </span>
);

// Sample recents data
// We don't know which app the user dictated into — iOS keyboard extensions can't read
// the host bundle ID. But we DO get textDocumentProxy hints, so we infer the kind of field.
const RECENTS = [
  { time: "7:45 PM", kind: "message",   snippet: "Hi.", dur: "2s" },
  { time: "7:45 PM", kind: "message",   snippet: "Much better. The wizard read and vocab help is good, but the streaming card needs a little more padding.", dur: "11s" },
  { time: "7:41 PM", kind: "message",   snippet: "Yo, can you hear me? Testing the new mic gating on the keyboard.", dur: "4s" },
  { time: "6:12 PM", kind: "long-form", snippet: "Three things today: shipped the chrome change, talked to Priya about onboarding, drafted the AI sheet copy.", dur: "18s" },
  { time: "5:48 PM", kind: "message",   snippet: "Pushed the new gray. Take a look when you can — should match system keyboard exactly now.", dur: "9s" },
  { time: "3:30 PM", kind: "email",     snippet: "Thanks for the notes. Will revise the vocab screen tonight and send a v2.", dur: "7s" },
];

const RecentRow = ({ item, palette, isLast }) => {
  const p = palette;
  return (
    <div style={{
      padding: "16px 18px",
      borderBottom: isLast ? "none" : `0.5px solid ${p.card.separator}`,
    }}>
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        marginBottom: 6
      }}>
        <FieldKind kind={item.kind} color={p.card.sub} />
        <span style={{ fontSize: 11, color: p.card.sub, fontFeatureSettings: '"tnum"', letterSpacing: 0.1 }}>
          {item.time} · {item.dur}
        </span>
      </div>
      <div style={{
        fontSize: 15, color: p.card.fg, lineHeight: 1.4, letterSpacing: -0.1,
        display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden",
        textWrap: "pretty"
      }}>{item.snippet}</div>
    </div>
  );
};

const RecentsScreen = ({ palette }) => {
  const p = palette;
  return (
    <div style={{
      position: "absolute", inset: 0,
      background: p.page.gradient || p.page.bg,
      color: p.page.fg,
      display: "flex", flexDirection: "column",
      overflow: "hidden"
    }}>
      {/* Status bar pad */}
      <div style={{ height: 54 }} />

      {/* Nav / header */}
      <div style={{
        padding: "8px 18px 6px",
        display: "flex", alignItems: "center", justifyContent: "space-between"
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <JotMark color={p.nav.brand || p.accent.solid} size={20} />
          <span style={{ fontSize: 15, fontWeight: 600, color: p.nav.sub, letterSpacing: -0.1 }}>Jot</span>
        </div>
        <div style={{ display: "flex", gap: 10 }}>
          <div style={{
            width: 32, height: 32, borderRadius: 16, background: p.nav.pill,
            display: "flex", alignItems: "center", justifyContent: "center",
            border: `0.5px solid ${p.card.border}`
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <circle cx="11" cy="11" r="7" stroke={p.nav.fg} strokeWidth="2"/>
              <path d="M20 20l-3.5-3.5" stroke={p.nav.fg} strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </div>
          <Avatar initials="JS" bg={p.accent.soft} fg={p.accent.solid} ring={p.card.border} />
        </div>
      </div>

      {/* Big title */}
      <div style={{ padding: "10px 18px 14px" }}>
        <div style={{
          fontSize: 34, fontWeight: 700, letterSpacing: -1.2, color: p.nav.fg,
          fontFamily: '"SF Pro Display", -apple-system, sans-serif', lineHeight: 1.05
        }}>Recents</div>
        <div style={{ fontSize: 13.5, color: p.page.fgMuted, marginTop: 4, letterSpacing: -0.1 }}>
          47 dictations · 12 minutes saved today
        </div>
      </div>

      {/* Section label */}
      <div style={{
        padding: "8px 22px 6px",
        fontSize: 10.5, fontWeight: 700, letterSpacing: 1.4,
        color: p.page.sectionLabel, textTransform: "uppercase"
      }}>Today</div>

      {/* List card */}
      <div style={{ padding: "0 14px", flex: 1, overflow: "hidden" }}>
        <div style={{
          background: p.card.bg,
          backdropFilter: p.card.blur ? "blur(20px) saturate(180%)" : "none",
          WebkitBackdropFilter: p.card.blur ? "blur(20px) saturate(180%)" : "none",
          borderRadius: 18,
          border: `0.5px solid ${p.card.border}`,
          boxShadow: p.card.shadow,
          overflow: "hidden"
        }}>
          {RECENTS.map((it, i) => (
            <RecentRow key={i} item={it} palette={p} isLast={i === RECENTS.length - 1} />
          ))}
        </div>
      </div>

      {/* Floating dictate pill */}
      <div style={{
        position: "absolute", left: "50%", bottom: 96, transform: "translateX(-50%)",
        height: 56, padding: "0 22px 0 18px", borderRadius: 28,
        background: p.accent.gradient,
        boxShadow: `0 8px 24px -6px ${p.accent.shadow}, 0 0 0 0.5px rgba(255,255,255,0.25) inset`,
        color: p.accent.fg,
        display: "flex", alignItems: "center", gap: 10,
        fontSize: 16, fontWeight: 600, letterSpacing: -0.2
      }}>
        <MicIcon size={20} color={p.accent.fg} />
        <span>Dictate</span>
      </div>

      {/* Tab bar */}
      <div style={{
        height: 84, padding: "10px 20px 28px",
        display: "flex", justifyContent: "space-around", alignItems: "flex-start",
        background: p.tab.bg,
        backdropFilter: "blur(20px) saturate(180%)",
        WebkitBackdropFilter: "blur(20px) saturate(180%)",
        borderTop: `0.5px solid ${p.card.border}`
      }}>
        {[
          { label: "Recents", active: true, icon: (c) => (
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" stroke={c} strokeWidth="2"/><path d="M12 7v5l3 2" stroke={c} strokeWidth="2" strokeLinecap="round"/></svg>
          )},
          { label: "Vocab", icon: (c) => (
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M4 6h16M4 12h16M4 18h10" stroke={c} strokeWidth="2" strokeLinecap="round"/></svg>
          )},
          { label: "AI", icon: (c) => (
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2 2-5z" stroke={c} strokeWidth="1.8" strokeLinejoin="round"/></svg>
          )},
          { label: "Settings", icon: (c) => (
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3" stroke={c} strokeWidth="2"/><path d="M19 12a7 7 0 00-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 00-2-1.2L14 3h-4l-.6 2.6a7 7 0 00-2 1.2L5.1 5.9 3.1 9.3l2 1.5A7 7 0 005 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 002 1.2L10 21h4l.6-2.6a7 7 0 002-1.2l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z" stroke={c} strokeWidth="1.6"/></svg>
          )},
        ].map((t, i) => (
          <div key={i} style={{
            display: "flex", flexDirection: "column", alignItems: "center", gap: 3,
            color: t.active ? p.tab.active : p.tab.fg
          }}>
            {t.icon(t.active ? p.tab.active : p.tab.fg)}
            <span style={{ fontSize: 10, fontWeight: 600, letterSpacing: -0.1 }}>{t.label}</span>
          </div>
        ))}
      </div>

      {/* Home indicator */}
      <div style={{
        position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
        width: 134, height: 5, borderRadius: 3,
        background: p.dark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.4)"
      }} />
    </div>
  );
};

// ─────────────────────────────────────────────────────────────
// Variant D · "Comfort, alive" — adds personality without adding color:
//   • soft wallpaper visible behind real Liquid Glass
//   • editorial display type for the title
//   • a hero "today" stat card
//   • waveforms in each row (the voice as the visual)
//   • one featured entry rendered larger
// ─────────────────────────────────────────────────────────────

const Waveform = ({ bars, color, height = 18, width = 80, played = 1 }) => {
  // bars: array of 0..1 amplitudes
  const bw = width / (bars.length * 1.5);
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      {bars.map((amp, i) => {
        const h = Math.max(2, amp * height);
        const x = i * (bw * 1.5);
        const y = (height - h) / 2;
        const isPlayed = i / bars.length <= played;
        return (
          <rect key={i} x={x} y={y} width={bw} height={h} rx={bw/2}
            fill={color} fillOpacity={isPlayed ? 0.85 : 0.30} />
        );
      })}
    </svg>
  );
};

// Deterministic pseudo-waveform from a seed
const wave = (seed, n = 28) => {
  let s = seed;
  const out = [];
  for (let i = 0; i < n; i++) {
    s = (s * 9301 + 49297) % 233280;
    const r = s / 233280;
    // envelope: louder in the middle
    const env = 1 - Math.abs((i / n) - 0.5) * 1.3;
    out.push(Math.max(0.12, r * Math.max(0.2, env)));
  }
  return out;
};

const ALIVE_RECENTS = [
  { time: "7:45 PM", kind: "message",   dur: "0:11", text: "Much better. The wizard read and vocab help is good, but the streaming card needs a little more padding.", seed: 17, featured: true },
  { time: "7:41 PM", kind: "message",   dur: "0:04", text: "Yo, can you hear me? Testing the new mic gating on the keyboard.", seed: 43 },
  { time: "6:12 PM", kind: "long-form", dur: "0:18", text: "Three things today: shipped the chrome change, talked to Priya about onboarding, drafted the AI sheet copy.", seed: 71 },
  { time: "5:48 PM", kind: "message",   dur: "0:09", text: "Pushed the new gray. Take a look when you can — should match system keyboard exactly now.", seed: 109 },
  { time: "3:30 PM", kind: "email",     dur: "0:07", text: "Thanks for the notes. Will revise the vocab screen tonight and send a v2.", seed: 137 },
];

const AliveRow = ({ item, palette, isLast }) => {
  const p = palette;
  return (
    <div style={{
      padding: "14px 18px",
      borderBottom: isLast ? "none" : `0.5px solid ${p.card.separator}`,
    }}>
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        marginBottom: 4
      }}>
        <FieldKind kind={item.kind} color={p.card.sub} />
        <span style={{ fontSize: 11, color: p.card.sub, fontFeatureSettings: '"tnum"', fontWeight: 500 }}>
          {item.time} · {item.dur}
        </span>
      </div>
      <div style={{
        fontSize: 14, color: p.card.fg, lineHeight: 1.42, letterSpacing: -0.1,
        display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden",
        textWrap: "pretty"
      }}>{item.text}</div>
    </div>
  );
};

const FeaturedEntry = ({ item, palette, live = false, liveText = "" }) => {
  const p = palette;
  if (live) {
    return (
      <div style={{
        padding: "18px 20px 18px",
        borderBottom: `0.5px solid ${p.card.separator}`,
        background: `linear-gradient(180deg, ${p.accent.soft} 0%, ${p.accent.soft} 100%)`,
        boxShadow: `0 0 0 0.5px ${p.accent.solid}33 inset`
      }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <span style={{
              display: "inline-flex", alignItems: "center", gap: 6,
              fontSize: 9.5, fontWeight: 700, letterSpacing: 1.5, color: p.accent.solid,
              textTransform: "uppercase"
            }}>
              <span style={{
                width: 6, height: 6, borderRadius: 3,
                background: p.accent.solid,
                boxShadow: `0 0 0 3px ${p.accent.solid}33`,
                animation: "blink 1.2s ease-in-out infinite"
              }}/>
              Recording
            </span>
            <FieldKind kind={item.kind} color={p.card.sub} />
          </div>
          <span style={{ fontSize: 11, color: p.accent.solid, fontFeatureSettings: '"tnum"', fontWeight: 600 }}>
            {item.dur} · streaming
          </span>
        </div>
        <div style={{
          fontSize: 17, color: p.card.fg, lineHeight: 1.4, letterSpacing: -0.2,
          fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
          textWrap: "pretty"
        }}>
          “{liveText || item.text}
          <span style={{
            display: "inline-block", width: 2, height: 17,
            background: p.accent.solid, verticalAlign: "text-bottom",
            marginLeft: 2, marginBottom: -2,
            animation: "blink 1s steps(2) infinite"
          }}/>
        </div>
      </div>
    );
  }
  return (
    <div style={{
      padding: "18px 20px 18px",
      borderBottom: `0.5px solid ${p.card.separator}`,
      background: `linear-gradient(180deg, ${p.accent.soft} 0%, transparent 100%)`
    }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span style={{
            fontSize: 9.5, fontWeight: 700, letterSpacing: 1.5, color: p.accent.solid,
            textTransform: "uppercase"
          }}>Latest</span>
          <FieldKind kind={item.kind} color={p.card.sub} />
        </div>
        <span style={{ fontSize: 11, color: p.card.sub, fontFeatureSettings: '"tnum"', fontWeight: 500 }}>
          {item.time} · {item.dur}
        </span>
      </div>
      <div style={{
        fontSize: 17, color: p.card.fg, lineHeight: 1.38, letterSpacing: -0.2,
        fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
        textWrap: "pretty"
      }}>“{item.text}”</div>
    </div>
  );
};

// Soft abstract wallpaper rendered behind the glass — gives the Liquid Glass
// something to refract. No images, just CSS gradients.
const Wallpaper = ({ dark }) => (
  <div style={{
    position: "absolute", inset: 0, overflow: "hidden", zIndex: 0
  }}>
    <div style={{
      position: "absolute", inset: 0,
      background: dark
        ? "radial-gradient(ellipse 60% 40% at 20% 10%, rgba(31,71,171,0.45), transparent 70%), radial-gradient(ellipse 50% 35% at 90% 80%, rgba(0,122,255,0.30), transparent 70%), #15171C"
        : "radial-gradient(ellipse 55% 40% at 15% 5%, rgba(0,122,255,0.18), transparent 70%), radial-gradient(ellipse 50% 35% at 95% 25%, rgba(255,200,140,0.16), transparent 70%), radial-gradient(ellipse 60% 50% at 50% 100%, rgba(180,200,240,0.30), transparent 70%), linear-gradient(180deg, #DCDEE3 0%, #D1D3DA 100%)"
    }} />
  </div>
);

const RecentsScreenAlive = ({ palette, donationCard = null, recording = null }) => {
  const p = palette;
  return (
    <div style={{
      position: "absolute", inset: 0,
      color: p.page.fg,
      display: "flex", flexDirection: "column",
      overflow: "hidden"
    }}>
      <Wallpaper dark={p.dark} />

      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
        {/* Status bar pad */}
        <div style={{ height: 54 }} />

        {/* Nav */}
        <div style={{
          padding: "8px 18px 6px",
          display: "flex", alignItems: "center", justifyContent: "space-between"
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <JotMark color={p.nav.brand || p.accent.solid} size={20} />
            <span style={{ fontSize: 15, fontWeight: 600, color: p.nav.sub, letterSpacing: -0.1 }}>Jot</span>
          </div>
          <div style={{ display: "flex", gap: 10 }}>
            <div style={{
              width: 32, height: 32, borderRadius: 16,
              background: "rgba(255,255,255,0.45)",
              backdropFilter: "blur(20px) saturate(180%)",
              WebkitBackdropFilter: "blur(20px) saturate(180%)",
              display: "flex", alignItems: "center", justifyContent: "center",
              border: `0.5px solid ${p.card.border}`
            }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <circle cx="11" cy="11" r="7" stroke={p.nav.fg} strokeWidth="2"/>
                <path d="M20 20l-3.5-3.5" stroke={p.nav.fg} strokeWidth="2" strokeLinecap="round"/>
              </svg>
            </div>
            <Avatar initials="JS" bg={p.accent.soft} fg={p.accent.solid} ring={p.card.border} />
          </div>
        </div>

        {/* Editorial title */}
        <div style={{ padding: "14px 22px 18px" }}>
          <div style={{
            fontSize: 44, fontWeight: 400, letterSpacing: -1.6, color: p.nav.fg,
            fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
            lineHeight: 1.0, fontStyle: "italic"
          }}>Recents.</div>
          <div style={{ fontSize: 13, color: p.page.fgMuted, marginTop: 8, letterSpacing: -0.05 }}>
            Thursday, May 15
          </div>
        </div>

        {/* Hero stat card */}
        <div style={{ padding: "0 14px 14px" }}>
          <div style={{
            background: "rgba(255,255,255,0.55)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: `0.5px solid ${p.card.border}`,
            borderRadius: 20,
            padding: "16px 18px",
            display: "flex", alignItems: "center", justifyContent: "space-between",
            boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 18px 40px -28px rgba(15,17,28,0.30)"
          }}>
            <div>
              <div style={{
                fontSize: 36, fontWeight: 600, letterSpacing: -1.4, color: p.nav.fg,
                lineHeight: 1, fontFeatureSettings: '"tnum"'
              }}>12<span style={{ fontSize: 18, fontWeight: 500, color: p.card.sub, letterSpacing: -0.3 }}> min</span></div>
              <div style={{ fontSize: 12, color: p.card.sub, marginTop: 4 }}>saved today · 47 dictations</div>
            </div>
            {/* mini sparkline */}
            <svg width="92" height="36" viewBox="0 0 92 36">
              <defs>
                <linearGradient id="spark-fill" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={p.accent.solid} stopOpacity="0.30"/>
                  <stop offset="100%" stopColor={p.accent.solid} stopOpacity="0"/>
                </linearGradient>
              </defs>
              <path d="M2 28 L14 22 L26 24 L38 14 L50 18 L62 8 L74 12 L88 4 L88 34 L2 34 Z" fill="url(#spark-fill)"/>
              <path d="M2 28 L14 22 L26 24 L38 14 L50 18 L62 8 L74 12 L88 4" stroke={p.accent.solid} strokeWidth="1.8" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
              <circle cx="88" cy="4" r="3" fill={p.accent.solid}/>
            </svg>
          </div>
        </div>

        {/* Optional donation card — sits between hero stat card and list card */}
        {donationCard}

        {/* List card */}
        <div style={{ padding: "0 14px", flex: 1, overflow: "hidden" }}>
          <div style={{
            background: "rgba(255,255,255,0.58)",
            backdropFilter: "blur(28px) saturate(200%)",
            WebkitBackdropFilter: "blur(28px) saturate(200%)",
            border: `0.5px solid ${p.card.border}`,
            borderRadius: 20,
            overflow: "hidden",
            boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 18px 40px -28px rgba(15,17,28,0.30)"
          }}>
            <FeaturedEntry
              item={recording ? { ...ALIVE_RECENTS[0], kind: "message", dur: recording } : ALIVE_RECENTS[0]}
              palette={p}
              live={!!recording}
              liveText="three things today shipped the chrome change talked to priya about onboarding and drafted the"
            />
            {ALIVE_RECENTS.slice(1).map((it, i, arr) => (
              <AliveRow key={i} item={it} palette={p} isLast={i === arr.length - 1} />
            ))}
          </div>
        </div>

        {/* Floating dictate pill — idle OR live-recording state */}
        {recording ? (
          <div style={{
            position: "absolute", left: "50%", bottom: 96, transform: "translateX(-50%)",
            height: 56, padding: "0 22px 0 18px", borderRadius: 28,
            background: p.accent.gradient,
            boxShadow: `0 8px 28px -4px ${p.accent.shadow}, 0 0 0 0.5px rgba(255,255,255,0.25) inset, 0 0 0 6px ${p.accent.solid}22`,
            color: p.accent.fg,
            display: "flex", alignItems: "center", gap: 12,
            fontSize: 15.5, fontWeight: 600, letterSpacing: -0.2
          }}>
            {/* Pulsing dot */}
            <span style={{
              width: 10, height: 10, borderRadius: 5, background: "#fff",
              boxShadow: "0 0 0 4px rgba(255,255,255,0.30)",
              animation: "blink 1.2s ease-in-out infinite"
            }}/>
            <span>Recording</span>
            <span style={{
              width: 1, height: 16, background: "rgba(255,255,255,0.30)"
            }}/>
            <span style={{
              fontFeatureSettings: '"tnum"', fontWeight: 500, opacity: 0.92
            }}>{recording}</span>
            <span style={{
              marginLeft: 4, opacity: 0.85, fontSize: 13
            }}>↗</span>
          </div>
        ) : (
          <div style={{
            position: "absolute", left: "50%", bottom: 96, transform: "translateX(-50%)",
            height: 56, padding: "0 22px 0 18px", borderRadius: 28,
            background: p.accent.gradient,
            boxShadow: `0 8px 28px -4px ${p.accent.shadow}, 0 0 0 0.5px rgba(255,255,255,0.25) inset`,
            color: p.accent.fg,
            display: "flex", alignItems: "center", gap: 10,
            fontSize: 16, fontWeight: 600, letterSpacing: -0.2
          }}>
            <MicIcon size={20} color={p.accent.fg} />
            <span>Dictate</span>
          </div>
        )}

        {/* Tab bar */}
        <div style={{
          height: 84, padding: "10px 20px 28px",
          display: "flex", justifyContent: "space-around", alignItems: "flex-start",
          background: "rgba(255,255,255,0.55)",
          backdropFilter: "blur(28px) saturate(200%)",
          WebkitBackdropFilter: "blur(28px) saturate(200%)",
          borderTop: `0.5px solid ${p.card.border}`
        }}>
          {[
            { label: "Recents", active: true, icon: (c) => (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" stroke={c} strokeWidth="2"/><path d="M12 7v5l3 2" stroke={c} strokeWidth="2" strokeLinecap="round"/></svg>
            )},
            { label: "Vocab", icon: (c) => (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M4 6h16M4 12h16M4 18h10" stroke={c} strokeWidth="2" strokeLinecap="round"/></svg>
            )},
            { label: "AI", icon: (c) => (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2 2-5z" stroke={c} strokeWidth="1.8" strokeLinejoin="round"/></svg>
            )},
            { label: "Settings", icon: (c) => (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3" stroke={c} strokeWidth="2"/><path d="M19 12a7 7 0 00-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 00-2-1.2L14 3h-4l-.6 2.6a7 7 0 00-2 1.2L5.1 5.9 3.1 9.3l2 1.5A7 7 0 005 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 002 1.2L10 21h4l.6-2.6a7 7 0 002-1.2l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z" stroke={c} strokeWidth="1.6"/></svg>
            )},
          ].map((t, i) => (
            <div key={i} style={{
              display: "flex", flexDirection: "column", alignItems: "center", gap: 3,
              color: t.active ? p.tab.active : p.tab.fg
            }}>
              {t.icon(t.active ? p.tab.active : p.tab.fg)}
              <span style={{ fontSize: 10, fontWeight: 600, letterSpacing: -0.1 }}>{t.label}</span>
            </div>
          ))}
        </div>

        {/* Home indicator */}
        <div style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3,
          background: p.dark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.4)"
        }} />
      </div>
    </div>
  );
};

window.RecentsScreen = RecentsScreen;
window.RecentsScreenAlive = RecentsScreenAlive;
window.Wallpaper = Wallpaper;
window.JotMark = JotMark;
window.Avatar = Avatar;
window.MicIcon = MicIcon;
