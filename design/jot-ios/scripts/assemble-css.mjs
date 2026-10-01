// Compile the token stylesheet the converter ships as _ds_bundle.css: inline every
// relative @import of styles.css (tokens/*.css, in order) and hoist remote
// @import url(...) lines (Google Fonts) to the top so the result is valid CSS.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
const entry = readFileSync("styles.css", "utf8");
const remote = [];
let body = "";
for (const line of entry.split("\n")) {
  const m = /^\s*@import\s+["']([^"']+)["'];?\s*$/.exec(line);
  if (!m) continue;
  const css = readFileSync(m[1], "utf8");
  for (const l of css.split("\n")) {
    if (/^\s*@import\s+url\(/.test(l)) remote.push(l.trim());
    else body += l + "\n";
  }
  body += "\n";
}
// SF Pro is Apple's system font: it cannot ship as a web font, and naming it as
// a family makes the Design System pane report a "missing brand font" and
// substitute. The system-font keywords resolve to SF Pro on Apple devices
// anyway, so the compiled token asks for the system font without naming it.
body = body.replace(
  /--font-sys:[^;]+;/,
  '--font-sys: -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", Helvetica, Arial, sans-serif;'
);
body = body.replace(/SF Pro( Text| Display)?/g, "the system font (SF on Apple devices)");
mkdirSync("dist", { recursive: true });
writeFileSync("dist/jot.css", `/* Jot design tokens — compiled from styles.css @imports */\n${[...new Set(remote)].join("\n")}\n\n${body}`);
console.log(`dist/jot.css: ${(body.length / 1024).toFixed(0)} KB, ${remote.length} remote font import(s)`);
