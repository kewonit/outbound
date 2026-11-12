// The languages the site speaks besides English, by the folder their pages live in. English is the site's root.
// worker/index.js keeps the same list of folders for its language redirect, and app.js for the footer's picker.
export const SITE = "https://outbound.edbn.me";

export const LANGUAGES = [
  { folder: "es", tag: "es", locale: "es_ES", name: "Español" },
  { folder: "fr", tag: "fr", locale: "fr_FR", name: "Français" },
  { folder: "de", tag: "de", locale: "de_DE", name: "Deutsch" },
  { folder: "it", tag: "it", locale: "it_IT", name: "Italiano" },
  { folder: "pt-br", tag: "pt-BR", locale: "pt_BR", name: "Português (Brasil)" },
  { folder: "nl", tag: "nl", locale: "nl_NL", name: "Nederlands" },
  { folder: "ru", tag: "ru", locale: "ru_RU", name: "Русский" },
  { folder: "tr", tag: "tr", locale: "tr_TR", name: "Türkçe" },
  { folder: "pl", tag: "pl", locale: "pl_PL", name: "Polski" },
  { folder: "ja", tag: "ja", locale: "ja_JP", name: "日本語" },
  { folder: "ko", tag: "ko", locale: "ko_KR", name: "한국어" },
  { folder: "zh-hans", tag: "zh-Hans", locale: "zh_CN", name: "简体中文" },
  { folder: "zh-hant", tag: "zh-Hant", locale: "zh_TW", name: "繁體中文" },
  { folder: "hi", tag: "hi", locale: "hi_IN", name: "हिन्दी" },
  { folder: "ar", tag: "ar", locale: "ar_AR", rtl: true, name: "العربية" },
];

export const ENGLISH = { folder: undefined, tag: "en", locale: "en_US", name: "English" };

export const language = (folder) => (folder ? LANGUAGES.find((l) => l.folder === folder) : ENGLISH);

// The pages search engines list in every language, by their address in English.
export const LISTED = { index: "/", support: "/support", waitlist: "/waitlist" };

// A page's address in a language: /support, /es/support, /es/.
export const pageURL = (folder, path) => `${SITE}${folder ? `/${folder}` : ""}${path}`;

// Every translated page is built once in English, at the root, and once in each language's folder.
export const everyLanguage = () => [{ params: { lang: undefined } }, ...LANGUAGES.map(({ folder }) => ({ params: { lang: folder } }))];
