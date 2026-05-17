// Setup wizard — 9 required steps + a divider + 2 optional.
// Cream base (warm welcoming surface, distinct from the gray Comfort app).
// Same serif titles, same icon tiles, same coral CTAs.

const CORAL = "#FF6B57";
const CORAL_DEEP = "#E0533F";
const TOTAL_REQUIRED = 9;
const TOTAL_OPTIONAL = 2;

const WizardWallpaper = () => <window.Wallpaper dark={false} />;

const Dots = ({ step, optional = false }) => {
  const dotStyle = (filled) => ({
    width: filled ? 7 : 5, height: filled ? 7 : 5, borderRadius: 4,
    background: filled ? CORAL : "rgba(0,0,0,0.18)",
    transition: "all 200ms", flexShrink: 0
  });
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
      {Array.from({ length: TOTAL_REQUIRED }, (_, i) => (
        <span key={i} style={dotStyle(!optional && i + 1 === step)} />
      ))}
      <span style={{ width: 12, height: 1.5, background: "rgba(0,0,0,0.18)", borderRadius: 1 }} />
      {Array.from({ length: TOTAL_OPTIONAL }, (_, i) => (
        <span key={`o${i}`} style={dotStyle(optional && i + 1 === step)} />
      ))}
    </div>
  );
};

const RoundButton = ({ children }) => (
  <div style={{
    width: 36, height: 36, borderRadius: 18,
    background: "rgba(255,255,255,0.7)",
    backdropFilter: "blur(20px)",
    WebkitBackdropFilter: "blur(20px)",
    border: "0.5px solid rgba(0,0,0,0.05)",
    display: "flex", alignItems: "center", justifyContent: "center",
    color: "#15171C", flexShrink: 0
  }}>{children}</div>
);

const TopBar = ({ step, optional, showBack = true, showClose = true }) => (
  <div style={{
    display: "grid", gridTemplateColumns: "auto 1fr auto",
    alignItems: "center", padding: "10px 18px 8px", gap: 12
  }}>
    {showBack ? (
      <RoundButton>
        <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
          <path d="M9 1.5L3.5 7 9 12.5" stroke="#15171C" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </RoundButton>
    ) : <div style={{ width: 36 }} />}
    <div style={{ display: "flex", justifyContent: "center" }}><Dots step={step} optional={optional}/></div>
    {showClose ? (
      <RoundButton>
        <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
          <path d="M2 2l10 10M12 2L2 12" stroke="#15171C" strokeWidth="2" strokeLinecap="round"/>
        </svg>
      </RoundButton>
    ) : <div style={{ width: 36 }} />}
  </div>
);

// Big gradient icon tile — wizard's hero glyph
const HeroTile = ({ color, children, size = 92, soft }) => (
  <div style={{
    width: size, height: size, borderRadius: size * 0.26,
    background: `linear-gradient(160deg, ${color} 0%, ${shadeHexW(color, -0.20)} 100%)`,
    boxShadow: `0 1px 0 rgba(255,255,255,0.4) inset, 0 12px 32px -10px ${color}80, 0 0 0 0.5px rgba(0,0,0,0.06)`,
    display: "flex", alignItems: "center", justifyContent: "center",
    color: "#fff", margin: "0 auto"
  }}>{children}</div>
);
function shadeHexW(hex, amt) {
  const h = hex.replace("#", "");
  const r = parseInt(h.substr(0,2),16), g = parseInt(h.substr(2,2),16), b = parseInt(h.substr(4,2),16);
  const f = (v) => Math.max(0, Math.min(255, Math.round(v + v * amt)));
  return `#${[f(r),f(g),f(b)].map(v=>v.toString(16).padStart(2,"0")).join("")}`;
}

