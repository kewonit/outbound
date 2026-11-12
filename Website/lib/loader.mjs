// The one inline script every page ends with. It starts the page's scripts. The Content Security Policy in
// public/_headers runs this script alone, by its hash, and what it starts ('strict-dynamic'), so it is the same on
// every page and starts only the site's own files and Plausible. astro.config.mjs checks every page carries it
// unchanged and writes its hash into the built _headers.
//
// Each script's address carries a hash of the file, so a changed script is never served from a stale cache.
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const SCRIPTS = ["app", "thanks", "feedback", "waitlist"];

export function loader(publicDir) {
  const version = (name) => createHash("sha256").update(readFileSync(new URL(`${name}.js`, publicDir))).digest("hex").slice(0, 10);
  const urls = Object.fromEntries(SCRIPTS.map((name) => [name, `/${name}.js?v=${version(name)}`]));
  const source = `
(function () {
  var missing = document.documentElement.getAttribute("data-page") === "404";
  var page = missing ? null : (location.pathname.match(/(?:^|\\/)(thanks|feedback|waitlist)(?:\\.html)?$/) || [])[1];
  // The checkout id, and any customer session token Polar adds, come off the address bar at once, so they stay out
  // of history, bookmarks and screenshots. The id lives on in this tab only.
  if (page === "thanks") {
    var id = new URLSearchParams(location.search).get("checkout_id");
    try {
      if (id) sessionStorage.setItem("outbound-checkout", id);
      else id = sessionStorage.getItem("outbound-checkout");
    } catch (error) {}
    window.OUTBOUND_CHECKOUT = id;
    if (location.search) history.replaceState(null, "", location.pathname);
  }
  // Plausible's queue, ready before its script arrives. A thank-you page gives it only the page, since its address
  // can hold a checkout that fetches a key; a missing page counts as a 404, with the address asked for.
  window.plausible = window.plausible || function () { (plausible.q = plausible.q || []).push(arguments); };
  plausible.init = plausible.init || function (i) { plausible.o = i || {}; };
  if (page === "thanks") {
    plausible.init({ transformRequest: function (request) { request.u = request.u.split("?")[0]; return request; } });
  } else {
    plausible.init();
  }
  if (missing) plausible("404");
  // Addresses go through a Trusted Types policy where the browser has them, which takes these and nothing else.
  var urls = ${JSON.stringify({ plausible: "https://plausible.io/js/pa-UjwzQoq8qX6tVKev_Xvxo.js", ...urls })};
  var policy = window.trustedTypes && trustedTypes.createPolicy("outbound", {
    createScriptURL: function (url) {
      for (var name in urls) if (urls[name] === url) return url;
      throw new TypeError("Not one of Outbound's scripts: " + url);
    }
  });
  function start(name, async) {
    var script = document.createElement("script");
    script.src = policy ? policy.createScriptURL(urls[name]) : urls[name];
    script.async = async;
    document.body.appendChild(script);
  }
  start("plausible", true);
  // The page's own scripts run in this order, as they would from tags here.
  start("app", false);
  if (page) start(page, false);
})();
`;
  // Shipped without its comments and indentation.
  return source.split("\n").map((line) => line.trim()).filter((line) => line && !line.startsWith("//")).join("\n");
}
