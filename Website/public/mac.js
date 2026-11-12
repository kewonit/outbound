// The Macs drawn on the homepage: their clocks, their menus beside the notch, and the picture of the two displays,
// fetched as its section comes near.
(function () {
  // The clock, as macOS writes it in the page's language, and in the visitor's own way where that is the same one.
  var page = document.documentElement.lang || "en";
  var own = navigator.language || "";
  var locale = own.toLowerCase().split("-")[0] === page.toLowerCase().split("-")[0] ? own : page;
  // The day, then the time in the language's own short form: 1:00 AM in English, 01:00 in German.
  var day, time;
  try {
    day = new Intl.DateTimeFormat(locale, { weekday: "short", month: "short", day: "numeric" });
    time = new Intl.DateTimeFormat(locale, { timeStyle: "short" });
  } catch (error) {}
  var clocks = document.querySelectorAll(".mac-clock");
  function tick() {
    var now = new Date();
    var text = day ? (day.format(now) + " " + time.format(now)).replace(/[,،]/g, "").replace(/\s+/g, " ") : "";
    clocks.forEach(function (clock) { clock.textContent = text; });
    setTimeout(tick, 60500 - now.getSeconds() * 1000 - now.getMilliseconds());
  }
  if (clocks.length) tick();

  // A MacBook's menus stop short of the notch, as macOS leaves out the ones that don't fit.
  document.querySelectorAll(".mac-bar-notch .mac-bar-left").forEach(function (menus) {
    var end = menus.getBoundingClientRect().right;
    menus.querySelectorAll("span").forEach(function (title) {
      if (title.getBoundingClientRect().right > end + 0.5) title.style.visibility = "hidden";
    });
  });

  // The two displays' picture loads as their section comes near; app.js starts the clip once it's in view.
  var displays = document.querySelector("[data-displays]");
  if (!displays) return;
  var clip = displays.querySelector("video");
  var poster = function () { clip.setAttribute("poster", clip.getAttribute("data-poster")); };
  if (!("IntersectionObserver" in window)) {
    poster();
    return;
  }
  var near = new IntersectionObserver(function (entries) {
    if (!entries[0].isIntersecting) return;
    near.disconnect();
    poster();
  }, { rootMargin: "600px 0px" });
  near.observe(displays);
})();
