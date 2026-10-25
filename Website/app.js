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
