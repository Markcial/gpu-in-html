// Entry shader: an isometric city block that leaves a plaza for the form.
//
// The camera is orthographic and true-isometric, which is what makes the
// coupling work. Under an orthographic projection the map from world to screen
// is a fixed linear one, so the shader can project any sample point to screen
// space exactly and ask whether it falls inside the form's rectangle. Where it
// does, nothing is allowed to stand: the block opens into a paved plaza and the
// page sits in the gap it made.
//
// A perspective camera would not allow this — the projection depends on depth,
// and the form's upright rectangle would have to be skewed to lie on any
// surface. Isometric is the framing that makes an upright screen rectangle and
// a 3D scene agree.

import { applyGrain, contrast, vignette } from "@gpu-in-html/wgsl/post";
import { sdRoundedBox } from "@gpu-in-html/wgsl/shape2d";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";
import { saturate } from "@vgpu/wgsl-std/math";
import { ROAD_HALF, citySdf, lotTint } from "./city.wgsl";

struct Params {
  resolution: vec2f,
  panelCenter: vec2f,
  panelHalf: vec2f,
  time: f32,
  scroll: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const MAX_STEPS: i32 = 140;
const MAX_DIST: f32 = 170.0;
const SURFACE: f32 = 0.005;

// True isometric: azimuth 45°, elevation 35.264°. The view direction works out
// to (-1,-1,-1)/√3, which is where the tidy numbers below come from.
const ISO_FWD: vec3f = vec3f(-0.5773503, -0.5773503, -0.5773503);
const ISO_RIGHT: vec3f = vec3f(0.7071068, 0.0, -0.7071068);
const ISO_UP: vec3f = vec3f(-0.4082483, 0.8164966, -0.4082483);

// World units the frame covers vertically.
const VIEW: f32 = 20.0;
const SUN: vec3f = vec3f(-0.42, 0.66, -0.62);


fn focusPoint() -> vec3f {
  return vec3f(0.0, 0.0, -params.scroll);
}

// Exact inverse of the orthographic projection, which is the whole trick.
fn worldToScreen(p: vec3f, aspect: f32) -> vec2f {
  let rel = p - focusPoint();
  return vec2f(
    dot(rel, ISO_RIGHT) / (VIEW * aspect) + 0.5,
    0.5 - dot(rel, ISO_UP) / VIEW,
  );
}

// 1 inside the plaza the form asks for, 0 outside, soft at the edge so the
// buildings sink rather than pop as it moves.
fn plazaAt(p: vec3f, aspect: f32) -> f32 {
  let enabled = step(1e-5, params.panelHalf.x * params.panelHalf.y);
  let s = worldToScreen(p, aspect);
  let q = (s - params.panelCenter) * vec2f(aspect, 1.0);
  // A margin, so the clearing is comfortably larger than the text on it.
  let h = (params.panelHalf + vec2f(0.022, 0.012)) * vec2f(aspect, 1.0);
  let d = sdRoundedBox(q, h, 0.02 * aspect);
  // A wide ramp on purpose. A hard edge would slice buildings in half; over a
  // few world units the block instead steps down toward the clearing, which
  // reads as a terrace rather than as damage.
  return smoothstep(0.15, -0.02, d) * enabled;
}

fn sceneSdf(p: vec3f, aspect: f32) -> f32 {
  return citySdf(p, plazaAt(p, aspect));
}

fn march(origin: vec3f, direction: vec3f, aspect: f32) -> f32 {
  var t = 0.0;
  for (var i = 0; i < MAX_STEPS; i++) {
    let d = sceneSdf(origin + direction * t, aspect);
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

fn normalAt(p: vec3f, aspect: f32) -> vec3f {
  let e = vec2f(0.005, 0.0);
  return normalize(vec3f(
    sceneSdf(p + e.xyy, aspect) - sceneSdf(p - e.xyy, aspect),
    sceneSdf(p + e.yxy, aspect) - sceneSdf(p - e.yxy, aspect),
    sceneSdf(p + e.yyx, aspect) - sceneSdf(p - e.yyx, aspect),
  ));
}

fn shadow(p: vec3f, light: vec3f, aspect: f32) -> f32 {
  var result = 1.0;
  var t = 0.08;
  for (var i = 0; i < 34; i++) {
    let d = sceneSdf(p + light * t, aspect);
    if (d < 0.003) {
      return 0.0;
    }
    result = min(result, 8.0 * d / t);
    t += clamp(d, 0.06, 1.6);
    if (t > 30.0) {
      break;
    }
  }
  return saturate(result);
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let aspect = params.resolution.x / max(params.resolution.y, 1e-4);
  let sun = normalize(SUN);

  // Orthographic: every ray shares a direction and the image plane slides.
  let px = (uv.x - 0.5) * VIEW * aspect;
  let py = (0.5 - uv.y) * VIEW;
  let origin = focusPoint() + ISO_RIGHT * px + ISO_UP * py - ISO_FWD * 60.0;

  var col = srgbToLinear3(vec3f(0.62, 0.66, 0.72));

  let t = march(origin, ISO_FWD, aspect);
  if (t > 0.0) {
    let hit = origin + ISO_FWD * t;
    let n = normalAt(hit, aspect);
    let lit = saturate(dot(n, sun)) * shadow(hit, sun, aspect);
    let plaza = plazaAt(hit, aspect);

    let onGround = hit.y < 0.06;
    let onRoad = abs(hit.x) < ROAD_HALF;

    var albedo = srgbToLinear3(vec3f(0.42, 0.43, 0.45));

    if (onGround) {
      let grit = fbmSimplex3d(hit * 5.5, 4, 2.0, 0.5);
      if (onRoad) {
        albedo = srgbToLinear3(vec3f(0.32, 0.325, 0.335)) * (0.90 + 0.20 * grit);
        let dash = step(0.55, fract(hit.z * 0.22));
        albedo = mix(
          albedo,
          srgbToLinear3(vec3f(0.80, 0.76, 0.58)),
          smoothstep(0.11, 0.05, abs(hit.x)) * dash * 0.85,
        );
      } else {
        albedo = srgbToLinear3(vec3f(0.55, 0.545, 0.535)) * (0.94 + 0.10 * grit);
        let joint = smoothstep(0.03, 0.0, abs(fract(hit.z * 0.55) - 0.5) - 0.46);
        albedo *= 1.0 - joint * 0.18;
      }

      // The plaza itself: pale flagstones on a square grid, so it reads as
      // something built rather than as road with the buildings deleted.
      // Distance to the nearest cell edge, so the darkening lands on the
      // joints between flagstones and not on the stones themselves.
      let joints = max(
        smoothstep(0.43, 0.5, abs(fract(hit.x * 0.62) - 0.5)),
        smoothstep(0.43, 0.5, abs(fract(hit.z * 0.62) - 0.5)),
      );
      var paving = srgbToLinear3(vec3f(0.60, 0.59, 0.575)) * (0.94 + 0.12 * grit);
      paving *= 1.0 - joints * 0.26;
      // The road keeps running through the plaza rather than being paved over,
      // so the clearing reads as a square the street widens into — but mostly
      // paved, because dark tarmac under body text is unreadable and the page
      // has to stay legible wherever the browser puts it.
      albedo = mix(albedo, paving, plaza * select(1.0, 0.68, onRoad));
    } else {
      let tint = lotTint(hit);
      albedo = srgbToLinear3(mix(vec3f(0.36, 0.35, 0.37), vec3f(0.66, 0.62, 0.57), tint));
      let roof = fbmSimplex3d(hit * 2.2 + vec3f(7.0, 0.0, 0.0), 3, 2.0, 0.5);
      albedo *= 0.90 + 0.18 * roof;

      // Street trees, told apart by where they sit rather than by a material
      // id: the SDF is one long min() and carries no id out with it. The
      // canopies are the only thing between the kerb and the building line
      // that stands above a parked car and below a roof.
      let tree = step(1.05, hit.y)
        * step(hit.y, 3.1)
        * smoothstep(6.35, 6.05, abs(hit.x))
        * (1.0 - step(0.002, plaza));
      albedo = mix(albedo, srgbToLinear3(vec3f(0.29, 0.39, 0.25)), tree);
    }

    // Vertical faces see half the sky, so the ambient term follows the normal
    // instead of switching off — otherwise every shaded wall reads as a hole.
    let skyFacing = 0.5 + 0.5 * n.y;
    let sky = srgbToLinear3(vec3f(0.47, 0.55, 0.69));
    col = albedo * mix(0.30, 0.56, skyFacing) + albedo * lit * 1.00 + albedo * sky * 0.26 * skyFacing;
  }

  col = tonemapAces(col);
  col = contrast(col, 1.05);
  col *= 1.0 - vignette(uv, 0.24, 0.62);
  col = applyGrain(col, uv, params.resolution, params.time, 0.022);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
