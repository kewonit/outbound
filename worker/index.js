// The site's small API. Everything outside /api/ is a static file from Website/, served before this
// script ever runs.
//
//   GET  /, /support, /thanks          The page in the visitor's language: their pick in the footer if they made
//                                      one, else the first of their browser's languages the site speaks.
//                                      Every page shows Outbound's price in the visitor's own money (PRICES).
//   GET  /buy[?currency=usd][&twclid=] On to a new Polar checkout for Outbound, in that money, or in dollars,
//                                      carrying the X ad click it came from, if any.
//   GET  /download                     The newest disk image, Outbound-v1.0.dmg and so on, from GitHub.
//   POST /api/checkout                 A new Polar checkout for Outbound, in the buyer's money: { id, url, expires_at }.
//   POST /api/license { checkout }     That checkout's license key once it is paid:
//                                      { status: "ready", key, email, paid } or { status: "pending" | "open" | ... },
//                                      with city: true when it bought a city painted in as well. paid is what
//                                      the buyer paid before tax, { amount, currency }, for counting sales.
//                                      The first time an order is ready, X Ads hears of the sale (tellX).
//   POST /api/waitlist { email, platform, lang }
//                                      Puts an address down for one email when Outbound comes to Windows or
//                                      iPhone: { ok: true }, the same whether or not it was already there.
//   POST /api/feedback { message, email?, lang, app? }
//                                      Keeps a message from the feedback page: { ok: true }.
//
// POLAR_ACCESS_TOKEN is a secret: a Polar organization token with checkouts:read, checkouts:write,
// orders:read, benefits:read and license_keys:read. The waitlist and feedback need three more: SUPABASE_URL,
// SUPABASE_KEY (the project's publishable key) and WAITLIST_TOKEN, the one secret the database's functions accept,
// named for the first of them (worker/supabase.sql). Sales reach X Ads with X_PIXEL_TOKEN, the pixel's Conversion API
// token from X Ads Manager, and the CONVERSIONS store, which remembers the orders X has heard of. Everything else
// comes from vars in wrangler.jsonc.

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
// An X ad's click id, as X adds it to the ad's link (twclid), no longer than Polar keeps in a checkout's metadata.
const TWCLID = /^[\w.~-]{1,500}$/;
// How long the store remembers an order X has heard of: longer than a checkout can still be claimed.
const TOLD_FOR = 90 * 24 * 3600;
// Outbound's price in the visitor's own money, in the countries most buyers come from, as Cloudflare places them:
// the currency its checkout charges, how the pages write the price, and the usual price they show struck out beside
// it, about as many times the price as $12.99 is $4.99. The Outbound product in Polar needs a price of that amount in
// each currency. Everywhere else, and for anyone who asks for dollars, it's $4.99, down from $12.99. The city is
// $99 everywhere. Turkish pages say "$4.99'a", which suits a lira price ending in 9 (dokuz).
const priceIn = (currency, label, was) => ({ currency, label, was });
const EURO = [
  "AD", "AT", "AX", "BE", "BG", "CY", "DE", "EE", "ES", "FI", "FR", "GF", "GP", "GR", "HR", "IT", "LT", "LU", "LV",
  "MC", "ME", "MQ", "PT", "RE", "SI", "SK", "SM", "VA", "XK", "YT",
];
const PRICES = {
  ...Object.fromEntries(EURO.map((country) => [country, priceIn("eur", "4,49\u00a0€", "11,99\u00a0€")])),
  IE: priceIn("eur", "€4.49", "€11.99"), MT: priceIn("eur", "€4.49", "€11.99"), NL: priceIn("eur", "€4,49", "€11,99"),
  ...Object.fromEntries(["GB", "GG", "IM", "JE"].map((country) => [country, priceIn("gbp", "£3.99", "£9.99")])),
  CH: priceIn("chf", "CHF\u00a04.49", "CHF\u00a011.99"), LI: priceIn("chf", "CHF\u00a04.49", "CHF\u00a011.99"),
  SE: priceIn("sek", "49\u00a0kr", "129\u00a0kr"),
  CA: priceIn("cad", "CA$6.99", "CA$17.99"),
  AU: priceIn("aud", "A$6.99", "A$17.99"),
  SG: priceIn("sgd", "S$6.49", "S$16.99"),
  HK: priceIn("hkd", "HK$39", "HK$99"),
  JP: priceIn("jpy", "¥800", "¥2,000"),
  KR: priceIn("krw", "₩6,500", "₩16,900"),
  TW: priceIn("twd", "NT$150", "NT$390"),
  CN: priceIn("cny", "¥29", "¥79"),
  SA: priceIn("sar", "SAR\u00a018.99", "SAR\u00a048.99"),
  AE: priceIn("aed", "AED\u00a018.99", "AED\u00a048.99"),
  PL: priceIn("pln", "19\u00a0zł", "49\u00a0zł"),
  MX: priceIn("mxn", "MX$79", "MX$199"),
  BR: priceIn("brl", "R$10,99", "R$28,99"),
  TR: priceIn("try", "₺109", "₺279"),
  IN: priceIn("inr", "₹199", "₹499"),
};
// On a page, its $4.99 and the $12.99 struck out beside it, and the link to pay in dollars, which stays hidden
// where $4.99 is the price anyway.
const PRICE_OR_DOLLARS = /(<a\b[^>]*\sdata-dollars\b[^>]*>)([\s\S]*?<\/a>)|\$(4|12)\.99(?![\d.,])/g;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return download(request, env);
    if (url.pathname === "/buy") return buy(request, env, url);
    if (TRANSLATED.has(url.pathname)) return page(request, env, url);
    if (!url.pathname.startsWith("/api/")) return priced(request, env);
    if (request.method !== "POST") return reply({ error: "Use POST." }, 405);
    try {
      if (url.pathname === "/api/checkout") return await checkout(request, env);
      if (url.pathname === "/api/license") return await license(request, env, ctx);
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

// The newest disk image, read from the site's own update feed, which scripts/release.sh writes once the release
// is up. No call to GitHub's API, whose limits shared addresses run into. Before any release, the releases page.
async function download(request, env) {
  const feed = await env.ASSETS.fetch(new Request(new URL("/appcast.xml", request.url)));
  const match = (await feed.text()).match(/<enclosure url="(https:\/\/github\.com\/kewonit\/outbound\/[^"]+\.dmg)"/);
  return new Response(null, {
    status: 302,
    headers: { Location: match ? match[1] : "https://github.com/kewonit/outbound/releases/latest", "Cache-Control": "no-store" },
  });
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

// A page with its $4.99 and $12.99 in the visitor's own money, where PRICES has one, and the offer to pay in dollars
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
  const html = (await response.text()).replace(PRICE_OR_DOLLARS, (match, link, rest, dollars) =>
    link ? link.replace(/\shidden(?=[\s>])/, "") + rest : dollars === "12" ? price.was : price.label);
  const answer = new Response(html, response);
  for (const name of ["ETag", "Last-Modified", "Content-Length"]) answer.headers.delete(name);
  if (!answer.headers.get("Cache-Control")?.includes("no-store")) answer.headers.set("Cache-Control", "private, no-cache");
  return answer;
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

// The site's Buy: a new checkout, in the money the page showed, or in dollars when the visitor asked for that, which
// keeps the X ad click the visitor came from (app.js) for when the sale is told. Should the store be busy or
// unreachable, Polar's own checkout link instead, which picks the money from the address itself.
async function buy(request, env, url) {
  const twclid = url.searchParams.get("twclid");
  try {
    if (await allowed(env.CHECKOUTS, request.headers.get("CF-Connecting-IP") ?? "unknown")) {
      const session = await newCheckout(request, env, url.searchParams.get("currency") === "usd", {
        return_url: `${url.origin}/`,
        metadata: { source: "site", ...(twclid && TWCLID.test(twclid) ? { twclid } : {}) },
      });
      return redirect(session.url);
    }
  } catch (error) {
    console.error(error.message);
  }
  return redirect(env.POLAR_CHECKOUT_LINK);
}

// The app's Buy.
async function checkout(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await allowed(env.CHECKOUTS, ip))) return reply({ error: "Too many checkouts. Wait a minute." }, 429);
  const session = await newCheckout(request, env, false, { metadata: { source: "app" } });
  return reply({ id: session.id, url: session.url, expires_at: session.expires_at });
}

