// Entry shader: raymarched flesh over a wet floor, lit hard, graded dirty.
//
// This is where the march loop lives, and it has to: WGSL has no function
// pointers, so no library can hand you a generic march() that calls your scene
// function. The library supplies everything that does not need the scene —
// camera rays, SDF shapes and operators, the grade.

import { rayFromUv, orbit } from "@gpu-in-html/wgsl/camera";
import { applyGrain, contrast, halation, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { saturate } from "@vgpu/wgsl-std/math";
import { fleshSdf, veins } from "./flesh.wgsl";

struct Params {
  resolution: vec2f,
  pointer: vec2f,
  time: f32,
  mutation: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const MAX_STEPS: i32 = 72;
const MAX_DIST: f32 = 9.0;
const SURFACE: f32 = 0.0018;
const FLOOR_Y: f32 = -1.16;

// Hard key from the upper left. One direction, used by the shading, the
// bleed-through and the floor shadow, so they cannot disagree.
const KEY: vec3f = vec3f(-0.58, 0.70, 0.40);

fn normalAt(p: vec3f, time: f32, mutation: f32) -> vec3f {
  let e = vec2f(0.0022, 0.0);
  return normalize(vec3f(
    fleshSdf(p + e.xyy, time, mutation) - fleshSdf(p - e.xyy, time, mutation),
    fleshSdf(p + e.yxy, time, mutation) - fleshSdf(p - e.yxy, time, mutation),
    fleshSdf(p + e.yyx, time, mutation) - fleshSdf(p - e.yyx, time, mutation),
  ));
}

// Returns distance along the ray, or -1 for a miss.
fn march(origin: vec3f, direction: vec3f, time: f32, mutation: f32) -> f32 {
  var t = 0.30;
  for (var i = 0; i < MAX_STEPS; i++) {
    let d = fleshSdf(origin + direction * t, time, mutation);
    // Relax the hit threshold with distance: one pixel covers more world the
    // further out it is, so a fixed epsilon shimmers on the silhouette.
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

// How much mass sits between this point and the light. A cheap stand-in for
// subsurface transport, and for the floor it doubles as a contact shadow.
fn massTowardLight(p: vec3f, time: f32, mutation: f32) -> f32 {
  let light = normalize(KEY);
  var acc = 0.0;
  for (var i = 1; i <= 4; i++) {
    acc += saturate(-fleshSdf(p + light * f32(i) * 0.13, time, mutation) * 3.0);
  }
  return acc * 0.25;
}

// Cold industrial room with one hot source behind the mass. The room stays
// blue on purpose: red flesh against a red room is a single hue and reads
// flat, however much detail the surface has.
fn room(uv: vec2f, direction: vec3f) -> vec3f {
  // These look high for a dark room, and they are not: sRGB 0.06 is linear
  // 0.004, which is black once the vignette and the contrast have had it.
  // A dim-but-readable room needs to be authored around sRGB 0.2.
  var col = mix(
    srgbToLinear3(vec3f(0.150, 0.175, 0.235)),
    srgbToLinear3(vec3f(0.205, 0.215, 0.245)),
    smoothstep(0.5, -0.3, direction.y),
  );
  // Tight, so it haloes the silhouette instead of flooding the frame.
  let glow = pow(saturate(1.0 - length(uv - vec2f(0.5, 0.44)) * 2.55), 4.0);
  col += srgbToLinear3(vec3f(0.78, 0.15, 0.07)) * glow * 0.55;
  return col;
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let time = params.time;
  let mutation = clamp(params.mutation, 0.0, 1.0);
  let key = normalize(KEY);

  // Pointer orbits the camera. Drifts slowly on its own so a still frame is
  // never quite still.
  let yaw = (params.pointer.x - 0.5) * 1.7 + sin(time * 0.06) * 0.10;
  let pitch = (0.5 - params.pointer.y) * 0.70 + 0.12;
  // Pull back and look slightly high: at full mutation the tendrils reach well
  // above the core, and a tighter frame just clips them off.
  let focus = vec3f(0.0, 0.30, 0.0);
  let origin = orbit(focus, 4.15, yaw, pitch);
  let ray = rayFromUv(uv, params.resolution, origin, focus, 0.95);

  var col = room(uv, ray.direction);

  let tMass = march(ray.origin, ray.direction, time, mutation);

  // The floor is a plane, so it needs no marching at all — one intersection
  // test, exact, and the mass simply wins wherever it is nearer.
  var tFloor = -1.0;
  if (ray.direction.y < -1e-4) {
    let candidate = (FLOOR_Y - ray.origin.y) / ray.direction.y;
    if (candidate > 0.0 && candidate < MAX_DIST) {
      tFloor = candidate;
    }
  }

  let hitFloor = tFloor > 0.0 && (tMass < 0.0 || tFloor < tMass);

  if (hitFloor) {
    let p = ray.origin + ray.direction * tFloor;

    // Wet, dirty concrete: dark, with the red source smeared into it.
    let dirt = veins(p * 0.9 + vec3f(3.1, 0.0, 1.7), 0.0);
    var floorCol = mix(
      srgbToLinear3(vec3f(0.195, 0.205, 0.235)),
      srgbToLinear3(vec3f(0.120, 0.125, 0.150)),
      dirt,
    );
    floorCol += srgbToLinear3(vec3f(0.74, 0.14, 0.07))
      * pow(saturate(1.0 - length(p.xz) * 0.52), 4.0)
      * 0.30;

    // Contact shadow, from the same field the mass is made of. This is what
    // stops it reading as a blob floating in a void.
    let shadow = saturate(massTowardLight(p, time, mutation) * 2.6);
    floorCol *= 1.0 - shadow * 0.85;

    col = mix(floorCol, room(uv, ray.direction), saturate((tFloor - 3.0) * 0.22));
  }

  if (tMass > 0.0 && (!hitFloor)) {
    let p = ray.origin + ray.direction * tMass;
    let n = normalAt(p, time, mutation);
    let view = -ray.direction;

    let diffuse = saturate(dot(n, key));
    let fresnel = pow(1.0 - saturate(dot(n, view)), 3.2);
    let specular = pow(saturate(dot(reflect(-key, n), view)), 46.0);

    let vein = veins(p, time);

    // Meat, not lava: crimson in the shadow, dull mauve where the light lands.
    var albedo = mix(
      srgbToLinear3(vec3f(0.40, 0.12, 0.13)),
      srgbToLinear3(vec3f(0.64, 0.34, 0.32)),
      saturate(n.y * 0.5 + 0.5),
    );
    albedo = mix(albedo, srgbToLinear3(vec3f(0.20, 0.04, 0.07)), vein * 0.66);

    col = albedo * (0.10 + diffuse * 0.95);

    // Light bleeding through the thin parts. Deep red, and kept well under the
    // diffuse term — pushed too far it stops reading as flesh and turns into
    // an emissive lump.
    let thin = 1.0 - massTowardLight(p, time, mutation);
    col += srgbToLinear3(vec3f(0.86, 0.12, 0.07)) * pow(thin, 3.2) * (0.20 + mutation * 0.28);

    // Cold fill from behind and to the right. Without it the side away from
    // the key goes to flat black and the form stops turning.
    let fill = normalize(vec3f(0.66, 0.12, -0.74));
    col += srgbToLinear3(vec3f(0.18, 0.34, 0.58)) * saturate(dot(n, fill)) * 0.34;

    // Cold rim, so the silhouette separates from the dark room.
    col += srgbToLinear3(vec3f(0.34, 0.68, 1.00)) * fresnel * 0.55;

    // Wet highlight, broken up by the veins so it does not read as plastic.
    col += vec3f(1.0, 0.94, 0.88) * specular * 0.32 * (0.35 + 0.65 * (1.0 - vein));

    col = mix(col, room(uv, ray.direction), saturate((tMass - 2.6) * 0.45));
  }

  col = halation(col, srgbToLinear3(vec3f(1.0, 0.30, 0.16)), 0.78, 0.12);
  col = tonemapAces(col);
  col = contrast(col, 1.07);
  col *= 1.0 - vignette(uv, 0.34, 0.55);
  col = applyGrain(col, uv, params.resolution, time, 0.13);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
