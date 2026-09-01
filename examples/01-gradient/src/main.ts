import { mount } from "@gpu-in-html/harness";
import gradient from "./gradient.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !errorEl) throw new Error("Missing #stage or #error in the document");

try {
  const sketch = await mount(canvas, gradient);
  // Vite replaces this module on edit; tear the old GPU loop down first.
  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  // WebGPU missing or the shader failed to compile — say so on the page
  // instead of leaving a silent black canvas.
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
