// The site's small API. Everything outside /api/ is a static file from Website/dist, which Astro builds from
// Website/src (npm run build), served before this script ever runs.
//
//   GET  /, /support, /thanks          The page in the visitor's language: their pick in the footer if they made
//                                      one, else the first of their browser's languages the site speaks.
//                                      Every page shows Outbound's price in the visitor's own money (PRICES).
//                                      With ?from=appstore, as the Mac App Store copy opens them, without any way
//                                      to buy or download it here (forAppStore).
//   GET  /buy[?currency=usd]           On to a new Polar checkout for Outbound, in that money, or in dollars.
//   GET  /download                     On to the newest disk image, /download/Outbound-v1.0.dmg and so on.
//   GET  /download/Outbound-v1.0.dmg   That version's disk image, or its .zip, from the site's own storage.
//   POST /api/checkout                 A new Polar checkout for Outbound, in the buyer's money: { id, url, expires_at }.
//   POST /api/license { checkout }     That checkout's license key once it is paid:
//                                      { status: "ready", key, email, paid } or { status: "pending" | "open" | ... }.
//                                      paid is what the buyer paid before tax, { amount, currency }, for counting
//                                      sales.
//   POST /api/waitlist { email, platform, lang }
//                                      Puts an address down for one email when Outbound comes to Windows or
//                                      iPhone: { ok: true }, the same whether or not it was already there.
//   POST /api/feedback { message, email?, lang, app? }
//                                      Keeps a message from the feedback page: { ok: true }.
//   GET/POST /ingest/...               PostHog, through the site's own address (posthog below).
//
// POLAR_ACCESS_TOKEN is a secret: a Polar organization token with checkouts:read, checkouts:write,
// orders:read, benefits:read and license_keys:read. The waitlist and feedback need three more: SUPABASE_URL,
// SUPABASE_KEY (the project's publishable key) and WAITLIST_TOKEN, the one secret the database's functions accept,
// named for the first of them (worker/supabase.sql). Everything else comes from vars in wrangler.jsonc.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// A checkout id keeps working as a way back to its key for a month, then only the customer portal does.
const CLAIM_WINDOW = 30 * 24 * 3600 * 1000;
// Pinned here, where it is easy to move on, rather than in the app.
const POLAR_VERSION = "2026-10";
// The languages the site is translated into, by their folder. English is the site's own root.
const LANGUAGES = ["es", "fr", "de", "it", "pt-br", "nl", "ru", "tr", "pl", "ja", "ko", "zh-hans", "zh-hant", "hi", "ar"];
const TRANSLATED = new Set(["/", "/support", "/thanks", "/waitlist", "/feedback"]);
// What the forms take: an address of a sensible shape, one of the two platforms on the way, a message of a few
// paragraphs at most, and the app's version as it writes it.
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Control characters, apart from line breaks and tabs, which a message has no use for and Postgres can't always keep.
const CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;
const PLATFORMS = ["windows", "ios"];
const MESSAGE_LIMIT = 2000;
const VERSION = /^\d{1,3}(\.\d{1,3}){0,2}$/;
// The app's line about how the painting runs on that Mac: chip, macOS, holds, GPU errors and cost.
const DIAG = /^[A-Za-z0-9 =:,._-]{1,160}$/;
// What a release puts up for download: its disk image and its zip, by version. scripts/release.sh makes versions like
// 1.9 and 1.9.1; a name of any other version still finds its GitHub release.
const RELEASE_FILE = /^Outbound-v(\d[\w.-]{0,30})\.(dmg|zip)$/;
// Outbound's price in the visitor's own money, in the countries most buyers come from, as Cloudflare places them:
// the currency its checkout charges, and how the pages write the price. The Outbound product in Polar needs a price
// of that amount in each currency. Everywhere else, and for anyone who asks for dollars, it's $4.99. Turkish pages
// say "$4.99'a", which suits a lira price ending in 9 (dokuz).
const priceIn = (currency, label) => ({ currency, label });
const EURO = [
  "AD", "AT", "AX", "BE", "BG", "CY", "DE", "EE", "ES", "FI", "FR", "GF", "GP", "GR", "HR", "IT", "LT", "LU", "LV",
  "MC", "ME", "MQ", "PT", "RE", "SI", "SK", "SM", "VA", "XK", "YT",
];
const PRICES = {
  ...Object.fromEntries(EURO.map((country) => [country, priceIn("eur", "4,49\u00a0€")])),
  IE: priceIn("eur", "€4.49"), MT: priceIn("eur", "€4.49"), NL: priceIn("eur", "€4,49"),
  ...Object.fromEntries(["GB", "GG", "IM", "JE"].map((country) => [country, priceIn("gbp", "£3.99")])),
  CH: priceIn("chf", "CHF\u00a04.49"), LI: priceIn("chf", "CHF\u00a04.49"),
  SE: priceIn("sek", "49\u00a0kr"),
  CA: priceIn("cad", "CA$6.99"),
  AU: priceIn("aud", "A$6.99"),
  SG: priceIn("sgd", "S$6.49"),
  HK: priceIn("hkd", "HK$39"),
  JP: priceIn("jpy", "¥800"),
  KR: priceIn("krw", "₩6,500"),
  TW: priceIn("twd", "NT$150"),
  CN: priceIn("cny", "¥29"),
  SA: priceIn("sar", "SAR\u00a018.99"),
  AE: priceIn("aed", "AED\u00a018.99"),
  PL: priceIn("pln", "19\u00a0zł"),
  MX: priceIn("mxn", "MX$79"),
  BR: priceIn("brl", "R$10,99"),
  TR: priceIn("try", "₺109"),
  IN: priceIn("inr", "₹199"),
};
// On a page, its $4.99, and the link to pay in dollars, which stays hidden where $4.99 is the price anyway.
const PRICE_OR_DOLLARS = /(<a\b[^>]*\sdata-dollars\b[^>]*>)([\s\S]*?<\/a>)|\$4\.99(?![\d.,])/g;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return newest(request, env);
    if (url.pathname.startsWith("/download/")) return download(request, env, ctx, url);
    if (url.pathname === "/buy") return buy(request, env, url);
    if (url.pathname.startsWith("/ingest/")) return posthog(request, url);
    if (TRANSLATED.has(url.pathname)) return forAppStore(url, await page(request, env, url));
    if (!url.pathname.startsWith("/api/")) return forAppStore(url, await priced(request, env));
    if (request.method !== "POST") return reply({ error: "Use POST." }, 405);
    try {
      if (url.pathname === "/api/checkout") return await checkout(request, env);
      if (url.pathname === "/api/license") return await license(request, env);
      if (url.pathname === "/api/waitlist") return await waitlist(request, env, url);
      if (url.pathname === "/api/feedback") return await feedback(request, env, url);
      return reply({ error: "Not found." }, 404);
    } catch (error) {
      // Messages name the Polar endpoint and status only, never a key.
      console.error(error.message);
      return reply({ error: "The store is unavailable." }, 502);
    }
  },
};

