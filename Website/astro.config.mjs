// The website, built to plain HTML in Website/dist, which the Worker serves (wrangler.jsonc). No JavaScript framework
// reaches the browser: each page runs the inline loader (lib/loader.mjs) and the small scripts in public/.
import { defineConfig } from "astro/config";
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { loader } from "./lib/loader.mjs";
import { checkTranslations } from "./lib/check.mjs";

const publicDir = new URL("./public/", import.meta.url);
const LOADER = loader(publicDir);

// Stops the build on a bad translation, then, once the pages are written, makes sure each runs the loader and no
// other inline script, and puts the loader's hash into the built _headers.
const outbound = {
  name: "outbound",
  hooks: {
    "astro:build:start": () => {
      const problems = checkTranslations(new URL("./src/i18n/", import.meta.url), publicDir);
      if (problems.length) {
        throw new Error(`Translations need fixing:\n${problems.slice(0, 80).join("\n")}${problems.length > 80 ? `\n... and ${problems.length - 80} more` : ""}`);
      }
    },
    "astro:build:done": ({ dir }) => {
      const root = fileURLToPath(dir);
      const pages = readdirSync(root, { recursive: true }).filter((path) => path.endsWith(".html"));
      const wrong = pages.filter((path) => {
        const scripts = [...readFileSync(join(root, path), "utf8").matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)]
          .filter(([, attributes]) => !/type="application\/(?:ld\+)?json"/.test(attributes));
        return scripts.length !== 1 || scripts[0][1].trim() || scripts[0][2] !== LOADER;
      });
      if (wrong.length) throw new Error(`These pages must run the loader and no other script: ${wrong.join(", ")}`);
      const hash = `'sha256-${createHash("sha256").update(LOADER).digest("base64")}'`;
      const headers = readFileSync(join(root, "_headers"), "utf8");
      if (!headers.includes("script-src 'sha256-LOADER'")) throw new Error("public/_headers needs script-src 'sha256-LOADER'");
      writeFileSync(join(root, "_headers"), headers.replace("script-src 'sha256-LOADER'", `script-src ${hash}`));
      console.log(`${pages.length} pages, loader ${hash}`);
    },
  },
};

export default defineConfig({
  site: "https://outbound.edbn.me",
  // es/index.html, support.html, es/support.html: the Worker's assets serve them as /es/, /support and /es/support.
  build: { format: "preserve" },
  trailingSlash: "ignore",
  devToolbar: { enabled: false },
  integrations: [outbound],
  vite: {
    define: { __LOADER__: JSON.stringify(LOADER) },
    build: { rollupOptions: { output: { assetFileNames: "_astro/site.[hash][extname]" } } },
  },
});
