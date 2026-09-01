import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const slider = document.querySelector<HTMLInputElement>("#tone");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !slider || !errorEl) throw new Error("Missing #stage, #tone or #error");

const readouts = {
  depth: document.querySelector<HTMLSpanElement>("#r-depth"),
  tone: document.querySelector<HTMLSpanElement>("#r-tone"),
  mucosa: document.querySelector<HTMLSpanElement>("#r-mucosa"),
};

let target = Number(slider.value) / 100;
let tone = target;

slider.addEventListener("input", () => {
  target = Number(slider.value) / 100;
});

// The view drifts along the wall at this rate on its own (DRIFT in
// scene.wgsl — keep the two in step). The readout derives its station from the
// same constant rather than counting frames, so a dropped frame cannot drift
// it away from what is on screen. The pointer moves the camera too, and this
// number deliberately ignores that: it reports the survey's own progress.
const DRIFT_PER_SECOND = 0.055;

try {
  const sketch = await mount(canvas, scene, {
    // A raymarched frame is far more expensive than a fullscreen gradient.
    // Rendering it at 2× device pixels buys nothing you can see.
    dpr: 1,
    uniforms: (ctx) => {
      tone += (target - tone) * (1 - Math.exp(-ctx.deltaTime * 3.5));

      if (readouts.depth) {
        readouts.depth.textContent = `${(ctx.time * DRIFT_PER_SECOND).toFixed(2)} m`;
      }
      if (readouts.tone) readouts.tone.textContent = `${(tone * 100).toFixed(0)}%`;
      if (readouts.mucosa) {
        readouts.mucosa.textContent = tone > 0.7 ? "contracted" : "relaxed";
      }

      return {
        pointer: [ctx.pointer.position[0], ctx.pointer.position[1]],
        tone,
      };
    },
  });

  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