// PostHog, which the loader (Website/lib/loader.mjs) starts on outbound.edbn.me, sends its events and fetches its
// scripts through /ingest on the site's own address, so blockers that match PostHog's own hosts don't drop them.
// Only the headers PostHog needs go on, with the visitor's IP for the rough location (the project drops the IP).
const POSTHOG_API = "https://us.i.posthog.com";
const POSTHOG_ASSETS = "https://us-assets.i.posthog.com";
const POSTHOG_REQUEST_HEADERS = ["content-type", "user-agent", "accept"];
// Encoding and length stay behind: fetch has already decoded the body.
const POSTHOG_RESPONSE_HEADERS = ["content-type", "cache-control", "etag", "vary"];

async function posthog(request, url) {
  if (request.method !== "GET" && request.method !== "HEAD" && request.method !== "POST") {
    return new Response(null, { status: 405 });
  }
  // The path keeps its trailing slash (/e/, /flags/), which PostHog expects.
  const path = url.pathname.slice("/ingest".length);
  const host = path.startsWith("/static/") || path.startsWith("/array/") ? POSTHOG_ASSETS : POSTHOG_API;
  const headers = new Headers();
  for (const name of POSTHOG_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) headers.set("x-forwarded-for", ip);
  let upstream;
  try {
    upstream = await fetch(new URL(`${path}${url.search}`, host), {
      method: request.method,
      headers,
      body: request.method === "POST" ? await request.arrayBuffer() : undefined,
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return new Response(null, { status: 502 });
  }
  const answer = new Headers({ "X-Content-Type-Options": "nosniff" });
  for (const name of POSTHOG_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value) answer.set(name, value);
  }
  return new Response(upstream.body, { status: upstream.status, headers: answer });
}

// The newest disk image is the first in the site's own update feed, which scripts/release.sh writes once the release
// is up. No call to GitHub's API, whose limits shared addresses run into. Before any release, the releases page.
async function newest(request, env) {
  const feed = await env.ASSETS.fetch(new Request(new URL("/appcast.xml", request.url)));
  const match = (await feed.text()).match(/<enclosure url="[^"]*\/(Outbound-v[\w.-]+\.dmg)"/);
  return redirect(match ? `/download/${match[1]}` : "https://github.com/kewonit/outbound/releases/latest");
}

// A release's disk image or zip, from the site's own storage on Cloudflare (DOWNLOADS, in R2), which
// scripts/release.sh fills. GitHub sent them slowly, at times about 20 KB a second, to the app's updates as well.
// Once sent whole, a file is kept for a day in the cache where it was asked for. A download resumed part way gets the
// rest, from the cache or from storage. A file that isn't in storage, or storage that fails, sends the download on to
// the file's GitHub release.
async function download(request, env, ctx, url) {
  const name = url.pathname.slice("/download/".length);
  const release = name.match(RELEASE_FILE);
  if (!release) return env.ASSETS.fetch(request);
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const github = `https://github.com/kewonit/outbound/releases/download/v${release[1]}/${name}`;
  const key = new Request(`${url.origin}${url.pathname}`, request);
  const part = request.method === "GET" && request.headers.has("Range");
  if (request.method === "GET") {
    // The cache failing is no reason to skip storage.
    const kept = await caches.default.match(key).catch(() => null);
    if (kept) return kept;
  }
  let file;
  try {
    if (request.method === "HEAD") {
      file = await env.DOWNLOADS.head(name);
    } else if (part) {
      // A range storage can't serve, past the end or in several pieces, gets the whole file instead. So does a
      // download resumed on a file that has changed since it began.
      file = await env.DOWNLOADS.get(name, { range: request.headers }).catch(() => undefined);
      const since = request.headers.get("If-Range");
      if (file?.range && since && since !== file.httpEtag) {
        file.body?.cancel();
        file = undefined;
      }
      if (file === undefined) file = await env.DOWNLOADS.get(name);
    } else {
      file = await env.DOWNLOADS.get(name);
    }
  } catch (error) {
    console.error(`/download/${name}: ${error.message}`);
    return redirect(github);
  }
  if (!file) return redirect(github);
  const headers = new Headers({
    "Content-Type": release[2] === "dmg" ? "application/x-apple-diskimage" : "application/zip",
    "Content-Disposition": `attachment; filename="${name}"`,
    "Content-Length": String(file.size),
    "Accept-Ranges": "bytes",
    // Only a day, in case a file ever has to be replaced, though scripts/release.sh never replaces one already offered.
    "Cache-Control": "public, max-age=86400",
    ETag: file.httpEtag,
    // As every page has (Website/public/_headers, which reaches only the files the site serves itself).
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
    "X-Content-Type-Options": "nosniff",
  });
  if (!file.body) return new Response(null, { headers });
  const [first, last] = file.range ? span(file.range, file.size) : [0, file.size - 1];
  if (first > 0 || last < file.size - 1) {
    headers.set("Content-Range", `bytes ${first}-${last}/${file.size}`);
    headers.set("Content-Length", String(last - first + 1));
    return new Response(file.body, { status: 206, headers });
  }
  const response = new Response(file.body, { headers });
  // A plain download fills the cache; one that asked for a part and got the whole file is left out of it.
  if (!part) ctx.waitUntil(caches.default.put(key, response.clone()).catch(() => {}));
  return response;
}

// The first and last byte an R2 range covers, in a file of that size.
function span(range, size) {
  if (range.suffix !== undefined) return [Math.max(size - range.suffix, 0), size - 1];
  const first = range.offset ?? 0;
  const last = range.length === undefined ? size - 1 : first + range.length - 1;
  return [first, Math.min(last, size - 1)];
}

// An English page, or a redirect to the same page in the visitor's language. Search engines, which send no
// languages, get English and find the others through the pages' hreflang links.
async function page(request, env, url) {
  const language = preferredLanguage(request);
  if (language) {
    const path = url.pathname === "/" ? "/" : url.pathname;
    return new Response(null, {
      status: 302,
      headers: { Location: `/${language}${path}${url.search}`, Vary: "Accept-Language, Cookie", "Cache-Control": "private, no-store" },
    });
  }
  const response = await priced(request, env);
  const answer = new Response(response.body, response);
  answer.headers.append("Vary", "Accept-Language, Cookie");
  return answer;
}

// A page with its $4.99 in the visitor's own money, where PRICES has one, and the offer to pay in dollars
// shown. The page is always fetched in full, so a copy the browser kept from before, in dollars, can't be confirmed as
// current, and the answer is cached only in that browser, never somewhere a visitor from another country could be
// handed it.
async function priced(request, env) {
  const price = PRICES[request.cf?.country];
  if (!price) return env.ASSETS.fetch(request);
  const headers = new Headers(request.headers);
  headers.delete("If-None-Match");
  headers.delete("If-Modified-Since");
  const response = await env.ASSETS.fetch(new Request(request, { headers }));
  if (!response.ok || !response.headers.get("Content-Type")?.startsWith("text/html")) return response;
  const html = (await response.text()).replace(PRICE_OR_DOLLARS, (match, link, rest) =>
    link ? link.replace(/\shidden(?=[\s>])/, "") + rest : price.label);
  const answer = new Response(html, response);
  for (const name of ["ETag", "Last-Modified", "Content-Length"]) answer.headers.delete(name);
  if (!answer.headers.get("Cache-Control")?.includes("no-store")) answer.headers.set("Cache-Control", "private, no-cache");
  return answer;
}

const STORE_ONLY = [
  'a[data-url="buy"]', 'a[data-url="download"]', "a[data-dollars]", 'a[href$="#buy"]', "[data-direct]",
];

// A page opened from the Mac App Store copy, whose rules keep it from pointing anywhere else to buy: without the Buy
// and download links, the offer to pay in dollars, or anything marked data-direct (the price box, and help with
// license keys an App Store copy doesn't have), and with the help marked data-appstore shown instead.
function forAppStore(url, response) {
  if (url.searchParams.get("from") !== "appstore") return response;
  if (!response.headers.get("Content-Type")?.startsWith("text/html")) return response;
  const rewriter = new HTMLRewriter().on("[data-appstore]", { element: (element) => element.removeAttribute("hidden") });
  for (const selector of STORE_ONLY) rewriter.on(selector, { element: (element) => element.remove() });
  return rewriter.transform(response);
}

// The folder of the language to show, or null for English: the footer's pick, kept in a cookie, wins; then the
// browser's languages in order of preference, the first the site speaks (English included) deciding.
function preferredLanguage(request) {
  const picked = /(?:^|;\s*)lang=([\w-]+)/.exec(request.headers.get("Cookie") ?? "")?.[1]?.toLowerCase();
  if (picked) return LANGUAGES.includes(picked) ? picked : null;
  const wanted = (request.headers.get("Accept-Language") ?? "")
    .split(",")
    .map((part, i) => {
      const [tag, ...params] = part.trim().toLowerCase().split(";");
      const q = Number(params.find((p) => p.trim().startsWith("q="))?.trim().slice(2) ?? 1);
      return { tag, q: Number.isFinite(q) ? q : 0, i };
    })
    .filter(({ tag, q }) => tag && q > 0)
    .sort((a, b) => b.q - a.q || a.i - b.i);
  for (const { tag } of wanted) {
    const [base, ...rest] = tag.split("-");
    if (base === "en") return null;
    if (base === "zh") {
      return rest.some((part) => ["hant", "tw", "hk", "mo"].includes(part)) ? "zh-hant" : "zh-hans";
    }
    if (base === "pt") return "pt-br";
    if (LANGUAGES.includes(base)) return base;
  }
  return null;
}

// The site's Buy: a new checkout, in the money the page showed, or in dollars when the visitor asked for that. Should
// the store be busy or unreachable, Polar's own checkout link instead, which picks the money from the address itself.
async function buy(request, env, url) {
  try {
    if (await allowed(env.CHECKOUTS, request.headers.get("CF-Connecting-IP") ?? "unknown")) {
      const session = await newCheckout(request, env, env.POLAR_PRODUCT_ID, url.searchParams.get("currency") === "usd", {
        return_url: `${url.origin}/`,
        metadata: { source: "site" },
      });
      return redirect(session.url);
    }
  } catch (error) {
    console.error(error.message);
  }
  return redirect(env.POLAR_CHECKOUT_LINK);
}

// The app's Buy. It sells what that app's own buy window offers: 1 Mac from the release that asks with { macs: "1" },
// and up to 3 Macs to 1.8.1 and every version before it, which ask with nothing.
async function checkout(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await allowed(env.CHECKOUTS, ip))) return reply({ error: "Too many checkouts. Wait a minute." }, 429);
  const body = await request.json().catch(() => ({}));
  const product = body?.macs === "1" ? env.POLAR_PRODUCT_ID : env.POLAR_APP_PRODUCT_ID;
  const session = await newCheckout(request, env, product, false, { metadata: { source: "app" } });
  return reply({ id: session.id, url: session.url, expires_at: session.expires_at });
}

