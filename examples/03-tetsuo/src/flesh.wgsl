// The mutating mass.
//
// Pure module. `mutation` runs 0..1: at 0 this is a smooth sphere, at 1 the
// lobes have erupted and the surface is displaced past recognition.

import { sdCapsule, sdSphere } from "@gpu-in-html/wgsl/shape3d";
import { opSmoothUnion } from "@gpu-in-html/wgsl/sdf";
import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";

const LOBES: i32 = 6;

export fn fleshSdf(p: vec3f, time: f32, mutation: f32) -> f32 {
  // Core mass, swelling as the mutation runs.
  var d = sdSphere(p, 0.84 + mutation * 0.14);

  // Lobes straining out of the core. Each drifts on its own phase and is
  // smooth-unioned in, so they read as one body under pressure rather than as
  // a bag of separate spheres.
  for (var i = 0; i < LOBES; i++) {
    let fi = f32(i);
    let a = fi * 1.0472 + time * (0.13 + fi * 0.021);
    let b = fi * 2.39996 + time * 0.10;
    let dir = vec3f(cos(a) * cos(b), sin(b), sin(a) * cos(b));

    let reach = (0.30 + 0.34 * sin(time * 0.71 + fi * 1.7)) * mutation;
    let radius = (0.26 + 0.10 * sin(time * 1.13 + fi * 2.3)) * (0.40 + 0.70 * mutation);

    d = opSmoothUnion(d, sdSphere(p - dir * (0.62 + reach), radius), 0.32);
  }

  // Tendrils. Deliberately asymmetric and biased up and to one side — evenly
  // distributed lobes average out into a ball, and a ball is not a body coming
  // apart.
  for (var i = 0; i < 3; i++) {
    let fi = f32(i);
    let sway = sin(time * 0.63 + fi * 2.1) * 0.30;
    let root = vec3f(-0.15 + fi * 0.22, 0.30, -0.10 + fi * 0.18);
    let tip = root
      + vec3f(0.35 + sway, 0.85 + 0.30 * fi, -0.25 + sway * 0.6)
      * (0.35 + mutation * 1.05);
    d = opSmoothUnion(d, sdCapsule(p, root, tip, 0.20 - fi * 0.035), 0.26);
  }

  // Coarse lumps over the whole body.
  let warp = fbmSimplex3d(p * 1.9 + vec3f(0.0, time * 0.14, time * 0.05), 3, 2.0, 0.5);
  d -= warp * (0.07 + 0.24 * mutation);

  // Fine warty detail, only worth evaluating near the surface — it is the most
  // expensive term in the march and contributes nothing out in empty space.
  if (d < 0.14) {
    let fine = fbmSimplex3d(p * 6.5 - vec3f(time * 0.06), 2, 2.0, 0.55);
    d -= fine * 0.040 * mutation;
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
