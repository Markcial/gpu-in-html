// Entry shader: a flythrough down the inside of an organ.
//
// The lighting model is the point of this one. There is no sun and no room —
// the only light is on the camera, so brightness falls off with distance and
// the tunnel ahead goes black on its own. That single change is most of what
// separates "inside a body" from "outside an object".

import { rayFromUv } from "@gpu-in-html/wgsl/camera";
import { applyGrain, contrast, fog, halation, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";
import { saturate } from "@vgpu/wgsl-std/math";
import { lumenSdf, tubeCenter, vessels } from "./organ.wgsl";

struct Params {
  resolution: vec2f,
  pointer: vec2f,
  time: f32,
  tone: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const MAX_STEPS: i32 = 90;
const MAX_DIST: f32 = 14.0;
const SURFACE: f32 = 0.0016;

// How fast the camera travels down the tube, in units per second. Kept low: a
// brisk flythrough reads as a ride, and the readouts in main.ts derive depth
// from this same number.
const ADVANCE: f32 = 0.14;

fn normalAt(p: vec3f, time: f32, tone: f32) -> vec3f {
  let e = vec2f(0.0020, 0.0);
  return normalize(vec3f(
    lumenSdf(p + e.xyy, time, tone) - lumenSdf(p - e.xyy, time, tone),
    lumenSdf(p + e.yxy, time, tone) - lumenSdf(p - e.yxy, time, tone),
    lumenSdf(p + e.yyx, time, tone) - lumenSdf(p - e.yyx, time, tone),
  ));
}

fn march(origin: vec3f, direction: vec3f, time: f32, tone: f32) -> f32 {
  var t = 0.02;
  for (var i = 0; i < MAX_STEPS; i++) {
    let d = lumenSdf(origin + direction * t, time, tone);
    if (d < SURFACE * t) {
      return t;
    }
    t += d;
    if (t > MAX_DIST) {
      break;
    }
  }
  return -1.0;
}

// Cavity occlusion: how enclosed a point is. Sampling the field a short way
// along the normal is the cheapest useful ambient term, and inside a tube it
// does most of the work — the creases between folds are exactly the places
// that should go dark.
fn occlusion(p: vec3f, n: vec3f, time: f32, tone: f32) -> f32 {
  var acc = 0.0;
  var weight = 1.0;
  for (var i = 1; i <= 4; i++) {
    let step = f32(i) * 0.085;
    acc += weight * (step - lumenSdf(p + n * step, time, tone));
    weight *= 0.65;
  }
  return saturate(1.0 - acc * 2.2);
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let time = params.time;
  let tone = clamp(params.tone, 0.0, 1.0);

  // Travel down the tube, staying on its wandering axis so the camera never
  // clips the wall.
  let travelY = -time * ADVANCE;
  let here = tubeCenter(travelY);
  let origin = vec3f(here.x, travelY, here.y);

  // Aim further down the tube, offset by the pointer so it can be steered.
  let aheadY = travelY - 2.6;
  let ahead = tubeCenter(aheadY);
  let steer = (params.pointer - vec2f(0.5)) * 0.9;
  let at = vec3f(ahead.x + steer.x, aheadY, ahead.y - steer.y);

  let ray = rayFromUv(uv, params.resolution, origin, at, 1.02);

  // Not black. Out of the lamp's reach there is still tissue glowing dimly
  // around the light, and a pure black hole down the middle reads as a missing
  // object rather than as depth.
  let voidColor = srgbToLinear3(vec3f(0.115, 0.030, 0.036));
  var col = voidColor;

  let t = march(ray.origin, ray.direction, time, tone);

  if (t > 0.0) {
    let p = ray.origin + ray.direction * t;
    let n = normalAt(p, time, tone);
    let view = -ray.direction;

    // The lamp rides the camera, so the light direction is the view direction.
    // True inverse-square is too aggressive here: it leaves a lit ring at the
    // very edge of frame and nothing else. Softening the quadratic term lets
    // the lamp reach a few metres down the tube, which is what an endoscope
    // actually does.
    let attenuation = 1.0 / (1.0 + t * t * 0.16);
    let facing = dot(n, view);

    // Wrap lighting. Tissue is translucent, so light does not stop at the
    // terminator — a hard lambert falloff is one of the things that makes
    // organic surfaces read as painted plastic.
    let wrap = 0.42;
    let diffuse = saturate((facing + wrap) / (1.0 + wrap)) * attenuation;
    let ao = occlusion(p, n, time, tone);

    // Mucosa colour, continuous rather than patched. Real tissue does not come
    // in discrete cells at this scale; the Voronoi that suits the arm reads as
    // camouflage in here. Two low frequencies move the colour inside a narrow
    // hue range instead, which is all the variation a mucosa actually has.
    let deep = fbmSimplex3d(p * 0.85 + vec3f(0.0, 0.0, 3.7), 3, 2.0, 0.5);
    let thin = fbmSimplex3d(p * 2.30 + vec3f(5.1, 0.0, 0.0), 3, 2.0, 0.5);

    var albedo = mix(
      srgbToLinear3(vec3f(0.56, 0.26, 0.25)), // congested
      srgbToLinear3(vec3f(0.74, 0.46, 0.42)), // thin and pale
      saturate(deep * 0.95 + 0.5),
    );
    albedo = mix(
      albedo,
      srgbToLinear3(vec3f(0.66, 0.55, 0.43)),
      saturate(thin * 0.75 + 0.25) * 0.20,
    );

    // Vessels at two scales: a few large veins, and a fine net over
    // everything. The net is what actually sells it — a single scale of
    // branching reads as cracks.
    let veins = vessels(p * 0.95, time, 0.075);
    let capillaries = vessels(p * 3.10 + vec3f(9.3, 2.1, 4.7), time, 0.16);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.38, 0.10, 0.13)), veins * 0.52);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.52, 0.19, 0.20)), capillaries * 0.24);

    col = albedo * (diffuse * 3.0 * ao + 0.07 * ao);

    // Light scattering forward through the thin folds, warm and close.
    col += srgbToLinear3(vec3f(0.88, 0.24, 0.18))
      * pow(saturate(1.0 - abs(facing)), 2.4)
      * attenuation
      * (0.38 + tone * 0.30);

    // Mucus pools rather than coating evenly, so the sheen has to be patchy
    // and weak. An even glossy layer over the whole wall is exactly what makes
    // it look like moulded plastic.
    let wetness = saturate(
      fbmSimplex3d(p * 3.1 + vec3f(0.0, time * 0.05, 0.0), 3, 2.0, 0.5) * 1.7 + 0.30,
    );
    col += vec3f(1.0, 0.96, 0.93)
      * pow(saturate(facing), 36.0)
      * 0.15
      * wetness
      * attenuation;

    col = fog(col, voidColor, t, 0.14);
  }

  col = halation(col, srgbToLinear3(vec3f(1.0, 0.34, 0.22)), 0.72, 0.15);
  col = tonemapAces(col);
  col = contrast(col, 1.05);
  col *= 1.0 - vignette(uv, 0.40, 0.68);
  col = applyGrain(col, uv, params.resolution, time, 0.10);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
