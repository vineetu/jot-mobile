// Assemble dist/index.d.ts from the per-component .d.ts files (each declares <Name>Props).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
const comps = [["actions", "CtaPill"], ["actions", "GlassButton"], ["actions", "GlassPill"], ["actions", "IosToggle"], ["actions", "TextLink"], ["brand", "HeroTile"], ["brand", "JotAppIcon"], ["brand", "JotGlyph"], ["brand", "JotMark"], ["display", "CitationChip"], ["display", "GlassCard"], ["display", "ProgressDots"], ["display", "SourceRow"], ["display", "StopPill"], ["display", "Waveform"], ["typography", "BodyText"], ["typography", "CapsLabel"], ["typography", "SerifTitle"]];
let out = 'import type * as React from "react";\n\n';
for (const [g, n] of comps) {
  const src = readFileSync(`components/${g}/${n}.d.ts`, "utf8");
  out += src.trimEnd() + "\n";
  out += `export declare function ${n}(props: ${n}Props): React.JSX.Element;\n\n`;
}
mkdirSync("dist", { recursive: true });
writeFileSync("dist/index.d.ts", out);
console.log(`dist/index.d.ts: ${comps.length} components`);