// A Polar checkout for a product of Outbound's in the visitor's money, or in dollars, as well when Polar won't take that
// money. It comes back to the thank-you page. The visitor's address fills in their country.
async function newCheckout(request, env, product, dollars, fields) {
  const origin = new URL(request.url).origin;
  const local = dollars ? null : PRICES[request.cf?.country]?.currency;
  const currencies = local ? [local, "usd"] : ["usd"];
  for (const [i, currency] of currencies.entries()) {
    try {
      const session = await polar(env, "/v1/checkouts/", {
        method: "POST",
        body: JSON.stringify({
          products: [product],
          currency,
          customer_ip_address: request.headers.get("CF-Connecting-IP") ?? undefined,
          success_url: `${origin}/thanks?checkout_id={CHECKOUT_ID}`,
          ...fields,
        }),
      });
      if (session) return session;
    } catch (error) {
      if (i === currencies.length - 1) throw error;
      console.error(error.message);
    }
  }
  throw new Error("Polar POST /v1/checkouts/ found no product");
}

async function license(request, env) {
  const body = await request.json().catch(() => ({}));
  const id = typeof body.checkout === "string" ? body.checkout.trim() : "";
  if (!UUID.test(id)) return reply({ error: "That isn't a checkout." }, 400);
  if (!(await allowed(env.LOOKUPS, id))) return reply({ status: "pending" }, 429);

  // A checkout for Outbound, paid within the last month: the site's product (1 Mac) or the app's (up to 3), each with
  // the license key benefit it grants.
  const checkout = await polar(env, `/v1/checkouts/${id}`);
  const benefit = checkout && {
    [env.POLAR_PRODUCT_ID]: env.POLAR_BENEFIT_ID,
    [env.POLAR_APP_PRODUCT_ID]: env.POLAR_APP_BENEFIT_ID,
  }[checkout.product_id];
  if (!benefit) return reply({ status: "unknown" }, 404);
  if (checkout.status !== "succeeded") return reply({ status: checkout.status });
  if (Date.now() - Date.parse(checkout.created_at) > CLAIM_WINDOW) return reply({ status: "expired" });

  // Its order, then the license key benefit granted for that order. Grants are made in the background a
  // moment after payment, so until then the answer is "pending".
  const orders = await polar(env, `/v1/orders/?checkout_id=${id}&limit=1`);
  const order = orders?.items?.[0];
  if (!order) return reply({ status: "pending" });
  if (order.status === "refunded") return reply({ status: "refunded" });
  const grants = await polar(env,
    `/v1/benefits/${benefit}/grants?customer_id=${order.customer_id}&is_granted=true&limit=100`);
  const grant = grants?.items?.find((g) => g.order_id === order.id && !g.is_revoked);
  const keyID = grant?.properties?.license_key_id;
  if (!keyID) return reply({ status: "pending" });
  const key = await polar(env, `/v1/license-keys/${keyID}`);
  if (!key || key.status !== "granted") return reply({ status: "pending" });
  return reply({ status: "ready", key: key.key, email: mask(order.customer?.email ?? checkout.customer_email),
    paid: paid(order) });
}

