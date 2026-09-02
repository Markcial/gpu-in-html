// The background pass: the tunnel itself, and a rim of light on everything the
// browser measured.
//
// It runs before the streaks and reads the same obstacle array the simulation
// does, so what glows here is exactly what the air is deflecting off — if a
// rim and a wake ever disagreed, one of the two would be lying.

import { sdObstacle } from "./flow.wgsl";
import { grain, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3 } from "@vgpu/wgsl-std/color";

const MAX_OBSTACLES: u32 = 24u;

// Member order matters: vgpu writes a `set()` bag in declaration order, and
// the headless still renderer always supplies resolution and time first. Keeping
// those two at the front is what lets scripts/render.mjs produce a thumbnail
// from this shader without a bespoke code path.
struct Field {
  resolution: vec2f,
  time: f32,
  aspect: f32,
  obstacleCount: f32,
  pointerRadius: f32,
  pointer: vec2f,
  obstacles: array<vec4f, 24>,
}

@group(0) @binding(0) var<uniform> params: Field;

const GROUND: vec3f = vec3f(0.043, 0.055, 0.078);
const RIM: vec3f = vec3f(0.30, 0.52, 0.86);

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let p = vec2f(uv.x * params.aspect, uv.y);

  var col = srgbToLinear3(GROUND);

  // Nearest surface in the page, so overlapping rectangles light as one shape
  // rather than as a pile of separate outlines.
  var d = 1e9;
  let count = min(u32(params.obstacleCount), MAX_OBSTACLES);
  for (var i = 0u; i < count; i++) {
    d = min(d, sdObstacle(p, params.obstacles[i]));
  }
  d = min(d, length(p - params.pointer) - params.pointerRadius);

  // A tight rim just outside the surface, and a wide bloom beyond it.
  let rim = smoothstep(0.006, 0.0, abs(d) - 0.002);
  let bloom = smoothstep(0.10, 0.0, max(d, 0.0)) * 0.24;
  col += srgbToLinear3(RIM) * (rim * 0.55 + bloom);

  // Inside a measured rectangle the page's own DOM is drawn on top, so the
  // interior is kept dark rather than filled.
  col *= mix(0.55, 1.0, smoothstep(-0.02, 0.01, d));

  col *= 1.0 - vignette(uv, 0.18, 0.92) * 0.85;
  col += vec3f(grain(uv, params.resolution, params.time)) * 0.012;

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
