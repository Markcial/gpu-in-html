// The mutating arm.
//
// Pure module. `mutation` runs 0..1: at 0 this is close to a limb, at 1 the
// masses have pushed out of it and the surface is displaced past recognition.
//
// The arm is built along the y axis on purpose. Keeping it axis-aligned makes
// the cylindrical texture projection a single atan2 — the camera orbits, the
// arm does not.

import { sdRoundCone, sdSphere } from "@gpu-in-html/wgsl/shape3d";
import { opSmoothUnion } from "@gpu-in-html/wgsl/sdf";
import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";

const WRIST: vec3f = vec3f(0.0, 1.55, 0.0);
const ELBOW: vec3f = vec3f(0.0, -2.05, 0.0);
const MASSES: i32 = 5;

export fn armSdf(p: vec3f, time: f32, mutation: f32) -> f32 {
  // The limb: thicker at the elbow, tapering to the wrist, swelling as the
  // mutation runs.
  let swell = 1.0 + mutation * 0.50;
  var d = sdRoundCone(p, ELBOW, WRIST, 0.50 * swell, 0.27 * swell);

  // Masses pushing out *along* the limb rather than around a centre. This is
  // the difference between an arm coming apart and a lump.
  for (var i = 0; i < MASSES; i++) {
    let fi = f32(i);
    let along = -1.45 + fi * 0.76;
    let angle = fi * 2.39996 + time * (0.15 + fi * 0.021);
    let reach = (0.20 + 0.16 * sin(time * 0.79 + fi * 1.9)) * mutation;
    let dir = vec3f(cos(angle), 0.0, sin(angle));
    let centre = vec3f(0.0, along, 0.0) + dir * (0.26 + reach);
    let radius = (0.21 + 0.08 * sin(time * 1.17 + fi * 2.7)) * (0.50 + 0.70 * mutation);
    d = opSmoothUnion(d, sdSphere(p - centre, radius), 0.32);
  }

  // Coarse lumps over the whole limb.
  let warp = fbmSimplex3d(p * 1.8 + vec3f(0.0, time * 0.13, time * 0.05), 3, 2.0, 0.5);
  d -= warp * (0.05 + 0.19 * mutation);

  // Fine detail, only worth evaluating near the surface — it is the most
  // expensive term in the march and contributes nothing out in empty space.
  if (d < 0.14) {
    let fine = fbmSimplex3d(p * 6.5 - vec3f(time * 0.06), 2, 2.0, 0.55);
    d -= fine * 0.038 * mutation;
  }

  // The displacement above breaks the Lipschitz bound the marcher relies on,
  // so a full step would tunnel straight through a lump. Shortening every step
  // is the cheap, standard fix.
  return d * 0.55;
}

// Ridge mask where a noise field crosses zero — reads as veins and seams under
// the skin. Returns 0..1.
export fn veins(p: vec3f, time: f32) -> f32 {
  let n = fbmSimplex3d(p * 4.2 + vec3f(0.0, time * 0.05, 0.0), 3, 2.0, 0.5);
  return 1.0 - smoothstep(0.0, 0.11, abs(n));
}
