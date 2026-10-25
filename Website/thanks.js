/* The thank-you page after checkout: looks up the buyer's key, offers to hand the purchase to the app, and
   shows the key to paste as a fallback. No dependencies. */
(function () {
  "use strict";

  var id = window.OUTBOUND_CHECKOUT;
  var status = document.getElementById("status");
  var activate = document.getElementById("activate");
  var panel = document.getElementById("license");
  var keyText = document.getElementById("key");
  var email = document.getElementById("email");
  var copy = document.getElementById("copy");

  function say(text) {
    status.textContent = text;
  }

  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) {
    say("This page needs the link from your checkout. Your key is in your customer portal below.");
    return;
  }

  // The app swaps the checkout for the key itself, so the key never travels in a link.
  activate.href = "outbound://activate?checkout=" + encodeURIComponent(id);
  activate.removeAttribute("aria-disabled");

  var started = Date.now();
  function poll() {
    fetch("/api/license", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ checkout: id }),
      cache: "no-store",
      referrerPolicy: "no-referrer"
    })
      .then(function (response) { return response.json().catch(function () { return {}; }); })
      .then(function (answer) {
        if (answer.status === "ready" && answer.key) {
          keyText.textContent = answer.key;
          email.textContent = answer.email ? "Bought with " + answer.email + "." : "";
          panel.hidden = false;
          say("");
          return;
        }
        if (answer.status === "open" || answer.status === "confirmed" || answer.status === "pending" || !answer.status) {
          if (Date.now() - started < 90000) {
            say("Finding your license key…");
            setTimeout(poll, 2000);
          } else {
            say("Your key is taking longer than usual. Activate in Outbound, or find it in your customer portal in a minute.");
          }
          return;
        }
        if (answer.status === "refunded") {
          say("This purchase was refunded, so its key no longer works.");
        } else {
          say("This checkout didn't finish. If you were charged, your key is in your customer portal.");
        }
      })
      .catch(function () {
        if (Date.now() - started < 90000) {
          setTimeout(poll, 3000);
        } else {
          say("Couldn't reach the store. Activate in Outbound, or find your key in your customer portal.");
        }
      });
  }
  poll();

  copy.addEventListener("click", function () {
    var text = keyText.textContent;
    if (!text) return;
    navigator.clipboard.writeText(text).then(function () {
      copy.textContent = "Copied";
      setTimeout(function () { copy.textContent = "Copy"; }, 1600);
    });
  });
})();
