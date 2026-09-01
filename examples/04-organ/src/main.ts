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

// Radians per second of the wall's breathing dilation (BREATH_RATE in
// organ.wgsl — keep the two in step). The readout derives its phase from the
// same constant rather than counting frames, so a dropped frame cannot drift
// it away from what is on screen.
const BREATH_RATE = 0.16;

try {
  const sketch = await mount(canvas, scene, {
    // A raymarched frame is far more expensive than a fullscreen gradient.
    // Rendering it at 2× device pixels buys nothing you can see.
    dpr: 1,
    uniforms: (ctx) => {
      tone += (target - tone) * (1 - Math.exp(-ctx.deltaTime * 3.5));

      // Same phase the shader dilates the wall with, so the number and the
      // picture breathe together.
      const breath = Math.sin(ctx.time * BREATH_RATE) * 0.5 + 0.5;

      if (readouts.depth) {
        readouts.depth.textContent = `${(88 + breath * 9).toFixed(0)}%`;
      }
      if (readouts.tone) readouts.tone.textContent = `${(tone * 100).toFixed(0)}%`;
      if (readouts.mucosa) {
        readouts.mucosa.textContent = tone > 0.7 ? "contracted" : "relaxed";
      }

      return { tone };
    },
  });

  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
