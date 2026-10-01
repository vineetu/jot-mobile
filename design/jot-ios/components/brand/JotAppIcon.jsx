import React from "react";
import { JotMark } from "./JotMark.jsx";

/**
 * The Jot app-icon squircle: 168° blue gradient tile, white mark,
 * top sheen + inset highlights + blue glow.
 */
export function JotAppIcon({ size = 132 }) {
  const r = size * 0.245;
  return (
    <div style={{
      width: size, height: size, borderRadius: r, flexShrink: 0,
      background: "var(--jot-icon-grad)", position: "relative",
      display: "flex", alignItems: "center", justifyContent: "center",
      boxShadow: `inset 0 1.5px 0 rgba(255,255,255,0.45), inset 0 -1px 1px rgba(0,40,100,0.30), inset 0 0 0 0.5px rgba(255,255,255,0.16), 0 ${size * 0.1}px ${size * 0.22}px -${size * 0.06}px var(--jot-glow), 0 ${size * 0.03}px ${size * 0.08}px -${size * 0.04}px rgba(0,0,0,0.38)`,
    }}>
      <div style={{ position: "absolute", inset: 0, borderRadius: r, pointerEvents: "none",
        background: "linear-gradient(180deg, rgba(255,255,255,0.22) 0%, rgba(255,255,255,0) 38%)" }}></div>
      <JotMark size={size * 0.52} sw={15} />
    </div>
  );
}
