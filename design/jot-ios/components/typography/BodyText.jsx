import React from "react";

/**
 * Standard body copy — SF/system, muted ink, centered by default (wizard style).
 */
export function BodyText({ children, align = "center", max = 320, size = 17.5 }) {
  return (
    <p style={{
      fontFamily: "var(--font-sys)", fontWeight: 400, fontSize: size,
      lineHeight: "var(--lh-body)", color: "var(--ink-sub)", textAlign: align,
      margin: 0, maxWidth: max, textWrap: "pretty",
    }}>{children}</p>
  );
}
