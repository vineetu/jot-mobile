// Three color directions for the Jot main app, side-by-side.
// The keyboard chrome below each phone is LOCKED per Reference v3 — what varies is the app.

const PALETTES = {
  coolGray: {
    name: "A · Cool Gray (current)",
    dark: false,
    page: {
      bg: "#F2F3F6",
      gradient: "linear-gradient(180deg, #F4F5F8 0%, #ECEEF2 100%)",
      fg: "#0F1115",
      fgMuted: "rgba(60,60,67,0.6)",
      sectionLabel: "rgba(60,60,67,0.55)",
    },
    nav: {
      bg: "rgba(242,243,246,0.85)",
      fg: "#0F1115",
      sub: "rgba(60,60,67,0.85)",
      pill: "rgba(255,255,255,0.9)",
      brand: "#0F1115",
    },
    card: {
      bg: "#FFFFFF",
      blur: false,
      border: "rgba(0,0,0,0.06)",
      shadow: "0 1px 0 rgba(0,0,0,0.02), 0 18px 40px -24px rgba(15,17,21,0.18)",
      fg: "#0F1115",
      sub: "rgba(60,60,67,0.55)",
      separator: "rgba(60,60,67,0.10)",
    },
    chip: {
      bg: "rgba(255,255,255,0.7)",
      fg: "rgba(60,60,67,0.85)",
      activeBg: "#0F1115",
      activeFg: "#FFFFFF",
    },
    accent: {
      solid: "#007AFF",
      gradient: "linear-gradient(180deg, #1A8CFF 0%, #0064CC 100%)",
      fg: "#FFFFFF",
      soft: "rgba(0,122,255,0.10)",
      shadow: "rgba(0,80,200,0.30)",
    },
    tab: {
      bg: "rgba(242,243,246,0.85)",
      fg: "rgba(60,60,67,0.55)",
      active: "#0F1115",
    },
  },

  jotBlue: {
    name: "B · Jot Blue (continuation)",
    dark: false,
    page: {
      bg: "#ECF1FA",
      gradient: "linear-gradient(180deg, #F0F4FB 0%, #E4ECF8 100%)",
      fg: "#162447",
      fgMuted: "rgba(60,80,140,0.65)",
      sectionLabel: "#6F84B4",
    },
    nav: {
      bg: "rgba(236,241,250,0.85)",
      fg: "#162447",
      sub: "#3C5A99",
      pill: "rgba(255,255,255,0.75)",
      brand: "#1F47AB",
    },
    card: {
      bg: "rgba(255,255,255,0.62)",
      blur: true,
      border: "rgba(31,71,171,0.10)",
      shadow: "0 1px 0 rgba(255,255,255,0.6) inset, 0 18px 40px -22px rgba(31,71,171,0.20)",
      fg: "#1B2945",
      sub: "#6F84B4",
      separator: "rgba(31,71,171,0.08)",
    },
    chip: {
      bg: "rgba(255,255,255,0.55)",
      fg: "#3C5A99",
      activeBg: "#1F47AB",
      activeFg: "#FFFFFF",
    },
    accent: {
      solid: "#1F6FEB",
      gradient: "linear-gradient(180deg, #1A8CFF 0%, #0050C8 100%)",
      fg: "#FFFFFF",
      soft: "rgba(31,111,235,0.14)",
      shadow: "rgba(15,55,160,0.40)",
    },
    tab: {
      bg: "rgba(236,241,250,0.85)",
      fg: "rgba(31,71,171,0.55)",
      active: "#1F47AB",
    },
  },

  // The synthesis: cool gray base (matches locked keyboard chrome) + blue as the ONLY
  // accent. No competing app colors. Soft contrast, generous whitespace.
  comfort: {
    name: "C · Comfort (recommended synthesis)",
    dark: false,
    page: {
      // Match the keyboard chrome exactly so app and keyboard read as one surface
      bg: "#D1D3DA",
      gradient: "linear-gradient(180deg, #DCDEE3 0%, #D1D3DA 60%, #C9CCD3 100%)",
      fg: "#15171C",
      fgMuted: "rgba(60,60,67,0.55)",
      sectionLabel: "rgba(60,60,67,0.5)",
    },
    nav: {
      bg: "transparent",
      fg: "#15171C",
      sub: "rgba(60,60,67,0.75)",
      pill: "rgba(255,255,255,0.55)",
      brand: "#15171C",
    },
    card: {
      // Liquid Glass over the gray — same recipe as the keyboard's Recents card
      bg: "rgba(255,255,255,0.62)",
      blur: true,
      border: "rgba(0,0,0,0.05)",
      shadow: "0 1px 0 rgba(255,255,255,0.6) inset, 0 22px 50px -28px rgba(15,17,28,0.25)",
      fg: "#15171C",
      sub: "rgba(60,60,67,0.55)",
      separator: "rgba(60,60,67,0.10)",
    },
    chip: {
      bg: "rgba(255,255,255,0.45)",
      fg: "rgba(60,60,67,0.85)",
      activeBg: "#15171C",
      activeFg: "#FFFFFF",
    },
    accent: {
      // The keyboard's exact Dictate blue — the one and only accent
      solid: "#007AFF",
      gradient: "linear-gradient(180deg, #1A8CFF 0%, #0064CC 100%)",
      fg: "#FFFFFF",
      soft: "rgba(0,122,255,0.12)",
      shadow: "rgba(0,80,200,0.35)",
    },
    tab: {
      bg: "rgba(209,211,218,0.85)",
      fg: "rgba(60,60,67,0.45)",
      active: "#007AFF",
    },
  },
};

