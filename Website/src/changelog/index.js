// The changelog: one file per version in this folder, 1.8.md and so on, newest first on the page. Each has its date
// up top, then "### New", "### Changed" and "### Fixed", each with one "- line" per change, or a plain line of text.
// scripts/release.sh writes the file for a new version, or stamps the release date on one written ahead.
//
// The homepage's footer shows the newest version in full, in every language: ../i18n/latest.json has its lines in each
// language, in the same order, and the headings. A language without them shows the English.
import latest from "../i18n/latest.json";

const files = import.meta.glob("./*.md", { query: "?raw", import: "default", eager: true });

const order = (a, b) => {
  const [x, y] = [a.version.split(".").map(Number), b.version.split(".").map(Number)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (y[i] ?? 0) - (x[i] ?? 0);
  return 0;
};

// [{ heading: "New", items: [...] }, { text: "First release." }]
function blocks(body) {
  const out = [];
  for (const line of body.split("\n")) {
    const text = line.trim();
    if (!text) continue;
    if (text.startsWith("### ")) out.push({ heading: text.slice(4), items: [] });
    else if (text.startsWith("- ")) {
      if (!out.at(-1)?.items) out.push({ items: [] });
      out.at(-1).items.push(text.slice(2));
    } else out.push({ text });
  }
  return out;
}

export const releases = Object.entries(files).map(([path, raw]) => {
  const version = /\/([\d.]+)\.md$/.exec(path)?.[1];
  const front = /^---\n([\s\S]*?)\n---\n/.exec(raw);
  const date = front && /^date:\s*(\d{4}-\d{2}-\d{2})\s*$/m.exec(front[1])?.[1];
  if (!version || !date) throw new Error(`src/changelog${path.slice(1)} needs a version for a name and a date up top`);
  return { version, date, blocks: blocks(raw.slice(front[0].length)) };
}).sort(order);

export const newest = releases[0];

export const formatDate = (date, tag) => new Intl.DateTimeFormat(tag, {
  day: "numeric", month: "long", year: "numeric", timeZone: "UTC", numberingSystem: "latn",
}).format(new Date(`${date}T00:00:00Z`));

// The newest version's notes in a language, or null where latest.json doesn't have them line for line.
export function newestIn(folder) {
  if (!folder) return newest.blocks;
  const lines = latest.notes[newest.version]?.[folder];
  const count = newest.blocks.reduce((n, block) => n + (block.items ? block.items.length : 1), 0);
  if (lines?.length !== count) return null;
  const headings = latest.headings[folder] ?? {};
  let i = 0;
  return newest.blocks.map((block) => ({
    ...block,
    heading: block.heading && (headings[block.heading] ?? block.heading),
    items: block.items?.map(() => lines[i++]),
    text: block.text !== undefined ? lines[i++] : undefined,
  }));
}
