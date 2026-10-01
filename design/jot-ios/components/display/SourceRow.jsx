import React from "react";
import { JotGlyph } from "../brand/JotGlyph.jsx";

/**
 * Source list row (Ask Jot "SOURCES"): blue doc tile + date + snippet + chevron.
 * Rows are divided by 0.5px hairlines (use the parent for borders between rows).
 */
export function SourceRow({ date, snippet, onClick }) {
  return (
    <button onClick={onClick} style={{
      display: "flex", alignItems: "center", gap: 12, width: "100%",
      padding: "11px 4px", background: "none", border: "none",
      borderBottom: "0.5px solid var(--card-bord)", cursor: "pointer",
      textAlign: "left", WebkitTapHighlightColor: "transparent",
    }}>
      <span style={{
        width: 30, height: 30, borderRadius: 9, background: "var(--jot-blue-soft)",
        display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0,
      }}>
        <JotGlyph name="doc" size={16} color="var(--jot-blue-flat)" />
      </span>
      <span style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ fontFamily: "var(--font-sys)", fontWeight: 600, fontSize: 14.5, color: "var(--ink)" }}>{date}</span>
        <span style={{
          fontFamily: "var(--font-sys)", fontWeight: 400, fontSize: 13, color: "var(--ink-sub)",
          whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
        }}>{snippet}</span>
      </span>
      <JotGlyph name="chevron-right" size={15} color="var(--ink-caption)" />
    </button>
  );
}
