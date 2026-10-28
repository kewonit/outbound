/* The feedback page. No dependencies. */
(function () {
  "use strict";

  // A translated page carries these words in its own language, as JSON in #outbound-words.
  var WORDS = (function () {
    var block = document.getElementById("outbound-words");
    try { return block ? JSON.parse(block.textContent) : {}; } catch (error) { return {}; }
  })();
  function word(key, english) {
    return WORDS[key] || english;
  }

  function track(name, props) {
    try {
      if (typeof window.plausible === "function") window.plausible(name, { props: props });
    } catch (error) {}
  }

  var form = document.getElementById("feedback");
  var done = document.getElementById("feedback-done");
  if (!form || !done) return;
  var status = document.getElementById("feedback-status");
  var button = form.querySelector('button[type="submit"]');

  // Opened from the app's menu, the address says which version, as ?app=1.3, and the message carries it along.
  var app = new URLSearchParams(location.search).get("app");
  if (!/^\d{1,3}(\.\d{1,3}){0,2}$/.test(app || "")) app = null;
  // And one line about how the painting runs on that Mac, as ?diag=chip=M1 os=26.1 ..., for a painting that won't move.
  var diag = new URLSearchParams(location.search).get("diag");
  if (!/^[A-Za-z0-9 =:,._-]{1,160}$/.test(diag || "")) diag = null;

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var message = form.elements.message.value.trim();
    var email = form.elements.email.value.trim();
    if (!message) {
      status.textContent = word("js.feedbackEmpty", "Write something first.");
      form.elements.message.focus();
      return;
    }
    // Counted in characters as the server counts them, which a browser's maxlength doesn't always do.
    if (Array.from(message).length > 2000) {
      status.textContent = word("js.feedbackLong", "Keep it to 2000 characters.");
      form.elements.message.focus();
      return;
    }
    if (email && (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) {
      status.textContent = word("js.emailInvalid", "That email doesn't look right.");
      form.elements.email.focus();
      return;
    }
    status.textContent = "";
    button.disabled = true;
    fetch("/api/feedback", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: message,
        email: email,
        lang: document.documentElement.lang.toLowerCase(),
        app: app,
        diag: diag,
        hp: form.elements.hp.value
      })
    }).then(function (response) {
      if (!response.ok) throw new Error(String(response.status));
      track("Feedback", { from: app ? "app" : "site" });
      done.textContent = word("js.feedbackSent", "Thank you. It's on its way.");
      form.hidden = true;
      done.hidden = false;
      done.focus();
    }).catch(function (error) {
      // What was written stays in the box, so nothing is lost. The checks above catch what the server would turn
      // down, so a refusal now is most likely the length.
      status.textContent = error.message === "429" ? word("js.formBusy", "Too many tries. Wait a minute.")
        : error.message === "400" || error.message === "413" ? word("js.feedbackLong", "Keep it to 2000 characters.")
        : word("js.formFailed", "That didn't go through. Try again.");
      button.disabled = false;
    });
  });
})();
