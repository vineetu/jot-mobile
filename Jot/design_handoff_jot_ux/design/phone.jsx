// Minimal iPhone frame, palette-driven so each variation can own its chrome.
const PhoneFrame = ({ children, width = 390, height = 844, dark = false, statusFg, time = "10:32" }) => {
  const fg = statusFg ?? (dark ? "#fff" : "#000");
  return (
    <div style={{
      width, height, borderRadius: 54, position: "relative",
      background: dark ? "#000" : "#fff",
      boxShadow: "0 1px 0 rgba(255,255,255,0.06) inset, 0 0 0 1px rgba(0,0,0,0.85), 0 30px 60px -20px rgba(0,0,0,0.45)",
      padding: 10, overflow: "hidden"
    }}>
      <div style={{
        width: "100%", height: "100%", borderRadius: 44, overflow: "hidden",
        position: "relative", background: dark ? "#000" : "#fff"
      }}>
        {/* Status bar */}
        <div style={{
          position: "absolute", top: 0, left: 0, right: 0, height: 54,
          display: "flex", alignItems: "flex-end", justifyContent: "space-between",
          padding: "0 32px 8px", zIndex: 10, color: fg,
          fontSize: 17, fontWeight: 600, letterSpacing: -0.2, fontFeatureSettings: '"tnum"'
        }}>
          <span>{time}</span>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            {/* signal dots */}
            <svg width="18" height="11" viewBox="0 0 18 11"><g fill={fg}>
              <rect x="0" y="7" width="3" height="4" rx="0.8"/>
              <rect x="5" y="5" width="3" height="6" rx="0.8"/>
              <rect x="10" y="2" width="3" height="9" rx="0.8"/>
              <rect x="15" y="0" width="3" height="11" rx="0.8"/>
            </g></svg>
            <span style={{ fontSize: 14, fontWeight: 600 }}>5G</span>
            {/* battery */}
            <svg width="27" height="12" viewBox="0 0 27 12">
              <rect x="0.5" y="0.5" width="22" height="11" rx="3" fill="none" stroke={fg} strokeOpacity="0.45"/>
              <rect x="2" y="2" width="19" height="8" rx="1.8" fill={fg}/>
              <rect x="24" y="4" width="2" height="4" rx="0.8" fill={fg} fillOpacity="0.45"/>
            </svg>
          </div>
        </div>
        {/* Notch / Dynamic Island */}
        <div style={{
          position: "absolute", top: 11, left: "50%", transform: "translateX(-50%)",
          width: 122, height: 35, borderRadius: 20, background: "#000", zIndex: 11
        }}></div>
        {children}
      </div>
    </div>
  );
};

window.PhoneFrame = PhoneFrame;
