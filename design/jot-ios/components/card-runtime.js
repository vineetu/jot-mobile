/* Card runtime: resolve Jot DS components.
   1) Try the compiled _ds_bundle.js (present once the project is a Design System).
   2) Fallback: fetch the raw .jsx sources, strip module syntax, transpile with Babel.
   `files` must be listed in dependency order (project-root-relative paths). */
window.loadJotComponents = function (files) {
  const root = "../../";
  const names = files.map((f) => f.split("/").pop().replace(/\.jsx$/, ""));
  const tryBundle = () => new Promise((resolve) => {
    if (window.__dsBundleTried) { resolve(window.__dsBundleLoaded); return; }
    window.__dsBundleTried = true;
    const s = document.createElement("script");
    s.src = root + "_ds_bundle.js";
    s.onload = () => { window.__dsBundleLoaded = true; resolve(true); };
    s.onerror = () => { window.__dsBundleLoaded = false; resolve(false); };
    document.head.appendChild(s);
  });
  const scan = () => {
    for (const k of Object.getOwnPropertyNames(window)) {
      let v; try { v = window[k]; } catch (e) { continue; }
      if (v && typeof v === "object" && v !== window && names.every((n) => v[n])) return v;
    }
    return null;
  };
  const fallback = async () => {
    const out = {};
    for (const f of files) {
      const src = await (await fetch(root + f)).text();
      const code = src.replace(/^import[^\n]*$/gm, "").replace(/^export\s+/gm, "");
      const js = Babel.transform(code, { presets: ["react"] }).code;
      const name = f.split("/").pop().replace(/\.jsx$/, "");
      const fn = new Function("React", ...Object.keys(out), js + "\nreturn " + name + ";");
      out[name] = fn(React, ...Object.values(out));
    }
    return out;
  };
  return tryBundle().then((ok) => (ok && scan()) || fallback());
};