// The waitlist page's form: one email when Outbound comes to Windows or iPhone. The answer never says whether an
// address was already on the list.
async function waitlist(request, env, url) {
  const { body, refusal } = await form(request, url, env.WAITLIST, 2048);
  if (refusal) return refusal;
  const email = text(body.email).toLowerCase();
  const platform = PLATFORMS.includes(body.platform) ? body.platform : null;
  if (!platform || email.length > 254 || !EMAIL.test(email)) return reply({ error: "That isn't an email." }, 400);
  if (body.hp) return reply({ ok: true });
  await supabase(env, "outbound_join_waitlist", {
    p_email: email,
    p_platform: platform,
    p_lang: LANGUAGES.includes(body.lang) ? body.lang : "en",
  });
  return reply({ ok: true });
}

// The feedback page's form: a message, an address only when the writer wants a reply, and the app's version and its line
// about how the painting runs when the app opened the page.
async function feedback(request, env, url) {
  const { body, refusal } = await form(request, url, env.FEEDBACK, 16384);
  if (refusal) return refusal;
  const message = text(body.message);
  const email = text(body.email).toLowerCase();
  if (!message || [...message].length > MESSAGE_LIMIT) {
    return reply({ error: `Write something, up to ${MESSAGE_LIMIT} characters.` }, 400);
  }
  if (email && (email.length > 254 || !EMAIL.test(email))) return reply({ error: "That isn't an email." }, 400);
  if (body.hp) return reply({ ok: true });
  await supabase(env, "outbound_send_feedback", {
    p_message: message,
    p_email: email || null,
    p_lang: LANGUAGES.includes(body.lang) ? body.lang : "en",
    p_app: typeof body.app === "string" && VERSION.test(body.app) ? body.app : null,
    // Only when there is one, so feedback from the site still reaches a database not yet given the column.
    ...(typeof body.diag === "string" && DIAG.test(body.diag) ? { p_diag: body.diag } : {}),
  });
  return reply({ ok: true });
}

