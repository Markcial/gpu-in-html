import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const form = document.querySelector<HTMLFormElement>("#permit");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !form || !errorEl) throw new Error("Missing #stage, #permit or #error");

// World units of street per pixel scrolled.
const UNITS_PER_PIXEL = 0.012;

let scrollTarget = 0;
let scroll = 0;

const readScroll = () => {
  scrollTarget = window.scrollY * UNITS_PER_PIXEL;
};

readScroll();
window.addEventListener("scroll", readScroll, { passive: true });

try {
  const sketch = await mount(canvas, scene, {
    dpr: 1,
    uniforms: (ctx) => {
      // Eased, because wheel and trackpad events arrive in coarse jumps and
      // following them literally makes the camera stutter.
      scroll += (scrollTarget - scroll) * (1 - Math.exp(-ctx.deltaTime * 9));

      // Measured every frame and not eased: the clearing has to sit exactly
      // where the browser drew the form.
      const box = form.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;

      // The form is about three pages tall, so most of it is off screen at any
      // moment. Only the visible slice is sent: hand the shader the whole rect
      // and the clearing grows to three screens of city, which deletes the
      // scene instead of making room in it. A little overshoot past each edge
      // keeps the plaza from ending inside the frame.
      const top = Math.max(box.top, -0.14 * vh);
      const bottom = Math.min(box.bottom, 1.14 * vh);
      const visible = Math.max(bottom - top, 0);

      return {
        scroll,
        panelCenter: [(box.left + box.width / 2) / vw, (top + bottom) / 2 / vh],
        panelHalf: [box.width / 2 / vw, visible / 2 / vh],
      };
    },
  });

  import.meta.hot?.dispose(() => {
    window.removeEventListener("scroll", readScroll);
    sketch.stop();
  });
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
