// Direct vgpu again rather than the shared harness: this needs a ping-pong
// pair of offscreen targets, ten passes per frame into them, and a sampler —
// none of which the harness's single fullscreen effect covers.

import { clock, effect, frameLoop, init, pingPong, sampler, surface } from "vgpu";

import display from "./display.wgsl";
import step from "./step.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const errorEl = document.querySelector<HTMLPreElement>("#error");
const resetButton = document.querySelector<HTMLButtonElement>("#reseed");

if (!canvas || !errorEl) throw new Error("Missing #stage or #error");

// Reaction steps per displayed frame. Stepped once per frame the culture
// creeps; sixteen is fast enough to watch a front advance and cheap enough at
// this grid size.
const STEPS_PER_FRAME = 16;

// The state grid runs at half the window's pixels. Diffusion is defined in
// texels, so a coarser grid is not just cheaper — it makes the features larger
// and the pattern legible instead of hair-fine.
const STATE_SCALE = 0.42;
const MAX_OBSTACLES = 24;

type Box = [number, number, number, number];

const boxes: Box[] = Array.from({ length: MAX_OBSTACLES }, () => [-9, -9, 0, 0]);
let focused: Box = [0, 0, 0, 0];

let pointer: [number, number] = [-1, -1];
let pointerRadius = 0;
let painting = 0;

window.addEventListener("pointermove", (event) => {
  const rect = canvas.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return;
  const aspect = rect.width / rect.height;
  pointer = [((event.clientX - rect.left) / rect.width) * aspect, (event.clientY - rect.top) / rect.height];
  pointerRadius = 0.05;
});
window.addEventListener("pointerdown", () => {
  painting = 1;
});
window.addEventListener("pointerup", () => {
  painting = 0;
});
window.addEventListener("pointerleave", () => {
  pointerRadius = 0;
  painting = 0;
});

const measure = (aspect: number): number => {
  const vw = window.innerWidth;
  const vh = window.innerHeight;

  // Where a focused field's inoculation goes. Not on the field: the field is
  // inside a rectangle the reaction holds inert, so a seed placed there is
  // wiped on the next step. It goes just outside the containing box, level
  // with the field, where there is live medium to take.
  focused = [0, 0, 0, 0];
  const active = document.activeElement;
  if (active instanceof HTMLElement) {
    const host = active.closest<HTMLElement>("[data-solid]");
    if (host && host !== active) {
      const field = active.getBoundingClientRect();
      const box = host.getBoundingClientRect();
      focused = [
        ((box.right + 26) / vw) * aspect,
        (field.top + field.height / 2) / vh,
        0.05,
        0,
      ];
    }
  }

  let n = 0;
  for (const el of document.querySelectorAll<HTMLElement>("[data-solid]")) {
    if (n === MAX_OBSTACLES) break;

    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) continue;
    if (rect.bottom < -0.3 * vh || rect.top > 1.3 * vh) continue;

    const box = boxes[n];
    if (!box) break;
    box[0] = ((rect.left + rect.width / 2) / vw) * aspect;
    box[1] = (rect.top + rect.height / 2) / vh;
    box[2] = ((rect.width / 2) / vw) * aspect;
    box[3] = rect.height / 2 / vh;

    n++;
  }

  for (let i = n; i < MAX_OBSTACLES; i++) {
    const box = boxes[i];
    if (box) {
      box[0] = -9;
      box[1] = -9;
      box[2] = 0;
      box[3] = 0;
    }
  }

  return n;
};

try {
  const gpu = await init();
  const output = surface(gpu, canvas, { dpr: [1, 2] });
  const time = clock(gpu);

  const stateSize = (): [number, number] => [
    Math.max(2, Math.round(output.size[0] * STATE_SCALE)),
    Math.max(2, Math.round(output.size[1] * STATE_SCALE)),
  ];

  let [stateWidth, stateHeight] = stateSize();
  // rgba16float, not the default rgba8unorm: a step of this reaction moves a
  // concentration by less than one 8-bit level, so in bytes the whole system
  // quantises to a standstill.
  const state = pingPong(gpu, stateWidth, stateHeight, { format: "rgba16float" });

  const advance = effect(gpu, step);
  const present = effect(gpu, display, { set: { stateSampler: sampler(gpu) } });

  // One frame of reset is enough: every step in it writes the initial
  // condition, and there are more steps per frame than halves in the pair.
  let reseedNext = true;
  const reseed = () => {
    reseedNext = true;
  };
  resetButton?.addEventListener("click", reseed);

  frameLoop(gpu, (frame) => {
    const [width, height] = output.size;
    const aspect = width / Math.max(height, 1);

    const [wantWidth, wantHeight] = stateSize();
    if (wantWidth !== stateWidth || wantHeight !== stateHeight) {
      // resize() rather than a fresh pair: the halves belong to the gpu and are
      // only destroyed with it, so allocating a new pair per resize would leak
      // one for every pixel the window is dragged through.
      state.read.resize([wantWidth, wantHeight]);
      state.write.resize([wantWidth, wantHeight]);
      stateWidth = wantWidth;
      stateHeight = wantHeight;
      reseed();
    }

    const obstacleCount = measure(aspect);

    // Uniforms are set once for the whole frame, and only the state binding
    // changes between steps. This is not a style choice: every pass encoded
    // into one frame shares a single uniform buffer, and set() writes that
    // buffer immediately rather than recording a value into the command
    // stream. Change a uniform between two passes of the same frame and both
    // passes see the second value — the last write wins for all of them.
    //
    // That is what makes a ping-pong loop a trap. Sixteen steps that each set
    // their own `reset` flag all run with whatever the sixteenth asked for, so
    // the initial condition is never written and the plate stays empty for
    // ever. A bind group is recorded per pass, so `state` may alternate; a
    // uniform may not.
    const reset = reseedNext ? 1 : 0;
    reseedNext = false;

    advance.set({
      params: {
        resolution: [stateWidth, stateHeight],
        time: time.time,
        aspect,
        reset,
        obstacleCount,
        pointerRadius,
        seedStrength: painting ? 0.9 : 0.0,
        pointer,
        focused,
        obstacles: boxes,
      },
    });

    for (let i = 0; i < STEPS_PER_FRAME; i++) {
      advance.set({ state: state.read });
      frame.pass({ target: state.write, clear: false }, advance);
      state.swap();
    }

    present.set({
      params: {
        resolution: [width, height],
        time: time.time,
        aspect,
        obstacleCount,
        obstacles: boxes,
      },
      state: state.read,
    });
    frame.pass({ target: output, clear: false }, present);
  });
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
