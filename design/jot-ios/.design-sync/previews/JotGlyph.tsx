import React from "react";
import { JotGlyph } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);
const Label = ({ children }: { children: React.ReactNode }) => (
  <span style={{ fontSize: 10.5, color: "var(--ink-caption)" }}>{children}</span>
);

const NAMES = ["mic", "keyboard", "check", "sparkle", "chevron-left", "chevron-right", "close", "arrow-up",
  "doc", "copy", "trash", "pause", "globe", "search", "keyboard-mini", "watch"] as const;

/** Every glyph in the set at 24, labelled. */
export const AllGlyphs = () => (
  <Screen width={520}>
    <div style={{ display: "grid", gridTemplateColumns: "repeat(8, 1fr)", gap: 14, alignItems: "end" }}>
      {NAMES.map((n) => (
        <div key={n} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}>
          <div style={{ height: 30, display: "flex", alignItems: "center" }}><JotGlyph name={n} size={24} /></div>
          <span style={{ fontSize: 9.5, color: "var(--ink-caption)" }}>{n}</span>
        </div>
      ))}
    </div>
  </Screen>
);

/** Sizes and colors: the AI sparkle in brand blue, a large white mic, the red trash. */
export const SizesAndColors = () => (
  <Screen width={400}>
    <div style={{ display: "flex", gap: 24, alignItems: "center" }}>
      <JotGlyph name="mic" size={56} color="#fff" />
      <JotGlyph name="sparkle" size={34} color="var(--jot-blue-2)" />
      <JotGlyph name="trash" size={28} color="var(--jot-red)" />
      <JotGlyph name="check" size={40} color="var(--jot-blue-2)" />
      <Label>56 · 34 · 28 · 40</Label>
    </div>
  </Screen>
);
