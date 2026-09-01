// Seam-free Voronoi for cylindrical and tiled projections.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// `@vgpu/wgsl-std/noise` already ships voronoi2d, and for a flat field you
// should use that. This exists for one reason: a cylinder's angular coordinate
// wraps, and a Voronoi keyed on floor(position) puts a different cell on each
// side of the join, so the seam where the surface closes is visible as a line
// of mismatched cells. Wrapping the hashed cell index closes it.
//
// It uses the same pcg2d hash as wgsl-std, so cells generated here and there
// have the same character.

import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

export struct VoronoiTile {
  // Distance to the nearest feature point.
  f1: f32,
  // Distance to the second nearest. `f2 - f1` is near zero on a cell border,
  // which is the cheap way to draw the seams between cells.
  f2: f32,
  // Wrapped integer id of the owning cell. Stable across the seam, so a colour
  // looked up from it matches on both sides.
  cell: vec2i,
  // Vector from the sample to the nearest feature point.
  offset: vec2f,
}

// Voronoi whose x axis repeats every `periodX` cells. Feed it
// `cylindricalUv(p, periodX, along)` and the field closes around the cylinder.
//
// `periodX` must be a whole number of cells; anything else cannot tile.
export fn voronoiTiled(position: vec2f, periodX: f32) -> VoronoiTile {
  let baseCell = vec2i(floor(position));
  let period = max(i32(periodX), 1);

  var f1 = 1.0e20;
  var f2 = 1.0e20;
  var nearest = baseCell;
  var offset = vec2f(0.0);

  for (var y = -1; y <= 1; y++) {
    for (var x = -1; x <= 1; x++) {
      let cell = baseCell + vec2i(x, y);

      // Hash the wrapped index, but keep the unwrapped one for the position —
      // the feature point has to stay where it geometrically is, or the
      // distances go wrong at the join.
      let wrapped = vec2i(((cell.x % period) + period) % period, cell.y);
      let hashed = pcg2d(bitcast<vec2u>(wrapped));
      let feature = vec2f(f32(cell.x), f32(cell.y))
        + vec2f(unitFloat(hashed.x), unitFloat(hashed.y));

      let delta = feature - position;
      let distance = length(delta);

      if (distance < f1) {
        f2 = f1;
        f1 = distance;
        nearest = wrapped;
        offset = delta;
      } else if (distance < f2) {
        f2 = distance;
      }
    }
  }

  return VoronoiTile(f1, f2, nearest, offset);
}

// A stable 0..1 value per cell. Use it to pick a colour, a height, a material —
// anything that has to stay constant across the whole cell and not flicker
// when the camera moves.
export fn cellRandom(cell: vec2i, salt: u32) -> f32 {
  return unitFloat(pcg2d(bitcast<vec2u>(cell) + vec2u(salt, salt * 7919u)).x);
}
