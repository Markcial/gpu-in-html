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
import { effect, frame, init, pingPong, sampler, target } from "vgpu/node";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: "string", short: "o" },
    width: { type: "string", short: "w", default: "1200" },
    height: { type: "string", short: "h", default: "675" },
    time: { type: "string", short: "t", default: "0" },
    set: { type: "string", short: "s" },
    feedback: { type: "string", short: "f" },
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

// A feedback shader cannot be rendered in one pass: it reads its own previous
// output, so there is nothing to read until it has been run. With `--feedback`
// the entry is treated as the step, iterated against a ping-pong pair, and a
// second shader turns the settled state into pixels — the same two shaders the
// page runs, just wound forward off screen instead of over several seconds.
//
//   -f '{"steps":20000,"scale":0.42,"display":"examples/09-culture/src/display.wgsl"}'
//
// `state` is the binding name both shaders use for the pair, and `reset` is how
// many opening steps run with params.reset = 1 to lay down the initial
// condition.
const feedback = values.feedback ? JSON.parse(values.feedback) : null;

if (feedback) {
  const scale = feedback.scale ?? 0.5;
  const stateWidth = Math.max(2, Math.round(width * scale));
  const stateHeight = Math.max(2, Math.round(height * scale));
  const state = pingPong(gpu, stateWidth, stateHeight, {
    format: feedback.format ?? "rgba16float",
  });

  const step = effect(gpu, resolved.wgsl);
  const displayResolved = await resolveShader({
    entry: resolvePath(feedback.display),
    validate: "auto",
  });
  const present = effect(gpu, displayResolved.wgsl, { set: { stateSampler: sampler(gpu) } });

  const steps = feedback.steps ?? 2000;
  const resets = feedback.reset ?? 2;

  // Uniforms are set once per frame and only `state` alternates between
  // passes. Every pass in a frame shares one uniform buffer — set() writes it
  // straight away instead of recording it into the command stream — so a
  // value changed between two passes of the same frame applies to both. The
  // reset therefore gets a frame of its own rather than the first two passes
  // of a long one, or the initial condition is overwritten by the reaction's
  // params before anything is submitted and the state stays empty.
  const stepParams = (reset) => ({
    // `reset` last: the feedback driver owns it, and a manifest that also
    // names it must not be able to hold the initial condition off.
    params: { resolution: [stateWidth, stateHeight], time, ...extra, reset },
  });

  step.set(stepParams(1));
  frame(gpu, (currentFrame) => {
    for (let i = 0; i < resets; i++) {
      step.set({ state: state.read });
      currentFrame.pass({ target: state.write, clear: false }, step);
      state.swap();
    }
  });

  // Chunked, because one command encoder holding twenty thousand render passes
  // is a lot of memory to hand the driver at once for no benefit.
  const CHUNK = 500;
  step.set(stepParams(0));
  for (let done = 0; done < steps; done += CHUNK) {
    frame(gpu, (currentFrame) => {
      for (let i = done; i < Math.min(done + CHUNK, steps); i++) {
        step.set({ state: state.read });
        currentFrame.pass({ target: state.write, clear: false }, step);
        state.swap();
      }
    });
  }

  if (feedback.debug) {
    const px = await state.read.readFloats();
    let maxB = 0;
    let sumB = 0;
    for (let i = 1; i < px.length; i += 4) {
      maxB = Math.max(maxB, px[i]);
      sumB += px[i];
    }
    console.log(`state ${stateWidth}x${stateHeight} maxB=${maxB.toFixed(4)} meanB=${(sumB / (px.length / 4)).toFixed(5)}`);
  }

  present.set({
    params: {
      resolution: [width, height],
      time,
      ...extra,
      ...(feedback.displaySet ?? {}),
    },
    state: state.read,
  });
  frame(gpu, (currentFrame) => {
    currentFrame.pass(scene, present);
  });
} else {
  const shader = effect(gpu, resolved.wgsl, {
    set: { params: { resolution: [width, height], time, ...extra } },
  });

  frame(gpu, (currentFrame) => {
    currentFrame.pass(scene, shader);
  });
}

const pixels = await scene.read();

const png = new PNG({ width, height });
png.data = Buffer.from(pixels.buffer, pixels.byteOffset, pixels.byteLength);

await mkdir(dirname(out), { recursive: true });
await writeFile(out, PNG.sync.write(png));

console.log(`${out} — ${width}×${height} at t=${time}s`);

// Dawn keeps handles that hold the event loop open, so the process would sit
// there after the PNG is on disk. The work is done; leave deliberately.
process.exit(0);
