// The homepage's paintings, rendered by scripts/make-site-assets.sh. The sitemap lists them for image search. Assets are
// cached for a day, so bump ?v= on a picture that is rendered again.
export const POSTER = "/assets/poster.jpg?v=4";

export const DAY = [
  { src: "/assets/day/morning.jpg?v=3", key: "morning" },
  { src: "/assets/day/noon.jpg?v=3", key: "noon" },
  { src: "/assets/day/evening.jpg?v=3", key: "evening" },
  { src: "/assets/day/night.jpg?v=3", key: "night" },
];

// Place names stay in English in every language, as the app writes them.
export const PLACES = [
  { src: "/assets/places/niigata.jpg?v=3", key: "niigata", name: "Niigata, Japan" },
  { src: "/assets/places/punjab.jpg?v=3", key: "punjab", name: "Punjab, India" },
  { src: "/assets/places/lisse.jpg?v=3", key: "lisse", name: "Lisse, Netherlands" },
  { src: "/assets/places/serengeti.jpg?v=3", key: "serengeti", name: "Serengeti, Tanzania" },
  { src: "/assets/places/normandy.jpg?v=3", key: "normandy", name: "Normandy, France" },
  { src: "/assets/places/kansas.jpg?v=3", key: "kansas", name: "Kansas, United States" },
  { src: "/assets/places/lapland.jpg?v=3", key: "lapland", name: "Lapland, Finland" },
  { src: "/assets/places/pampa.jpg?v=3", key: "pampa", name: "La Pampa, Argentina" },
];

export const HOME_PICTURES = [POSTER, ...DAY.map((p) => p.src), ...PLACES.map((p) => p.src)];
