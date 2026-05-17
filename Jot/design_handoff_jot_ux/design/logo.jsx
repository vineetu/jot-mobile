// App icon — the Jot mark.
// Black tile, serif J, coral "recording indicator" dot.
// Two variants: current (flat) and refined (Liquid Glass dimensionality + exact coral).

const ICON_CORAL = "#FF6B57";
const ICON_CORAL_DEEP = "#E0533F";

const JotIcon = ({ size = 220, glass = false, dotColor = "#FF3B30", showRing = false, lowercase = false, tileBg = "#0A0A0C", lightTile = false }) => {
  const r = size * 0.225;
  const dotSize = lowercase ? size * 0.16 : size * 0.13;
  // Position the coral dot where a lowercase j's natural dot would sit
  const dotTop  = lowercase ? size * 0.16 : size * 0.16;
  // Horizontally: dot center over the j's stem (slightly right of geometric center)
  const dotLeft = lowercase ? size * 0.46 : size * 0.30;
  // Optical centering: lowercase j's visual center is below its line-box center
  // due to the descender; the glyph box also extends left because of the hook.
  // Shift the letterform down-right so the j's stem sits in the tile center.
  const optY = lowercase ? -size * 0.06 : 0;
  const optX = lowercase ?  size * 0.03 : 0;
  const fg = lightTile ? "#15171C" : "#fff";

  return (
    <div style={{
      width: size, height: size, position: "relative",
      borderRadius: r, overflow: "hidden",
      background: tileBg,
      boxShadow: glass
        ? `0 1px 0 ${lightTile ? "rgba(0,0,0,0.04)" : "rgba(255,255,255,0.10)"} inset, 0 0 0 0.5px rgba(0,0,0,${lightTile ? 0.1 : 0.6}), 0 28px 60px -18px rgba(0,0,0,0.45)`
        : `0 0 0 0.5px rgba(0,0,0,0.4), 0 28px 60px -18px rgba(0,0,0,0.45)`
    }}>
      {/* Liquid Glass dimensionality */}
      {glass && (
        <>
          {/* Top-left specular highlight */}
          <div style={{
            position: "absolute", inset: 0,
            background: lightTile
              ? "radial-gradient(ellipse 90% 55% at 28% 8%, rgba(255,255,255,0.45), rgba(255,255,255,0.10) 40%, transparent 64%)"
              : "radial-gradient(ellipse 90% 55% at 28% 8%, rgba(255,255,255,0.22), rgba(255,255,255,0.04) 38%, transparent 62%)"
          }}/>
          {/* Bottom vignette */}
          <div style={{
            position: "absolute", inset: 0,
            background: lightTile
              ? "radial-gradient(ellipse 75% 50% at 70% 105%, rgba(60,70,100,0.22), transparent 60%)"
              : "radial-gradient(ellipse 75% 50% at 70% 105%, rgba(0,0,0,0.55), transparent 60%)"
          }}/>
          {/* Subtle top edge gleam */}
          <div style={{
            position: "absolute", top: 0, left: "8%", right: "8%", height: 1,
            background: lightTile
              ? "linear-gradient(90deg, transparent, rgba(255,255,255,0.7), transparent)"
              : "linear-gradient(90deg, transparent, rgba(255,255,255,0.45), transparent)"
          }}/>
          {/* Inner hairline */}
          <div style={{
            position: "absolute", inset: 1, borderRadius: r - 1,
            boxShadow: lightTile
              ? "0 0 0 0.5px rgba(0,0,0,0.04) inset"
              : "0 0 0 0.5px rgba(255,255,255,0.06) inset"
          }}/>
        </>
      )}

      {/* The letterform */}
      <div style={{
        position: "absolute", inset: 0,
        display: "flex", alignItems: "center", justifyContent: "center",
        fontFamily: '"New York", "Iowan Old Style", "Charter", Georgia, serif',
        fontWeight: lowercase ? 600 : 700,
        fontSize: lowercase ? size * 0.62 : size * 0.78,
        color: fg,
        lineHeight: 1,
        letterSpacing: -size * 0.02,
        textShadow: (glass && !lightTile) ? "0 1px 2px rgba(0,0,0,0.3)" : "none",
        transform: (optY || optX) ? `translate(${optX}px, ${optY}px)` : "none"
      }}>{lowercase ? "ȷ" : "J"}</div>

      {/* Recording dot — microphone is live */}
      <div style={{
        position: "absolute", top: dotTop, left: dotLeft,
        width: dotSize, height: dotSize, borderRadius: "50%",
        background: glass
          ? `radial-gradient(circle at 35% 30%, ${shadeC(dotColor, 0.3)}, ${dotColor} 50%, ${ICON_CORAL_DEEP} 100%)`
          : dotColor,
        boxShadow: showRing
          ? `0 0 0 ${size * 0.018}px ${dotColor}33, 0 ${size * 0.005}px ${size * 0.02}px rgba(0,0,0,0.4)`
          : `0 ${size * 0.004}px ${size * 0.015}px rgba(0,0,0,0.4), 0 1px 0 rgba(255,255,255,0.18) inset`
      }}/>
    </div>
  );
};
function shadeC(hex, amt) {
  const h = hex.replace("#", "");
  const r = parseInt(h.substr(0,2),16), g = parseInt(h.substr(2,2),16), b = parseInt(h.substr(4,2),16);
  const f = (v) => Math.max(0, Math.min(255, Math.round(v + (255 - v) * amt)));
  return `#${[f(r),f(g),f(b)].map(v=>v.toString(16).padStart(2,"0")).join("")}`;
}

