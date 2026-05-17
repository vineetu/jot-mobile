// Settings screen — in the Comfort + Alive language.
// Preserves: big italic serif title, multi-color semantic section icons,
// inset rounded cards, descriptive captions below each section.
// Adds:      gray Comfort background with wallpaper hint, Liquid Glass cards,
//           coral as the action color alongside blue.

const SETTINGS_COLORS = {
  blue:   "#1A8CFF",  // speech model
  cyan:   "#1FCED1",  // vocabulary
  coral:  "#FF6B57",  // AI / brand action
  green:  "#34C759",  // on-device, ready
  purple: "#7C5CFF",  // full access / privacy policy
  orange: "#FF9A33",  // mic / warnings
  pink:   "#FF4F6B",  // acknowledgements
  red:    "#FF3B30",  // destructive
  slate:  "#8B8E96",  // version / debug
};

// Square rounded icon tile — gradient fill, soft inner highlight
const IconTile = ({ color, size = 30, children }) => (
  <div style={{
    width: size, height: size, borderRadius: size * 0.28,
    background: `linear-gradient(180deg, ${color} 0%, ${shade(color, -0.18)} 100%)`,
    boxShadow: `0 1px 0 rgba(255,255,255,0.35) inset, 0 1px 2px rgba(0,0,0,0.10), 0 0 0 0.5px rgba(0,0,0,0.06)`,
    display: "flex", alignItems: "center", justifyContent: "center",
    color: "#fff", flexShrink: 0
  }}>{children}</div>
);

function shade(hex, amt) {
  const h = hex.replace("#", "");
  const r = parseInt(h.substr(0,2),16), g = parseInt(h.substr(2,2),16), b = parseInt(h.substr(4,2),16);
  const f = (v) => Math.max(0, Math.min(255, Math.round(v + v * amt)));
  return `#${[f(r),f(g),f(b)].map(v=>v.toString(16).padStart(2,"0")).join("")}`;
}

