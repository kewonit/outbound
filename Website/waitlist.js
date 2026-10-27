/* The waitlist page: one email when Outbound comes to Windows or iPhone. No dependencies. */
(function () {
  "use strict";

  // A translated page carries these words in its own language in OUTBOUND_I18N.
  var WORDS = window.OUTBOUND_I18N || {};
  function word(key, english) {
    return WORDS[key] || english;
  }

  function track(name, props) {
    try {
      if (typeof window.plausible === "function") window.plausible(name, { props: props });
    } catch (error) {}
  }

  var form = document.getElementById("waitlist");
  var done = document.getElementById("waitlist-done");
  if (!form || !done) return;
  var status = document.getElementById("waitlist-status");
  var button = form.querySelector('button[type="submit"]');

  function finished(platform) {
    done.textContent = platform === "ios"
      ? word("js.waitlistIos", "You're on the list. One email when Outbound comes to iPhone.")
      : word("js.waitlistWindows", "You're on the list. One email when Outbound comes to Windows.");
    form.hidden = true;
    done.hidden = false;
  }

  // Someone who already signed up in this browser sees that again, not the form. Only the platform is kept here,
  // never the address, and one signup per browser is enough.
  var saved = null;
  try {
    saved = JSON.parse(localStorage.getItem("outbound-waitlist") || "null");
  } catch (error) {}
  if (saved && (saved.platform === "ios" || saved.platform === "windows")) {
    finished(saved.platform);
    return;
  }

  // Starts on iPhone, or on Windows for a visitor on a Windows PC, or on whichever a link asked for with ?for=.
  var asked = new URLSearchParams(location.search).get("for");
  form.elements.platform.value = asked === "ios" || asked === "windows" ? asked
    : /Windows/.test(navigator.userAgent) ? "windows" : "ios";

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var email = form.elements.email.value.trim();
    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      status.textContent = word("js.emailInvalid", "That email doesn't look right.");
      form.elements.email.focus();
      return;
    }
    var platform = form.elements.platform.value;
    status.textContent = "";
    button.disabled = true;
    fetch("/api/waitlist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email: email,
        platform: platform,
        lang: document.documentElement.lang.toLowerCase(),
        hp: form.elements.hp.value
      })
    }).then(function (response) {
      if (!response.ok) throw new Error(String(response.status));
      track("Waitlist", { platform: platform });
      try {
        localStorage.setItem("outbound-waitlist", JSON.stringify({ platform: platform, saved: Date.now() }));
      } catch (error) {}
      finished(platform);
      done.focus();
    }).catch(function (error) {
      status.textContent = error.message === "429"
        ? word("js.formBusy", "Too many tries. Wait a minute.")
        : word("js.formFailed", "That didn't go through. Try again.");
      button.disabled = false;
    });
  });
})();