// A form sent from the site's own pages, as JSON, no bigger than it needs to be, a few times a minute from one
// address: { body }, or { refusal } to answer with instead. A filled-in trap field (hp) means a bot, which the forms
// answer as if all went well while keeping nothing.
async function form(request, url, limiter, size) {
  if (request.headers.get("Origin") !== url.origin) return { refusal: reply({ error: "Not from this site." }, 403) };
  if (!request.headers.get("Content-Type")?.startsWith("application/json")) {
    return { refusal: reply({ error: "Send JSON." }, 415) };
  }
  if (!(await allowed(limiter, request.headers.get("CF-Connecting-IP") ?? "unknown"))) {
    return { refusal: reply({ error: "Too many tries. Wait a minute." }, 429) };
  }
  const raw = await request.text();
  if (raw.length > size) return { refusal: reply({ error: "Too long." }, 413) };
  try {
    const body = JSON.parse(raw);
    if (body && typeof body === "object" && !Array.isArray(body)) return { body };
  } catch {}
  return { refusal: reply({ error: "Send JSON." }, 400) };
}

// A field as the database can keep it: whole characters only, no control characters, trimmed. Anything not text is "".
function text(value) {
  return typeof value === "string" ? value.toWellFormed().replace(CONTROL, "").trim() : "";
}

