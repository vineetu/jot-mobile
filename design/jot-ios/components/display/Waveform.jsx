import React from "react";

/**
 * Animated reactive waveform — thin blue bars scaling on a loop.
 * Static end-state under prefers-reduced-motion (via CSS in the keyframes).
 */
export function Waveform({ bars = 7, height = 22, color = "var(--jot-blue-flat)", animate = true }) {
  const hs = [0.45, 0.8, 0.6, 1, 0.7, 0.9, 0.5];
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 3, height }}>
      <style>{`
        @keyframes jotWv { 0%,100% { transform: scaleY(0.55); } 50% { transform: scaleY(1); } }
        @media (prefers-reduced-motion: reduce) { .jot-wv-bar { animation: none !important; } }
      `}</style>
      {Array.from({ length: bars }).map((_, i) => (
        <span key={i} className="jot-wv-bar" style={{
          display: "block", width: 3.5, borderRadius: 3,
          height: height * hs[i % hs.length], background: color,
          transformOrigin: "center",
          animation: animate ? `jotWv ${0.9 + (i % 3) * 0.25}s ease-in-out ${i * 0.09}s infinite` : "none",
        }}></span>
      ))}
    </span>
  );
}
