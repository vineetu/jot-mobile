import React from "react";

/**
 * Jot's primary CTA: full-width pill, blue gradient, white SF 600 label,
 * blue glow + inset top highlight. Press = scale(0.975).
 */
export function CtaPill({ children, onClick, height = 62, disabled = false }) {
  return (
    <button onClick={onClick} disabled={disabled} style={{
      width: "100%", height, borderRadius: height / 2, border: "none",
      background: "var(--jot-blue-grad)", color: "#fff",
      cursor: disabled ? "default" : "pointer", opacity: disabled ? 0.5 : 1,
      fontFamily: "var(--font-sys)", fontWeight: 600, fontSize: "var(--ts-cta)", letterSpacing: "-0.2px",
      boxShadow: "var(--shadow-cta)",
      display: "flex", alignItems: "center", justifyContent: "center", gap: 10,
      transition: "transform var(--dur-press)", WebkitTapHighlightColor: "transparent",
    }}
      onMouseDown={(e) => { e.currentTarget.style.transform = "scale(0.975)"; }}
      onMouseUp={(e) => { e.currentTarget.style.transform = "scale(1)"; }}
      onMouseLeave={(e) => { e.currentTarget.style.transform = "scale(1)"; }}>
      {children}
    </button>
  );
}
