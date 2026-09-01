// The cloud that acts as the form's chrome.
//
// Pure module. The shape is built from the form's real measured rectangle, so
// the silhouette always contains the inputs no matter how the page reflows.

import {
  sdCircle,
  sdRoundedBox,
  opSmoothUnion,
  opSmoothIntersect,
} from "@gpu-in-html/wgsl/shape2d";
import { fbmSimplex2d } from "@vgpu/wgsl-std/noise/simplex";

// Signed distance to the cloud, in form units: `q` is the fragment position
// relative to the form's centre divided by the form's half-height, so y = ±1
// lands on the form's top and bottom edges. `halfN` is the form's half-extent
// in those units — (aspect-of-the-form, 1).
//
// `swell` (0..1) puffs the cloud up; drive it from focus state.
export fn cloudSdf(q: vec2f, halfN: vec2f, time: f32, swell: f32) -> f32 {
  let w = halfN.x;
  let lift = 1.0 + swell * 0.10;

  // The body covers the form's own rectangle, so text can never overhang the
  // silhouette. Everything else is added on top of that guarantee.
  var d = sdRoundedBox(q, vec2f(w * 1.00, 0.82), 0.50);

  // Domes along the top. A tall centre with lower flanks reads as cumulus;
  // equal-sized circles read as a caterpillar.
  d = opSmoothUnion(d, sdCircle(q - vec2f(-0.08 * w, -0.62 * lift), 0.70 * lift), 0.44);
  d = opSmoothUnion(d, sdCircle(q - vec2f(-0.66 * w, -0.30 * lift), 0.52 * lift), 0.44);
  d = opSmoothUnion(d, sdCircle(q - vec2f(0.64 * w, -0.36 * lift), 0.56 * lift), 0.44);

  // Wide low shoulders that reach past the form on both sides, which is what
  // stops the shape reading as a ball.
  d = opSmoothUnion(d, sdCircle(q - vec2f(-1.14 * w, 0.30), 0.46), 0.42);
  d = opSmoothUnion(d, sdCircle(q - vec2f(1.18 * w, 0.26), 0.44), 0.42);
  d = opSmoothUnion(d, sdCircle(q - vec2f(-0.58 * w, 0.52), 0.44), 0.42);
  d = opSmoothUnion(d, sdCircle(q - vec2f(0.52 * w, 0.54), 0.42), 0.42);

  // Cumulus sit on a level condensation line. Cut the base flat, just below
  // the form's bottom edge so the last field stays inside the cloud.
  d = opSmoothIntersect(d, q.y - 1.12, 0.30);

  // Break the silhouette with drifting noise so the edge reads fluffy.
  // Weighted to the boundary — applied everywhere it would warp the interior
  // shading too, and the body would stop tracking the form.
  let edge = 1.0 - smoothstep(0.0, 0.9, abs(d));
  let warp = fbmSimplex2d(q * 2.4 + vec2f(time * 0.06, time * 0.02), 4, 2.0, 0.5);
  return d - warp * 0.15 * edge;
}
