// Builds the gallery from examples/manifest.json, which is also what
// scripts/stills.mjs reads. One source of truth: adding an example to the
// manifest gives it a card and a thumbnail, with nothing to keep in sync.

import manifest from "../examples/manifest.json";

interface Example {
  slug: string;
  title: string;
  blurb: string;
  tags: string[];
}

const grid = document.querySelector<HTMLDivElement>("#grid");
if (!grid) throw new Error("Missing #grid");

const examples = manifest as Example[];

if (examples.length === 0) {
  grid.innerHTML = '<p id="empty">No examples in examples/manifest.json yet.</p>';
} else {
  for (const example of examples) {
    const card = document.createElement("a");
    card.className = "card";
    // Relative, so the gallery works the same on a dev server and under a
    // subpath on a static host.
    card.href = `./examples/${example.slug}/`;

    const img = document.createElement("img");
    img.src = `./stills/${example.slug}.png`;
    img.alt = `${example.title} rendered still`;
    img.loading = "lazy";

    const body = document.createElement("div");
    body.className = "body";

    const title = document.createElement("h2");
    title.textContent = example.title;

    const blurb = document.createElement("p");
    blurb.textContent = example.blurb;

    const tags = document.createElement("div");
    tags.className = "tags";
    for (const tag of example.tags) {
      const chip = document.createElement("span");
      chip.className = "tag";
      chip.textContent = tag;
      tags.append(chip);
    }

    body.append(title, blurb, tags);
    card.append(img, body);
    grid.append(card);
  }
}