const PrimaryCTA = ({ children, icon }) => (
  <div style={{
    height: 56, borderRadius: 28, margin: "0 18px",
    background: `linear-gradient(180deg, ${CORAL}, ${CORAL_DEEP})`,
    boxShadow: `0 12px 28px -8px ${CORAL}80, 0 0 0 0.5px rgba(255,255,255,0.2) inset`,
    color: "#fff", fontSize: 16, fontWeight: 600, letterSpacing: -0.2,
    display: "flex", alignItems: "center", justifyContent: "center", gap: 10
  }}>
    {icon}{children}
  </div>
);

const SecondaryLink = ({ children }) => (
  <div style={{
    textAlign: "center", padding: "16px 0 8px",
    fontSize: 14, color: "rgba(60,60,67,0.65)", fontWeight: 500
  }}>{children}</div>
);

const HomeBar = () => (
  <div style={{
    position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
    width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
  }} />
);

// Common page chrome
const WizardFrame = ({ step, optional, showBack, showClose, primary, secondary, primaryIcon, children }) => (
  <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
    <WizardWallpaper />
    <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
      <div style={{ height: 54 }} />
      <TopBar step={step} optional={optional} showBack={showBack} showClose={showClose} />
      <div style={{ flex: 1, overflow: "hidden", padding: "0 22px", display: "flex", flexDirection: "column" }}>
        {children}
      </div>
      <div style={{ padding: "0 0 8px" }}>
        {primary && <PrimaryCTA icon={primaryIcon}>{primary}</PrimaryCTA>}
        {secondary && <SecondaryLink>{secondary}</SecondaryLink>}
      </div>
      <div style={{ height: 22 }} />
      <HomeBar />
    </div>
  </div>
);

// Title + subtitle block
const Hero = ({ icon, title, subtitle, italicHint, big, italic }) => (
  <div style={{ textAlign: "center", paddingTop: italic ? 8 : 12, paddingBottom: 8 }}>
    {icon && <div style={{ marginBottom: 20 }}>{icon}</div>}
    <div style={{
      fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
      fontSize: big ? 56 : 30, fontWeight: big ? 600 : 700, letterSpacing: big ? -2 : -0.6,
      color: "#15171C", lineHeight: 1.05, textWrap: "balance"
    }}>{title}</div>
    {subtitle && (
      <div style={{
        marginTop: 14, fontSize: 15.5, lineHeight: 1.45, letterSpacing: -0.1,
        color: "rgba(60,60,67,0.70)", textWrap: "pretty", maxWidth: 320, margin: "14px auto 0"
      }}>{subtitle}</div>
    )}
    {italicHint && (
      <div style={{
        marginTop: 14, fontSize: 13.5, lineHeight: 1.5,
        fontStyle: "italic", color: "rgba(60,60,67,0.55)",
        textWrap: "pretty", maxWidth: 320, margin: "14px auto 0"
      }}>{italicHint}</div>
    )}
  </div>
);

