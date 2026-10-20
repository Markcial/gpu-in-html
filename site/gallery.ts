// Builds the gallery from examples/manifest.json, which is also what
// scripts/stills.mjs reads. One source of truth: adding an example to the
// manifest gives it a card and a thumbnail, with nothing to keep in sync.

import manifest from "../examples/manifest.json";

interface Example {
  slug: string;
  title: string;
  blurb: string;
  tags: string[];
  still?: unknown;
}

// One sentence each. The manifest blurbs are the long notes; the landing
// page only needs enough to choose a demo.
const summaries: Record<string, string> = {
  "01-gradient": "A fullscreen fragment shader: a cosine palette swept around the polar angle.",
  "02-cloud-form": "A real HTML form whose chrome is a cloud drawn by the shader.",
  "03-tetsuo": "A raymarched arm coming apart, driven by a slider on the page.",
  "04-organ": "Inside a living cylinder, with a form that presses on the wall as you scroll.",
  "05-forge": "A scene composed in TypeScript and written out as ordinary WGSL.",
  "06-street": "An isometric block that clears a plaza under the form.",
  "07-marginalia": "A page that highlights its own lines, one rectangle per line box.",
  "08-windtunnel": "Twenty thousand particles of air blowing around the controls on the page.",
  "09-culture": "A Gray-Scott reaction that grows up to the text and stops.",
};

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

    // No still settings means the shader is assembled at runtime and the
    // headless renderer has no entry file to read, so there is nothing to
    // show but a placeholder.
    let thumb: HTMLElement;
    if (example.still) {
      const img = document.createElement("img");
      img.src = `./stills/${example.slug}.png`;
      img.alt = `${example.title} rendered still`;
      img.loading = "lazy";
      thumb = img;
    } else {
      thumb = document.createElement("div");
      thumb.className = "noshot";
      thumb.textContent = "runtime-generated · open to view";
    }

    const body = document.createElement("div");
    body.className = "body";

    const title = document.createElement("h2");
    title.textContent = example.title;

    const blurb = document.createElement("p");
    blurb.textContent = summaries[example.slug] ?? example.blurb;

    const tags = document.createElement("div");
    tags.className = "tags";
    for (const tag of example.tags) {
      const chip = document.createElement("span");
      chip.className = "tag";
      chip.textContent = tag;
      tags.append(chip);
    }

    body.append(title, blurb, tags);
    card.append(thumb, body);
    grid.append(card);
  }
}
