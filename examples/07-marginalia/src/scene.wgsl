// Entry shader: a page that highlights itself, line by line.
//
// Every other DOM-coupled example in this repo hands the shader one rectangle
// — a form, a panel, a block. This one goes a level down. `Range.getClientRects()`
// returns one rectangle per *line box*, so the browser reports exactly where
// each wrapped line of real, selectable text ended up, and the shader gets an
// array of them.
//
// That is the whole point of the example. Line breaking is the one thing a
// shader genuinely cannot do: it depends on the font file, the hyphenation
// dictionary, the reader's zoom and their font-size preference. So the browser
// does it, and the shader marks the result. The ragged right-hand edge of the
// highlighting is not noise — it is where each line of text actually stops.

import { highlightStroke, marginTick, paper } from "./marks.wgsl";
import { applyGrain, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3 } from "@vgpu/wgsl-std/color";
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

// Enough for a screenful of lines with room to spare either side. The page can
// be any length: only the lines currently on screen are ever sent.
const MAX_LINES: u32 = 48u;

struct Params {
  resolution: vec2f,
  pointer: vec2f,
  time: f32,
  lineCount: f32,
  marginX: f32,
  sweep: f32,
  lines: array<vec4f, 48>,
}

@group(0) @binding(0) var<uniform> params: Params;

const PAPER: vec3f = vec3f(0.960, 0.949, 0.925);
const HIGHLIGHT: vec3f = vec3f(1.0, 0.74, 0.13);
const PEN: vec3f = vec3f(0.16, 0.22, 0.46);

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let aspect = params.resolution.x / max(params.resolution.y, 1e-4);

  // Work in a space where x and y are the same physical size, so a stroke's
  // wobble and its round ends are not stretched by the window's shape.
  let p = vec2f(uv.x * aspect, uv.y);
  let pointer = vec2f(params.pointer.x * aspect, params.pointer.y);

  var col = srgbToLinear3(PAPER) * paper(uv);

  let count = u32(clamp(params.lineCount, 0.0, f32(MAX_LINES)));
  for (var i = 0u; i < count; i++) {
    let raw = params.lines[i];
    let line = vec4f(raw.x * aspect, raw.y * aspect, raw.z, raw.w);

    let mid = (line.z + line.w) * 0.5;
    let halfH = (line.w - line.z) * 0.5;

    // Most pixels are nowhere near most lines. Rejecting on y first is what
    // keeps a per-pixel loop over the whole screenful cheap.
    if (abs(p.y - mid) > halfH * 2.5) {
      continue;
    }

    let seed = unitFloat(pcg2d(vec2u(i + 1u, 733u)).x);

    // Hovering a line inks it immediately, wherever it is on the page.
    let hovered = step(line.z, pointer.y) * step(pointer.y, line.w)
      * step(line.x - 0.02, pointer.x) * step(pointer.x, line.y + 0.03);

    // Otherwise a line is marked as it rises past the sweep, and the stroke
    // draws itself across while it does.
    let progress = max(smoothstep(params.sweep + 0.04, params.sweep - 0.10, line.z), hovered);
    if (progress < 0.002) {
      continue;
    }

    // Highlighter is transparent ink: it multiplies the paper rather than
    // covering it, which is why the fibre still shows through a mark.
    let stroke = highlightStroke(p, line, seed, hovered, progress);
    col *= mix(vec3f(1.0), srgbToLinear3(HIGHLIGHT), stroke * 0.94);

    // The margin tick is opaque, being a pen.
    let tick = marginTick(p, line, params.marginX * aspect, seed, progress);
    col = mix(col, srgbToLinear3(PEN), tick * 0.85);
  }

  col *= 1.0 - vignette(uv, 0.30, 0.72) * 0.5;
  col = applyGrain(col, uv, params.resolution, params.time, 0.010);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
