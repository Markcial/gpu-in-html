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

      // Measured every frame and not eased: the paint has to sit exactly where
      // the browser drew the form.
      const box = form.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;

      // The fold eases in over the first stretch of street and then holds, so
      // the top of the page is an ordinary street and the bend is something
      // you scroll into.
      const fold = Math.min(scroll * 0.026, 0.32);

      return {
        scroll,
        fold,
        panelCenter: [(box.left + box.width / 2) / vw, (box.top + box.height / 2) / vh],
        panelHalf: [box.width / 2 / vw, box.height / 2 / vh],
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