// ─────────────────────────────────────────────────────────────
// W1 · Welcome
// ─────────────────────────────────────────────────────────────
const W1Welcome = () => (
  <WizardFrame step={1} showBack={false} showClose primary="Get started">
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", textAlign: "center", paddingBottom: 80 }}>
      <div style={{
        fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
        fontSize: 96, fontWeight: 600, letterSpacing: -3.5, lineHeight: 1, color: "#15171C"
      }}>Jot</div>
      <div style={{
        marginTop: 18, fontSize: 17, color: "rgba(60,60,67,0.70)",
        letterSpacing: -0.1, lineHeight: 1.45, textWrap: "pretty"
      }}>Voice transcription,<br/>on your iPhone.</div>
    </div>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W2 · Speech model installed
// ─────────────────────────────────────────────────────────────
const W2Speech = () => (
  <WizardFrame step={2} primary="Continue">
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", paddingBottom: 60 }}>
      <Hero
        icon={
          <HeroTile color="#6F5BFF">
            <svg width="44" height="44" viewBox="0 0 44 44" fill="none">
              <rect x="13" y="13" width="18" height="18" rx="3" transform="rotate(45 22 22)" fill="#fff"/>
            </svg>
          </HeroTile>
        }
        title="Speech model installed"
        subtitle="Parakeet is already on this iPhone — about 1.25 GB."
      />
    </div>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W3 · Jot keyboard detected
// ─────────────────────────────────────────────────────────────
const W3Keyboard = () => (
  <WizardFrame step={3} primary="Continue" secondary="I've already done this">
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", paddingBottom: 40 }}>
      <Hero
        icon={
          <HeroTile color="#F3EEE7">
            <svg width="56" height="40" viewBox="0 0 56 40" fill="none">
              <rect x="4" y="6" width="48" height="28" rx="3.5" fill="#fff" stroke="rgba(0,0,0,0.06)"/>
              {Array.from({length: 9}).map((_,i)=> <circle key={i} cx={9 + i*5} cy={13} r="1.2" fill="#444"/>)}
              {Array.from({length: 9}).map((_,i)=> <circle key={i} cx={9 + i*5} cy={20} r="1.2" fill="#444"/>)}
              <rect x="14" y="26" width="28" height="3" rx="1.5" fill={CORAL}/>
            </svg>
          </HeroTile>
        }
        title="Jot keyboard detected"
        subtitle="In Settings, add Jot as a keyboard, then open Jot and turn on Full Access so dictations can paste into other apps."
        italicHint="We'll detect the keyboard when you're back. Full Access is a manual setting."
      />
    </div>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W4 · How it works
// ─────────────────────────────────────────────────────────────
const TinyKey = ({ children, bg = "#F3EEE7" }) => (
  <div style={{
    width: 44, height: 44, borderRadius: 10,
    background: bg,
    boxShadow: "0 1px 0 rgba(255,255,255,0.5) inset, 0 1px 2px rgba(0,0,0,0.08)",
    display: "flex", alignItems: "center", justifyContent: "center"
  }}>{children}</div>
);

const W4How = () => (
  <WizardFrame step={4} primary="Got it">
    <Hero
      title="How it works"
      subtitle={<>
        Jot is dictation-only — no QWERTY. Keep your usual keyboard for typing.<br/><br/>
        Tapping Dictate opens Jot to record (iOS doesn't allow mic access from keyboards). After recording, swipe right along the bottom to return — text is in the field.
      </>}
    />
    {/* Flow diagram */}
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, marginTop: 24 }}>
      <TinyKey>
        <svg width="22" height="16" viewBox="0 0 22 16" fill="none">
          <rect x="0.5" y="0.5" width="21" height="15" rx="2" fill="#fff" stroke="rgba(0,0,0,0.08)"/>
          {Array.from({length:5}).map((_,i)=><circle key={i} cx={3 + i*4} cy={5} r="0.8" fill="#666"/>)}
          {Array.from({length:5}).map((_,i)=><circle key={i} cx={3 + i*4} cy={8.5} r="0.8" fill="#666"/>)}
          <rect x="5" y="11" width="12" height="2" rx="1" fill="#666"/>
        </svg>
      </TinyKey>
      <span style={{ color: "rgba(60,60,67,0.55)", fontSize: 16 }}>→</span>
      <TinyKey bg={`linear-gradient(180deg, ${CORAL}, ${CORAL_DEEP})`}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <rect x="9" y="3" width="6" height="12" rx="3" fill="#fff"/>
          <path d="M6 11a6 6 0 0012 0M12 17v3" stroke="#fff" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      </TinyKey>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center" }}>
        <svg width="20" height="14" viewBox="0 0 20 14" fill="none">
          <path d="M2 7h15M13 3l4 4-4 4" stroke={CORAL} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
        <span style={{ fontSize: 9, fontWeight: 700, letterSpacing: 1.2, color: CORAL, marginTop: 2 }}>SWIPE</span>
      </div>
      <TinyKey>
        <svg width="22" height="16" viewBox="0 0 22 16" fill="none">
          <rect x="0.5" y="0.5" width="21" height="15" rx="2" fill="#fff" stroke="rgba(0,0,0,0.08)"/>
          {Array.from({length:5}).map((_,i)=><circle key={i} cx={3 + i*4} cy={5} r="0.8" fill="#666"/>)}
          {Array.from({length:5}).map((_,i)=><circle key={i} cx={3 + i*4} cy={8.5} r="0.8" fill="#666"/>)}
          <rect x="5" y="11" width="12" height="2" rx="1" fill="#666"/>
        </svg>
      </TinyKey>
    </div>
    <div style={{
      textAlign: "center", marginTop: 12,
      fontSize: 10.5, fontWeight: 700, letterSpacing: 1.4, color: "rgba(60,60,67,0.55)",
      lineHeight: 1.6
    }}>TAP DICTATE → RECORD IN JOT → SWIPE BACK →<br/>TEXT PASTED</div>
    <div style={{ flex: 1 }}/>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W5 · Try it once — empty
// ─────────────────────────────────────────────────────────────
const W5TryEmpty = () => (
  <WizardFrame step={5} primary="Start dictating" primaryIcon={<svg width="18" height="18" viewBox="0 0 24 24" fill="none"><rect x="9" y="3" width="6" height="12" rx="3" fill="#fff"/><path d="M6 11a6 6 0 0012 0M12 17v3" stroke="#fff" strokeWidth="1.8" strokeLinecap="round"/></svg>}>
    <Hero
      title="Try it once"
      subtitle="Say something. We'll show your words as they appear."
    />
    <div style={{
      margin: "20px 0 0",
      background: "rgba(255,255,255,0.55)",
      backdropFilter: "blur(20px) saturate(180%)",
      WebkitBackdropFilter: "blur(20px) saturate(180%)",
      border: "0.5px solid rgba(0,0,0,0.06)",
      borderRadius: 20,
      padding: "18px 18px",
      fontSize: 15, color: "rgba(60,60,67,0.65)", lineHeight: 1.5, textWrap: "pretty"
    }}>
      Tap the mic below and read this aloud —<br/>
      <span style={{ color: "#15171C" }}>"Testing Jot — looks like it's working."</span>
    </div>
    <div style={{
      marginTop: 14, padding: "0 6px",
      fontSize: 12.5, color: "rgba(60,60,67,0.55)", lineHeight: 1.5, textWrap: "pretty"
    }}>Live preview is fast and rough — no punctuation yet. When you stop, Parakeet makes a more accurate final pass with punctuation and casing.</div>
    <div style={{ flex: 1 }}/>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W6 · Try it once — result
// ─────────────────────────────────────────────────────────────
const W6TryResult = () => (
  <WizardFrame step={5} primary="Sounds good" primaryIcon={<svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M2 7l3.5 3.5L12 4" stroke="#fff" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>} secondary="Try again">
    <Hero
      title="Try it once"
      subtitle="Say something. We'll show your words as they appear."
    />
    <div style={{
      margin: "20px 0 0",
      background: "rgba(255,255,255,0.55)",
      backdropFilter: "blur(20px) saturate(180%)",
      WebkitBackdropFilter: "blur(20px) saturate(180%)",
      border: "0.5px solid rgba(0,0,0,0.06)",
      borderRadius: 20,
      padding: "18px 18px",
      fontSize: 16, color: "#15171C", lineHeight: 1.45, textWrap: "pretty"
    }}>Testing Jot — looks like it's working.</div>
    <div style={{
      marginTop: 14, padding: "0 6px",
      fontSize: 12.5, color: "rgba(60,60,67,0.55)", lineHeight: 1.5, textWrap: "pretty"
    }}>Live preview is fast and rough — no punctuation yet. When you stop, Parakeet makes a more accurate final pass with punctuation and casing.</div>
    <div style={{ flex: 1 }}/>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W7 · Now try the keyboard — iOS keyboard up
// ─────────────────────────────────────────────────────────────
const IOSKey = ({ children, w = 32, h = 38, bg = "#FCFCFD", color = "#15171C", weight = 400 }) => (
  <div style={{
    width: w, height: h, borderRadius: 5, background: bg,
    boxShadow: "0 1px 0 rgba(0,0,0,0.18)",
    display: "flex", alignItems: "center", justifyContent: "center",
    color, fontSize: 16, fontWeight: weight
  }}>{children}</div>
);

const FakeIOSKeyboard = () => (
  <div style={{
    background: "linear-gradient(180deg, #D5D7DE 0%, #C9CCD3 100%)",
    padding: "8px 4px 0",
    borderTop: "0.5px solid rgba(0,0,0,0.05)"
  }}>
    {/* Suggestion strip */}
    <div style={{ display: "flex", justifyContent: "space-around", padding: "4px 0 8px", fontSize: 14, color: "#15171C" }}>
      <span>I</span><span style={{ color: "rgba(0,0,0,0.4)" }}>|</span>
      <span>The</span><span style={{ color: "rgba(0,0,0,0.4)" }}>|</span>
      <span>I'm</span>
    </div>
    {[
      ["Q","W","E","R","T","Y","U","I","O","P"],
      ["A","S","D","F","G","H","J","K","L"],
    ].map((row, ri) => (
      <div key={ri} style={{ display: "flex", justifyContent: "center", gap: 3, marginBottom: 6, padding: ri === 1 ? "0 18px" : 0 }}>
        {row.map(k => <IOSKey key={k} w={31}>{k}</IOSKey>)}
      </div>
    ))}
    <div style={{ display: "flex", justifyContent: "center", gap: 3, marginBottom: 6, padding: "0 4px" }}>
      <IOSKey w={42} bg="#A9ADB6" color="#fff">
        <svg width="14" height="11" viewBox="0 0 14 11" fill="none"><path d="M7 1l5 5H10v3H4V6H2l5-5z" fill="#fff"/></svg>
      </IOSKey>
      {["Z","X","C","V","B","N","M"].map(k => <IOSKey key={k} w={31}>{k}</IOSKey>)}
      <IOSKey w={42} bg="#A9ADB6" color="#fff">
        <svg width="14" height="11" viewBox="0 0 14 11" fill="none"><rect x="0.5" y="2.5" width="9.5" height="6" rx="1" fill="none" stroke="#fff"/><path d="M3.5 5.5l2 0M6 4l1.5 1.5L6 7" stroke="#fff" strokeWidth="1.2" strokeLinecap="round"/></svg>
      </IOSKey>
    </div>
    <div style={{ display: "flex", justifyContent: "center", gap: 3, padding: "0 4px" }}>
      <IOSKey w={40} bg="#A9ADB6" color="#fff">123</IOSKey>
      <IOSKey w={120} bg="#FCFCFD" weight={400}>
        <span style={{ fontSize: 13 }}>space</span>
      </IOSKey>
      <IOSKey w={60} bg="#A9ADB6" color="#fff"><span style={{ fontSize: 13 }}>↵</span></IOSKey>
    </div>
    <div style={{ display: "flex", justifyContent: "space-between", padding: "6px 14px 8px", color: "#15171C" }}>
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <circle cx="10" cy="10" r="7.5" stroke="#15171C" strokeWidth="1.4" fill="none"/>
        <path d="M2.5 10h15M10 2.5c2 2.4 3 5 3 7.5s-1 5.1-3 7.5c-2-2.4-3-5-3-7.5s1-5.1 3-7.5z" stroke="#15171C" strokeWidth="1.4" fill="none"/>
      </svg>
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
        <rect x="9" y="3" width="6" height="12" rx="3" fill="none" stroke="#15171C" strokeWidth="1.6"/>
        <path d="M6 11a6 6 0 0012 0M12 17v3" stroke="#15171C" strokeWidth="1.6" strokeLinecap="round"/>
      </svg>
    </div>
  </div>
);

const W7KbIOS = () => (
  <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
    <WizardWallpaper />
    <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
      <div style={{ height: 54 }} />
      <TopBar step={6} />
      <div style={{ padding: "0 22px", display: "flex", flexDirection: "column", gap: 18 }}>
        <Hero
          title="Now try the keyboard"
          subtitle="Tap the field below, switch to Jot via the globe key, then tap Dictate."
        />
        <div style={{
          background: "rgba(255,255,255,0.55)",
          backdropFilter: "blur(20px) saturate(180%)",
          WebkitBackdropFilter: "blur(20px) saturate(180%)",
          border: `1px solid ${CORAL}`,
          borderRadius: 14,
          padding: "14px 16px",
          fontSize: 14, color: "rgba(60,60,67,0.45)", letterSpacing: -0.1,
          boxShadow: `0 0 0 4px rgba(255,107,87,0.10)`
        }}>Tap here, then switch to the Jot keyboard…</div>
        <div style={{ textAlign: "center", fontSize: 12.5, color: "rgba(60,60,67,0.55)", fontStyle: "italic" }}>Listening for your text…</div>
        <PrimaryCTA>I tried it</PrimaryCTA>
      </div>
      <div style={{ flex: 1 }}/>
      <FakeIOSKeyboard/>
      <HomeBar/>
    </div>
  </div>
);

// ─────────────────────────────────────────────────────────────
// W8 · Now try the keyboard — Jot keyboard active (idle)
// ─────────────────────────────────────────────────────────────
const W8KbJot = () => (
  <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
    <WizardWallpaper />
    <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
      <div style={{ height: 54 }} />
      <TopBar step={6} />
      <div style={{ padding: "0 22px", display: "flex", flexDirection: "column", gap: 16 }}>
        <Hero
          title="Now try the keyboard"
          subtitle="Tap the field below, switch to Jot via the globe key, then tap Dictate."
        />
        <div style={{
          background: "rgba(255,255,255,0.55)",
          border: `1px solid ${CORAL}`,
          borderRadius: 14,
          padding: "14px 16px",
          fontSize: 14, color: "rgba(60,60,67,0.45)", letterSpacing: -0.1,
          boxShadow: `0 0 0 4px rgba(255,107,87,0.10)`
        }}>Tap here, then switch to the Jot keyboard…</div>
        <div style={{ textAlign: "center", fontSize: 12.5, color: "rgba(60,60,67,0.55)", fontStyle: "italic" }}>Listening for your text…</div>
        <PrimaryCTA>I tried it</PrimaryCTA>
      </div>
      <div style={{ flex: 1 }}/>
      <window.KeyboardRef dark={false} state="idle" />
      <HomeBar/>
    </div>
  </div>
);

// ─────────────────────────────────────────────────────────────
// W9 · Now try the keyboard — filled with "Can you hear me?"
// ─────────────────────────────────────────────────────────────
const W9KbFilled = () => (
  <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
    <WizardWallpaper />
    <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%" }}>
      <div style={{ height: 54 }} />
      <TopBar step={7} />
      <div style={{ padding: "0 22px", display: "flex", flexDirection: "column", gap: 16 }}>
        <Hero
          title="Now try the keyboard"
          subtitle="Tap the field below, switch to Jot via the globe key, then tap Dictate."
        />
        <div style={{
          background: "rgba(255,255,255,0.55)",
          border: `1px solid ${CORAL}`,
          borderRadius: 14,
          padding: "14px 16px",
          fontSize: 16, color: "#15171C", letterSpacing: -0.1, fontWeight: 500,
          boxShadow: `0 0 0 4px rgba(255,107,87,0.10)`
        }}>Can you hear me?<span style={{ display: "inline-block", width: 1.5, height: 17, background: CORAL, marginLeft: 2, marginBottom: -2, verticalAlign: "text-bottom", animation: "blink 1s steps(2) infinite" }}/></div>
        <div style={{ textAlign: "center", fontSize: 12.5, color: "rgba(60,60,67,0.55)", fontStyle: "italic" }}>Listening for your text…</div>
        <PrimaryCTA>I tried it</PrimaryCTA>
      </div>
      <div style={{ flex: 1 }}/>
      <window.KeyboardRef dark={false} state="idle" />
      <HomeBar/>
    </div>
  </div>
);

// ─────────────────────────────────────────────────────────────
// W10 · Keep mic ready?
// ─────────────────────────────────────────────────────────────
const MicChoice = ({ label, selected }) => (
  <div style={{
    margin: "0 0 8px",
    padding: "16px 18px",
    borderRadius: 16,
    background: selected ? "rgba(255,107,87,0.10)" : "rgba(255,255,255,0.6)",
    border: selected ? `1px solid ${CORAL}` : "0.5px solid rgba(0,0,0,0.06)",
    boxShadow: selected ? `0 0 0 4px rgba(255,107,87,0.08)` : "none",
    display: "flex", alignItems: "center", justifyContent: "space-between",
    fontSize: 15.5, fontWeight: 500, color: "#15171C", letterSpacing: -0.2
  }}>
    {label}
    {selected && (
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <circle cx="10" cy="10" r="9" fill={CORAL}/>
        <path d="M5.5 10.2l3 3 6-6.2" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    )}
  </div>
);

const W10Mic = () => (
  <WizardFrame step={8}>
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center" }}>
      <Hero
        icon={
          <HeroTile color={CORAL} size={76}>
            <svg width="34" height="34" viewBox="0 0 24 24" fill="none">
              <rect x="9" y="3" width="6" height="12" rx="3" fill="#fff"/>
              <path d="M6 11a6 6 0 0012 0M12 17v3" stroke="#fff" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </HeroTile>
        }
        title="Keep mic ready?"
        subtitle="After a dictation, Jot can keep a 60-second audio session active so the next recording starts faster. The orange mic indicator stays on during that wait, but Jot is not transcribing while it waits. You can change this anytime in Settings."
      />
    </div>
    <div style={{ padding: "0 0 8px" }}>
      <MicChoice label="Keep mic ready" selected />
      <MicChoice label="No thanks" />
    </div>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W11 · You're ready
// ─────────────────────────────────────────────────────────────
const W11Ready = () => (
  <WizardFrame step={9} primary="Set up now" secondary="Maybe later">
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", paddingBottom: 30 }}>
      <Hero
        icon={
          <HeroTile color="#34C759" size={76}>
            <svg width="36" height="36" viewBox="0 0 36 36" fill="none">
              <path d="M9 18.5l5.5 5.5L27 11.5" stroke="#fff" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </HeroTile>
        }
        title="You're ready."
        subtitle="Jot works now. You can start dictating any time."
        italicHint="Two optional steps make it noticeably better — teaching Jot words you use, and adding AI rewrite. Vocabulary takes a minute. AI is a 2.4 GB download."
      />
    </div>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W12 · Teach Jot some words (optional)
// ─────────────────────────────────────────────────────────────
const W12Vocab = () => (
  <WizardFrame step={1} optional primary="Done" secondary="Skip">
    <Hero
      icon={
        <HeroTile color="#1FCED1" size={76}>
          <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinejoin="round">
            <path d="M4 5a2 2 0 012-2h12v16H6a2 2 0 00-2 2V5z"/>
            <path d="M8 7h7M8 11h7"/>
          </svg>
        </HeroTile>
      }
      title="Teach Jot some words"
      subtitle="Names or unusual terms Jot might mishear."
    />
    <div style={{ marginTop: 22, display: "flex", flexDirection: "column", gap: 4 }}>
      {["Parakeet", "Phi-4"].map((w, i) => (
        <div key={i} style={{
          padding: "12px 4px",
          borderBottom: "0.5px solid rgba(60,60,67,0.12)",
          display: "flex", alignItems: "center", justifyContent: "space-between"
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <span style={{ width: 4, height: 4, borderRadius: 2, background: "rgba(60,60,67,0.35)" }}/>
            <span style={{ fontSize: 16, color: "#15171C" }}>{w}</span>
          </div>
          <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
            <circle cx="9" cy="9" r="8.5" fill="rgba(60,60,67,0.10)"/>
            <path d="M6 6l6 6M12 6l-6 6" stroke="rgba(60,60,67,0.55)" strokeWidth="1.4" strokeLinecap="round"/>
          </svg>
        </div>
      ))}
    </div>
    <div style={{
      marginTop: 14, padding: "12px 14px",
      background: "rgba(60,60,67,0.06)",
      borderRadius: 12,
      display: "flex", alignItems: "center", justifyContent: "space-between"
    }}>
      <span style={{ fontSize: 15, color: "rgba(60,60,67,0.45)", letterSpacing: -0.1 }}>Liquid Glass</span>
      <div style={{
        width: 30, height: 30, borderRadius: 15,
        background: `linear-gradient(180deg, ${CORAL}, ${CORAL_DEEP})`,
        display: "flex", alignItems: "center", justifyContent: "center",
        boxShadow: `0 4px 10px -2px ${CORAL}66`
      }}>
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 2v10M2 7h10" stroke="#fff" strokeWidth="2" strokeLinecap="round"/></svg>
      </div>
    </div>
    <div style={{
      marginTop: 18, textAlign: "center", fontSize: 12.5, fontStyle: "italic",
      color: "rgba(60,60,67,0.55)", lineHeight: 1.5
    }}>You can edit these any time in Settings → Vocabulary.</div>
    <div style={{ flex: 1 }}/>
  </WizardFrame>
);

// ─────────────────────────────────────────────────────────────
// W13 · Add AI rewrite (optional)
// ─────────────────────────────────────────────────────────────
const W13AI = () => (
  <WizardFrame step={2} optional primary={<>Download <span style={{ opacity: 0.85, fontWeight: 500, marginLeft: 4 }}>· 2.4 GB</span></>} secondary="Skip">
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", paddingBottom: 60 }}>
      <Hero
        icon={
          <HeroTile color={CORAL} size={92}>
            <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
              <path d="M24 6l3.5 9 9 3.5-9 3.5-3.5 9-3.5-9-9-3.5 9-3.5 3.5-9z" fill="#fff"/>
              <circle cx="36" cy="36" r="3" fill="#fff"/>
              <circle cx="14" cy="34" r="2" fill="#fff" opacity="0.9"/>
            </svg>
          </HeroTile>
        }
        title={<>Add AI rewrite <span style={{
          fontFamily: "-apple-system, sans-serif", fontStyle: "normal",
          fontSize: 10, fontWeight: 700, letterSpacing: 1.2, verticalAlign: "middle",
          padding: "3px 7px", borderRadius: 6, marginLeft: 6, position: "relative", top: -6,
          background: "rgba(255,107,87,0.14)", color: CORAL_DEEP, textTransform: "uppercase"
        }}>Experimental</span></>}
        subtitle="Polish dictations and convert prose to bullets. Phi-4 mini runs on your iPhone — about 2.4 GB."
      />
    </div>
  </WizardFrame>
);

Object.assign(window, {
  W1Welcome, W2Speech, W3Keyboard, W4How,
  W5TryEmpty, W6TryResult,
  W7KbIOS, W8KbJot, W9KbFilled,
  W10Mic, W11Ready, W12Vocab, W13AI
});
