// Post-processing that fits in the same pass as the shading: grain, vignette,
// halation and a cheap tone contrast.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// Anything that needs to read neighbouring pixels — real bloom, blur, true
// chromatic aberration — cannot live here. That takes a second pass: render to
// a `target`, then bind it as the input of another `effect`.

import { hash2 } from "@vgpu/wgsl-std/hash";
import { saturate } from "@vgpu/wgsl-std/math";

// 0 at the centre, rising to `amount` in the corners. Multiply your colour by
// the result subtracted from 1.
export fn vignette(uv: vec2f, amount: f32, softness: f32) -> f32 {
  let d = length(uv - vec2f(0.5)) * 1.41421356;
  return smoothstep(1.0 - softness, 1.0, d) * amount;
}

// Per-pixel noise in -0.5..0.5. Seeded by pixel and time, so it crawls the way
// film grain does instead of sitting still.
export fn grain(uv: vec2f, resolution: vec2f, time: f32) -> f32 {
  return hash2(uv * resolution + vec2f(time * 61.7, time * 37.3)).x - 0.5;
}

// Grain scaled by luminance: heaviest in the mid-tones, nearly gone in the
// blacks and the highlights, which is how real film behaves. Flat grain over
// everything is the thing that reads as a cheap overlay.
export fn applyGrain(color: vec3f, uv: vec2f, resolution: vec2f, time: f32, amount: f32) -> vec3f {
  let l = saturate(dot(color, vec3f(0.2126, 0.7152, 0.0722)));
  let weight = 4.0 * l * (1.0 - l);
  return color + vec3f(grain(uv, resolution, time) * amount * weight);
}

// Pivoted contrast around mid-grey. Values above 1 crush, below 1 flatten.
export fn contrast(color: vec3f, amount: f32) -> vec3f {
  return max((color - vec3f(0.5)) * amount + vec3f(0.5), vec3f(0.0));
}

// Cheap halation: bleed the brightest channel outward in colour only. Not a
// real bloom — it adds no spatial spread — but it warms hot areas the way an
// overexposed frame does, for one multiply.
export fn halation(color: vec3f, tint: vec3f, threshold: f32, amount: f32) -> vec3f {
  let excess = max(max(color.r, max(color.g, color.b)) - threshold, 0.0);
  return color + tint * excess * amount;
}
