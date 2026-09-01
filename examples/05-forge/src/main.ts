// Nothing here is unusual, and that is the point of the trial's second pass:
// TypeGPU composed the scene at build time, and by the time the browser runs
// this it is looking at an ordinary vgpu shader.

import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !errorEl) throw new Error("Missing #stage or #error");

try {
  const sketch = await mount(canvas, scene, { dpr: 1 });
  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
