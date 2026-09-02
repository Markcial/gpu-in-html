import { mount } from "@gpu-in-html/harness";
import scene from "./scene.wgsl";

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const article = document.querySelector<HTMLElement>("#page");
const errorEl = document.querySelector<HTMLPreElement>("#error");

if (!canvas || !article || !errorEl) throw new Error("Missing #stage, #page or #error");

// Must match the array length in scene.wgsl. Only the lines currently on
// screen are ever sent, so this is a screenful plus slack, not a page limit.
const MAX_LINES = 48;

/** One line box of laid-out text, in document coordinates. */
interface Line {
  x0: number;
  x1: number;
  top: number;
  bottom: number;
}

let lines: Line[] = [];

// The measurement. `Range.getClientRects()` over an element's contents returns
// one rectangle per line box — this is the browser reporting where its own
// line breaking landed, which is the thing the shader cannot work out.
//
// Rectangles come back in viewport coordinates, so they are stored in document
// coordinates instead: scrolling moves the text on screen without relaying it
// out, so the measurement survives a scroll and only a resize invalidates it.
const measure = () => {
  const scrollX = window.scrollX;
  const scrollY = window.scrollY;

  // Keyed by rounded top edge. An inline element inside a line — a <em>, a
  // <code> — produces its own rectangle for that line, so the fragments of one
  // visual line are merged back into the run they came from.
  const byRow = new Map<number, Line>();

  for (const block of article.querySelectorAll<HTMLElement>("h1, h2, p, li")) {
    const range = document.createRange();
    range.selectNodeContents(block);

    for (const rect of range.getClientRects()) {
      // Collapsed rectangles at the seams between inline elements.
      if (rect.width < 3 || rect.height < 5) continue;

      const key = Math.round((rect.top + scrollY) * 2);
      const found = byRow.get(key);
      if (found) {
        found.x0 = Math.min(found.x0, rect.left + scrollX);
        found.x1 = Math.max(found.x1, rect.right + scrollX);
        found.bottom = Math.max(found.bottom, rect.bottom + scrollY);
      } else {
        byRow.set(key, {
          x0: rect.left + scrollX,
          x1: rect.right + scrollX,
          top: rect.top + scrollY,
          bottom: rect.bottom + scrollY,
        });
      }
    }
  }

  lines = [...byRow.values()].sort((a, b) => a.top - b.top);
};

measure();
window.addEventListener("resize", measure);

// Line boxes move when the text reflows, which a resize listener alone misses:
// an image loading, a details element opening, the scrollbar appearing.
const observer = new ResizeObserver(measure);
observer.observe(article);

// Web fonts change every metric in the page, and they land after first paint.
document.fonts?.ready.then(measure);

// Reused every frame: the pack is a hot path and there is no reason to hand
// the GC forty-eight short-lived arrays a frame.
type Packed = [number, number, number, number];
const packed: Packed[] = Array.from({ length: MAX_LINES }, () => [0, 0, -9, -9]);
const park = (slot: Packed) => {
  slot[0] = 0;
  slot[1] = 0;
  slot[2] = -9;
  slot[3] = -9;
};

try {
  const sketch = await mount(canvas, scene, {
    dpr: [1, 2],
    uniforms: (ctx) => {
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const scrollY = window.scrollY;

      // Only what is on screen, with a little slack past each edge so a mark
      // is never seen to begin or end at the frame boundary.
      let n = 0;
      for (const line of lines) {
        if (n === MAX_LINES) break;
        const top = line.top - scrollY;
        const bottom = line.bottom - scrollY;
        if (bottom < -0.1 * vh || top > 1.1 * vh) continue;

        const slot = packed[n];
        if (!slot) break;
        slot[0] = line.x0 / vw;
        slot[1] = line.x1 / vw;
        slot[2] = top / vh;
        slot[3] = bottom / vh;
        n++;
      }

      // Unused slots are parked off screen rather than left stale.
      for (let i = n; i < MAX_LINES; i++) {
        const slot = packed[i];
        if (slot) park(slot);
      }

      const column = article.getBoundingClientRect();

      return {
        pointer: [ctx.pointer.position[0], ctx.pointer.position[1]],
        lineCount: n,
        // Where the annotator's pen rests, just outside the text column.
        marginX: (column.left - 26) / vw,
        // Lines above this height on screen have been read, and get marked.
        sweep: 0.66,
        lines: packed,
      };
    },
  });

  import.meta.hot?.dispose(() => {
    window.removeEventListener("resize", measure);
    observer.disconnect();
    sketch.stop();
  });
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
