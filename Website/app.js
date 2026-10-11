/* Outbound homepage behavior. No dependencies. URLs come from window.OUTBOUND_URLS
   (defined once at the top of each page) so swaps are a single edit. */
(function () {
  "use strict";

  // Enables collapsible FAQ only when JS runs (no-JS keeps answers visible).
  document.documentElement.classList.add("js");

  var URLS = window.OUTBOUND_URLS || {};

  // Apply configured URLs to every [data-url] link.
  document.querySelectorAll("a[data-url]").forEach(function (link) {
    var url = URLS[link.getAttribute("data-url")];
    if (url) {
      link.setAttribute("href", url);
    }
  });

  // Until a screenshot exists, show a labeled placeholder instead of a broken image.
  function showPlaceholder(img) {
    var panel = document.createElement("div");
    panel.className = "img-fallback";
    panel.setAttribute("role", "img");
    panel.setAttribute("aria-label", img.getAttribute("alt") || "Screenshot");
    panel.textContent = img.getAttribute("alt") || "Screenshot";
    if (img.parentNode) {
      img.parentNode.replaceChild(panel, img);
    }
  }
  document.querySelectorAll("img").forEach(function (img) {
    // The image may have failed before this script ran.
    if (img.complete && img.naturalWidth === 0) {
      showPlaceholder(img);
    } else {
      img.addEventListener("error", function () { showPlaceholder(img); }, { once: true });
    }
  });

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
