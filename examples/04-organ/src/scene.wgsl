// Entry shader: a flythrough down the inside of an organ.
//
// The lighting model is the point of this one. There is no sun and no room —
// the only light is on the camera, so brightness falls off with distance and
// the tunnel ahead goes black on its own. That single change is most of what
// separates "inside a body" from "outside an object".

import { rayFromUv } from "@gpu-in-html/wgsl/camera";
import { cylindricalUv } from "@gpu-in-html/wgsl/shape3d";
import { voronoiTiled, cellRandom } from "@gpu-in-html/wgsl/voronoi";
import { applyGrain, contrast, fog, halation, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
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

// Voronoi density. CELLS_AROUND is the tiling period, so it must stay a whole
// number — a fractional count cannot close around the tube.
const CELLS_AROUND: f32 = 26.0;
const CELLS_ALONG: f32 = 3.4;

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

// The mucosa, picked per Voronoi cell. Low chroma on purpose: at full
// saturation these read as fluorescent paint rather than tissue, and the wet
// highlight is what should carry the intensity.
fn mucosa(t: f32) -> vec3f {
  if (t < 0.46) {
    return srgbToLinear3(vec3f(0.60, 0.30, 0.30)); // salmon
  }
  if (t < 0.72) {
    return srgbToLinear3(vec3f(0.47, 0.20, 0.25)); // congested
  }
  if (t < 0.90) {
    return srgbToLinear3(vec3f(0.60, 0.50, 0.36)); // pale patch
  }
  return srgbToLinear3(vec3f(0.38, 0.26, 0.38)); // bruised
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let time = params.time;
  let tone = clamp(params.tone, 0.0, 1.0);

  // Travel down the tube, staying on its wandering axis so the camera never
  // clips the wall.
  let travelY = -time * 0.55;
  let here = tubeCenter(travelY);
  let origin = vec3f(here.x, travelY, here.y);

  // Aim further down the tube, offset by the pointer so it can be steered.
  let aheadY = travelY - 2.6;
  let ahead = tubeCenter(aheadY);
  let steer = (params.pointer - vec2f(0.5)) * 0.9;
  let at = vec3f(ahead.x + steer.x, aheadY, ahead.y - steer.y);

  let ray = rayFromUv(uv, params.resolution, origin, at, 1.02);

  // Everything unlit falls to this. The tunnel ahead is simply out of range of
  // the lamp, which is why it goes black without any explicit backdrop.
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

    // The lamp rides the camera, so the light direction is the view direction
    // and the falloff is inverse-square from the eye.
    // True inverse-square is too aggressive here: it leaves a lit ring at the
    // very edge of frame and nothing else. Softening the quadratic term lets
    // the lamp reach a few metres down the tube, which is what an endoscope
    // actually does.
    let attenuation = 1.0 / (1.0 + t * t * 0.16);
    let diffuse = saturate(dot(n, view)) * attenuation;
    let ao = occlusion(p, n, time, tone);

    // Recentre on the wandering axis before projecting, or the texture slides
    // around the tube as it bends.
    let centre = tubeCenter(p.y);
    let local = vec3f(p.x - centre.x, p.y, p.z - centre.y);
    let cellular = voronoiTiled(cylindricalUv(local, CELLS_AROUND, CELLS_ALONG), CELLS_AROUND);

    var albedo = mucosa(cellRandom(cellular.cell, 17u));
    albedo *= 0.86 + 0.26 * cellRandom(cellular.cell, 91u);

    // The crease between cells.
    let border = 1.0 - smoothstep(0.0, 0.12, cellular.f2 - cellular.f1);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.20, 0.07, 0.09)), border * 0.72);

    // Vessels under the mucosa.
    let vessel = vessels(p, time);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.34, 0.06, 0.10)), vessel * 0.55);

    col = albedo * (diffuse * 3.2 * ao + 0.07 * ao);

    // Light scattering forward through the thin folds, warm and close.
    col += srgbToLinear3(vec3f(0.88, 0.24, 0.18))
      * pow(saturate(1.0 - abs(dot(n, view))), 2.4)
      * attenuation
      * (0.35 + tone * 0.30);

    // Everything in here is wet. With the lamp on the camera the light and
    // view directions are the same vector, so the half-vector collapses to the
    // view — the highlight simply lands wherever the wall faces the lens.
    // Two lobes: a tight one for the sheen on the mucus film, a broad one so
    // the whole surface stays glossy.
    let facing = saturate(dot(n, view));
    let spec = pow(facing, 64.0) * 0.55 + pow(facing, 8.0) * 0.10;
    col += vec3f(1.0, 0.95, 0.92) * spec * attenuation * (1.0 - border * 0.6);

    col = fog(col, voidColor, t, 0.14);
  }

  col = halation(col, srgbToLinear3(vec3f(1.0, 0.34, 0.22)), 0.70, 0.18);
  col = tonemapAces(col);
  col = contrast(col, 1.06);
  col *= 1.0 - vignette(uv, 0.40, 0.68);
  col = applyGrain(col, uv, params.resolution, time, 0.11);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