// SF-Symbol-ish glyphs
const G = {
  waveform: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M4 12v0M8 8v8M12 5v14M16 9v6M20 11v2"/>
    </svg>
  ),
  book: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 5a2 2 0 012-2h12v16H6a2 2 0 00-2 2V5z"/>
      <path d="M8 7h7M8 11h7"/>
    </svg>
  ),
  wand: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M14 6l4 4-10 10H4v-4L14 6z"/>
      <path d="M17 3v3M21 5h-3M19 9v2"/>
    </svg>
  ),
  phone: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round">
      <rect x="7" y="3" width="10" height="18" rx="2"/>
      <line x1="11" y1="18" x2="13" y2="18" strokeLinecap="round"/>
    </svg>
  ),
  shield: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round">
      <path d="M12 3l8 3v6c0 5-3.5 8.5-8 9-4.5-.5-8-4-8-9V6l8-3z"/>
      <path d="M9 12l2 2 4-4" strokeLinecap="round"/>
    </svg>
  ),
  mic: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="9" y="3" width="6" height="12" rx="3"/>
      <path d="M6 11a6 6 0 0012 0M12 17v3"/>
    </svg>
  ),
  help: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <circle cx="12" cy="12" r="9"/>
      <path d="M9.5 9a2.5 2.5 0 015 0c0 1.5-2 2-2.5 3.5M12 17h.01"/>
    </svg>
  ),
  refresh: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 12a9 9 0 0115-6.7L21 8M21 3v5h-5M21 12a9 9 0 01-15 6.7L3 16M3 21v-5h5"/>
    </svg>
  ),
  mail: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round">
      <rect x="3" y="5" width="18" height="14" rx="2"/>
      <path d="M4 6l8 7 8-7"/>
    </svg>
  ),
  info: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <circle cx="12" cy="12" r="9"/>
      <path d="M12 8h.01M12 11v6"/>
    </svg>
  ),
  hand: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9 11V5a1.5 1.5 0 013 0v5"/>
      <path d="M12 10V4a1.5 1.5 0 013 0v6"/>
      <path d="M15 10V6a1.5 1.5 0 013 0v9a6 6 0 01-6 6h-1c-2 0-3.5-1-4.5-3l-3-5a1.5 1.5 0 012.5-1.5L9 14V8a1.5 1.5 0 013 0"/>
    </svg>
  ),
  heart: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 21s-7-4.5-9.5-9.2C.8 7.7 3.3 4 7 4c2 0 3.5 1 5 2.5C13.5 5 15 4 17 4c3.7 0 6.2 3.7 4.5 7.8C19 16.5 12 21 12 21z"/>
    </svg>
  ),
  palette: (s=16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round">
      <path d="M12 3a9 9 0 100 18c1 0 1.5-.7 1.5-1.5S13 18 13 17c0-1 .8-1.5 1.7-1.5H17a4 4 0 004-4 8.5 8.5 0 00-9-8.5z"/>
      <circle cx="8" cy="11" r="1.2" fill="currentColor"/>
      <circle cx="12" cy="8" r="1.2" fill="currentColor"/>
      <circle cx="16" cy="11" r="1.2" fill="currentColor"/>
    </svg>
  ),
  chevron: (s=12, c="rgba(60,60,67,0.40)") => (
    <svg width={s} height={s*1.4} viewBox="0 0 8 12" fill="none">
      <path d="M2 1l5 5-5 5" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  arrowOut: (s=14, c="rgba(60,60,67,0.40)") => (
    <svg width={s} height={s} viewBox="0 0 14 14" fill="none">
      <path d="M5 3h6v6M11 3L5 9" stroke={c} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
};

// Status pill — Ready / Enabled / Always (green) or coral for warnings
const StatusPill = ({ kind = "ready", label }) => {
  const colors = {
    ready:    { bg: "rgba(52,199,89,0.12)", fg: "#1A9F40", dot: "#34C759" },
    warn:     { bg: "rgba(255,154,51,0.14)", fg: "#C5651A", dot: "#FF9A33" },
    coral:    { bg: "rgba(255,107,87,0.14)", fg: "#C24531", dot: "#FF6B57" },
    inactive: { bg: "rgba(60,60,67,0.10)",  fg: "rgba(60,60,67,0.65)", dot: "rgba(60,60,67,0.45)" },
  }[kind] || { bg: "rgba(52,199,89,0.12)", fg: "#1A9F40", dot: "#34C759" };
  return (
    <div style={{
      display: "inline-flex", alignItems: "center", gap: 6,
      padding: "5px 10px 5px 8px", borderRadius: 999,
      background: colors.bg, color: colors.fg,
      fontSize: 12, fontWeight: 600, letterSpacing: -0.1
    }}>
      <span style={{ width: 6, height: 6, borderRadius: 3, background: colors.dot }}/>
      {label}
    </div>
  );
};

const IOSToggle = ({ on = true, tint = "#34C759" }) => (
  <div style={{
    width: 51, height: 31, borderRadius: 16,
    background: on ? tint : "rgba(120,120,128,0.32)",
    position: "relative", flexShrink: 0,
    boxShadow: "0 0 0 0.5px rgba(0,0,0,0.04) inset"
  }}>
    <div style={{
      position: "absolute", top: 2, left: on ? 22 : 2,
      width: 27, height: 27, borderRadius: 14, background: "#fff",
      boxShadow: "0 3px 8px rgba(0,0,0,0.15), 0 3px 1px rgba(0,0,0,0.06)",
      transition: "left 200ms"
    }}/>
  </div>
);

// One row in a card
const SettingsRow = ({ iconColor, icon, title, sub, trailing, isLast, multiline = false, descriptionLong }) => (
  <div style={{
    display: "grid",
    gridTemplateColumns: "auto 1fr auto",
    columnGap: 14, alignItems: multiline ? "flex-start" : "center",
    padding: "13px 16px",
    borderBottom: isLast ? "none" : "0.5px solid rgba(60,60,67,0.10)"
  }}>
    {icon ? <IconTile color={iconColor} size={30}>{icon}</IconTile> : <div style={{ width: 0 }}/>}
    <div style={{ minWidth: 0, paddingTop: multiline ? 1 : 0 }}>
      <div style={{ fontSize: 15, color: "#15171C", fontWeight: 500, letterSpacing: -0.2 }}>{title}</div>
      {sub && <div style={{ fontSize: 12.5, color: "rgba(60,60,67,0.65)", marginTop: 2, letterSpacing: -0.05 }}>{sub}</div>}
      {descriptionLong && <div style={{ fontSize: 12.5, color: "rgba(60,60,67,0.65)", marginTop: 4, lineHeight: 1.4, letterSpacing: -0.05, textWrap: "pretty" }}>{descriptionLong}</div>}
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>{trailing}</div>
  </div>
);

// Section: caps label + card + caption
const Section = ({ label, caption, children }) => (
  <div style={{ padding: "0 14px 8px" }}>
    {label && (
      <div style={{
        fontSize: 11, fontWeight: 700, letterSpacing: 1.5,
        color: "rgba(60,60,67,0.55)", textTransform: "uppercase",
        padding: "16px 8px 8px"
      }}>{label}</div>
    )}
    <div style={{
      background: "rgba(255,255,255,0.62)",
      backdropFilter: "blur(28px) saturate(200%)",
      WebkitBackdropFilter: "blur(28px) saturate(200%)",
      border: "0.5px solid rgba(0,0,0,0.05)",
      borderRadius: 18,
      overflow: "hidden",
      boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 14px 36px -28px rgba(15,17,28,0.30)"
    }}>{children}</div>
    {caption && (
      <div style={{
        fontSize: 12.5, color: "rgba(60,60,67,0.55)",
        padding: "8px 8px 0", letterSpacing: -0.05, lineHeight: 1.4,
        textWrap: "pretty"
      }}>{caption}</div>
    )}
  </div>
);

const SettingsScreen = ({ showDonation = false }) => {
  const Wallpaper = window.Wallpaper;
  const JotMark = window.JotMark;
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
      <Wallpaper dark={false} />
      <div style={{ position: "relative", zIndex: 1, display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" }}>
        <div style={{ height: 54 }} />

        {/* Top bar */}
        <div style={{
          padding: "8px 18px 6px",
          display: "flex", alignItems: "center", justifyContent: "space-between"
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <JotMark color="#15171C" size={20} />
            <span style={{ fontSize: 15, fontWeight: 600, color: "rgba(60,60,67,0.85)", letterSpacing: -0.1 }}>Jot</span>
          </div>
          <div style={{
            padding: "7px 16px", borderRadius: 999,
            background: "rgba(255,255,255,0.7)",
            backdropFilter: "blur(20px)",
            WebkitBackdropFilter: "blur(20px)",
            border: "0.5px solid rgba(0,0,0,0.06)",
            fontSize: 13, fontWeight: 600, color: "#15171C"
          }}>Done</div>
        </div>

        {/* Title */}
        <div style={{ padding: "14px 22px 18px" }}>
          <div style={{
            fontSize: 44, fontWeight: 400, letterSpacing: -1.6, color: "#15171C",
            fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
            lineHeight: 1.0, fontStyle: "italic"
          }}>Settings.</div>
        </div>

        <div style={{ flex: 1, overflow: "hidden", paddingBottom: 16 }}>
          {/* SPEECH MODEL */}
          <Section
            label="Speech model"
            caption="Runs entirely on this iPhone. Audio never leaves the device."
          >
            <SettingsRow
              iconColor={SETTINGS_COLORS.blue}
              icon={G.waveform(16)}
              title="Parakeet TDT"
              sub="On your iPhone · about 700 MB"
              trailing={<StatusPill kind="ready" label="Ready"/>}
            />
            <SettingsRow
              title="Variant"
              trailing={<>
                <span style={{ fontSize: 13.5, color: "rgba(60,60,67,0.65)" }}>Parakeet 600M</span>
                {G.chevron()}
              </>}
              isLast
            />
          </Section>

          {/* VOCABULARY */}
          <Section
            label="Vocabulary"
            caption="Bias the speech model toward names, technical terms, and words Jot tends to mishear."
          >
            <SettingsRow
              iconColor={SETTINGS_COLORS.cyan}
              icon={G.book(16)}
              title="Custom terms"
              sub="2 terms · on this iPhone"
              trailing={G.chevron()}
              isLast
            />
          </Section>

          {/* AI */}
          <Section
            label="AI"
            caption="Titles and tags use the system's built-in AI automatically."
          >
            <SettingsRow
              iconColor={SETTINGS_COLORS.coral}
              icon={G.wand(16)}
              title="Rewrite & prompts"
              sub="Phi-4 mini · Unloaded"
              trailing={G.chevron()}
              isLast
            />
          </Section>

          {/* PRIVACY */}
          <Section
            label="Privacy"
            caption="Your words stay on your iPhone. No accounts, no cloud, no telemetry."
          >
            <SettingsRow
              iconColor={SETTINGS_COLORS.green}
              icon={G.phone(16)}
              title="On-device only"
              sub="Always"
              trailing={<StatusPill kind="ready" label="Always"/>}
            />
            <SettingsRow
              iconColor={SETTINGS_COLORS.purple}
              icon={G.shield(16)}
              title="Full Access"
              sub="Required for paste"
              trailing={<StatusPill kind="ready" label="Enabled"/>}
            />
            <SettingsRow
              iconColor={SETTINGS_COLORS.orange}
              icon={G.mic(16)}
              title="Keep mic ready"
              descriptionLong="Skips cold-start latency for repeat dictations within 60 seconds. While ready, the iOS orange mic indicator stays on — the audio session is active but Jot is not transcribing."
              trailing={<IOSToggle on={true} tint="#34C759"/>}
              multiline
              isLast
            />
          </Section>

          {/* Optional stats moment — quiet two-line summary above the About card */}
          {showDonation && (
            <div style={{ padding: "4px 0 0" }}>
              <div style={{
                fontSize: 11, fontWeight: 700, letterSpacing: 1.5,
                color: "rgba(60,60,67,0.55)", textTransform: "uppercase",
                padding: "16px 22px 8px"
              }}>About</div>
              <div style={{ padding: "0 22px 12px" }}>
                <div style={{
                  fontSize: 17, fontWeight: 500, color: "#15171C", letterSpacing: -0.3,
                  fontFamily: '"New York", "Iowan Old Style", Georgia, serif'
                }}>12 dictations</div>
                <div style={{
                  fontSize: 13, color: "rgba(60,60,67,0.65)", marginTop: 2, letterSpacing: -0.05
                }}>About 5h 22m saved over typing.</div>
              </div>
            </div>
          )}

          {/* ABOUT */}
          <Section label={showDonation ? "" : "About"}>
            <SettingsRow iconColor={SETTINGS_COLORS.cyan}   icon={G.help(16)}    title="Help & Support"     trailing={G.chevron()} />
            <SettingsRow iconColor={SETTINGS_COLORS.blue}   icon={G.refresh(16)} title="Re-run setup wizard" trailing={G.chevron()} />
            <SettingsRow iconColor={SETTINGS_COLORS.purple} icon={G.mail(16)}    title="Send feedback"      trailing={G.arrowOut()} />
            <SettingsRow iconColor={SETTINGS_COLORS.slate}  icon={G.info(16)}    title="Version"            trailing={<span style={{ fontSize: 13.5, color: "rgba(60,60,67,0.65)" }}>0.8 (1)</span>} />
            {showDonation && (
              <SettingsRow iconColor="#34C759" icon={window.donationIcon} title="Donations" trailing={G.arrowOut()} />
            )}
            <SettingsRow iconColor={SETTINGS_COLORS.purple} icon={G.hand(16)}    title="Privacy Policy"     trailing={G.arrowOut()} />
            <SettingsRow iconColor={SETTINGS_COLORS.pink}   icon={G.heart(16)}   title="Acknowledgements"   trailing={G.chevron()} />
            <SettingsRow iconColor={SETTINGS_COLORS.orange} icon={G.palette(16)} title="Design catalog"     sub="Debug" trailing={G.chevron()} isLast />
          </Section>

          {/* Footer */}
          <div style={{
            padding: "20px 22px 12px",
            fontSize: 12, color: "rgba(60,60,67,0.45)", textAlign: "center",
            letterSpacing: -0.05, lineHeight: 1.5
          }}>
            Made with care in San Francisco.<br/>
            No accounts, no cloud, no telemetry.
          </div>
        </div>

        {/* Home indicator */}
        <div style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.4)"
        }} />
      </div>
    </div>
  );
};

window.SettingsScreen = SettingsScreen;
window.IconTile = IconTile;
window.SettingsRow = SettingsRow;
window.Section = Section;
window.StatusPill = StatusPill;
window.IOSToggle = IOSToggle;
window.G = G;
window.SETTINGS_COLORS = SETTINGS_COLORS;
