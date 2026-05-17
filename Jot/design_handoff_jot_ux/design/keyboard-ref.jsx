// Locked keyboard reference per Reference v3 spec.
// Chrome = iOS system gray, light/dark aware. The app palette varies; the keyboard does NOT.

const KEY_GLYPH_LIGHT = "rgba(0,0,0,0.85)";
const KEY_GLYPH_DARK  = "rgba(255,255,255,0.92)";

const KeyboardRef = ({ dark = false, state = "idle" }) => {
  // Chrome gradient per spec
  const chrome = dark
    ? "linear-gradient(180deg, #25252A 0%, #1F1F22 50%, #1A1A1D 100%)"
    : "linear-gradient(180deg, #D5D7DE 0%, #D1D3DA 50%, #C9CCD3 100%)";
  const recordTint = dark ? "rgba(10,132,255,0.10)" : "rgba(0,122,255,0.06)";
  const cardBg = dark ? "rgba(28,28,32,0.55)" : "rgba(255,255,255,0.62)";
  const cardBorder = dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.05)";
  const txt = dark ? "rgba(255,255,255,0.92)" : "#0F1115";
  const linkTxt = dark ? "#9CB3E5" : "#3C5A99";
  const sub = dark ? "rgba(255,255,255,0.45)" : "rgba(60,60,67,0.55)";
  const keyBg = dark ? "rgba(110,114,126,0.42)" : "#fff";
  const keyShadow = dark ? "0 1px 0 rgba(0,0,0,0.35)" : "0 1px 0 rgba(0,0,0,0.18)";
  const returnTint = dark ? "rgba(105,110,124,0.7)" : "rgba(170,190,220,0.55)";

  return (
    <div style={{
      position: "relative",
      background: chrome,
      paddingTop: 6, paddingBottom: 0,
      borderTop: dark ? "0.5px solid rgba(0,0,0,0.4)" : "0.5px solid rgba(0,0,0,0.05)",
    }}>
      {state === "recording" && (
        <div style={{ position: "absolute", inset: 0, background: recordTint, pointerEvents: "none" }} />
      )}

      {/* Target field strip */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        padding: "4px 14px 6px", fontSize: 11, color: sub, fontWeight: 500
      }}>
        <span style={{ letterSpacing: 0.2 }}>Text Message · SMS</span>
        <span>🎙</span>
      </div>

      {/* Liquid Glass card — Recents */}
      <div style={{
        margin: "0 10px",
        background: cardBg,
        backdropFilter: "blur(24px) saturate(180%)",
        WebkitBackdropFilter: "blur(24px) saturate(180%)",
        border: `0.5px solid ${cardBorder}`,
        borderRadius: 14,
        padding: "10px 12px"
      }}>
        <div style={{
          display: "flex", justifyContent: "space-between", alignItems: "center",
          marginBottom: 6
        }}>
          <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 1.4, color: sub }}>RECENT</span>
          <span style={{ fontSize: 11, color: linkTxt, fontWeight: 500 }}>See all</span>
        </div>
        {[
          { t: "7:45 PM", s: "Hi." },
          { t: "7:45 PM", s: "Much better. The wizard read and vocab…" },
          { t: "7:41 PM", s: "Yo, can you hear me?" },
        ].map((r, i, arr) => (
          <div key={i} style={{
            display: "flex", gap: 8, padding: "5px 0",
            borderBottom: i < arr.length - 1 ? `0.5px solid ${cardBorder}` : "none",
            fontSize: 12.5, color: linkTxt, letterSpacing: -0.1
          }}>
            <span style={{ color: sub, fontFeatureSettings: '"tnum"', flexShrink: 0 }}>{r.t}</span>
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r.s}</span>
          </div>
        ))}
      </div>

      {/* Actions row */}
      <div style={{
        display: "flex", justifyContent: "space-between", alignItems: "center",
        padding: "10px 14px 6px"
      }}>
        <span style={{ fontSize: 12, fontWeight: 600, color: sub, letterSpacing: 0.2 }}>Actions</span>
        <div style={{
          display: "flex", alignItems: "center", gap: 6, padding: "6px 14px",
          borderRadius: 999,
          background: "linear-gradient(180deg, #1A8CFF 0%, #0064CC 100%)",
          color: "#fff", fontSize: 13, fontWeight: 600,
          boxShadow: "0 2px 6px rgba(0,80,200,0.25)"
        }}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="3" width="6" height="12" rx="3" fill="#fff"/>
            <path d="M6 11a6 6 0 0012 0" stroke="#fff" strokeWidth="2" strokeLinecap="round"/>
          </svg>
          Dictate
        </div>
      </div>

      {/* Punctuation row */}
      <div style={{
        display: "flex", gap: 4, padding: "6px 6px 4px"
      }}>
        {["@", ".", ",", "?", "!", "'"].map(g => (
          <div key={g} style={{
            flex: 1, height: 36, borderRadius: 5, background: keyBg,
            boxShadow: keyShadow,
            display: "flex", alignItems: "center", justifyContent: "center",
            color: dark ? KEY_GLYPH_DARK : KEY_GLYPH_LIGHT,
            fontSize: 15, fontWeight: 400
          }}>{g}</div>
        ))}
      </div>

      {/* Space + Return row */}
      <div style={{ display: "flex", gap: 4, padding: "0 6px 6px" }}>
        <div style={{
          flex: 3, height: 36, borderRadius: 5, background: keyBg, boxShadow: keyShadow,
          display: "flex", alignItems: "center", justifyContent: "center",
          color: dark ? KEY_GLYPH_DARK : KEY_GLYPH_LIGHT, fontSize: 13
        }}>space</div>
        <div style={{
          flex: 1, height: 36, borderRadius: 5, background: returnTint,
          display: "flex", alignItems: "center", justifyContent: "center",
          color: dark ? KEY_GLYPH_DARK : "#0F1115", fontSize: 13, fontWeight: 500
        }}>Return</div>
      </div>

      {/* iOS system bottom strip — same gray, seamless */}
      <div style={{ height: 18 }} />
    </div>
  );
};

window.KeyboardRef = KeyboardRef;
