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
  rate: document.querySelector<HTMLSpanElement>("#r-rate"),
};

let target = Number(slider.value) / 100;
let tone = target;

slider.addEventListener("input", () => {
  target = Number(slider.value) / 100;
});

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

try {
  const sketch = await mount(canvas, scene, {
    // A raymarched frame is far more expensive than a fullscreen gradient.
    // Rendering it at 2× device pixels buys nothing you can see.
    dpr: 1,
    uniforms: (ctx) => {
      tone += (target - tone) * (1 - Math.exp(-ctx.deltaTime * 3.5));

      // Same waveform the shader moves the wall with, so the number and the
      // picture beat together.
      const pulse = heartbeat(ctx.time * BEAT_RATE);

      if (readouts.depth) {
        readouts.depth.textContent = `${(86 + pulse * 11).toFixed(0)}%`;
      }
      if (readouts.rate) readouts.rate.textContent = `${Math.round(BEAT_RATE * 60)} bpm`;
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
