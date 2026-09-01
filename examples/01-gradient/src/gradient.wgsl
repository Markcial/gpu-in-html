// Entry shader. Bindings live here, never in the imported modules.

import { centered, polar } from "@gpu-in-html/wgsl/space";
import { paletteDefault } from "@gpu-in-html/wgsl/color";
import { pulse } from "@gpu-in-html/wgsl/shaping";
// Transfer functions and tonemapping come from the vgpu standard library.
import { linearToSrgb3, tonemapAces } from "@vgpu/wgsl-std/color";

struct Params {
  resolution: vec2f,
  time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let p = centered(uv, params.resolution);
  let pol = polar(p);

  // Sweep the palette around the angle and outward along the radius.
  let t = pol.y + pol.x * 0.35 - params.time * 0.05;
  var color = paletteDefault(t);

  // A ring that breathes, so the frame is obviously live. Keep the width well
  // under the frame radius or the falloff covers everything and reads as a
  // flat vignette instead of a ring.
  let ring = pulse(pol.x, 0.55 + 0.12 * sin(params.time * 0.6), 0.28);
  color *= 0.30 + 1.15 * ring;

  return vec4f(linearToSrgb3(tonemapAces(color)), 1.0);
}
