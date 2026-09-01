// Entry shader: the wall of an organ, looked at.
//
// Two things carry this one. The lamp rides the camera, so there is no sun and
// no room and the light falls off with distance. And the camera does not move:
// the only motion in the frame is the tissue itself, slowly. A moving camera
// over a wall reads as a shot; a still one reads as something being looked at.

import { rayFromUv } from "@gpu-in-html/wgsl/camera";
import { applyGrain, contrast, fog, halation, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { fbmSimplex3d, simplex3d } from "@vgpu/wgsl-std/noise/simplex";
import { saturate } from "@vgpu/wgsl-std/math";
import { lumenSdf, skin, tubeCenter, vessels } from "./organ.wgsl";

struct Params {
  resolution: vec2f,
  time: f32,
  tone: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const MAX_STEPS: i32 = 90;
const MAX_DIST: f32 = 14.0;
const SURFACE: f32 = 0.0016;

// A fixed viewpoint: where around the axis the camera sits, at what height,
// and how far back from the wall as a fraction of the lumen radius. Close
// enough that the surface fills the frame, far enough that there is real
// perspective across it.
const VIEW_ANGLE: f32 = 0.65;
const VIEW_Y: f32 = 0.0;
const STANDOFF: f32 = 0.55;

fn normalAt(p: vec3f, time: f32, tone: f32) -> vec3f {
  let e = vec2f(0.0020, 0.0);
  return normalize(vec3f(
    lumenSdf(p + e.xyy, time, tone) - lumenSdf(p - e.xyy, time, tone),
    lumenSdf(p + e.yxy, time, tone) - lumenSdf(p - e.yxy, time, tone),
    lumenSdf(p + e.yyx, time, tone) - lumenSdf(p - e.yyx, time, tone),
  ));
}

// Micro-relief. At this range the distance field's own detail is far too
// smooth, and a smooth normal plus any specular at all reads as polished —
// however matte the colour underneath is. Tilting the normal with a fine noise
// gradient breaks the shading up for four noise samples on hit pixels only.
// Putting the same detail in the SDF would cost an evaluation on every step of
// every ray, and would force the marcher to take shorter steps as well.
fn microNormal(p: vec3f, n: vec3f, scale: f32, strength: f32) -> vec3f {
  let e = 0.12;
  let base = simplex3d(p * scale);
  let gradient = vec3f(
    simplex3d(p * scale + vec3f(e, 0.0, 0.0)) - base,
    simplex3d(p * scale + vec3f(0.0, e, 0.0)) - base,
    simplex3d(p * scale + vec3f(0.0, 0.0, e)) - base,
  );
  // Only the part tangential to the surface should tilt it.
  let tangential = gradient - n * dot(gradient, n);
  return normalize(n + tangential * strength);
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
// along the normal is the cheapest useful ambient term, and against a folded
// wall it does most of the work — the creases are exactly what should go dark.
fn occlusion(p: vec3f, n: vec3f, time: f32, tone: f32) -> f32 {
  var acc = 0.0;
  var weight = 1.0;
  for (var i = 1; i <= 4; i++) {
    let step = f32(i) * 0.085;
    acc += weight * (step - lumenSdf(p + n * step, time, tone));
    weight *= 0.65;
  }
  // A light touch. Driven hard, this is what digs the creases to black and
  // splits the image into pale ridges and dark pits — the tissue should read
  // as one material at one value, shaped by light rather than by contrast.
  return saturate(1.0 - acc * 2.2);
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let time = params.time;
  let tone = clamp(params.tone, 0.0, 1.0);

  // Fixed camera, just off the axis, facing the wall.
  let axis = tubeCenter(VIEW_Y);
  let radial = vec3f(cos(VIEW_ANGLE), 0.0, sin(VIEW_ANGLE));
  let onAxis = vec3f(axis.x, VIEW_Y, axis.y);
  let ray = rayFromUv(uv, params.resolution, onAxis + radial * STANDOFF, onAxis + radial * 3.0, 1.02);

  // Not black. Out of the lamp's reach there is still tissue glowing dimly,
  // and a pure black hole reads as a missing object rather than as depth.
  let voidColor = srgbToLinear3(vec3f(0.115, 0.030, 0.036));
  var col = voidColor;

  let t = march(ray.origin, ray.direction, time, tone);

  if (t > 0.0) {
    let p = ray.origin + ray.direction * t;
    let view = -ray.direction;

    // The geometric normal is kept as well as the perturbed one: occlusion is
    // a property of the shape, and feeding it a bumped normal would make the
    // micro-relief cast shadows it has no geometry for.
    let geometric = normalAt(p, time, tone);

    // Everything that decorates the surface is sampled in skin space, so the
    // pattern stays stuck to the tissue while the wall breathes underneath it.
    let s = skin(p);

    // Two scales of micro-relief: pores, then the grain between them. Gentle —
    // enough to stop the specular reading as polished, not enough to make the
    // membrane look rough. The bumps in the distance field carry the relief.
    var n = microNormal(s, geometric, 9.0, 0.45);
    n = microNormal(s, n, 34.0, 0.22);

    // The lamp rides the camera, so the light direction is the view direction.
    // True inverse-square is too aggressive: it leaves a lit ring at the very
    // edge of frame and nothing else.
    let attenuation = 1.0 / (1.0 + t * t * 0.16);
    let facing = dot(n, view);

    // Wrap lighting. Tissue is translucent, so light does not stop at the
    // terminator — a hard lambert falloff is one of the things that makes
    // organic surfaces read as painted plastic.
    let wrap = 0.42;
    let diffuse = saturate((facing + wrap) / (1.0 + wrap)) * attenuation;
    let ao = occlusion(p, geometric, time, tone);

    // Mucosa colour, continuous rather than patched. Real tissue does not come
    // in discrete cells at this scale, so two low frequencies move the colour
    // inside a narrow hue range, and a fine one breaks it up close in.
    let deep = fbmSimplex3d(s * 0.85 + vec3f(0.0, 0.0, 3.7), 3, 2.0, 0.5);
    let thin = fbmSimplex3d(s * 2.30 + vec3f(5.1, 0.0, 0.0), 3, 2.0, 0.5);

    // A narrow range on purpose. Real mucosa is one colour with slight
    // variation, not a marbled pattern; widening these endpoints is what turned
    // the wall into a map of light and dark regions.
    var albedo = mix(
      srgbToLinear3(vec3f(0.63, 0.35, 0.33)),
      srgbToLinear3(vec3f(0.72, 0.46, 0.43)),
      saturate(deep * 0.95 + 0.5),
    );
    albedo = mix(
      albedo,
      srgbToLinear3(vec3f(0.70, 0.53, 0.45)),
      saturate(thin * 0.75 + 0.25) * 0.10,
    );
    albedo *= 0.95 + 0.08 * (simplex3d(s * 21.0) * 0.5 + 0.5);

    // Vessels at two scales: a few large veins, and a fine net over
    // everything. The net is what actually sells it — a single scale of
    // branching reads as cracks.
    let veins = vessels(s * 0.95, 0.075);
    let capillaries = vessels(s * 3.10 + vec3f(9.3, 2.1, 4.7), 0.16);
    // Vessels sit under the mucosa, so they show through rather than being
    // drawn on it — a much lighter mix than a surface marking would take.
    albedo = mix(albedo, srgbToLinear3(vec3f(0.47, 0.20, 0.22)), veins * 0.30);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.56, 0.28, 0.28)), capillaries * 0.14);

    // The lamp gain is tuned for how far the wall actually is. Facing it at
    // roughly a radius' standoff, everything is near, so the value that lit a
    // receding tunnel blows this out completely.
    // A generous ambient term relative to the lamp. Lifting the floor is what
    // keeps the shadows off black and holds the whole wall inside one value
    // range instead of splitting it into lit and unlit halves.
    col = albedo * (diffuse * 1.55 * ao + 0.16 * ao);

    // Light scattering forward through the thin folds, warm and close.
    col += srgbToLinear3(vec3f(0.88, 0.24, 0.18))
      * pow(saturate(1.0 - abs(facing)), 2.4)
      * attenuation
      * (0.24 + tone * 0.18);

    // Barely any specular, and broad rather than tight. Mucosa is damp, not
    // polished: a narrow bright lobe over a smooth surface is exactly what
    // makes this read as a mirror instead of tissue. The micro-relief above
    // scatters what little is left.
    let wetness = saturate(fbmSimplex3d(s * 3.1, 3, 2.0, 0.5) * 1.7 + 0.30);
    col += vec3f(1.0, 0.96, 0.93)
      * pow(saturate(facing), 14.0)
      * 0.045
      * wetness
      * attenuation;

    col = fog(col, voidColor, t, 0.14);
  }

  col = halation(col, srgbToLinear3(vec3f(1.0, 0.34, 0.22)), 0.78, 0.09);
  col = tonemapAces(col);
  // Below 1: flatten rather than crush. The grade should not be adding the
  // black-and-white separation the shading was just tuned to avoid.
  col = contrast(col, 1.0);
  col *= 1.0 - vignette(uv, 0.20, 0.62);
  // Grain is reseeded every frame, so it is a real contributor to how busy the
  // image feels even though nothing in the scene is moving because of it.
  col = applyGrain(col, uv, params.resolution, time, 0.032);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
