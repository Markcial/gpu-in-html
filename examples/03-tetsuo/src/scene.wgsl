// Entry shader: the raymarched arm over a wet floor, lit hard, graded dirty.
//
// This is where the march loop lives, and it has to: WGSL has no function
// pointers, so no library can hand you a generic march() that calls your scene
// function. The library supplies everything that does not need the scene —
// camera rays, SDF shapes and operators, the tiled Voronoi, the grade.

import { rayFromUv, orbit } from "@gpu-in-html/wgsl/camera";
import { cylindricalUv } from "@gpu-in-html/wgsl/shape3d";
import { voronoiTiled, cellRandom } from "@gpu-in-html/wgsl/voronoi";
import { applyGrain, contrast, halation, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { saturate } from "@vgpu/wgsl-std/math";
import { armSdf, veins } from "./arm.wgsl";

struct Params {
  resolution: vec2f,
  pointer: vec2f,
  time: f32,
  mutation: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const MAX_STEPS: i32 = 78;
const MAX_DIST: f32 = 11.0;
const SURFACE: f32 = 0.0018;
const FLOOR_Y: f32 = -1.80;

// Hard key from the upper left. One direction, used by the shading, the
// bleed-through and the floor shadow, so they cannot disagree.
const KEY: vec3f = vec3f(-0.58, 0.70, 0.40);

// Voronoi density. CELLS_AROUND is the tiling period, so it must stay a whole
// number — a fractional count cannot close around the cylinder.
const CELLS_AROUND: f32 = 22.0;
const CELLS_ALONG: f32 = 4.2;

fn normalAt(p: vec3f, time: f32, mutation: f32) -> vec3f {
  let e = vec2f(0.0022, 0.0);
  return normalize(vec3f(
    armSdf(p + e.xyy, time, mutation) - armSdf(p - e.xyy, time, mutation),
    armSdf(p + e.yxy, time, mutation) - armSdf(p - e.yxy, time, mutation),
    armSdf(p + e.yyx, time, mutation) - armSdf(p - e.yyx, time, mutation),
  ));
}

// Returns distance along the ray, or -1 for a miss.
fn march(origin: vec3f, direction: vec3f, time: f32, mutation: f32) -> f32 {
  var t = 0.30;
  for (var i = 0; i < MAX_STEPS; i++) {
    let d = armSdf(origin + direction * t, time, mutation);
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
    acc += saturate(-armSdf(p + light * f32(i) * 0.13, time, mutation) * 3.0);
  }
  return acc * 0.25;
}

// The tissue types, picked per Voronoi cell. Weighted so raw muscle dominates
// and the rest read as contamination spreading through it rather than as a
// four-colour pattern.
// Deliberately desaturated. Fully saturated purple and yellow read as
// fluorescent paint rather than tissue; the hues still separate at this
// chroma, and the lighting is what carries the intensity.
fn tissue(t: f32) -> vec3f {
  if (t < 0.42) {
    return srgbToLinear3(vec3f(0.50, 0.21, 0.20)); // raw muscle
  }
  if (t < 0.66) {
    return srgbToLinear3(vec3f(0.33, 0.21, 0.37)); // bruised purple
  }
  if (t < 0.86) {
    return srgbToLinear3(vec3f(0.56, 0.48, 0.29)); // sallow fat
  }
  return srgbToLinear3(vec3f(0.27, 0.32, 0.41)); // cold blue-grey
}

// Cold industrial room with one hot source behind the arm. The room stays blue
// on purpose: warm flesh against a warm room is a single hue and reads flat,
// however much detail the surface has.
fn room(uv: vec2f, direction: vec3f) -> vec3f {
  // These look high for a dark room, and they are not: sRGB 0.06 is linear
  // 0.004, which is black once the vignette and the contrast have had it.
  var col = mix(
    srgbToLinear3(vec3f(0.150, 0.175, 0.235)),
    srgbToLinear3(vec3f(0.205, 0.215, 0.245)),
    smoothstep(0.5, -0.3, direction.y),
  );
  let glow = pow(saturate(1.0 - length(uv - vec2f(0.5, 0.44)) * 2.55), 4.0);
  col += srgbToLinear3(vec3f(0.78, 0.15, 0.07)) * glow * 0.55;
  return col;
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let time = params.time;
  let mutation = clamp(params.mutation, 0.0, 1.0);
  let key = normalize(KEY);

  let yaw = (params.pointer.x - 0.5) * 1.7 + sin(time * 0.06) * 0.10;
  let pitch = (0.5 - params.pointer.y) * 0.60 + 0.06;
  let focus = vec3f(0.0, -0.05, 0.0);
  let origin = orbit(focus, 4.75, yaw, pitch);
  let ray = rayFromUv(uv, params.resolution, origin, focus, 0.95);

  var col = room(uv, ray.direction);

  let tMass = march(ray.origin, ray.direction, time, mutation);

  // The floor is a plane, so it needs no marching at all — one intersection
  // test, exact, and the arm simply wins wherever it is nearer.
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

    let dirt = veins(p * 0.9 + vec3f(3.1, 0.0, 1.7), 0.0);
    var floorCol = mix(
      srgbToLinear3(vec3f(0.195, 0.205, 0.235)),
      srgbToLinear3(vec3f(0.120, 0.125, 0.150)),
      dirt,
    );
    floorCol += srgbToLinear3(vec3f(0.74, 0.14, 0.07))
      * pow(saturate(1.0 - length(p.xz) * 0.52), 4.0)
      * 0.30;

    // Contact shadow, from the same field the arm is made of. This is what
    // stops it reading as a shape floating in a void.
    floorCol *= 1.0 - saturate(massTowardLight(p, time, mutation) * 2.6) * 0.85;

    col = mix(floorCol, room(uv, ray.direction), saturate((tFloor - 3.4) * 0.20));
  }

  if (tMass > 0.0 && (!hitFloor)) {
    let p = ray.origin + ray.direction * tMass;
    let n = normalAt(p, time, mutation);
    let view = -ray.direction;

    let diffuse = saturate(dot(n, key));
    let fresnel = pow(1.0 - saturate(dot(n, view)), 3.2);
    let specular = pow(saturate(dot(reflect(-key, n), view)), 46.0);

    // Cylindrical projection, then a Voronoi that tiles on the angular axis.
    // Wrapping is the whole reason this is not wgsl-std's voronoi2d: an
    // unwrapped field puts different cells on the two sides of the join and
    // the seam runs visibly down the arm.
    let cuv = cylindricalUv(p, CELLS_AROUND, CELLS_ALONG);
    let cellular = voronoiTiled(cuv, CELLS_AROUND);

    var albedo = tissue(cellRandom(cellular.cell, 17u));
    // Vary each cell's value a little, so neighbours of the same tissue still
    // read as separate cells rather than one flat patch.
    albedo *= 0.84 + 0.28 * cellRandom(cellular.cell, 91u);

    // The membrane between cells: f2 - f1 goes to zero on a border.
    let border = 1.0 - smoothstep(0.0, 0.13, cellular.f2 - cellular.f1);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.07, 0.035, 0.05)), border * 0.88);

    let vein = veins(p, time);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.19, 0.04, 0.07)), vein * 0.35);

    col = albedo * (0.10 + diffuse * 0.95);

    // Light bleeding through the thin parts, weighted to the side facing away
    // from the key. Without that weighting it fires hardest exactly where the
    // surface already faces the light — there is no material in the way, so
    // the term saturates — and the red wash swallows the tissue colours.
    // Backscatter belongs on the shadow side.
    let thin = 1.0 - massTowardLight(p, time, mutation);
    let backlit = pow(thin, 3.2) * (1.0 - diffuse);
    col += srgbToLinear3(vec3f(0.86, 0.12, 0.07)) * backlit * (0.28 + mutation * 0.42);

    // Cold fill from behind and to the right. Without it the side away from
    // the key goes to flat black and the form stops turning.
    let fill = normalize(vec3f(0.66, 0.12, -0.74));
    col += srgbToLinear3(vec3f(0.18, 0.34, 0.58)) * saturate(dot(n, fill)) * 0.34;

    // Cold rim, so the silhouette separates from the dark room.
    col += srgbToLinear3(vec3f(0.34, 0.68, 1.00)) * fresnel * 0.32;

    // Wet highlight, dulled on the membranes so it does not read as plastic.
    col += vec3f(1.0, 0.94, 0.88) * specular * 0.32 * (0.30 + 0.70 * (1.0 - border));

    col = mix(col, room(uv, ray.direction), saturate((tMass - 3.6) * 0.40));
  }

  col = halation(col, srgbToLinear3(vec3f(1.0, 0.30, 0.16)), 0.78, 0.12);
  col = tonemapAces(col);
  col = contrast(col, 1.07);
  col *= 1.0 - vignette(uv, 0.34, 0.55);
  col = applyGrain(col, uv, params.resolution, time, 0.13);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
