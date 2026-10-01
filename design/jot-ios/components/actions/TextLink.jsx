import React from "react";

/**
 * Quiet text-button ("I've already added it", "Type instead").
 */
export function TextLink({ children, onClick }) {
  return (
    <button onClick={onClick} style={{
      background: "none", border: "none", cursor: "pointer",
      fontFamily: "var(--font-sys)", fontWeight: 500, fontSize: "var(--ts-label)",
      color: "var(--ink-sub)", padding: "10px 16px",
      display: "inline-flex", alignItems: "center", gap: 8,
      WebkitTapHighlightColor: "transparent",
    }}>{children}</button>
  );
}
