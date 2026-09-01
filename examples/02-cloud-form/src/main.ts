import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const form = document.querySelector<HTMLFormElement>("#cloud-form");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !form || !errorEl) throw new Error("Missing #stage, #cloud-form or #error");

// The form's rectangle in uv space (0..1, top-origin), which is exactly the
// space the shader works in. Measuring the real element rather than hardcoding
// a size means the cloud follows the layout through any reflow.
let center: [number, number] = [0.5, 0.5];
let half: [number, number] = [0.2, 0.15];

// An arrow const, not a function declaration: a hoisted declaration could in
// principle run before the null guard above, so TypeScript refuses to narrow
// `form` inside it.
const measure = () => {
  const rect = form.getBoundingClientRect();
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  if (vw === 0 || vh === 0) return;
  center = [(rect.left + rect.width / 2) / vw, (rect.top + rect.height / 2) / vh];
  half = [rect.width / 2 / vw, rect.height / 2 / vh];
};

measure();
new ResizeObserver(measure).observe(form);
window.addEventListener("resize", measure);

// focusin/focusout bubble, so one pair of listeners covers every field.
let focusTarget = 0;
form.addEventListener("focusin", () => {
  focusTarget = 1;
});
form.addEventListener("focusout", () => {
  focusTarget = 0;
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
});

let focus = 0;

try {
  const sketch = await mount(canvas, scene, {
    uniforms: (ctx) => {
      // Exponential smoothing toward the target. Framing it in deltaTime keeps
      // the ease identical at 60 and 120 Hz.
      focus += (focusTarget - focus) * (1 - Math.exp(-ctx.deltaTime * 8));
      return {
        cloudCenter: center,
        cloudHalf: half,
        pointer: [ctx.pointer.position[0], ctx.pointer.position[1]],
        focus,
      };
    },
  });

  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
