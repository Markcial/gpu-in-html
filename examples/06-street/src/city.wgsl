// A street seen from directly above.
//
// Pure module. The camera looks straight down on purpose: the form is a
// screen-space rectangle, and only from directly above does screen space line
// up with the road plane well enough for a painted patch to read as paint
// lying on the tarmac rather than as an overlay floating over it.
//
// Height is sold by shadows instead of perspective, which is why the sun sits
// low.

import { sdBox, sdRoundBox, sdSphere } from "@gpu-in-html/wgsl/shape3d";
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

// Wide enough that a readable form column still lands inside the tarmac. At
// VIEW_HEIGHT 14 this puts the kerbs at roughly 47% of the frame width, so a
// 520px form fits on a 1280px viewport with room either side.
export const ROAD_HALF: f32 = 7.0;
const LOT: f32 = 4.4;
const SETBACK: f32 = 1.15;

fn lotRandom(cell: vec2i, salt: u32) -> f32 {
  return unitFloat(pcg2d(bitcast<vec2u>(cell) + vec2u(salt, salt * 2654435761u)).x);
}

// Distance to the ground and to the buildings lining both sides.
//
// Lots repeat along z. Only the three nearest are tested, which is enough
// because a lot is never wider than its period.
export fn citySdf(p: vec3f) -> f32 {
  var d = p.y;

  let base = i32(round(p.z / LOT));

  for (var s = 0; s < 2; s++) {
    let side = select(-1.0, 1.0, s == 1);
    for (var k = -1; k <= 1; k++) {
      let cell = vec2i(base + k, s);

      let height = 1.5 + 6.2 * lotRandom(cell, 3u);
      // Near the lot period, so frontages nearly touch. Leaving real gaps made
      // the block read as scattered tiles rather than a street.
      let halfZ = 1.75 + 0.45 * lotRandom(cell, 11u);
      let halfX = 1.05 + 1.45 * lotRandom(cell, 19u);
      let jitter = (lotRandom(cell, 29u) - 0.5) * 0.6;

      let centre = vec3f(
        side * (ROAD_HALF + SETBACK + halfX),
        height * 0.5,
        f32(base + k) * LOT + jitter,
      );
      d = min(d, sdBox(p - centre, vec3f(halfX, height * 0.5, halfZ)));
    }
  }

  // Parked cars along both kerbs, and street trees on the pavement. Two cheap
  // lattices, and between them they are most of what makes the block read as a
  // street rather than as blocks beside a grey band.
  let carBase = i32(round(p.z / 2.9));
  for (var s = 0; s < 2; s++) {
    let side = select(-1.0, 1.0, s == 1);
    for (var k = -1; k <= 1; k++) {
      let cell = vec2i(carBase + k, s + 8);
      if (lotRandom(cell, 5u) > 0.42) {
        let z = f32(carBase + k) * 2.9 + (lotRandom(cell, 13u) - 0.5) * 0.4;
        let body = vec3f(side * (ROAD_HALF - 1.05), 0.34, z);
        d = min(d, sdRoundBox(p - body, vec3f(0.82, 0.30, 1.06), 0.16));
        // Cabin, set back a little so the silhouette is not a plain brick.
        d = min(d, sdRoundBox(p - body - vec3f(0.0, 0.34, -0.1), vec3f(0.66, 0.24, 0.62), 0.14));
      }
    }
  }

  let treeBase = i32(round(p.z / 5.6));
  for (var s = 0; s < 2; s++) {
    let side = select(-1.0, 1.0, s == 1);
    for (var k = -1; k <= 1; k++) {
      let cell = vec2i(treeBase + k, s + 16);
      if (lotRandom(cell, 7u) > 0.3) {
        let z = f32(treeBase + k) * 5.6 + (lotRandom(cell, 17u) - 0.5) * 0.8;
        let at = vec3f(side * (ROAD_HALF + 0.55), 0.0, z);
        let r = 0.66 + 0.26 * lotRandom(cell, 23u);
        d = min(d, sdSphere(p - at - vec3f(0.0, 1.5 + r * 0.5, 0.0), r));
      }
    }
  }

  return d;
}

// Bend the far street up and over, the way the Paris street folds in
// Inception. Everything nearer than `start` is left alone, so the stretch of
// tarmac under the form stays flat and the screen-to-road mapping the paint
// depends on still holds.
//
// This is a domain bend: the sample point is un-bent before the field is
// evaluated. It is not a rigid transform, so it breaks the marcher's Lipschitz
// bound and callers have to shorten their steps.
export fn foldWorld(p: vec3f, start: f32, amount: f32) -> vec3f {
  let reach = max(p.z - start, 0.0);
  // Ease the curvature in rather than switching it on. A linear angle leaves a
  // hard crease where the flat street meets the folded one, because curvature
  // jumps from nothing to full across a single line.
  let a = reach * amount * smoothstep(0.0, 3.5, reach);
  let s = sin(a);
  let c = cos(a);
  let y = p.y;
  let z = p.z - start;
  return vec3f(p.x, c * y - s * z, s * y + c * z + start);
}

// Per-building tint, so a block is not one flat grey. Returns 0..1 keyed on the
// lot the point belongs to, so it is constant across a whole roof.
export fn lotTint(p: vec3f) -> f32 {
  let cell = vec2i(i32(round(p.z / LOT)), select(0, 1, p.x > 0.0));
  return lotRandom(cell, 47u);
}
