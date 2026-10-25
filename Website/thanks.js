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
    say("Your key is in your customer portal below.");
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
          email.textContent = answer.email ? "(" + answer.email + ")" : "";
          panel.hidden = false;
          say("");
          return;
        }
        if (answer.status === "open" || answer.status === "confirmed" || answer.status === "pending" || !answer.status) {
          if (Date.now() - started < 90000) {
            say("Finding your key…");
            setTimeout(poll, 2000);
          } else {
            say("Taking longer than usual. Try Activate, or check your customer portal in a minute.");
          }
          return;
        }
        if (answer.status === "refunded") {
          say("This purchase was refunded.");
        } else {
          say("This checkout didn't finish.");
        }
      })
      .catch(function () {
        if (Date.now() - started < 90000) {
          setTimeout(poll, 3000);
        } else {
          say("Couldn't reach the store. Try Activate, or check your customer portal.");
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
