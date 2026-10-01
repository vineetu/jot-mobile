import React from "react";

/**
 * Wizard progress dots: active = blue + slightly larger, done = mid, todo = faint.
 */
export function ProgressDots({ total, current }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      {Array.from({ length: total }).map((_, i) => {
        const active = i === current;
        const done = i < current;
        return (
          <span key={i} style={{
            width: active ? 7.5 : 6.5, height: active ? 7.5 : 6.5, borderRadius: 5,
            background: active ? "var(--jot-blue-flat)" : (done ? "var(--dot-done)" : "var(--dot-todo)"),
            transition: "all .3s ease",
          }}></span>
        );
      })}
    </div>
  );
}
