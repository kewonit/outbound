/* Outbound site behavior. No dependencies. */
(function () {
  "use strict";

  // The only place site URLs live. Emptying buy or download turns its buttons into
  // "Coming soon", or hides them.
  var URLS = {
    download: "https://github.com/kewonit/outbound/releases/latest/download/Outbound.dmg",
    buy: "https://buy.polar.sh/polar_cl_2WXlRKhLcEPJSQ0KnyuM3gQNFurhMbUrD99Gl4EQHLA",
    github: "https://github.com/kewonit/outbound"
  };

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

  // A buyer's key, kept in this browser for a year after checkout so it is easy to find again.
  var yourKey = document.getElementById("your-key");
  if (yourKey) {
    var saved = null;
    try {
      saved = JSON.parse(localStorage.getItem("outbound-license") || "null");
    } catch (error) {}
    var year = 365 * 24 * 3600 * 1000;
    if (saved && typeof saved.key === "string" && Date.now() - saved.saved < year) {
      var value = document.getElementById("your-key-value");
      var copyKey = document.getElementById("your-key-copy");
      value.textContent = saved.key;
      yourKey.hidden = false;
      copyKey.addEventListener("click", function () {
        navigator.clipboard.writeText(saved.key).then(function () {
          copyKey.textContent = "Copied";
          setTimeout(function () { copyKey.textContent = "Copy"; }, 1600);
        });
      });
      document.getElementById("your-key-forget").addEventListener("click", function () {
        try {
          localStorage.removeItem("outbound-license");
        } catch (error) {}
        yourKey.hidden = true;
      });
    } else if (saved) {
      try {
        localStorage.removeItem("outbound-license");
      } catch (error) {}
    }
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
      }
    });
  });
})();
