// The one inline script every page ends with. It starts the page's scripts. The Content Security Policy in
// public/_headers runs this script alone, by its hash, and what it starts ('strict-dynamic'), so it is the same on
// every page and starts only the site's own files, Plausible and PostHog. astro.config.mjs checks every page carries it
// unchanged and writes its hash into the built _headers.
//
// Each script's address carries a hash of the file, so a changed script is never served from a stale cache.
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const SCRIPTS = ["app", "mac", "thanks", "feedback", "waitlist"];

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
  // PostHog, on the live site only: page views, clicks, heatmaps, web vitals, errors and recordings of visits, in
  // the edbn project ui.edbn.me uses, through /ingest on this site (worker/index.js). Calls wait in its queue until
  // its script arrives. It keeps its random id in this site's local storage, never a cookie, so nothing joins a
  // visit here to ui.edbn.me. Recordings never hold what is typed, and leave out anything marked ph-no-capture: the
  // key and the buyer's email. Privacy section 6 says exactly this, so change both together.
  var reports = location.hostname === "outbound.edbn.me";
  if (reports) {
    var posthog = window.posthog = [];
    posthog.people = [];
    posthog.capture = function () { posthog.push(["capture"].concat([].slice.call(arguments))); };
    posthog._i = [["phc_Ckkg6Qm4MnyqPUe27H93ZjigjBJxh3booYsszWpsN8Yi", {
      api_host: "/ingest",
      ui_host: "https://us.posthog.com",
      defaults: "2026-08-30",
      persistence: "localStorage",
      person_profiles: "identified_only",
      capture_exceptions: true,
      capture_heatmaps: true,
      capture_dead_clicks: true,
      capture_performance: { web_vitals: true, network_timing: true },
      enable_recording_console_log: true,
      session_recording: { maskAllInputs: true, recordHeaders: false, recordBody: false },
      // Polar's checkout address, which a buyer arrives on the thank-you page from, is cut to its host.
      before_send: function (event) {
        [event && event.properties, event && event.$set_once, event && event.$set].forEach(function (props) {
          for (var key in props || {}) {
            if (/referr?er$/.test(key) && typeof props[key] === "string" && /polar\\.sh/.test(props[key])) {
              props[key] = props[key].replace(/^(https?:\\/\\/[^\\/?#]+).*$/, "$1");
            }
          }
        });
        return event;
      }
    }]];
  }
  // Addresses go through a Trusted Types policy where the browser has them, which takes these and nothing else.
  var urls = ${JSON.stringify({ plausible: "https://plausible.io/js/pa-UjwzQoq8qX6tVKev_Xvxo.js", posthog: "/ingest/static/array.js", ...urls })};
  var policy = window.trustedTypes && trustedTypes.createPolicy("outbound", {
    createScriptURL: function (url) {
      for (var name in urls) if (urls[name] === url) return url;
      throw new TypeError("Not one of Outbound's scripts: " + url);
    }
  });
  // PostHog fetches the rest of itself (recordings, web vitals and so on) by setting addresses of its own, which
  // the default policy lets through when they are on this site under /ingest/static/ or /ingest/array/.
  if (reports && window.trustedTypes) {
    trustedTypes.createPolicy("default", {
      createScriptURL: function (url) {
        var address = new URL(url, location.href);
        if (address.origin === location.origin && /^\\/ingest\\/(static|array)\\//.test(address.pathname)) return url;
        throw new TypeError("Not one of Outbound's scripts: " + url);
      }
    });
  }
  function start(name, async) {
    var script = document.createElement("script");
    script.src = policy ? policy.createScriptURL(urls[name]) : urls[name];
    script.async = async;
    document.body.appendChild(script);
  }
  start("plausible", true);
  if (reports) start("posthog", true);
  // The page's own scripts run in this order, as they would from tags here.
  start("app", false);
  if (page) start(page, false);
  // The homepage's drawn Macs: their clocks.
  if (document.querySelector(".mac-bar")) start("mac", false);
})();
`;
  // Shipped without its comments and indentation.
  return source.split("\n").map((line) => line.trim()).filter((line) => line && !line.startsWith("//")).join("\n");
}
