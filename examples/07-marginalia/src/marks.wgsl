// Marker strokes fitted to a line of text.
//
// Pure module. A line arrives as vec4f(x0, x1, top, bottom) in the same
// aspect-corrected screen space as the sample point, so a stroke drawn here is
// a stroke drawn on exactly the run of glyphs the browser laid out — not on
// the paragraph box, and not on a guess about where the text wrapped.
//
// Everything below exists to stop the marks looking machine-made. A rectangle
// snapped to a line box reads as a CSS background; what makes it read as ink
// is that the nib overshoots the start, runs dry towards the end, wanders off
// the baseline, and stops somewhere just past the last glyph rather than on
// it.

import { fbmSimplex2d, simplex2d } from "@vgpu/wgsl-std/noise/simplex";

// Ink laid down by a highlighter dragged across one line.
//
// `wet` is 1 for a line being marked right now, which keeps the nib loaded
// instead of drying out along the stroke. `progress` clips the stroke part way
// along, so a mark draws itself left to right rather than appearing whole.
export fn highlightStroke(
  p: vec2f,
  line: vec4f,
  seed: f32,
  wet: f32,
  progress: f32,
) -> f32 {
  // A highlighter does not start or stop on the text. It overshoots at the
  // start, where the hand is still moving, and trails past the last glyph.
  let lead = 0.004 + 0.007 * seed;
  let tail = 0.003 + 0.016 * fract(seed * 7.13);
  let x0 = line.x - lead;
  let x1 = line.y + tail;

  // Position along the stroke: 0 at the start, 1 at the end.
  let t = (p.x - x0) / max(x1 - x0, 1e-4);
  if (t < -0.15 || t > 1.15) {
    return 0.0;
  }

  let mid = (line.z + line.w) * 0.5;
  let halfH = (line.w - line.z) * 0.5;

  // The nib wanders off the baseline and the whole stroke sits at a slight
  // angle, because a hand does not draw parallel to a line of type.
  let wobble = simplex2d(vec2f(p.x * 9.0, seed * 40.0)) * halfH * 0.22;
  let tilt = (t - 0.5) * halfH * (seed - 0.5) * 0.55;
  let centre = mid + wobble + tilt;

  // Taller than the line box — a marker covers the ascenders — and tapered at
  // both ends where the pen touches down and lifts.
  let reach = halfH * (1.06 + 0.10 * seed);
  let ends = smoothstep(-0.03, 0.07, t) * smoothstep(1.08, 0.88, t);
  let band = smoothstep(reach, reach * 0.86, abs(p.y - centre)) * ends;

  // Streaks the width of the felt tip, and ink running out along the stroke
  // unless the line is being marked right now.
  let streak = 0.84 + 0.16 * simplex2d(vec2f(p.x * 26.0, p.y * 7.0 + seed * 10.0));
  let load = mix(mix(1.0, 0.55, smoothstep(0.3, 1.0, t)), 1.0, wet);

  // Draws itself left to right as the line is marked.
  let drawn = smoothstep(progress, progress - 0.07, t);

  return band * streak * load * drawn;
}

// A short pen stroke in the margin beside a marked line.
export fn marginTick(p: vec2f, line: vec4f, x: f32, seed: f32, progress: f32) -> f32 {
  let mid = (line.z + line.w) * 0.5;
  let halfH = (line.w - line.z) * 0.5;

  // Leans, because a vertical stroke drawn by hand is never vertical.
  let lean = (seed - 0.5) * 0.012;
  let cx = x + lean * clamp((p.y - mid) / max(halfH, 1e-4), -1.0, 1.0);

  let along = smoothstep(halfH * 0.98, halfH * 0.66, abs(p.y - mid));
  let width = 0.0016 + 0.0012 * seed;
  let nib = smoothstep(width, width * 0.3, abs(p.x - cx));

  // The tick appears once its line's mark is well under way, so the eye reads
  // the highlight first and the annotation second.
  return nib * along * smoothstep(0.35, 0.75, progress);
}

// Paper: fibre at the pixel scale and blotches at the page scale. Returns a
// multiplier around 1, so the caller keeps ownership of the paper's colour.
export fn paper(uv: vec2f) -> f32 {
  let fibre = fbmSimplex2d(uv * vec2f(340.0, 270.0), 3, 2.1, 0.55);
  let blotch = fbmSimplex2d(uv * 4.5, 3, 2.0, 0.5);
  return 1.0 - 0.030 * fibre - 0.022 * max(blotch, 0.0);
}