// Artboard contents — single logo at hero size + a 3-up scale row
const IconStudy = ({ title, glass, dotColor, caption, showRing, lowercase, tileBg, lightTile }) => (
  <div style={{
    width: 360, padding: 30,
    display: "flex", flexDirection: "column", alignItems: "center", gap: 24
  }}>
    {/* Hero size */}
    <JotIcon size={220} glass={glass} dotColor={dotColor} showRing={showRing} lowercase={lowercase} tileBg={tileBg} lightTile={lightTile}/>
    <div style={{ textAlign: "center" }}>
      <div style={{
        fontFamily: '"New York", "Iowan Old Style", Georgia, serif',
        fontSize: 22, fontWeight: 500, color: "#15171C", letterSpacing: -0.4
      }}>{title}</div>
      {caption && (
        <div style={{
          marginTop: 6, fontSize: 12.5, color: "rgba(60,60,67,0.65)",
          lineHeight: 1.45, textWrap: "pretty", maxWidth: 280, margin: "6px auto 0"
        }}>{caption}</div>
      )}
    </div>
    {/* Scale row */}
    <div style={{
      display: "flex", alignItems: "flex-end", gap: 20,
      padding: "16px 8px 4px", marginTop: 8
    }}>
      {[120, 60, 29].map(s => (
        <div key={s} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
          <JotIcon size={s} glass={glass} dotColor={dotColor} showRing={showRing} lowercase={lowercase} tileBg={tileBg} lightTile={lightTile}/>
          <span style={{ fontSize: 10.5, fontWeight: 600, letterSpacing: 0.8, color: "rgba(60,60,67,0.55)" }}>{s}px</span>
        </div>
      ))}
    </div>
  </div>
);

// Wallpaper-backed container so artboards harmonize with the canvas
const IconArtboard = ({ children }) => (
  <div style={{
    width: 420, height: 520,
    background: "linear-gradient(180deg, #ECEEF2 0%, #DCDEE3 100%)",
    display: "flex", alignItems: "center", justifyContent: "center",
    position: "relative", overflow: "hidden"
  }}>
    <div style={{
      position: "absolute", inset: 0,
      background:
        "radial-gradient(ellipse 55% 40% at 15% 10%, rgba(0,122,255,0.10), transparent 70%), " +
        "radial-gradient(ellipse 50% 35% at 90% 90%, rgba(255,154,113,0.10), transparent 70%)"
    }}/>
    <div style={{ position: "relative", zIndex: 1 }}>{children}</div>
  </div>
);

const LogoCurrent = () => (
  <IconArtboard>
    <IconStudy
      title="Current"
      glass={false}
      dotColor="#FF3B30"
      caption="Flat black tile, system red dot, white serif J."
    />
  </IconArtboard>
);

const LogoRefined = () => (
  <IconArtboard>
    <IconStudy
      title="Refined · Black"
      glass
      dotColor={ICON_CORAL}
      showRing
      lowercase
      caption="Lowercase j on a black Liquid Glass tile. The coral dot is the j's dot — and the live mic light."
    />
  </IconArtboard>
);

const LogoRefinedGray = () => (
  <IconArtboard>
    <IconStudy
      title="Refined · App gray"
      glass
      dotColor={ICON_CORAL}
      showRing
      lowercase
      tileBg="linear-gradient(180deg, #DCDEE3 0%, #C9CCD3 100%)"
      lightTile
      caption="Same mark on the same gray as the keyboard / app chrome. Continuous with the product surface."
    />
  </IconArtboard>
);

window.LogoCurrent = LogoCurrent;
window.LogoRefined = LogoRefined;
window.LogoRefinedGray = LogoRefinedGray;
