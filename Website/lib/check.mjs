// Checks every translation against the English before a build, and stops the build on any problem. A translation has
// every key of en.json and no other, keeps the English's markup exactly (the same tags with the same attributes), its
// prices and its keyboard keys, and never uses an em dash. Place names stay in English.
//
// The scripts in public/ write some words themselves, word("js.copy", "Copy"): their English must match en.json.
import { readFileSync, existsSync } from "node:fs";
import { LANGUAGES } from "../src/i18n/languages.js";

const markup = (html) => [...html.matchAll(/<\/?\w+[^>]*>/g)].map((m) => m[0]).sort();
const fixed = (text) => [...text.matchAll(/\$\d+(?:\.\d+)?|⌘\w/g)].map((m) => m[0]).sort();
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

export function checkTranslations(i18nDir, publicDir) {
  const read = (name) => JSON.parse(readFileSync(new URL(name, i18nDir), "utf8"));
  const english = read("en.json");
  const problems = [];

  for (const script of ["app.js", "thanks.js", "waitlist.js", "feedback.js"]) {
    const code = readFileSync(new URL(script, publicDir), "utf8");
    for (const [, key, value] of code.matchAll(/word\("(js\.\w+)", "((?:[^"\\]|\\.)*)"\)/g)) {
      if (english[key] !== JSON.parse(`"${value}"`)) problems.push(`${script}: ${key} says "${value}" but en.json has "${english[key]}"`);
    }
  }

  for (const [key, value] of Object.entries(english)) if (value.includes("\u2014")) problems.push(`en: em dash in ${key}`);

  for (const { folder } of LANGUAGES) {
    if (!existsSync(new URL(`${folder}.json`, i18nDir))) {
      problems.push(`${folder}: no src/i18n/${folder}.json`);
      continue;
    }
    const strings = read(`${folder}.json`);
    for (const [key, value] of Object.entries(english)) {
      const translated = strings[key];
      if (typeof translated !== "string" || !translated.trim()) {
        problems.push(`${folder}: missing ${key}`);
        continue;
      }
      if (translated.includes("\u2014")) problems.push(`${folder}: em dash in ${key}`);
      if (!same(markup(translated), markup(value))) problems.push(`${folder}: markup of ${key} differs from the English`);
      if (!same(fixed(translated), fixed(value))) {
        problems.push(`${folder}: ${key} must keep ${fixed(value).join(" ") || "no prices or keys"}`);
      }
    }
    for (const key of Object.keys(strings)) if (!(key in english)) problems.push(`${folder}: unknown key ${key}`);
  }

  const latest = read("latest.json");
  for (const [version, languages] of Object.entries(latest.notes)) {
    for (const [folder, lines] of Object.entries(languages)) {
      if (!LANGUAGES.some((language) => language.folder === folder)) problems.push(`latest.json: unknown language ${folder}`);
      for (const line of lines) {
        if (line.includes("\u2014")) problems.push(`latest.json: em dash in ${folder}'s ${version}`);
        if (/[<>]/.test(line)) problems.push(`latest.json: markup in ${folder}'s ${version}; write plain text`);
      }
    }
  }
  return problems;
}
