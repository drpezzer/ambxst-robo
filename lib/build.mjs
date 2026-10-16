// Bundles Coucou's DOM-free TypeScript (vendored, as patched for this port,
// in lib/vendor/coucou: see its UPSTREAM) with the QML shims into
// mod/payload/modules/robo/robo-lib.js. Run: npm ci && node lib/build.mjs [out]
//
// Always the public build, with Robo and Axenide. __PUBLIC__ is true, and every
// module of upstream's own mascot (imported as mascot/<name>, which is not
// vendored) is swapped for one under lib/public/ (engine, greeting, wardrobe,
// outfits, desktop-logic, minibots); the recap image and the drop draw Robo or
// Axenide.
import * as esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const UP = path.join(here, "vendor", "coucou", "src");
const args = process.argv.slice(2);
const PUBLIC = true; // (--public is accepted and changes nothing)
const out = args.find((a) => !a.startsWith("--")) || path.join(here, "..", "mod", "payload", "modules", "robo", "robo-lib.js");

/** Public build: upstream's mascot/<name> → lib/public/<name>.ts. */
const PUBLIC_MASCOT = {
  engine: "engine.ts",
  greeting: "greeting.ts",
  wardrobe: "wardrobe.ts",
  outfits: "outfits.ts",
  "desktop-logic": "desktop-logic.ts",
  minibots: "minibots.ts",
};
const publicMascot = (name) => {
  const f = PUBLIC_MASCOT[name.replace(/\.ts$/, "")];
  if (!f) throw new Error(`--public: no stand-in for mascot/${name}`);
  return { path: path.join(here, "public", f) };
};


const qmlHost = {
  name: "qml-host",
  setup(b) {
    if (PUBLIC) {
      // Upstream's own mascot, by package path or relative from upstream's
      // own files → the stand-ins in lib/public/.
      b.onResolve({ filter: /^@coucou\/mascot\// }, (a) => publicMascot(a.path.slice("@coucou/mascot/".length)));
      b.onResolve({ filter: /(^|\/)mascot\/[\w-]+(\.ts)?$/ }, (a) => {
        if (!a.importer.startsWith(UP + path.sep)) return undefined;
        return publicMascot(path.basename(a.path));
      });
      // Personal-only port modules (Axenide on the Coucou mascot's engine, its
      // eye arcs and slot, its compacting loop, its drop colours, its name) →
      // their public stand-ins.
      b.onResolve({ filter: /\/(personal-patch|personal-only)$/ }, (a) => ({ path: path.join(here, "public", path.basename(a.path) + ".ts") }));
    }
    // Translations: core/i18n's copy of upstream's two tables, with the
    // Coucou strings renamed to Robo (keys and every language), so the lib
    // and ambxst-robo look up the same keys.
    b.onResolve({ filter: /^\.\/(strings|extra)\.json$/ }, (a) => {
      if (path.dirname(a.importer) !== path.join(UP, "i18n")) return undefined;
      return { path: path.join(here, "..", "core", "i18n", path.basename(a.path)) };
    });
    b.onResolve({ filter: /^@coucou\// }, (a) => {
      const rel = a.path.slice("@coucou/".length);
      // core/sound is replaced by the QML player.
      if (rel === "core/sound") return { path: path.join(here, "sound.js") };
      for (const ext of [".ts", ".js", "/index.ts"]) {
        const p = path.join(UP, rel + ext);
        if (fs.existsSync(p)) return { path: p };
      }
      return { path: path.join(UP, rel) };
    });
    b.onResolve({ filter: /\/core\/sound$/ }, () => ({ path: path.join(here, "sound.js") }));
    b.onResolve({ filter: /^@tauri-apps\/api\/core$/ }, () => ({ path: path.join(here, "tauri-core.js") }));
    b.onResolve({ filter: /^@tauri-apps\/api\/event$/ }, () => ({ path: path.join(here, "tauri-event.js") }));
    b.onResolve({ filter: /^@tauri-apps\/api\/(webview|window|webviewWindow)$/ }, () => ({ path: path.join(here, "tauri-webview.js") }));
    b.onResolve({ filter: /\.css$/ }, (a) => ({ path: a.path, namespace: "empty" }));
    b.onLoad({ filter: /.*/, namespace: "empty" }, () => ({ contents: "", loader: "js" }));
  },
};

await esbuild.build({
  entryPoints: [path.join(here, "entry.ts")],
  bundle: true,
  format: "iife",
  globalName: "RoboLib",
  target: "es2016",
  inject: [path.join(here, "shims.js")],
  banner: { js: fs.readFileSync(path.join(here, "prelude.js"), "utf8") + fs.readFileSync(path.join(here, "intl-shim.js"), "utf8") },
  plugins: [qmlHost],
  define: { __PUBLIC__: PUBLIC ? "true" : "false" },
  outfile: out,
  logLevel: "warning",
  charset: "utf8",
});
console.log("built", PUBLIC ? "(public)" : "(personal)", out, fs.statSync(out).size, "bytes");
