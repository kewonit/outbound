// The site's small API. Everything outside /api/ is a static file from Website/, served before this
// script ever runs.
//
//   GET  /, /support, /thanks          The page in the visitor's language: their pick in the footer if they made
//                                      one, else the first of their browser's languages the site speaks.
//   GET  /download                     The newest disk image, Outbound-v1.0.dmg and so on, from GitHub.
//   POST /api/checkout                 A new Polar checkout for Outbound: { id, url, expires_at }.
//   POST /api/license { checkout }     That checkout's license key once it is paid:
//                                      { status: "ready", key, email } or { status: "pending" | "open" | ... },
//                                      with city: true when it bought a city painted in as well.
//
// POLAR_ACCESS_TOKEN is a secret: a Polar organization token with checkouts:read, checkouts:write,
// orders:read, benefits:read and license_keys:read. Everything else comes from vars in wrangler.jsonc.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// A checkout id keeps working as a way back to its key for a month, then only the customer portal does.
const CLAIM_WINDOW = 30 * 24 * 3600 * 1000;
// Pinned here, where it is easy to move on, rather than in the app.
const POLAR_VERSION = "2026-10";
// The languages the site is translated into, by their folder. English is the site's own root.
const LANGUAGES = ["es", "fr", "de", "it", "pt-br", "nl", "ru", "tr", "pl", "ja", "ko", "zh-hans", "zh-hant", "hi", "ar"];
const TRANSLATED = new Set(["/", "/support", "/thanks"]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return download(request, env);
    if (TRANSLATED.has(url.pathname)) return page(request, env, url);
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(request);
    if (request.method !== "POST") return reply({ error: "Use POST." }, 405);
    try {
      if (url.pathname === "/api/checkout") return await checkout(request, env, url.origin);
      if (url.pathname === "/api/license") return await license(request, env);
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
  const response = await env.ASSETS.fetch(request);
  const answer = new Response(response.body, response);
  answer.headers.append("Vary", "Accept-Language, Cookie");
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

async function checkout(request, env, origin) {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await allowed(env.CHECKOUTS, ip))) return reply({ error: "Too many checkouts. Wait a minute." }, 429);
  const session = await polar(env, "/v1/checkouts/", {
    method: "POST",
    body: JSON.stringify({
      products: [env.POLAR_PRODUCT_ID],
      success_url: `${origin}/thanks?checkout_id={CHECKOUT_ID}`,
      metadata: { source: "app" },
    }),
  });
  if (!session) throw new Error("Polar POST /v1/checkouts/ found no product");
  return reply({ id: session.id, url: session.url, expires_at: session.expires_at });
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
  return answer({ status: "ready", key: key.key, email: mask(order.customer?.email ?? checkout.customer_email) });
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
