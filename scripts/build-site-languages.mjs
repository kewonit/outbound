// The website in every language Outbound speaks. The English pages in Website/ are the source: each piece of text
// to translate carries data-i18n="key" (its inner HTML is replaced) or data-i18n-attr="attribute=key ...".
//
//   node scripts/build-site-languages.mjs extract   writes Website/i18n/en.json, the English of every key
//   node scripts/build-site-languages.mjs           checks Website/i18n/<language>.json against it, then writes
//                                                    Website/<language>/index.html, support.html, thanks.html,
//                                                    waitlist.html and feedback.html,
//                                                    the hreflang links of every page and the sitemap
//
// A translation keeps the English's markup exactly (the same tags with the same attributes), its prices and its
// keyboard keys, and never uses an em dash. Place names stay in English. No dependencies.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "Website");
const site = "https://outbound.edbn.me";
const pages = ["index", "support", "thanks", "waitlist", "feedback"];
// Pages search engines should list in every language; the thank-you page is for buyers only, and feedback is a form.
const listed = { index: "/", support: "/support", waitlist: "/waitlist" };

export const LANGUAGES = [
  { folder: "es", tag: "es", locale: "es_ES" },
  { folder: "fr", tag: "fr", locale: "fr_FR" },
  { folder: "de", tag: "de", locale: "de_DE" },
  { folder: "it", tag: "it", locale: "it_IT" },
  { folder: "pt-br", tag: "pt-BR", locale: "pt_BR" },
  { folder: "nl", tag: "nl", locale: "nl_NL" },
  { folder: "ru", tag: "ru", locale: "ru_RU" },
  { folder: "tr", tag: "tr", locale: "tr_TR" },
  { folder: "pl", tag: "pl", locale: "pl_PL" },
  { folder: "ja", tag: "ja", locale: "ja_JP" },
  { folder: "ko", tag: "ko", locale: "ko_KR" },
  { folder: "zh-hans", tag: "zh-Hans", locale: "zh_CN" },
  { folder: "zh-hant", tag: "zh-Hant", locale: "zh_TW" },
  { folder: "hi", tag: "hi", locale: "hi_IN" },
  { folder: "ar", tag: "ar", locale: "ar_AR", rtl: true },
];

const read = (path) => readFileSync(join(root, path), "utf8");
const TAGGED = /<(\w+)([^>]*?\sdata-i18n="([\w.]+)"[^>]*)>([\s\S]*?)<\/\1>/g;
const ATTRIBUTED = /<\w+[^>]*\sdata-i18n-attr="([^"]+)"[^>]*>/g;
const LD = /(<script type="application\/ld\+json">)([\s\S]*?)(<\/script>)/;