const STATUS_FG = {
  coolGray: "#000",
  jotBlue: "#162447",
  comfort: "#000",
};

// Variant of VariantCard that takes a donationCard prop and renders only the app (not the keyboard-up phone)
const DonationCard = ({ paletteKey }) => {
  const p = PALETTES[paletteKey];
  const PHONE_W = 390;
  const PHONE_H = 844;
  return (
    <div style={{
      width: PHONE_W + 40, padding: 20,
      display: "flex", flexDirection: "column", alignItems: "center", gap: 16
    }}>
      <window.PhoneFrame width={PHONE_W} height={PHONE_H} dark={p.dark} statusFg={STATUS_FG[paletteKey]} time="10:32">
        <window.RecentsScreenAlive palette={p} donationCard={<window.DonationHomeCard/>} />
      </window.PhoneFrame>
    </div>
  );
};

// Settings with donation stats + Donations row
const SettingsWithDonationCard = () => (
  <div style={{ width: 430, padding: 20, display: "flex", justifyContent: "center" }}>
    <window.PhoneFrame width={390} height={844} dark={false} statusFg="#000" time="10:32">
      <window.SettingsScreen showDonation />
    </window.PhoneFrame>
  </div>
);

// One artboard: phone with Recents app + locked keyboard reference rendered below
const VariantCard = ({ paletteKey, alive = false }) => {
  const p = PALETTES[paletteKey];
  const PHONE_W = 390;
  const APP_H = 720;       // Recents area (no keyboard)
  const KBD_H = 300;       // keyboard reference area
  const Screen = alive ? window.RecentsScreenAlive : window.RecentsScreen;
  // We render two stacked phone "screens" to visualize:
  //  top: app inside phone frame
  //  bottom: keyboard sliding up inside same phone frame width
  return (
    <div style={{
      width: PHONE_W + 40, padding: 20,
      background: "transparent",
      display: "flex", flexDirection: "column", alignItems: "center", gap: 16
    }}>
      {/* App phone */}
      <window.PhoneFrame width={PHONE_W} height={APP_H} dark={p.dark} statusFg={STATUS_FG[paletteKey]} time="10:32">
        <Screen palette={p} />
      </window.PhoneFrame>

      {/* Caption */}
      <div style={{
        fontSize: 12, color: "rgba(255,255,255,0.55)", letterSpacing: 0.3,
        textTransform: "uppercase", fontWeight: 600
      }}>↓ app meets the locked iOS-gray keyboard ↓</div>

      {/* Keyboard-up phone — shows compose surface above the keyboard */}
      <window.PhoneFrame width={PHONE_W} height={KBD_H + 110} dark={p.dark} statusFg={STATUS_FG[paletteKey]} time="10:32">
        <div style={{
          position: "absolute", inset: 0,
          background: p.page.gradient || p.page.bg,
          display: "flex", flexDirection: "column"
        }}>
          {/* status bar pad */}
          <div style={{ height: 54 }} />
          {/* Mini "compose" header to give context */}
          <div style={{ padding: "8px 18px 12px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <div style={{ fontSize: 13, color: p.page.fgMuted }}>To: Maya Lin</div>
            <div style={{
              padding: "4px 10px", borderRadius: 999, background: p.chip.bg, color: p.chip.fg,
              fontSize: 11, fontWeight: 600, border: `0.5px solid ${p.card.border}`
            }}>iMessage</div>
          </div>
          <div style={{ flex: 1, padding: "0 18px" }}>
            <div style={{
              alignSelf: "flex-end", marginLeft: "auto", maxWidth: "78%",
              background: p.accent.gradient, color: p.accent.fg,
              padding: "8px 12px", borderRadius: 18, borderBottomRightRadius: 6,
              fontSize: 14, marginBottom: 6, marginLeft: "auto",
              boxShadow: `0 1px 0 rgba(255,255,255,0.18) inset`
            }}>Much better. The wizard read and vocab help is good.</div>
          </div>
          {/* Locked keyboard */}
          <div style={{ marginTop: "auto" }}>
            <window.KeyboardRef dark={p.dark} state="idle" />
          </div>
        </div>
      </window.PhoneFrame>
    </div>
  );
};

// Single-screen variant card (no keyboard reference below) for the recording exploration.
const SingleCard = ({ paletteKey, Screen }) => {
  const p = PALETTES[paletteKey];
  const PHONE_W = 390;
  const PHONE_H = 844;
  return (
    <div style={{
      width: PHONE_W + 40, padding: 20,
      display: "flex", flexDirection: "column", alignItems: "center"
    }}>
      <window.PhoneFrame width={PHONE_W} height={PHONE_H} dark={p.dark} statusFg={STATUS_FG[paletteKey]} time="10:32">
        <Screen palette={p} />
      </window.PhoneFrame>
    </div>
  );
};

// ─────────────────────────────────────────────────────────────
// Canvas
// ─────────────────────────────────────────────────────────────
function App() {
  return (
    <window.DesignCanvas
      title="Jot · App design"
      subtitle="Finalized: Recents (D) + In-app recording (R1). Keyboard is locked per Reference v3."
    >
      <window.DCSection
        id="recents"
        title="Recents + keyboard harmony"
        subtitle="Top phone: Recents. Bottom phone: app meeting the locked iOS-gray keyboard."
      >
        <window.DCArtboard id="alive" label="Recents" width={430} height={1130}>
          <VariantCard paletteKey="comfort" alive />
        </window.DCArtboard>
        <window.DCArtboard id="alive-live" label="Recents · live dictation" width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={(props) => (
            <window.RecentsScreenAlive {...props} recording="0:14" />
          )} />
        </window.DCArtboard>
      </window.DCSection>

      <window.DCSection
        id="recording"
        title="In-app recording"
        subtitle="After tapping Dictate inside the app."
      >
        <window.DCArtboard id="letter" label="Recording" width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={window.RecordLetter} />
        </window.DCArtboard>
      </window.DCSection>

      <window.DCSection
        id="settings"
        title="Settings"
        subtitle="The existing structure, lifted into the Comfort + Alive language."
      >
        <window.DCArtboard id="settings-main" label="Settings" width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={window.SettingsScreen} />
        </window.DCArtboard>
      </window.DCSection>

      <window.DCSection
        id="donation"
        title="Donations & stats"
        subtitle="Home card (one-shot, dismissible) + quiet stats moment in Settings → About + permanent Donations link."
      >
        <window.DCArtboard id="donation-home" label="Recents · donation card visible" width={450} height={920}>
          <DonationCard paletteKey="comfort"/>
        </window.DCArtboard>
        <window.DCArtboard id="donation-settings" label="Settings · stats + Donations row" width={450} height={920}>
          <SettingsWithDonationCard/>
        </window.DCArtboard>
      </window.DCSection>

      <window.DCSection
        id="logo"
        title="App icon"
        subtitle="Lowercase ȷ on a black Liquid Glass tile. Coral dot = j's dot and live mic light."
      >
        <window.DCArtboard id="logo-refined" label="App icon" width={420} height={520}>
          <window.LogoRefined/>
        </window.DCArtboard>
      </window.DCSection>

      <window.DCSection
        id="wizard"
        title="Setup wizard"
        subtitle="9 required steps + 2 optional. Cream stays — onboarding is the warm welcoming surface."
      >
        <window.DCArtboard id="w1"  label="W1 · Welcome"               width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W1Welcome}/></window.DCArtboard>
        <window.DCArtboard id="w2"  label="W2 · Speech model"          width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W2Speech}/></window.DCArtboard>
        <window.DCArtboard id="w3"  label="W3 · Keyboard detected"     width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W3Keyboard}/></window.DCArtboard>
        <window.DCArtboard id="w4"  label="W4 · How it works"          width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W4How}/></window.DCArtboard>
        <window.DCArtboard id="w5"  label="W5 · Try it once · empty"   width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W5TryEmpty}/></window.DCArtboard>
        <window.DCArtboard id="w6"  label="W6 · Try it once · result"  width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W6TryResult}/></window.DCArtboard>
        <window.DCArtboard id="w8"  label="W7 · Try keyboard · Jot"    width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W8KbJot}/></window.DCArtboard>
        <window.DCArtboard id="w9"  label="W8 · Try keyboard · filled" width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W9KbFilled}/></window.DCArtboard>
        <window.DCArtboard id="w10" label="W10 · Keep mic ready?"      width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W10Mic}/></window.DCArtboard>
        <window.DCArtboard id="w11" label="W11 · You're ready"         width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W11Ready}/></window.DCArtboard>
        <window.DCArtboard id="w12" label="W12 · Vocabulary (opt)"     width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W12Vocab}/></window.DCArtboard>
        <window.DCArtboard id="w13" label="W13 · AI rewrite (opt)"     width={430} height={920}><SingleCard paletteKey="comfort" Screen={window.W13AI}/></window.DCArtboard>
      </window.DCSection>

      <window.DCSection
        id="ai"
        title="AI"
        subtitle="Prompts are the protagonist; model status is one thin strip."
      >
        <window.DCArtboard id="ai-main"   label="AI · Your prompts"        width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={window.AISettingsScreen} />
        </window.DCArtboard>
        <window.DCArtboard id="ai-new"    label="New prompt"               width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={window.NewPromptScreen} />
        </window.DCArtboard>
        <window.DCArtboard id="ai-prompt" label="Edit prompt"               width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={window.RewritePromptScreen} />
        </window.DCArtboard>
        <window.DCArtboard id="ai-result" label="Edit prompt · Try result"  width={430} height={920}>
          <SingleCard paletteKey="comfort" Screen={window.RewritePromptResultScreen} />
        </window.DCArtboard>
      </window.DCSection>
    </window.DesignCanvas>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
