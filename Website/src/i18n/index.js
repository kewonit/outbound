// The words of a page in its language. en.json is the source; every other language has the same keys
// (lib/check.mjs makes sure before each build).
import { language } from "./languages.js";

const files = import.meta.glob("./*.json", { eager: true, import: "default" });
const strings = (folder) => files[`./${folder ?? "en"}.json`];

// Links to the site's own translated pages stay in the page's language. Privacy, terms and the license are English.
export function href(folder, path) {
  if (!folder) return path;
  if (path === "/" || path.startsWith("/#")) return `/${folder}${path}`;
  if (/^\/(support|thanks|waitlist|feedback)$/.test(path)) return `/${folder}${path}`;
  return path;
}

const localize = (html, folder) => (folder
  ? html.replace(/(\shref=")(\/(?:#[\w-]+)?|\/(?:support|thanks|waitlist|feedback))"/g, (whole, open, path) => `${open}${href(folder, path)}"`)
  : html);

// t("hero.title") for a page in that language. Strings may hold markup; use set:html where they do.
export function translator(folder) {
  const words = strings(folder);
  return (key) => {
    const value = words[key];
    if (value === undefined) throw new Error(`No string ${key} in ${folder ?? "en"}.json`);
    return localize(value, folder);
  };
}

// The words the page's scripts write themselves (js.*), as JSON for #outbound-words. A "<" is escaped so no word can
// close the block early. English pages leave them out: the scripts carry their English.
export function scriptWords(folder) {
  if (!folder) return null;
  const words = Object.fromEntries(Object.entries(strings(folder)).filter(([key]) => key.startsWith("js.")));
  return JSON.stringify(words).replace(/</g, "\\u003c");
}

// Text as a reader sees it: no markup, entities decoded, white space collapsed. For structured data.
export const plain = (html) => html.replace(/<br\s*\/?>/g, " ").replace(/<[^>]+>/g, "")
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
  .replace(/\s+/g, " ").trim();

export { language };