const decode = (text) => text.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/&amp;/g, "&");
const escapeAttribute = (text) => text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
// Text as a reader sees it: no markup, entities decoded, white space collapsed.
const plain = (html) => decode(html.replace(/<br\s*\/?>/g, " ").replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();

// Every key's English, from the pages' markup and the words the scripts write.
function english() {
  const strings = {};
  const add = (key, value, where) => {
    if (key in strings && strings[key] !== value) throw new Error(`${key} differs in ${where}: ${strings[key]} / ${value}`);
    strings[key] = value;
  };
  for (const page of pages) {
    const html = read(`${page}.html`);
    for (const [, , , key, inner] of html.matchAll(TAGGED)) add(key, inner, page);
    for (const [tag, pairs] of html.matchAll(ATTRIBUTED)) {
      for (const pair of pairs.split(/\s+/)) {
        const [attribute, key] = pair.split("=");
        const value = new RegExp(`\\s${attribute}="([^"]*)"`).exec(tag)?.[1];
        if (value === undefined) throw new Error(`${page}: ${attribute} missing for ${key}`);
        add(key, decode(value), page);
      }
    }
  }
  for (const script of ["app.js", "thanks.js", "waitlist.js", "feedback.js"]) {
    for (const [, key, value] of read(script).matchAll(/word\("(js\.\w+)", "((?:[^"\\]|\\.)*)"\)/g)) add(key, value, script);
  }
  // Structured data that isn't on the page word for word. Its FAQ is rebuilt from the page's, so it must match.
  const graph = JSON.parse(LD.exec(read("index.html"))[2])["@graph"];
  graph.find((node) => node["@type"] === "FAQPage").mainEntity.forEach((question, i) => {
    if (question.name !== plain(strings[`faq.q${i + 1}`] ?? "") || question.acceptedAnswer.text !== plain(strings[`faq.a${i + 1}`] ?? "")) {
      throw new Error(`The structured FAQ's question ${i + 1} doesn't match the page's`);
    }
  });
  const visible = new Set(Object.values(strings).map(plain));
  for (const node of graph) {
    for (const field of ["name", "description", "operatingSystem"]) {
      const value = node[field];
      if (typeof value === "string" && value !== "Outbound" && !visible.has(value)) {
        add(`ld.${node["@type"]}.${field}`, value, "JSON-LD");
      }
    }
  }
  return strings;
}

// What can't change in translation: the markup, prices and keyboard keys.
const markup = (html) => [...html.matchAll(/<\/?\w+[^>]*>/g)].map((m) => m[0]).sort();
const fixed = (text) => [...text.matchAll(/\$\d+(?:\.\d+)?|⌘\w/g)].map((m) => m[0]).sort();

function check(source, language, strings) {
  const problems = [];
  for (const [key, value] of Object.entries(source)) {
    const translated = strings[key];
    if (typeof translated !== "string" || !translated.trim()) {
      problems.push(`${language}: missing ${key}`);
      continue;
    }
    if (translated.includes("\u2014")) problems.push(`${language}: em dash in ${key}`);
    if (JSON.stringify(markup(translated)) !== JSON.stringify(markup(value))) {
      problems.push(`${language}: markup of ${key} differs from the English`);
    }
    if (JSON.stringify(fixed(translated)) !== JSON.stringify(fixed(value))) {
      problems.push(`${language}: ${key} must keep ${fixed(value).join(" ") || "no prices or keys"}`);
    }
  }
  for (const key of Object.keys(strings)) if (!(key in source)) problems.push(`${language}: unknown key ${key}`);
  return problems;
}

const pageURL = (folder, page) => `${site}${folder ? `/${folder}` : ""}${listed[page] ?? `/${page}`}`;

// The hreflang links for a listed page, in every language and the default.
function alternates(page) {
  const links = [`<link rel="alternate" hreflang="en" href="${pageURL("", page)}">`];
  for (const { folder, tag } of LANGUAGES) links.push(`<link rel="alternate" hreflang="${tag}" href="${pageURL(folder, page)}">`);
  links.push(`<link rel="alternate" hreflang="x-default" href="${pageURL("", page)}">`);
  return `<!-- languages -->\n${links.join("\n")}\n<!-- /languages -->`;
}

function withAlternates(html, page) {
  if (!(page in listed)) return html;
  const block = alternates(page);
  if (html.includes("<!-- languages -->")) return html.replace(/<!-- languages -->[\s\S]*?<!-- \/languages -->/, block);
  return html.replace(/(<link rel="canonical"[^>]*>)/, `$1\n${block}`);
}

function translatePage(html, page, language, strings) {
  const { folder, tag, locale, rtl } = language;
  let out = html.replace(TAGGED, (whole, name, attributes, key) => `<${name}${attributes}>${strings[key]}</${name}>`);
  out = out.replace(ATTRIBUTED, (whole, pairs) => {
    let element = whole;
    for (const pair of pairs.split(/\s+/)) {
      const [attribute, key] = pair.split("=");
      element = element.replace(new RegExp(`(\\s${attribute}=")[^"]*(")`), `$1${escapeAttribute(strings[key])}$2`);
    }
    return element;
  });
  out = out.replace('<html lang="en">', `<html lang="${tag}"${rtl ? ' dir="rtl"' : ""}>`);
  // Pages here sit a folder down: relative files become absolute, and links to the site's own translated pages
  // stay in this language. Privacy and the license stay English.
  out = out.replace(/(\s(?:href|src|poster|data-src)=")(?!https?:|\/|#|mailto:|data:)([^"]+)"/g, '$1/$2"');
  out = out.replace(/(\shref=")\/(#[\w-]+)?"/g, `$1/${folder}/$2"`);
  out = out.replace(/(\shref=")\/(support|thanks|waitlist|feedback)"/g, `$1/${folder}/$2"`);
  out = out.replace(/(<link rel="canonical" href=")[^"]*"/, `$1${pageURL(folder, page)}"`);
  out = out.replace(/(<meta property="og:url" content=")[^"]*"/, `$1${pageURL(folder, page)}"`);
  out = out.replace(/(<meta property="og:locale" content=")[^"]*"/, `$1${locale}"`);
  out = out.replace(`<option value="${folder}">`, `<option value="${folder}" selected>`);
  const words = Object.fromEntries(Object.entries(strings).filter(([key]) => key.startsWith("js.")));
  out = out.replace(/<script src=/, `<script>window.OUTBOUND_I18N = ${JSON.stringify(words)};</script>\n<script src=`);
  const ld = LD.exec(out);
  if (ld) out = out.replace(LD, `$1${structuredData(ld[2], language, strings)}$3`);
  return out;
}

// The structured data in this language: the same graph, its words translated and its FAQ rebuilt from the
// translated FAQ, so it matches the page word for word.
function structuredData(json, { folder, tag }, strings) {
  const data = JSON.parse(json);
  const source = english();
  const byEnglish = new Map(Object.entries(source).map(([key, value]) => [plain(value), plain(strings[key])]));
  for (const node of data["@graph"]) {
    for (const field of ["name", "description", "operatingSystem"]) {
      const ldKey = `ld.${node["@type"]}.${field}`;
      if (strings[ldKey]) node[field] = strings[ldKey];
      else if (typeof node[field] === "string" && byEnglish.has(node[field])) node[field] = byEnglish.get(node[field]);
    }
    if (node["@type"] === "WebSite") node.inLanguage = tag;
    if (node["@type"] === "SoftwareApplication") {
      node.url = `${site}/${folder}/`;
      if (node.offers) node.offers.url = `${site}/${folder}/#buy`;
    }
    if (node["@type"] === "FAQPage") {
      node["@id"] = `${site}/${folder}/#faq`;
      node.inLanguage = tag;
      node.mainEntity.forEach((question, i) => {
        question.name = plain(strings[`faq.q${i + 1}`]);
        question.acceptedAnswer.text = plain(strings[`faq.a${i + 1}`]);
      });
    }
  }
  return `\n${JSON.stringify(data, null, 1)}\n`;
}

// The paintings on a page, for image search: its pictures of places and of the day, and the hero's poster, at the
// addresses the page itself uses.
function pictures(page) {
  const found = read(`${page}.html`).matchAll(/\s(?:src|poster)="(assets\/(?:places\/|day\/|poster\.)[^"]+)"/g);
  return [...new Set([...found].map((m) => `${site}/${m[1]}`))];
}

function sitemap() {
  const now = new Date();
  const today = new Date(now.getTime() - now.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  const entry = (page, folder) => {
    const links = [`    <xhtml:link rel="alternate" hreflang="en" href="${pageURL("", page)}"/>`];
    for (const { folder: f, tag } of LANGUAGES) links.push(`    <xhtml:link rel="alternate" hreflang="${tag}" href="${pageURL(f, page)}"/>`);
    links.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${pageURL("", page)}"/>`);
    for (const picture of pictures(page)) links.push(`    <image:image><image:loc>${picture}</image:loc></image:image>`);
    return `  <url><loc>${pageURL(folder, page)}</loc><lastmod>${today}</lastmod>\n${links.join("\n")}\n  </url>`;
  };
  const urls = [];
  for (const page of Object.keys(listed)) {
    urls.push(entry(page, ""));
    for (const { folder } of LANGUAGES) urls.push(entry(page, folder));
  }
  const old = read("sitemap.xml");
  for (const path of ["/privacy", "/license"]) {
    const kept = new RegExp(`\\s*<url><loc>${site}${path}</loc><lastmod>[^<]*</lastmod></url>`).exec(old);
    if (kept) urls.push(kept[0].trim().replace(/^/, "  "));
  }
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\n${urls.join("\n")}\n</urlset>\n`;
}

const source = english();
if (process.argv[2] === "extract") {
  mkdirSync(join(root, "i18n"), { recursive: true });
  const sorted = Object.fromEntries(Object.entries(source).sort(([a], [b]) => a.localeCompare(b)));
  writeFileSync(join(root, "i18n", "en.json"), `${JSON.stringify(sorted, null, 2)}\n`);
  console.log(`Website/i18n/en.json: ${Object.keys(sorted).length} strings`);
  process.exit(0);
}

const saved = JSON.parse(read("i18n/en.json"));
if (JSON.stringify(saved) !== JSON.stringify(Object.fromEntries(Object.entries(source).sort(([a], [b]) => a.localeCompare(b))))) {
  console.error("The English pages changed since Website/i18n/en.json: run with extract, then update the translations.");
  process.exit(1);
}
const problems = [];
const translations = {};
for (const language of LANGUAGES) {
  const path = join(root, "i18n", `${language.folder}.json`);
  if (!existsSync(path)) {
    problems.push(`${language.folder}: no Website/i18n/${language.folder}.json`);
    continue;
  }
  translations[language.folder] = JSON.parse(readFileSync(path, "utf8"));
  problems.push(...check(source, language.folder, translations[language.folder]));
}
if (problems.length) {
  console.error(problems.slice(0, 80).join("\n") + (problems.length > 80 ? `\n... and ${problems.length - 80} more` : ""));
  process.exit(1);
}
for (const page of pages) {
  const html = withAlternates(read(`${page}.html`), page);
  writeFileSync(join(root, `${page}.html`), html);
  for (const language of LANGUAGES) {
    mkdirSync(join(root, language.folder), { recursive: true });
    writeFileSync(join(root, language.folder, `${page}.html`), translatePage(html, page, language, translations[language.folder]));
  }
}
writeFileSync(join(root, "sitemap.xml"), sitemap());
console.log(`Wrote ${pages.length} pages in ${LANGUAGES.length} languages, and the sitemap.`);
