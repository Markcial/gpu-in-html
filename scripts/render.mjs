#!/usr/bin/env node
// Render an entry shader headless and write a PNG.
//
// The browser and this script feed the same .wgsl to the same library — that
// is the payoff for keeping the primitives pure. Use it for stills at any
// resolution, and as the basis for snapshot tests.
//
//   node scripts/render.mjs examples/01-gradient/src/gradient.wgsl -o out/01.png
//   node scripts/render.mjs <entry> [-o out.png] [-w 1200] [-h 675] [-t 0]

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve as resolvePath } from "node:path";
import { parseArgs } from "node:util";

import { resolveShader } from "@vgpu/wgsl/runtime";
import { PNG } from "pngjs";
import { effect, frame, init, target } from "vgpu/node";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: "string", short: "o" },
    width: { type: "string", short: "w", default: "1200" },
    height: { type: "string", short: "h", default: "675" },
    time: { type: "string", short: "t", default: "0" },
    set: { type: "string", short: "s" },
  },
});

const entry = positionals[0];
if (!entry) {
  console.error("usage: node scripts/render.mjs <entry.wgsl> [-o out.png] [-w 1200] [-h 675] [-t 0]");
  process.exit(1);
}

const width = Number(values.width);
const height = Number(values.height);
const time = Number(values.time);
const out = values.out ?? entry.replace(/\.wgsl$/, ".png");

// Resolve the import graph exactly as the bundler would, so a shader that
// renders here is the shader the browser gets.
const resolved = await resolveShader({ entry: resolvePath(entry), validate: "auto" });

const gpu = await init();
const scene = target(gpu, { size: [width, height] });
// Shaders with more than resolution/time — a measured layout rect, an
// interaction state — take the rest as JSON:
//   -s '{"cloudCenter":[0.5,0.55],"cloudHalf":[0.16,0.2],"focus":1}'
const extra = values.set ? JSON.parse(values.set) : {};

const shader = effect(gpu, resolved.wgsl, {
  set: { params: { resolution: [width, height], time, ...extra } },
});

frame(gpu, (currentFrame) => {
  currentFrame.pass(scene, shader);
});

const pixels = await scene.read();

const png = new PNG({ width, height });
png.data = Buffer.from(pixels.buffer, pixels.byteOffset, pixels.byteLength);

await mkdir(dirname(out), { recursive: true });
await writeFile(out, PNG.sync.write(png));

console.log(`${out} — ${width}×${height} at t=${time}s`);

// Dawn keeps handles that hold the event loop open, so the process would sit
// there after the PNG is on disk. The work is done; leave deliberately.
process.exit(0);
