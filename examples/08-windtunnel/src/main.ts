// This example talks to vgpu directly rather than through the shared harness.
// The harness mounts one fullscreen effect; this needs a storage buffer, a
// compute dispatch and an instanced draw, and showing that plumbing is half
// the point of the example.

import { clock, compute, draw, effect, frameLoop, init, storage, surface } from "vgpu";

import field from "./field.wgsl";
import simulate from "./simulate.wgsl";
import streaks from "./streaks.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const errorEl = document.querySelector<HTMLPreElement>("#error");
const countEl = document.querySelector<HTMLElement>("#count");

if (!canvas || !errorEl) throw new Error("Missing #stage or #error");

const PARTICLES = 20_000;
const FLOATS_PER_PARTICLE = 8; // position, velocity, seed, life, two pads
const WORKGROUP = 64; // matches @workgroup_size in simulate.wgsl
const MAX_OBSTACLES = 24; // matches the array length in both shaders

/** Page space: x runs 0..aspect, y runs 0..1 top-origin. */
type Box = [number, number, number, number];

const boxes: Box[] = Array.from({ length: MAX_OBSTACLES }, () => [0, 0, 0, 0]);

// How much each measured element is currently swollen. Focus and hover push it
// up, and it eases back down — the air has to have something to do when you
// interact with the page, and a rectangle that snapped would read as a bug.
const swell = new WeakMap<Element, number>();

let pointer: [number, number] = [-1, -1];
let pointerRadius = 0.0;

window.addEventListener("pointermove", (event) => {
  const rect = canvas.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return;
  const aspect = rect.width / rect.height;
  pointer = [((event.clientX - rect.left) / rect.width) * aspect, (event.clientY - rect.top) / rect.height];
  pointerRadius = 0.045;
});
window.addEventListener("pointerleave", () => {
  pointerRadius = 0;
});

const measure = (aspect: number, dt: number): number => {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const solids = document.querySelectorAll<HTMLElement>("[data-solid]");

  let n = 0;
  for (const el of solids) {
    if (n === MAX_OBSTACLES) break;

    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) continue;
    // Off screen: still measured, because an element about to scroll into
    // frame has to already be deflecting air when it arrives.
    if (rect.bottom < -0.4 * vh || rect.top > 1.4 * vh) continue;

    // Only controls swell on hover. A container that grew by a sixth would
    // pull its rim light well clear of the box the reader can actually see.
    const interactive = el.matches("input, select, button, textarea, a");
    const active = el === document.activeElement || (interactive && el.matches(":hover"));
    const wanted = active ? 1.18 : 1.0;
    const current = swell.get(el) ?? 1.0;
    const eased = current + (wanted - current) * Math.min(dt * 7, 1);
    swell.set(el, eased);

    const box = boxes[n];
    if (!box) break;
    box[0] = ((rect.left + rect.width / 2) / vw) * aspect;
    box[1] = (rect.top + rect.height / 2) / vh;
    box[2] = ((rect.width / 2) / vw) * aspect * eased;
    box[3] = (rect.height / 2 / vh) * eased;
    n++;
  }

  for (let i = n; i < MAX_OBSTACLES; i++) {
    const box = boxes[i];
    // Parked far off screen rather than left stale, and given zero size so it
    // cannot deflect anything even if it were reached.
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

  // Seeded once, on the host, and never read back. Everything after this
  // happens on the GPU.
  const seed = new Float32Array(PARTICLES * FLOATS_PER_PARTICLE);
  for (let i = 0; i < PARTICLES; i++) {
    const o = i * FLOATS_PER_PARTICLE;
    seed[o + 0] = Math.random() * 2.2 - 0.2;
    seed[o + 1] = Math.random();
    seed[o + 2] = 0.30 + Math.random() * 0.2;
    seed[o + 3] = 0;
    seed[o + 4] = Math.random();
    // Staggered, so the field does not turn over all at once a few seconds in.
    seed[o + 5] = 0.5 + Math.random() * 9;
  }

  const particles = storage(gpu, seed.byteLength, "read-write");
  particles.write(seed);

  const sim = compute(gpu, simulate, { set: { particles } });
  const background = effect(gpu, field);
  const air = draw(gpu, {
    shader: streaks,
    vertices: 6,
    instances: PARTICLES,
    blend: "additive",
    set: { particles },
  });

  if (countEl) countEl.textContent = PARTICLES.toLocaleString();

  frameLoop(gpu, (frame) => {
    const [width, height] = output.size;
    const aspect = width / Math.max(height, 1);

    // A tab that was in the background hands back one enormous delta; stepping
    // the simulation by it would fling every particle off the page.
    const dt = Math.min(time.deltaTime, 1 / 30);
    const obstacleCount = measure(aspect, dt);

    sim.set({
      sim: {
        pointer,
        aspect,
        time: time.time,
        dt,
        count: PARTICLES,
        obstacleCount,
        pointerRadius,
        obstacles: boxes,
      },
    });
    // Its own encoder, submitted immediately, so the simulation is on the
    // queue ahead of the frame that reads it.
    sim.dispatch(Math.ceil(PARTICLES / WORKGROUP));

    background.set({
      params: {
        resolution: [width, height],
        time: time.time,
        aspect,
        obstacleCount,
        pointerRadius,
        pointer,
        obstacles: boxes,
      },
    });
    air.set({
      render: { aspect, stretch: 0.055, width: 0.0011, fade: 0.30 },
    });

    frame.pass({ target: output, clear: [0.043, 0.055, 0.078, 1] }, background);
    frame.pass({ target: output, clear: false }, air);
  });
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
