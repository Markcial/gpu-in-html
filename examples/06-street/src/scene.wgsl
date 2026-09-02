// Entry shader: a street from above, with the form painted onto the road.
//
// The camera is orthographic-ish and looks straight down, so the screen-space
// rectangle the browser hands us maps onto the road plane. Scrolling the page
// drives the camera along the street rather than moving the document over a
// static picture.

import { applyGrain, contrast, vignette } from "@gpu-in-html/wgsl/post";
import { sdRoundedBox } from "@gpu-in-html/wgsl/shape2d";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";
import { saturate } from "@vgpu/wgsl-std/math";
import { ROAD_HALF, citySdf, foldWorld, lotTint } from "./city.wgsl";

struct Params {
  resolution: vec2f,
  panelCenter: vec2f,
  panelHalf: vec2f,
  time: f32,
  scroll: f32,
  // Radians of upward bend per world unit beyond the fold line. Driven by
  // scroll, so the street only curls once you have started moving down it.
  fold: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const MAX_STEPS: i32 = 96;
const MAX_DIST: f32 = 60.0;
const SURFACE: f32 = 0.004;

// How much world the frame covers vertically. Larger shows more street.
const VIEW_HEIGHT: f32 = 14.0;
const CAMERA_Y: f32 = 30.0;

// Low, so buildings throw long shadows across the road — that is what reads as
// height when there is no perspective to read it from.
const SUN: vec3f = vec3f(-0.52, 0.62, -0.74);

// Where the street starts curling, a few units ahead of the camera so the
// stretch under the form never bends.
// Far enough up-screen to clear the top of the form. The fold and the form
// compete for the same frame: wherever the street has curled there is no flat
// road left to paint, so any field that reaches past the fold line loses its
// background.
const FOLD_AHEAD: f32 = 5.2;

// The city, bent. The bend is not a rigid transform, so the returned distance
// is scaled down — at full length a step tunnels straight through a folded
// building.
fn sceneSdf(p: vec3f) -> f32 {
  let folded = foldWorld(p, params.scroll + FOLD_AHEAD, params.fold);
  return citySdf(folded) * 0.6;
}

fn march(origin: vec3f, direction: vec3f) -> f32 {
  var t = 0.0;
  for (var i = 0; i < MAX_STEPS; i++) {
    let d = sceneSdf(origin + direction * t);
    if (d < SURFACE) {
      return t;
    }
    t += d;
    if (t > MAX_DIST) {
      break;
    }
  }
  return -1.0;
}

fn normalAt(p: vec3f) -> vec3f {
  let e = vec2f(0.004, 0.0);
  return normalize(vec3f(
    sceneSdf(p + e.xyy) - sceneSdf(p - e.xyy),
    sceneSdf(p + e.yxy) - sceneSdf(p - e.yxy),
    sceneSdf(p + e.yyx) - sceneSdf(p - e.yyx),
  ));
}

// Hard-edged shadow with a soft penumbra, marched toward the sun. The whole
// look depends on this: without it the buildings are flat rectangles.
fn shadow(p: vec3f, light: vec3f) -> f32 {
  var result = 1.0;
  var t = 0.06;
  for (var i = 0; i < 40; i++) {
    let d = sceneSdf(p + light * t);
    if (d < 0.002) {
      return 0.0;
    }
    result = min(result, 9.0 * d / t);
    t += clamp(d, 0.05, 1.2);
    if (t > 34.0) {
      break;
    }
  }
  return saturate(result);
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let aspect = params.resolution.x / max(params.resolution.y, 1e-4);
  let sun = normalize(SUN);

  // Straight down. A tiny lean keeps the building sides from vanishing
  // completely without breaking the screen-to-road mapping.
  // Scrolling moves the camera toward +z, which is up-screen — into the
  // distance, and toward the fold.
  let along = params.scroll;
  var p = (uv - vec2f(0.5)) * VIEW_HEIGHT;
  p.x *= aspect;

  let origin = vec3f(p.x, CAMERA_Y, along - p.y);
  let direction = normalize(vec3f(0.06, -1.0, 0.05));

  var col = srgbToLinear3(vec3f(0.30, 0.33, 0.38));

  let t = march(origin, direction);
  if (t > 0.0) {
    let hit = origin + direction * t;
    let n = normalAt(hit);
    let lit = saturate(dot(n, sun)) * shadow(hit, sun);

    let onGround = hit.y < 0.05;
    let onRoad = abs(hit.x) < ROAD_HALF;

    var albedo = srgbToLinear3(vec3f(0.42, 0.43, 0.45));

    if (onGround) {
      if (onRoad) {
        // Asphalt: dark, with aggregate speckle and a worn sheen down the
        // wheel tracks.
        let grit = fbmSimplex3d(hit * 5.5, 4, 2.0, 0.5);
        albedo = srgbToLinear3(vec3f(0.31, 0.315, 0.325)) * (0.88 + 0.24 * grit);
        let wear = smoothstep(1.5, 0.7, abs(abs(hit.x) - 1.5));
        albedo *= 1.0 + wear * 0.16;

        // Centre line, dashed.
        let dash = step(0.55, fract(hit.z * 0.22));
        let centre = smoothstep(0.10, 0.05, abs(hit.x)) * dash;
        albedo = mix(albedo, srgbToLinear3(vec3f(0.78, 0.74, 0.55)), centre * 0.85);
      } else {
        // Pavement, with slab joints.
        let slab = smoothstep(0.03, 0.0, abs(fract(hit.z * 0.55) - 0.5) - 0.46);
        albedo = srgbToLinear3(vec3f(0.52, 0.51, 0.50));
        albedo *= 1.0 - slab * 0.22;
      }
    } else {
      // Roofs and the little of the sides that shows.
      let tint = lotTint(hit);
      albedo = srgbToLinear3(mix(vec3f(0.34, 0.33, 0.35), vec3f(0.62, 0.58, 0.54), tint));
      let roof = fbmSimplex3d(hit * 2.2 + vec3f(7.0, 0.0, 0.0), 3, 2.0, 0.5);
      albedo *= 0.90 + 0.18 * roof;
      // Sides read darker than roofs, which is most of what gives the blocks
      // their shape from straight above.
      albedo *= mix(0.55, 1.0, saturate(n.y));
    }

    // The form, painted on the tarmac. Screen space, because that is where the
    // browser put the form — and from directly above that is also the road.
    let panelLocal = (uv - params.panelCenter) * vec2f(aspect, 1.0);
    let panelActive = step(1e-5, params.panelHalf.x * params.panelHalf.y);
    let worn = fbmSimplex3d(vec3f(panelLocal * 26.0, 4.0), 3, 2.0, 0.5);
    let panelD = sdRoundedBox(
      panelLocal,
      params.panelHalf * vec2f(aspect, 1.0),
      0.006 * aspect,
    ) + worn * 0.004;

    // Only paint where there is road to paint on.
    let paintable = select(0.0, 1.0, onGround && onRoad);
    let paint = smoothstep(0.0015, -0.0015, panelD) * panelActive * paintable;
    let scuff = 0.72 + 0.28 * saturate(fbmSimplex3d(vec3f(panelLocal * 60.0, 9.0), 3, 2.0, 0.5) * 1.6 + 0.5);
    albedo = mix(albedo, srgbToLinear3(vec3f(0.88, 0.87, 0.83)) * scuff, paint * 0.94);

    // A generous ambient floor. A narrow street under a low sun is almost
    // entirely in shadow, and at 0.22 the tarmac came out black.
    let sky = srgbToLinear3(vec3f(0.42, 0.50, 0.64));
    col = albedo * (0.50 + lit * 0.95) + albedo * sky * 0.45 * saturate(n.y);
  }

  col = tonemapAces(col);
  col = contrast(col, 1.04);
  col *= 1.0 - vignette(uv, 0.26, 0.62);
  col = applyGrain(col, uv, params.resolution, params.time, 0.025);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
