// The sky behind the form: vertical gradient, a broad sun glow, and drifting
// cirrus. Pure module — no bindings, everything arrives as arguments.

import { fbmSimplex2d } from "@vgpu/wgsl-std/noise/simplex";
import { srgbToLinear3 } from "@vgpu/wgsl-std/color";
import { saturate } from "@vgpu/wgsl-std/math";

// Sky colour in linear light. `uv` is top-origin, so uv.y = 0 is the zenith.
// `parallax` shifts the cirrus layer only, which is what sells the depth.
//
// Palette constants are written as sRGB — the values you would pick in a
// colour picker — and converted once. Using them raw would treat a mid blue as
// if it were four times brighter than it looks, and the sky washes out.
export fn skyColor(uv: vec2f, aspect: f32, time: f32, parallax: vec2f) -> vec3f {
  let zenith = srgbToLinear3(vec3f(0.11, 0.35, 0.76));
  let horizon = srgbToLinear3(vec3f(0.71, 0.87, 0.97));
  var col = mix(zenith, horizon, pow(saturate(uv.y), 1.35));

  // Aspect-corrected coordinates, so the sun stays round on any canvas.
  let p = vec2f(uv.x * aspect, uv.y);

  // Sun high on the left. A glow, not a disc — a disc would fight the form.
  let sun = vec2f(0.20 * aspect, 0.06);
  let glow = exp(-length(p - sun) * 3.4);
  col += srgbToLinear3(vec3f(1.0, 0.88, 0.66)) * glow * 0.45;

  // Cirrus: noise stretched sideways and drifting, faded at the zenith and at
  // the horizon so the bands sit in a believable layer instead of tiling the
  // whole frame.
  let cp = vec2f(p.x * 1.7, uv.y * 5.0) + parallax + vec2f(time * 0.015, 0.0);
  let n = fbmSimplex2d(cp, 5, 2.0, 0.5);
  let band = smoothstep(0.18, 0.72, n)
    * smoothstep(0.02, 0.35, uv.y)
    * (1.0 - smoothstep(0.55, 0.92, uv.y));
  col = mix(col, srgbToLinear3(vec3f(1.0, 0.99, 0.98)), band * 0.38);

  return col;
}
