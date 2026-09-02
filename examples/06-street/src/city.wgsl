// An isometric city block.
//
// Pure module. Everything is laid out along z: a road down the middle and a
// row of buildings on each side, and nothing else. The windows are not
// geometry — they are shaded on by the caller from the hit position and the
// face normal, which costs one texture-free lookup instead of thousands of
// extra distance evaluations per pixel.
//
// The one unusual argument is `clear`: 1 where the form is, 0 elsewhere. The
// caller works that out by projecting the sample point to screen space, and
// everything that would stand up out of the ground is suppressed there — the
// block leaves a paved plaza exactly where the page needs one.

import { sdBox } from "@gpu-in-html/wgsl/shape3d";
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

export const ROAD_HALF: f32 = 5.0;
export const LOT: f32 = 4.4;
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

      let height = (2.2 + 7.4 * lotRandom(cell, 3u)) * stand;
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

  return d;
}

// Per-building tint, constant across a whole roof.
export fn lotTint(p: vec3f) -> f32 {
  let cell = vec2i(i32(round(p.z / LOT)), select(0, 1, p.x > 0.0));
  return lotRandom(cell, 47u);
}

// Which building a point belongs to, as a seed. Windows use it so that two
// neighbours do not light the same panes at the same height.
export fn lotSeed(p: vec3f) -> u32 {
  let cell = vec2i(i32(round(p.z / LOT)), select(0, 1, p.x > 0.0));
  return pcg2d(bitcast<vec2u>(cell)).x;
}
