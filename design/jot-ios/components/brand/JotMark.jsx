import React from "react";

/**
 * The locked Jot brand mark: lowercase stroked "j" whose tittle is a
 * 3-bar voice waveform (heights 10·18·10 — bars must never fuse).
 * viewBox 0 0 116 160; rendered height = size × 160/116.
 */
export function JotMark({ size = 64, color = "#fff", sw = 15 }) {
  const cx = 58, baseY = 24, sp = 11, ch = 18, sh = 10, bw = sw * 0.36;
  const bar = (dx, h, k) => (
    <line key={k} x1={cx + dx} y1={baseY - h / 2} x2={cx + dx} y2={baseY + h / 2}
      stroke={color} strokeWidth={bw} strokeLinecap="round" />
  );
  return (
    <svg width={size} height={(size * 160) / 116} viewBox="0 0 116 160" fill="none" style={{ overflow: "visible" }}>
      <g stroke={color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M58 52 L58 116 Q58 138 34 138"></path>
        {bar(-sp, sh, "l")}{bar(0, ch, "c")}{bar(sp, sh, "r")}
      </g>
    </svg>
  );
}
