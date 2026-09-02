// An isometric city block.
//
// Pure module. Everything is laid out along z, with a road down the middle and
// buildings, parked cars and street trees on both sides.
//
// The one unusual argument is `clear`: 1 where the form is, 0 elsewhere. The
// caller works that out by projecting the sample point to screen space, and
// everything that would stand up out of the ground is suppressed there — the
// block leaves a paved plaza exactly where the page needs one.

import { sdBox, sdRoundBox, sdSphere } from "@gpu-in-html/wgsl/shape3d";
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

export const ROAD_HALF: f32 = 5.0;
const LOT: f32 = 4.4;
const SETBACK: f32 = 1.3;

fn lotRandom(cell: vec2i, salt: u32) -> f32 {
  return unitFloat(pcg2d(bitcast<vec2u>(cell) + vec2u(salt, salt * 2654435761u)).x);
}

export fn citySdf(p: vec3f, clear: f32) -> f32 {
  var d = p.y;

  // Nothing stands up inside the plaza. Scaling the heights to zero rather
  // than skipping the shapes keeps the field continuous as the plaza edge
  // moves, so buildings sink instead of popping.
  let stand = 1.0 - clear;
  if (stand < 0.01) {
    return d;
  }

  let base = i32(round(p.z / LOT));

  for (var s = 0; s < 2; s++) {
    let side = select(-1.0, 1.0, s == 1);
    for (var k = -1; k <= 1; k++) {
      let cell = vec2i(base + k, s);

      let height = (1.6 + 6.4 * lotRandom(cell, 3u)) * stand;
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

  let carBase = i32(round(p.z / 2.9));
  for (var s = 0; s < 2; s++) {
    let side = select(-1.0, 1.0, s == 1);
    for (var k = -1; k <= 1; k++) {
      let cell = vec2i(carBase + k, s + 8);
      if (lotRandom(cell, 5u) > 0.42) {
        let z = f32(carBase + k) * 2.9 + (lotRandom(cell, 13u) - 0.5) * 0.4;
        let body = vec3f(side * (ROAD_HALF - 1.05), 0.34 * stand, z);
        d = min(d, sdRoundBox(p - body, vec3f(0.82, 0.30 * stand, 1.06), 0.16 * stand));
        d = min(d, sdRoundBox(p - body - vec3f(0.0, 0.34 * stand, -0.1), vec3f(0.66, 0.24 * stand, 0.62), 0.14 * stand));
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
        let at = vec3f(side * (ROAD_HALF + 0.6), 0.0, z);
        let r = (0.66 + 0.26 * lotRandom(cell, 23u)) * stand;
        d = min(d, sdSphere(p - at - vec3f(0.0, (1.5 + r * 0.5) * stand, 0.0), max(r, 0.001)));
      }
    }
  }

  return d;
}

// Per-building tint, constant across a whole roof.
export fn lotTint(p: vec3f) -> f32 {
  let cell = vec2i(i32(round(p.z / LOT)), select(0, 1, p.x > 0.0));
  return lotRandom(cell, 47u);
}

