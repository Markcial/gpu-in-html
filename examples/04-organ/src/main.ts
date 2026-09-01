import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const form = document.querySelector<HTMLFormElement>("#intake");
const toneInput = document.querySelector<HTMLInputElement>("#tone");
const toneValue = document.querySelector<HTMLSpanElement>("#tone-value");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !form || !toneInput || !toneValue || !errorEl) {
  throw new Error("Missing #stage, #intake, #tone, #tone-value or #error");
}

const readouts = {
  depth: document.querySelector<HTMLSpanElement>("#r-depth"),
  rate: document.querySelector<HTMLSpanElement>("#r-rate"),
  perfusion: document.querySelector<HTMLSpanElement>("#r-perfusion"),
};

// Beats per second (BEAT_RATE in organ.wgsl — keep the two in step). The
// readouts derive their phase from the same constant rather than counting
// frames, so a dropped frame cannot drift them away from what is on screen.
const BEAT_RATE = 0.8;

// The same waveform the shader dilates the wall with: a strong pulse, a weaker
// one after it, then a pause.
const heartbeat = (beats: number) => {
  const phase = beats - Math.floor(beats);
  const systole = Math.exp(-(((phase - 0.1) * 13) ** 2));
  const second = Math.exp(-(((phase - 0.27) * 15) ** 2)) * 0.5;
  return systole + second;
};

// World units travelled along the wall per pixel scrolled. Low enough that a
// full page of form covers a couple of units — far enough to see new tissue,
// short enough that the wall does not blur past.
const UNITS_PER_PIXEL = 0.0016;

let scrollTarget = 0;
let scroll = 0;

const readScroll = () => {
  scrollTarget = -window.scrollY * UNITS_PER_PIXEL;
};

readScroll();
// Passive: this listener never calls preventDefault, and saying so lets the
// browser keep scrolling on the compositor instead of waiting on it.
window.addEventListener("scroll", readScroll, { passive: true });

let toneTarget = Number(toneInput.value) / 100;
let tone = toneTarget;

toneInput.addEventListener("input", () => {
  toneTarget = Number(toneInput.value) / 100;
  toneValue.textContent = `${toneInput.value}%`;
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
});

try {
  const sketch = await mount(canvas, scene, {
    // A raymarched frame is far more expensive than a fullscreen gradient.
    // Rendering it at 2× device pixels buys nothing you can see.
    dpr: 1,
    uniforms: (ctx) => {
      // Ease both, framed in deltaTime so the feel is the same at any refresh
      // rate. Scroll especially: wheel and trackpad events arrive in coarse
      // jumps, and following them literally makes the camera stutter.
      const k = 1 - Math.exp(-ctx.deltaTime * 9);
      scroll += (scrollTarget - scroll) * k;
      tone += (toneTarget - tone) * (1 - Math.exp(-ctx.deltaTime * 3.5));

      const pulse = heartbeat(ctx.time * BEAT_RATE);

      if (readouts.depth) readouts.depth.textContent = `${Math.abs(scroll).toFixed(2)} m`;
      if (readouts.rate) readouts.rate.textContent = `${Math.round(BEAT_RATE * 60)} bpm`;
      if (readouts.perfusion) {
        readouts.perfusion.textContent = `${(86 + pulse * 11).toFixed(0)}%`;
      }

      return { tone, scroll };
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
