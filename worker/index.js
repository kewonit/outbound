// The site's small API. Everything outside /api/ is a static file from Website/, served before this
// script ever runs.
//
//   POST /api/checkout                 A new Polar checkout for Outbound: { id, url, expires_at }.
//   POST /api/license { checkout }     That checkout's license key once it is paid:
//                                      { status: "ready", key, email } or { status: "pending" | "open" | ... }.
//
// POLAR_ACCESS_TOKEN is a secret: a Polar organization token with checkouts:read, checkouts:write,
// orders:read, benefits:read and license_keys:read. Everything else comes from vars in wrangler.jsonc.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// A checkout id keeps working as a way back to its key for a month, then only the customer portal does.
const CLAIM_WINDOW = 30 * 24 * 3600 * 1000;
// Pinned here, where it is easy to move on, rather than in the app.
const POLAR_VERSION = "2026-10";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
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

  // A checkout for Outbound, paid within the last month.
  const checkout = await polar(env, `/v1/checkouts/${id}`);
  if (!checkout || checkout.product_id !== env.POLAR_PRODUCT_ID) return reply({ status: "unknown" }, 404);
  if (checkout.status !== "succeeded") return reply({ status: checkout.status });
  if (Date.now() - Date.parse(checkout.created_at) > CLAIM_WINDOW) return reply({ status: "expired" });

  // Its order, then the license key benefit granted for that order. Grants are made in the background a
  // moment after payment, so until then the answer is "pending".
  const orders = await polar(env, `/v1/orders/?checkout_id=${id}&limit=1`);
  const order = orders?.items?.[0];
  if (!order) return reply({ status: "pending" });
  if (order.status === "refunded") return reply({ status: "refunded" });
  const grants = await polar(env,
    `/v1/benefits/${env.POLAR_BENEFIT_ID}/grants?customer_id=${order.customer_id}&is_granted=true&limit=100`);
  const grant = grants?.items?.find((g) => g.order_id === order.id && !g.is_revoked);
  const keyID = grant?.properties?.license_key_id;
  if (!keyID) return reply({ status: "pending" });
  const key = await polar(env, `/v1/license-keys/${keyID}`);
  if (!key || key.status !== "granted") return reply({ status: "pending" });
  return reply({ status: "ready", key: key.key, email: mask(order.customer?.email ?? checkout.customer_email) });
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
