// An isometric city block.
//
// Pure module. Everything is laid out along z: a road down the middle and a
// row of buildings on each side, and nothing else. The windows are not
// geometry — they are shaded on by the caller from the hit position and the
// face normal, which costs one arithmetic lookup instead of thousands of extra
// distance evaluations per pixel.
//
// Every lot is described by the four helpers below rather than by numbers
// written out twice, because the caller has to be able to rebuild a building's
// exact frame from a point on its surface. Laying windows out in world
// coordinates cuts panes in half wherever a wall happens to start; laying them
// out in the building's own frame is what lets an integer number of bays and
// floors be fitted between its corners.
//
// The one unusual argument is `clear`: 1 where the form is, 0 elsewhere. The
// caller works that out by projecting the sample point to screen space, and
// everything that would stand up out of the ground is suppressed there — the
// block leaves a paved plaza exactly where the page needs one.

import { sdBox } from "@gpu-in-html/wgsl/shape3d";
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

export const ROAD_HALF: f32 = 5.0;
const LOT: f32 = 4.4;
const SETBACK: f32 = 1.3;

fn lotRandom(cell: vec2i, salt: u32) -> f32 {
  return unitFloat(pcg2d(bitcast<vec2u>(cell) + vec2u(salt, salt * 2654435761u)).x);
}

fn lotHalfX(cell: vec2i) -> f32 {
  return 1.05 + 1.45 * lotRandom(cell, 19u);
}

fn lotHalfZ(cell: vec2i) -> f32 {
  return 1.75 + 0.45 * lotRandom(cell, 11u);
}

fn lotHeight(cell: vec2i) -> f32 {
  return 2.2 + 7.4 * lotRandom(cell, 3u);
}

fn lotJitter(cell: vec2i) -> f32 {
  return (lotRandom(cell, 29u) - 0.5) * 0.6;
}

fn lotSide(cell: vec2i) -> f32 {
  return select(-1.0, 1.0, cell.y == 1);
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
    for (var k = -1; k <= 1; k++) {
      let cell = vec2i(base + k, s);
      let height = lotHeight(cell) * stand;
      let halfX = lotHalfX(cell);
      let centre = vec3f(
        lotSide(cell) * (ROAD_HALF + SETBACK + halfX),
        height * 0.5,
        f32(base + k) * LOT + lotJitter(cell),
      );
      d = min(d, sdBox(p - centre, vec3f(halfX, height * 0.5, lotHalfZ(cell))));
    }
  }

  return d;
}

// Which lot a surface point belongs to. Rounding p.z to the nearest lot is not
// enough: neighbouring buildings overlap, since a lot is 4.4 deep and a
// building can be 4.4 deep once its jitter is counted, so part of one
// building's wall rounds to the lot next door. That showed up as a seam
// mid-facade where the window rhythm and the tint changed. Testing the three
// candidates and taking the box the point actually lies on costs three
// distance evaluations at shading time and is exact.
fn lotCell(p: vec3f) -> vec2i {
  let s = select(0, 1, p.x > 0.0);
  let base = i32(round(p.z / LOT));

  var best = vec2i(base, s);
  var bestD = 1e9;
  for (var k = -1; k <= 1; k++) {
    let cell = vec2i(base + k, s);
    let halfX = lotHalfX(cell);
    let height = lotHeight(cell);
    let centre = vec3f(
      lotSide(cell) * (ROAD_HALF + SETBACK + halfX),
      height * 0.5,
      f32(base + k) * LOT + lotJitter(cell),
    );
    let d = abs(sdBox(p - centre, vec3f(halfX, height * 0.5, lotHalfZ(cell))));
    if (d < bestD) {
      bestD = d;
      best = cell;
    }
  }
  return best;
}

// The lot's footprint centre in xz.
export fn lotCentre(p: vec3f) -> vec2f {
  let cell = lotCell(p);
  return vec2f(
    lotSide(cell) * (ROAD_HALF + SETBACK + lotHalfX(cell)),
    f32(cell.x) * LOT + lotJitter(cell),
  );
}

// Half extent in x, half extent in z, and full height — the building's frame,
// so a caller can fit something to it exactly.
export fn lotExtent(p: vec3f) -> vec3f {
  let cell = lotCell(p);
  return vec3f(lotHalfX(cell), lotHalfZ(cell), lotHeight(cell));
}

// Per-building tint, constant across a whole roof.
export fn lotTint(p: vec3f) -> f32 {
  return lotRandom(lotCell(p), 47u);
}

// Which building a point belongs to, as a seed. Windows use it so that two
// neighbours do not light the same panes at the same height.
export fn lotSeed(p: vec3f) -> u32 {
  return pcg2d(bitcast<vec2u>(lotCell(p))).x;
}
