#!/usr/bin/env node
// Render a thumbnail for every example in examples/manifest.json.
//
// The gallery's cards are real renders of the same shaders the pages run, not
// screenshots — so a thumbnail can never drift from what the example does.

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";

const manifest = JSON.parse(readFileSync("examples/manifest.json", "utf8"));

mkdirSync("public/stills", { recursive: true });

for (const example of manifest) {
  // An example whose shader is assembled at runtime has no entry file to
  // render from. It gets no thumbnail rather than a wrong one.
  if (!example.still) {
    console.log(`skip ${example.slug} — no still settings (runtime-generated shader)`);
    continue;
  }

  const { width = 1600, height = 900, time = 0, set, feedback } = example.still;

  const args = [
    "scripts/render.mjs",
    `examples/${example.slug}/${example.entry}`,
    "-o",
    `public/stills/${example.slug}.png`,
    "-w",
    String(width),
    "-h",
    String(height),
    "-t",
    String(time),
  ];

  // Shaders whose uniforms go beyond resolution and time — a measured layout
  // rect, an interaction state — carry them in the manifest.
  if (set) args.push("-s", JSON.stringify(set));

  // A feedback example's thumbnail has to be wound forward before it exists.
  // The display shader's path is made relative to the repo here, so the
  // manifest can name it relative to the example like `entry` does.
  if (feedback) {
    args.push("-f", JSON.stringify({
      ...feedback,
      display: `examples/${example.slug}/${feedback.display}`,
    }));
  }

  execFileSync("node", args, { stdio: "inherit" });
}
