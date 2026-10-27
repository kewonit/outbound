/* Outbound site behavior. No dependencies. */
(function () {
  "use strict";

  // The only place site URLs live. Emptying buy or download turns its buttons into
  // "Coming soon", or hides them. Buy makes a checkout in the visitor's own money (worker/index.js).
  var URLS = {
    download: "/download",
    buy: "/buy",
    city: "https://buy.polar.sh/polar_cl_5YJmufj56lhrwpWLSpRyjrU8pa1n5FnVfkweV2Ahi7b",
    github: "https://github.com/kewonit/outbound"
  };

  // Words the script writes itself. A translated page carries them in its own language in OUTBOUND_I18N.
  var WORDS = window.OUTBOUND_I18N || {};
  function word(key, english) {
    return WORDS[key] || english;
  }

  // Counts a moment with Plausible. Blocked, missing or failing, it does nothing, and nothing waits for it.
  function track(name, props) {
    try {
      if (typeof window.plausible === "function") window.plausible(name, { props: props });
    } catch (error) {}
  }

  // Which part of the page a link sits in, so the counts can tell the top bar's Buy from the price box's.
  function place(link) {
    if (link.closest(".topbar")) return "topbar";
    if (link.closest(".hero")) return "hero";
    if (link.closest(".tier")) return "price";
    if (link.closest(".foot-cta")) return "footer";
    if (link.closest(".thanks")) return "thanks";
    return "page";
  }

  // The language picker in the footer. The choice is remembered, and the site keeps to it rather than the
  // browser's languages, then the same page opens in that language, with what its address carried (?app=, ?for=).
  var LANGUAGES = /^\/(es|fr|de|it|pt-br|nl|ru|tr|pl|ja|ko|zh-hans|zh-hant|hi|ar)(?=\/|$)/;
  document.querySelectorAll("select[data-lang-picker]").forEach(function (picker) {
    picker.addEventListener("change", function () {
      var language = picker.value;
      track("Language", { to: language });
      document.cookie = "lang=" + language + "; path=/; max-age=31536000; samesite=lax";
      var path = location.pathname.replace(LANGUAGES, "") || "/";
      location.href = (language === "en" ? "" : "/" + language) + path + location.search + location.hash;
    });
  });

  // Enables collapsible FAQ only when JS runs (no-JS keeps answers visible).
  document.documentElement.classList.add("js");

  // Apply configured URLs to every [data-url] link. A link with no URL yet shows its
  // data-soon text, or hides when that is empty.
  document.querySelectorAll("a[data-url]").forEach(function (link) {
    var url = URLS[link.getAttribute("data-url")];
    if (url) {
      link.setAttribute("href", url);
    } else if (link.hasAttribute("data-soon")) {
      var soon = link.getAttribute("data-soon");
      if (soon) {
        link.removeAttribute("href");
        link.setAttribute("aria-disabled", "true");
        link.classList.add("is-soon");
        link.textContent = soon;
      } else {
        link.hidden = true;
      }
    }
  });
  document.querySelectorAll("[data-needs]").forEach(function (element) {
    if (!URLS[element.getAttribute("data-needs")]) {
      element.hidden = true;
    }
  });

  // Counts the clicks that lead to a purchase or a download. A "Coming soon" link has no address, so it counts
  // nothing.
  var MOMENTS = { buy: "Buy", download: "Download", city: "City" };
  document.querySelectorAll("a[data-url], a[data-dollars]").forEach(function (link) {
    var name = link.hasAttribute("data-dollars") ? "Buy" : MOMENTS[link.getAttribute("data-url")];
    if (!name) return;
    link.addEventListener("click", function () {
      if (!link.getAttribute("href")) return;
      var props = { place: place(link) };
      if (name === "Buy") props.currency = link.hasAttribute("data-dollars") ? "usd" : "local";
      track(name, props);
    });
  });

  // A buyer's key, kept in this browser for a year after checkout so it is easy to find again. While it is
  // here, the Buy buttons in the top bar, the hero and the footer become the key, and a click copies it.
  var saved = null;
  try {
    saved = JSON.parse(localStorage.getItem("outbound-license") || "null");
  } catch (error) {}
  var year = 365 * 24 * 3600 * 1000;
  if (saved && !(typeof saved.key === "string" && Date.now() - saved.saved < year)) {
    try {
      localStorage.removeItem("outbound-license");
    } catch (error) {}
    saved = null;
  }
  if (saved) {
    document.querySelectorAll('.topbar a[data-url="buy"], .hero a[data-url="buy"], .foot-cta a[data-url="buy"]')
      .forEach(function (buy) {
        var small = buy.classList.contains("btn-sm");
        var button = document.createElement("button");
        button.type = "button";
        button.className = "btn btn-light key-button" + (small ? " btn-sm" : "");
        button.title = word("js.copyKeyTitle", "Copy your key");
        if (!small) {
          var code = document.createElement("code");
          code.textContent = saved.key;
          button.appendChild(code);
        }
        var label = document.createElement("span");
        label.textContent = small ? word("js.copyKey", "Copy key") : word("js.copy", "Copy");
        button.appendChild(label);
        button.addEventListener("click", function () {
          navigator.clipboard.writeText(saved.key).then(function () {
            var was = label.textContent;
            label.textContent = word("js.copied", "Copied");
            setTimeout(function () { label.textContent = was; }, 1600);
          });
        });
        buy.hidden = true;
        buy.parentNode.insertBefore(button, buy.nextSibling);
      });
    var yourKey = document.getElementById("your-key");
    if (yourKey) yourKey.hidden = false;
  }

  // Demo clips load and play only while on screen, so the page stays light.
  var demos = document.querySelectorAll("video[data-src]");
  var still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!still && "IntersectionObserver" in window) {
    var watcher = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var video = entry.target;
        if (entry.isIntersecting) {
          if (!video.getAttribute("src")) {
            video.setAttribute("src", video.getAttribute("data-src"));
          }
          var playing = video.play();
          if (playing && playing.catch) {
            playing.catch(function () {});
          }
        } else if (video.getAttribute("src")) {
          video.pause();
        }
      });
    }, { threshold: 0.35 });
    demos.forEach(function (video) {
      watcher.observe(video);
    });
  }

  // People who prefer less motion get the still painting instead of the flight.
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    document.querySelectorAll("video[autoplay]").forEach(function (video) {
      video.removeAttribute("autoplay");
      video.pause();
    });
  }

  // FAQ accordion: one open at a time, all collapsible.
  var items = document.querySelectorAll(".faq-item");
  items.forEach(function (item) {
    var button = item.querySelector(".faq-q");
    if (!button) {
      return;
    }
    button.addEventListener("click", function () {
      var willOpen = !item.classList.contains("open");
      items.forEach(function (other) {
        other.classList.remove("open");
        var otherButton = other.querySelector(".faq-q");
        if (otherButton) {
          otherButton.setAttribute("aria-expanded", "false");
        }
      });
      if (willOpen) {
        item.classList.add("open");
        button.setAttribute("aria-expanded", "true");
        // The question's key, the same in every language.
        track("FAQ", { question: button.getAttribute("data-i18n") || "unknown" });
      }
    });
  });
})();
