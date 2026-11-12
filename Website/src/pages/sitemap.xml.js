// The sitemap: every listed page in every language, each with the others as alternates and the homepage with its
// paintings, then the pages that are in English only.
import { LANGUAGES, LISTED, pageURL } from "../i18n/languages.js";
import { HOME_PICTURES } from "../pictures.js";
import { newest } from "../changelog/index.js";

// When each English-only page last changed. The changelog changes with each release.
const ENGLISH_ONLY = { "/privacy": "2026-11-01", "/license": "2026-10-26", "/terms": "2026-11-01", "/changelog": newest.date };

export function GET() {
  const today = new Date().toISOString().slice(0, 10);
  const entry = (page, path, folder) => {
    const links = [`    <xhtml:link rel="alternate" hreflang="en" href="${pageURL(undefined, path)}"/>`];
    for (const { folder: f, tag } of LANGUAGES) links.push(`    <xhtml:link rel="alternate" hreflang="${tag}" href="${pageURL(f, path)}"/>`);
    links.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${pageURL(undefined, path)}"/>`);
    if (page === "index") for (const picture of HOME_PICTURES) links.push(`    <image:image><image:loc>${pageURL(undefined, picture)}</image:loc></image:image>`);
    return `  <url><loc>${pageURL(folder, path)}</loc><lastmod>${today}</lastmod>\n${links.join("\n")}\n  </url>`;
  };
  const urls = [];
  for (const [page, path] of Object.entries(LISTED)) {
    urls.push(entry(page, path));
    for (const { folder } of LANGUAGES) urls.push(entry(page, path, folder));
  }
  for (const [path, lastmod] of Object.entries(ENGLISH_ONLY)) urls.push(`  <url><loc>${pageURL(undefined, path)}</loc><lastmod>${lastmod}</lastmod></url>`);
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\n${urls.join("\n")}\n</urlset>\n`;
  return new Response(xml, { headers: { "Content-Type": "application/xml" } });
}
