import React from "react";

/**
 * iOS-style switch, 52×31, green when on. Controlled component.
 */
export function IosToggle({ on, onChange }) {
  return (
    <button onClick={() => onChange && onChange(!on)} aria-pressed={!!on} style={{
      width: 52, height: 31, borderRadius: 16, border: "none", padding: 2,
      background: on ? "var(--ios-toggle-on)" : "rgba(120,128,142,0.32)",
      display: "flex", justifyContent: on ? "flex-end" : "flex-start",
      cursor: "pointer", transition: "background .2s",
      WebkitTapHighlightColor: "transparent", flexShrink: 0,
    }}>
      <span style={{
        width: 27, height: 27, borderRadius: "50%", background: "#fff",
        boxShadow: "0 2px 6px rgba(0,0,0,0.3), 0 0.5px 1px rgba(0,0,0,0.2)",
        transition: "transform .2s",
      }}></span>
    </button>
  );
}