// One of Outbound's functions in Supabase, which do nothing without WAITLIST_TOKEN (worker/supabase.sql).
async function supabase(env, name, args) {
  if (!env.SUPABASE_URL || !env.SUPABASE_KEY || !env.WAITLIST_TOKEN) throw new Error("Supabase isn't set up");
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: env.SUPABASE_KEY, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ p_token: env.WAITLIST_TOKEN, ...args }),
  });
  if (!response.ok) throw new Error(`Supabase ${name} answered ${response.status}`);
}

// What an order came to before tax, in whole units of its money. Polar counts in cents, except in currencies
// that have none.
const WHOLE = new Set(["jpy", "krw"]);
function paid(order) {
  const currency = typeof order.currency === "string" ? order.currency.toLowerCase() : "";
  if (!currency || typeof order.net_amount !== "number") return undefined;
  return { amount: WHOLE.has(currency) ? order.net_amount : order.net_amount / 100, currency };
}

async function polar(env, path, init = {}) {
  const response = await fetch(env.POLAR_API + path, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.POLAR_ACCESS_TOKEN}`,
      "Polar-Version": POLAR_VERSION,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Polar ${init.method ?? "GET"} ${path.split("?")[0]} answered ${response.status}`);
  return response.json();
}

// Cloudflare's rate limiting binding, when the account has one; without it every request is let through.
async function allowed(limiter, key) {
  if (!limiter) return true;
  const { success } = await limiter.limit({ key });
  return success;
}

// "kartik@example.com" becomes "k•••@example.com": enough to recognise, not enough to collect.
function mask(email) {
  if (typeof email !== "string" || !email.includes("@")) return null;
  const [name, domain] = email.split("@");
  return `${name.slice(0, 1)}•••@${domain}`;
}

function redirect(location) {
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
}

function reply(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
