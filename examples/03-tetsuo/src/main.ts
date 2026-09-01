import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const panel = document.querySelector<HTMLElement>("#panel");
const slider = document.querySelector<HTMLInputElement>("#mutation");
const status = document.querySelector<HTMLParagraphElement>("#status");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !panel || !slider || !status || !errorEl) {
  throw new Error("Missing #stage, #panel, #mutation, #status or #error");
}

const readouts = {
  output: document.querySelector<HTMLSpanElement>("#r-output"),
  mass: document.querySelector<HTMLSpanElement>("#r-mass"),
  lobes: document.querySelector<HTMLSpanElement>("#r-lobes"),
  core: document.querySelector<HTMLSpanElement>("#r-core"),
};

let target = Number(slider.value) / 100;
let mutation = target;

slider.addEventListener("input", () => {
  target = Number(slider.value) / 100;
});

// The panel is plain DOM, but the shader's state is what it reports — the same
// number drives the geometry and the readouts, so they cannot disagree.
const paint = (value: number) => {
  const level = value > 0.72 ? "critical" : "stable";
  if (panel.dataset.level !== level) {
    panel.dataset.level = level;
    status.textContent =
      level === "critical" ? "Containment failing" : "Within tolerance";
  }

  if (readouts.output) readouts.output.textContent = `${(value * 100).toFixed(1)}%`;
  if (readouts.mass) readouts.mass.textContent = `${(0.84 + value * 0.14).toFixed(3)} u`;
  if (readouts.lobes) readouts.lobes.textContent = value > 0.04 ? "6 active" : "dormant";
  if (readouts.core) readouts.core.textContent = `${(310 + value * 690).toFixed(0)} K`;
};

paint(mutation);

try {
  const sketch = await mount(canvas, scene, {
    // A raymarched frame is far more expensive than a fullscreen gradient.
    // Rendering it at 2× device pixels buys nothing you can see and costs
    // roughly four times the work, so pin the ratio at 1.
    dpr: 1,
    uniforms: (ctx) => {
      mutation += (target - mutation) * (1 - Math.exp(-ctx.deltaTime * 3.5));
      paint(mutation);
      return {
        pointer: [ctx.pointer.position[0], ctx.pointer.position[1]],
        mutation,
      };
    },
  });

  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
