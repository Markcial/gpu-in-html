// Entry shader: an isometric city block that leaves a plaza for the form.
//
// The block is buildings and nothing else. Windows are shaded on from the hit
// position and the face normal rather than modelled, so a facade full of them
// costs the same as a bare wall.
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
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";
import { saturate } from "@vgpu/wgsl-std/math";
import { ROAD_HALF, citySdf, lotSeed, lotTint } from "./city.wgsl";

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

// Window pane spacing, in world units: one storey is WIN_V tall.
const WIN_U: f32 = 1.15;
const WIN_V: f32 = 1.30;
const GLASS: vec3f = vec3f(0.17, 0.20, 0.25);
const WARM: vec3f = vec3f(0.98, 0.84, 0.58);


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
  return smoothstep(0.045, -0.015, d) * enabled;
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

// Windows, shaded rather than modelled: adding a recess per pane would cost
// thousands of extra distance evaluations a pixel for something a wall-space
// coordinate can draw exactly. Returns coverage in x and lit-or-dark in y.
//
// The wall's own 2D frame comes from the dominant normal axis. A face whose
// normal is mostly x runs along z, so its horizontal coordinate is z.
fn windowsAt(p: vec3f, n: vec3f) -> vec2f {
  let wall = 1.0 - smoothstep(0.25, 0.6, abs(n.y));
  // Only on true box faces. Where a building is sagging into the plaza its
  // normals sweep through every direction, and a grid drawn on that surface
  // breaks up into speckle.
  let axis = max(max(abs(n.x), abs(n.y)), abs(n.z));
  let flat = smoothstep(0.04, 0.005, 1.0 - axis);
  let facingX = abs(n.x) > abs(n.z);
  let u = select(p.x, p.z, facingX);

  let cu = floor(u / WIN_U);
  let cv = floor(p.y / WIN_V);
  let fu = fract(u / WIN_U);
  let fv = fract(p.y / WIN_V);

  let pane = smoothstep(0.20, 0.27, fu) * smoothstep(0.80, 0.73, fu)
    * smoothstep(0.16, 0.23, fv) * smoothstep(0.74, 0.67, fv);

  // Nothing at street level: that floor is shopfront, and a pane sliced off by
  // the pavement reads as a hole in the wall.
  let above = smoothstep(0.9, 1.2, p.y);

  // Seeded per building and per face as well as per pane, so two neighbours do
  // not light the same windows at the same height.
  let face = select(0u, 8191u, facingX);
  let key = bitcast<vec2u>(vec2i(i32(cu), i32(cv))) + vec2u(lotSeed(p) + face, 7u);
  let lit = step(0.76, unitFloat(pcg2d(key).x));

  return vec2f(pane * above * wall * flat, lit);
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
  // Lit panes read as light sources, not as paint, so they survive shadow.
  var glow = 0.0;

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
      albedo = mix(albedo, paving, plaza * select(1.0, 0.52, onRoad));
    } else {
      let tint = lotTint(hit);
      albedo = srgbToLinear3(mix(vec3f(0.50, 0.49, 0.50), vec3f(0.78, 0.74, 0.68), tint));
      let roof = fbmSimplex3d(hit * 2.2 + vec3f(7.0, 0.0, 0.0), 3, 2.0, 0.5);
      albedo *= 0.90 + 0.18 * roof;

      let win = windowsAt(hit, n);
      albedo = mix(albedo, srgbToLinear3(mix(GLASS, WARM, win.y)), win.x);
      glow = win.x * win.y;
    }

    // Vertical faces see half the sky, so the ambient term follows the normal
    // instead of switching off — otherwise every shaded wall reads as a hole.
    let skyFacing = 0.5 + 0.5 * n.y;
    let sky = srgbToLinear3(vec3f(0.47, 0.55, 0.69));
    col = albedo * mix(0.44, 0.60, skyFacing) + albedo * lit * 1.00 + albedo * sky * 0.26 * skyFacing;
    col += srgbToLinear3(WARM) * glow * 0.34;
  }

  col = tonemapAces(col);
  col = contrast(col, 1.05);
  col *= 1.0 - vignette(uv, 0.24, 0.62);
  col = applyGrain(col, uv, params.resolution, params.time, 0.022);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
