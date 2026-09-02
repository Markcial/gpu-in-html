// Colours the culture and lights the page's edges.
//
// Split from the step for a reason worth stating: the state texture holds
// concentrations, not colours. Keeping the palette out of the simulation means
// the reaction can be tuned without touching how it looks, and the look can be
// changed without perturbing a system where a few thousandths matter.

import { sdObstacle } from "./rd.wgsl";
import { applyGrain, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3 } from "@vgpu/wgsl-std/color";

const MAX_OBSTACLES: u32 = 24u;

struct Params {
  resolution: vec2f,
  time: f32,
  aspect: f32,
  obstacleCount: f32,
  obstacles: array<vec4f, 24>,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var state: texture_2d<f32>;
@group(0) @binding(2) var stateSampler: sampler;

const AGAR: vec3f = vec3f(0.115, 0.150, 0.140);
const GROWTH: vec3f = vec3f(0.20, 0.62, 0.52);
const CREST: vec3f = vec3f(0.86, 0.97, 0.82);
const RIM: vec3f = vec3f(0.42, 0.86, 0.72);

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let p = vec2f(uv.x * params.aspect, uv.y);

  // Filtered here, unlike in the step: the state grid is half the size of the
  // window and this is the one place where smoothing between texels is wanted.
  let here = textureSampleLevel(state, stateSampler, uv, 0.0).xy;
  let b = here.y;

  // A cheap slope, so the ridges of the pattern catch light. The gradient of B
  // is what the eye reads as relief.
  let texel = 1.0 / params.resolution;
  let dx = textureSampleLevel(state, stateSampler, uv + vec2f(texel.x, 0.0), 0.0).y
    - textureSampleLevel(state, stateSampler, uv - vec2f(texel.x, 0.0), 0.0).y;
  let dy = textureSampleLevel(state, stateSampler, uv + vec2f(0.0, texel.y), 0.0).y
    - textureSampleLevel(state, stateSampler, uv - vec2f(0.0, texel.y), 0.0).y;
  let relief = clamp((dx * 0.7 - dy * 0.7) * 26.0, -1.0, 1.0);

  var col = srgbToLinear3(AGAR);
  col = mix(col, srgbToLinear3(GROWTH), smoothstep(0.06, 0.26, b));
  col = mix(col, srgbToLinear3(CREST), smoothstep(0.30, 0.46, b));
  col *= 1.0 + relief * 0.35;

  // The same rectangles the reaction treats as inert, drawn as a rim so the
  // boundary the growth stops at is visibly the page's own.
  var distance = 1e9;
  let count = min(u32(params.obstacleCount), MAX_OBSTACLES);
  for (var i = 0u; i < count; i++) {
    distance = min(distance, sdObstacle(p, params.obstacles[i]));
  }
  col += srgbToLinear3(RIM) * smoothstep(0.005, 0.0, abs(distance) - 0.0015) * 0.5;
  col *= mix(0.42, 1.0, smoothstep(-0.02, 0.004, distance));

  // No contrast() here. It pivots around mid grey, and this palette lives an
  // order of magnitude below that in linear light: a 1.06 crush sends the agar
  // negative and the whole plate clamps to black.
  col *= 1.0 - vignette(uv, 0.18, 0.85);
  col = applyGrain(col, uv, params.resolution, params.time, 0.014);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
