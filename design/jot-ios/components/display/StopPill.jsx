import React from "react";

/**
 * Recording "Stop" pill: blue gradient capsule with a white stop square and
 * a tabular-numerals timer. The primary control on the recording surface.
 */
export function StopPill({ time = "0:08", onClick, height = 56, maxWidth = 190 }) {
  return (
    <button onClick={onClick} style={{
      flex: 1, maxWidth, height, borderRadius: height / 2, border: "none",
      background: "var(--jot-blue-grad)", color: "#fff", cursor: "pointer",
      fontFamily: "var(--font-sys)", fontWeight: 700, fontSize: height >= 60 ? 21 : 19,
      display: "flex", alignItems: "center", justifyContent: "center", gap: 11,
      boxShadow: "var(--shadow-stop)", fontVariantNumeric: "tabular-nums",
      transition: "transform var(--dur-press)", WebkitTapHighlightColor: "transparent",
    }}
      onMouseDown={(e) => { e.currentTarget.style.transform = "scale(0.975)"; }}
      onMouseUp={(e) => { e.currentTarget.style.transform = "scale(1)"; }}
      onMouseLeave={(e) => { e.currentTarget.style.transform = "scale(1)"; }}>
      <span style={{ width: 16, height: 16, borderRadius: 4, background: "#fff" }}></span>
      <span style={{ letterSpacing: "0.3px" }}>{time}</span>
    </button>
  );
}
