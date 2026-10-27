// The site's small API. Everything outside /api/ is a static file from Website/, served before this
// script ever runs.
//
//   GET  /, /support, /thanks          The page in the visitor's language: their pick in the footer if they made
//                                      one, else the first of their browser's languages the site speaks.
//                                      Every page shows Outbound's price in the visitor's own money (PRICES).
//   GET  /buy[?currency=usd]           On to a new Polar checkout for Outbound, in that money, or in dollars.
//   GET  /download                     The newest disk image, Outbound-v1.0.dmg and so on, from GitHub.
//   POST /api/checkout                 A new Polar checkout for Outbound, in the buyer's money: { id, url, expires_at }.
//   POST /api/license { checkout }     That checkout's license key once it is paid:
//                                      { status: "ready", key, email, paid } or { status: "pending" | "open" | ... },
//                                      with city: true when it bought a city painted in as well. paid is what
//                                      the buyer paid before tax, { amount, currency }, for counting sales.
//   POST /api/waitlist { email, platform, lang }
//                                      Puts an address down for one email when Outbound comes to Windows or
//                                      iPhone: { ok: true }, the same whether or not it was already there.
//   POST /api/feedback { message, email?, lang, app? }
//                                      Keeps a message from the feedback page: { ok: true }.
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
// Outbound's price in the visitor's own money, in the countries most buyers come from, as Cloudflare places them:
// the currency its checkout charges, and how the pages write the price. The Outbound product in Polar needs a price
// of that amount in each currency. Everywhere else, and for anyone who asks for dollars, it's $7. The city is $99
// everywhere. Turkish pages say "$7'a", which suits a lira price ending in 9 (dokuz).
const priceIn = (currency, label) => ({ currency, label });
const EURO = [
  "AD", "AT", "AX", "BE", "BG", "CY", "DE", "EE", "ES", "FI", "FR", "GF", "GP", "GR", "HR", "IT", "LT", "LU", "LV",
  "MC", "ME", "MQ", "PT", "RE", "SI", "SK", "SM", "VA", "XK", "YT",
];
const PRICES = {
  ...Object.fromEntries(EURO.map((country) => [country, priceIn("eur", "6\u00a0€")])),
  IE: priceIn("eur", "€6"), MT: priceIn("eur", "€6"), NL: priceIn("eur", "€6"),
  ...Object.fromEntries(["GB", "GG", "IM", "JE"].map((country) => [country, priceIn("gbp", "£5")])),
  CH: priceIn("chf", "CHF\u00a06"), LI: priceIn("chf", "CHF\u00a06"),
  SE: priceIn("sek", "69\u00a0kr"),
  CA: priceIn("cad", "CA$9"),
  AU: priceIn("aud", "A$10"),
  SG: priceIn("sgd", "S$9"),
  HK: priceIn("hkd", "HK$50"),
  JP: priceIn("jpy", "¥1,000"),
  KR: priceIn("krw", "₩9,000"),
  TW: priceIn("twd", "NT$150"),
  CN: priceIn("cny", "¥29"),
  SA: priceIn("sar", "SAR\u00a025"),
  AE: priceIn("aed", "AED\u00a025"),
  PL: priceIn("pln", "19\u00a0zł"),
  MX: priceIn("mxn", "MX$79"),
  BR: priceIn("brl", "R$15"),
  TR: priceIn("try", "₺149"),
  IN: priceIn("inr", "₹279"),
};
// On a page, its $7, and the link to pay in dollars, which stays hidden where $7 is the price anyway.
const PRICE_OR_DOLLARS = /(<a\b[^>]*\sdata-dollars\b[^>]*>)([\s\S]*?<\/a>)|\$7(?![\d.,])/g;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return download(request, env);
    if (url.pathname === "/buy") return buy(request, env, url);
    if (TRANSLATED.has(url.pathname)) return page(request, env, url);
    if (!url.pathname.startsWith("/api/")) return priced(request, env);
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

// A page with its $7 in the visitor's own money, where PRICES has one, and the offer to pay in dollars shown. The
// page is always fetched in full, so a copy the browser kept from before, in dollars, can't be confirmed as current,
// and the answer is cached only in that browser, never somewhere a visitor from another country could be handed it.
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
      const session = await newCheckout(request, env, url.searchParams.get("currency") === "usd", {
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

async function license(request, env) {
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
  return answer({ status: "ready", key: key.key, email: mask(order.customer?.email ?? checkout.customer_email),
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
  const text = await request.text();
  if (text.length > size) return { refusal: reply({ error: "Too long." }, 413) };
  try {
    const body = JSON.parse(text);
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
