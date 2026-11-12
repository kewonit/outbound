// What search engines read about Outbound on the homepage, in the page's language. The FAQ comes from the same
// strings as the page's own, so the two always match word for word.
import { SITE, language } from "./i18n/languages.js";
import { plain } from "./i18n/index.js";

// The hero clip. Update its date and length when scripts/make-site-assets.sh renders it again.
const VIDEO = { uploadDate: "2026-10-27T01:33:53+05:30", duration: "PT16S" };

export function structuredData(lang, t, questions) {
  const { tag } = language(lang);
  const home = lang ? `${SITE}/${lang}/` : `${SITE}/`;
  const description = plain(t("meta.description"));
  const faq = {
    "@type": "FAQPage",
    "@id": `${home}#faq`,
    mainEntity: questions.map((n) => ({
      "@type": "Question",
      name: plain(t(`faq.q${n}`)),
      acceptedAnswer: { "@type": "Answer", text: plain(t(`faq.a${n}`)) },
    })),
  };
  if (lang) faq.inLanguage = tag;
  const graph = [
    {
      "@type": "WebSite",
      "@id": `${SITE}/#website`,
      url: `${SITE}/`,
      name: "Outbound",
      description,
      inLanguage: tag,
      publisher: { "@id": `${SITE}/#organization` },
    },
    {
      "@type": "Organization",
      "@id": `${SITE}/#organization`,
      name: "Outbound",
      url: `${SITE}/`,
      logo: { "@type": "ImageObject", url: `${SITE}/assets/icon-512.png`, width: 512, height: 512 },
      email: "outbound@edbn.me",
      sameAs: ["https://github.com/kewonit/outbound"],
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE}/#app`,
      name: "Outbound",
      description,
      url: home,
      applicationCategory: "DesktopEnhancementApplication",
      operatingSystem: plain(t("needs.macos")),
      processorRequirements: "Apple silicon",
      image: `${SITE}/assets/icon-512.png`,
      screenshot: [
        `${SITE}/assets/poster.jpg`,
        `${SITE}/assets/places/niigata.jpg`,
        `${SITE}/assets/places/lisse.jpg`,
        `${SITE}/assets/day/night.jpg`,
      ],
      downloadUrl: `${SITE}/download`,
      isAccessibleForFree: false,
      offers: { "@type": "Offer", price: "4.99", priceCurrency: "USD", availability: "https://schema.org/InStock", url: `${home}#buy` },
      publisher: { "@id": `${SITE}/#organization` },
      video: { "@id": `${SITE}/#video` },
    },
    {
      "@type": "VideoObject",
      "@id": `${SITE}/#video`,
      name: plain(t("visual.label")),
      description: t("ld.VideoObject.description"),
      thumbnailUrl: `${SITE}/assets/poster.jpg`,
      contentUrl: `${SITE}/assets/flight.mp4`,
      ...VIDEO,
    },
    faq,
  ];
  return JSON.stringify({ "@context": "https://schema.org", "@graph": graph }).replace(/</g, "\\u003c");
}
