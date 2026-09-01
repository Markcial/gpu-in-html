// Entry shader: sky, then the cloud that sits under the HTML form.
//
// The form's measured rectangle arrives as `cloudCenter` / `cloudHalf` in uv
// space, so the GPU shape and the DOM layout are always the same rectangle.

import { skyColor } from "./sky.wgsl";
import { cloudSdf } from "./cloud.wgsl";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { saturate } from "@vgpu/wgsl-std/math";

struct Params {
  resolution: vec2f,
  cloudCenter: vec2f,
  cloudHalf: vec2f,
  pointer: vec2f,
  time: f32,
  focus: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let aspect = params.resolution.x / params.resolution.y;
  let p = vec2f(uv.x * aspect, uv.y);

  // Move into form units: centred on the form, scaled by its half-height.
  let center = vec2f(params.cloudCenter.x * aspect, params.cloudCenter.y);
  let half = vec2f(params.cloudHalf.x * aspect, params.cloudHalf.y);
  let halfY = max(half.y, 1e-4);
  let halfN = vec2f(half.x / halfY, 1.0);
  let q = (p - center) / halfY;

  let parallax = (params.pointer - vec2f(0.5)) * vec2f(0.35, 0.15);
  var col = skyColor(uv, aspect, params.time, parallax);

  let d = cloudSdf(q, halfN, params.time, params.focus);

  // Shadow: the same field sampled down and to the right, darkening the sky.
  let ds = cloudSdf(q - vec2f(-0.12, 0.26), halfN, params.time, params.focus);
  col *= 1.0 - smoothstep(0.34, -0.06, ds) * 0.20;

  // Body: sunlit and warm on top, cool and dense underneath. Authored in sRGB
  // and converted, same as the sky.
  let coverage = smoothstep(0.06, -0.04, d);
  let depth = saturate(-d * 1.2);
  var body = mix(
    srgbToLinear3(vec3f(1.00, 0.99, 0.96)),
    srgbToLinear3(vec3f(0.55, 0.63, 0.82)),
    saturate(q.y * 0.52 + 0.44),
  );
  body = mix(body, body * 0.82, depth * 0.55);

  // Sunlit rim along the upper edge. Focus brightens it, which is the whole
  // feedback loop: the DOM has focus, the GPU shows it.
  let rim = smoothstep(0.15, 0.0, abs(d)) * saturate(-q.y * 0.7 + 0.5);
  body += srgbToLinear3(vec3f(1.0, 0.90, 0.72)) * rim * (0.30 + params.focus * 0.40);

  col = mix(col, body, coverage);

  return vec4f(linearToSrgb3(tonemapAces(col)), 1.0);
}
