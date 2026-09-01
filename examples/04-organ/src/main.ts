import { mount } from "@gpu-in-html/harness";
import { storage } from "vgpu";
import type { StorageBuffer } from "vgpu";
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

// Two vec4f per control. The cap is generous — only the controls actually on
// screen are uploaded, and a viewport holds well under a dozen.
const MAX_FIELDS = 48;
const FIELD_STRIDE = 8;
const fieldData = new Float32Array(MAX_FIELDS * FIELD_STRIDE);
let fieldBuffer: StorageBuffer | undefined;

// Corner radius, in the shader's aspect-corrected units. Matches the CSS
// radius closely enough that the lip sits on the element's own edge.
const FIELD_RADIUS = 0.009;

// The controls the shader draws. Radios, checkboxes and the range keep their
// native rendering: they are small, the platform draws them well, and a
// depression the size of a checkbox reads as a blemish rather than a field.
const TISSUE_CONTROLS = [
  "input:not([type='radio']):not([type='checkbox']):not([type='range'])",
  "select",
  "textarea",
  "button",
].join(", ");

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
    // The shader declares a storage binding, and WebGPU requires every binding
    // to be bound before the first draw — so it has to be attached here rather
    // than after mount resolves.
    setup: (gpu, shader) => {
      fieldBuffer = storage(gpu, fieldData.byteLength);
      shader.set({ fields: fieldBuffer });
    },
    uniforms: (ctx) => {
      // Ease both, framed in deltaTime so the feel is the same at any refresh
      // rate. Scroll especially: wheel and trackpad events arrive in coarse
      // jumps, and following them literally makes the camera stutter.
      const k = 1 - Math.exp(-ctx.deltaTime * 9);
      scroll += (scrollTarget - scroll) * k;
      tone += (toneTarget - tone) * (1 - Math.exp(-ctx.deltaTime * 3.5));

      // Measured every frame, and deliberately not eased. The blanched patch
      // has to sit exactly where the browser has drawn the form; easing it
      // would let the tissue slide out from under the text during a scroll.
      // The camera's own scroll is eased, so the wall lags slightly behind the
      // page — which reads as parallax rather than as a mismatch.
      const rect = form.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const panelCenter: [number, number] = [
        (rect.left + rect.width / 2) / vw,
        (rect.top + rect.height / 2) / vh,
      ];
      const panelHalf: [number, number] = [rect.width / 2 / vw, rect.height / 2 / vh];

      // Upload the controls that are actually on screen. A page of this form
      // holds twenty-seven of them and a viewport shows under a dozen, so
      // culling keeps the shader's loop short as well as the upload.
      let fieldCount = 0;
      for (const el of form.querySelectorAll<HTMLElement>(TISSUE_CONTROLS)) {
        if (fieldCount >= MAX_FIELDS) break;
        const box = el.getBoundingClientRect();
        if (box.bottom < -80 || box.top > vh + 80) continue;

        const at = fieldCount * FIELD_STRIDE;
        fieldData[at] = (box.left + box.width / 2) / vw;
        fieldData[at + 1] = (box.top + box.height / 2) / vh;
        fieldData[at + 2] = box.width / 2 / vw;
        fieldData[at + 3] = box.height / 2 / vh;
        // The button is the one control pushed out of the wall instead of into
        // it, so it carries dark type while everything else carries light.
        fieldData[at + 4] = el.tagName === "BUTTON" ? 1 : 0;
        fieldData[at + 5] = FIELD_RADIUS;
        fieldData[at + 6] = el === document.activeElement ? 1 : 0;
        // Seed for the ragged outline. Derived from the control's position in
        // the *document*, not the viewport, so it is stable while scrolling —
        // an opening keeps the shape it had rather than reshuffling as it
        // moves up the screen.
        fieldData[at + 7] = (box.top + window.scrollY) * 0.013 + box.left * 0.006;
        fieldCount += 1;
      }
      fieldBuffer?.write(fieldData);

      const pulse = heartbeat(ctx.time * BEAT_RATE);

      if (readouts.depth) readouts.depth.textContent = `${Math.abs(scroll).toFixed(2)} m`;
      if (readouts.rate) readouts.rate.textContent = `${Math.round(BEAT_RATE * 60)} bpm`;
      if (readouts.perfusion) {
        readouts.perfusion.textContent = `${(86 + pulse * 11).toFixed(0)}%`;
      }

      return { tone, scroll, panelCenter, panelHalf, fieldCount };
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