// A Polar checkout for Outbound in the visitor's money, or in dollars, as well when Polar won't take that money. It
// comes back to the thank-you page. The visitor's address fills in their country.
async function newCheckout(request, env, dollars, fields) {
  const origin = new URL(request.url).origin;
  const local = dollars ? null : PRICES[request.cf?.country]?.currency;
  const currencies = local ? [local, "usd"] : ["usd"];
  for (const [i, currency] of currencies.entries()) {
    try {
      const session = await polar(env, "/v1/checkouts/", {
        method: "POST",
        body: JSON.stringify({
          products: [env.POLAR_PRODUCT_ID],
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

async function license(request, env, ctx) {
  const body = await request.json().catch(() => ({}));
  const id = typeof body.checkout === "string" ? body.checkout.trim() : "";
  if (!UUID.test(id)) return reply({ error: "That isn't a checkout." }, 400);
  if (!(await allowed(env.LOOKUPS, id))) return reply({ status: "pending" }, 429);

  // A checkout for Outbound, or for a city painted into it, which comes with the same license key, paid within the
  // last month.
  const checkout = await polar(env, `/v1/checkouts/${id}`);
  if (!checkout || ![env.POLAR_PRODUCT_ID, env.POLAR_CITY_PRODUCT_ID].includes(checkout.product_id)) {
    return reply({ status: "unknown" }, 404);
  }
  const city = checkout.product_id === env.POLAR_CITY_PRODUCT_ID;
  const answer = (body) => reply({ ...body, city });
  if (checkout.status !== "succeeded") return answer({ status: checkout.status });
  if (Date.now() - Date.parse(checkout.created_at) > CLAIM_WINDOW) return answer({ status: "expired" });

  // Its order, then the license key benefit granted for that order. Grants are made in the background a
  // moment after payment, so until then the answer is "pending".
  const orders = await polar(env, `/v1/orders/?checkout_id=${id}&limit=1`);
  const order = orders?.items?.[0];
  if (!order) return answer({ status: "pending" });
  if (order.status === "refunded") return answer({ status: "refunded" });
  const grants = await polar(env,
    `/v1/benefits/${env.POLAR_BENEFIT_ID}/grants?customer_id=${order.customer_id}&is_granted=true&limit=100`);
  const grant = grants?.items?.find((g) => g.order_id === order.id && !g.is_revoked);
  const keyID = grant?.properties?.license_key_id;
  if (!keyID) return answer({ status: "pending" });
  const key = await polar(env, `/v1/license-keys/${keyID}`);
  if (!key || key.status !== "granted") return answer({ status: "pending" });
  ctx?.waitUntil(tellX(request, env, checkout, order).catch((error) => console.error(error.message)));
  return answer({ status: "ready", key: key.key, email: mask(order.customer?.email ?? checkout.customer_email),
    paid: paid(order) });
}

// Tells X Ads about a sale, once, so the ad a buyer came from is credited with it, after the answer has gone. X hears
// when the order was made, what it came to before tax and its id, the buyer's email as a SHA-256 hash, which X can
// only match against the accounts it has, the click id when the checkout came from an X ad, and the buyer's address
// and browser when the asking is done from the thank-you page rather than the app. Free orders aren't sales and aren't
// told. Without X_PIXEL_TOKEN, X_PURCHASE_EVENT or the CONVERSIONS store, nothing is sent.
async function tellX(request, env, checkout, order) {
  const value = paid(order);
  if (!env.X_PIXEL_TOKEN || !env.X_PIXEL_ID || !env.X_PURCHASE_EVENT || !env.CONVERSIONS || !value?.amount) return;
  const told = `x:${order.id}`;
  if (await env.CONVERSIONS.get(told)) return;
  await env.CONVERSIONS.put(told, new Date().toISOString(), { expirationTtl: TOLD_FOR });

  const buyer = {};
  const twclid = checkout.metadata?.twclid;
  if (typeof twclid === "string" && TWCLID.test(twclid)) buyer.twclid = twclid;
  const email = order.customer?.email ?? checkout.customer_email;
  if (typeof email === "string" && email.includes("@")) buyer.hashed_email = await sha256(email.trim().toLowerCase());
  const ip = request.headers.get("CF-Connecting-IP");
  const browser = request.headers.get("User-Agent");
  if (request.headers.get("Origin") === new URL(request.url).origin && ip && browser) {
    buyer.ip_address = ip;
    buyer.user_agent = browser.slice(0, 512);
  }
  if (!Object.keys(buyer).length) return;

  const response = await fetch(`https://ads-api.x.com/12/measurement/conversions/${env.X_PIXEL_ID}`, {
    method: "POST",
    headers: { "X-Pixel-Token": env.X_PIXEL_TOKEN, "Content-Type": "application/json" },
    body: JSON.stringify({
      conversions: [{
        conversion_time: new Date(order.created_at).toISOString(),
        event_id: env.X_PURCHASE_EVENT,
        event_source_url: `${new URL(request.url).origin}/thanks`,
        conversion_id: `order-${order.id}`,
        value: value.amount,
        price_currency: value.currency.toUpperCase(),
        number_items: 1,
        identifiers: [buyer],
      }],
    }),
  }).catch(() => null);
  if (response?.ok) return;
  // X turned it down or couldn't be reached. Unless the sale itself was refused, a later ask tries again.
  if (!response || response.status === 429 || response.status >= 500) await env.CONVERSIONS.delete(told);
  throw new Error(`X conversions ${response ? `answered ${response.status}` : "couldn't be reached"}`);
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
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

// The feedback page's form: a message, an address only when the writer wants a reply, and the app's version when the
// app opened the page.
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
