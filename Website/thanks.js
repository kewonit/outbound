/* The thank-you page after checkout: looks up the buyer's key, offers to hand the purchase to the app, and
   shows the key to paste as a fallback. No dependencies. */
(function () {
  "use strict";

  // Words the script writes itself. A translated page carries them in its own language in OUTBOUND_I18N.
  var WORDS = window.OUTBOUND_I18N || {};
  function word(key, english) {
    return WORDS[key] || english;
  }

  var id = window.OUTBOUND_CHECKOUT;
  var status = document.getElementById("status");
  var activate = document.getElementById("activate");
  var panel = document.getElementById("license");
  var keyText = document.getElementById("key");
  var email = document.getElementById("email");
  var copy = document.getElementById("copy");
  var city = document.getElementById("city");

  function say(text) {
    status.textContent = text;
  }

  function show(key, address) {
    keyText.textContent = key;
    email.textContent = address ? "(" + address + ")" : "";
    panel.hidden = false;
    say("");
  }

  // Without a checkout to look up, the key this browser kept after paying shows again, as on the homepage.
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) {
    var saved = null;
    try {
      saved = JSON.parse(localStorage.getItem("outbound-license") || "null");
    } catch (error) {}
    if (saved && typeof saved.key === "string" && Date.now() - saved.saved < 365 * 24 * 3600 * 1000) {
      show(saved.key);
    } else {
      say(word("js.portal", "Your key is in your customer portal below."));
    }
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
        if (answer.city) city.hidden = false;
        if (answer.status === "ready" && answer.key) {
          // Kept in this browser for a year, so the homepage can show it again.
          try {
            localStorage.setItem("outbound-license", JSON.stringify({ key: answer.key, saved: Date.now() }));
          } catch (error) {}
          show(answer.key, answer.email);
          return;
        }
        if (answer.status === "open" || answer.status === "confirmed" || answer.status === "pending" || !answer.status) {
          if (Date.now() - started < 90000) {
            say(word("js.finding", "Finding your key…"));
            setTimeout(poll, 2000);
          } else {
            say(word("js.slow", "Taking longer than usual. Try Activate, or check your customer portal in a minute."));
          }
          return;
        }
        if (answer.status === "refunded") {
          say(word("js.refunded", "This purchase was refunded."));
        } else {
          say(word("js.unfinished", "This checkout didn't finish."));
        }
      })
      .catch(function () {
        if (Date.now() - started < 90000) {
          setTimeout(poll, 3000);
        } else {
          say(word("js.offline", "Couldn't reach the store. Try Activate, or check your customer portal."));
        }
      });
  }
  poll();

  // If the browser won't write to the clipboard, the key is selected instead, so Command-C copies it and the
  // buyer doesn't paste whatever was there before.
  function selectKey() {
    var range = document.createRange();
    range.selectNodeContents(keyText);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    say(word("js.pressCopy", "Press ⌘C to copy your key."));
  }

  copy.addEventListener("click", function () {
    var text = keyText.textContent;
    if (!text) return;
    if (!navigator.clipboard) {
      selectKey();
      return;
    }
    navigator.clipboard.writeText(text).then(function () {
      copy.textContent = word("js.copied", "Copied");
      setTimeout(function () { copy.textContent = word("js.copy", "Copy"); }, 1600);
    }, selectKey);
  });
})();
