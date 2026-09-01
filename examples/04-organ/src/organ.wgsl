// The organ wall, seen from inside.
//
// Pure module. This is the same cylinder as the arm example, turned inside
// out: the camera sits in the lumen and the field is positive in the open
// space and negative in the tissue. Marching it from the inside is the whole
// trick — everything else follows from the camera being in the negative space
// of an ordinary tube.
//
// Motion here is deliberately slow. A body is never still, but it is also
// never busy: fast peristalsis reads as an animation loop rather than as
// something alive.

import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";

// Where the lumen's axis sits at a given height. The tube wanders, so you
// never see straight through it — a straight tube reads as a pipe, not a gut.
export fn tubeCenter(y: f32) -> vec2f {
  return vec2f(
    sin(y * 0.41) * 0.60 + sin(y * 0.17 + 1.7) * 0.34,
    cos(y * 0.33) * 0.54 + sin(y * 0.23 + 0.6) * 0.29,
  );
}

// Signed distance from a point in the lumen to the wall: positive in the open
// space, shrinking to zero at the tissue.
//
// `tone` (0..1) is muscular tone: it deepens the peristaltic rings and the
// longitudinal folds, and roughens the mucosa.
export fn lumenSdf(p: vec3f, time: f32, tone: f32) -> f32 {
  let centre = tubeCenter(p.y);
  let q = p.xz - centre;
  let r = length(q);
  let angle = atan2(q.y, q.x);

  // The radius has to leave real open space in front of the lens. At the
  // camera the wall is exactly `radius` away, so a tight tube plus a wide
  // field of view means the wall fills the frame and there is no lumen to see
  // down.
  var radius = 1.75;

  // Peristalsis: constriction rings travelling along the tube, slowly. This
  // and the breath below are the only things that move the wall, and between
  // them they are what makes the tunnel feel alive rather than extruded.
  radius += 0.26 * sin(p.y * 0.85 + time * 0.30) * (0.30 + tone);

  // A slow global dilation, like breathing. Small amplitude on purpose: it
  // should be felt rather than watched.
  radius += 0.05 * sin(time * 0.42);

  // Longitudinal folds running down the wall.
  radius -= (0.12 + 0.20 * tone) * (0.5 + 0.5 * cos(angle * 7.0 + p.y * 0.45));

  var d = radius - r;

  // Mucosal texture, only worth evaluating near the wall — it is the most
  // expensive term in the march and does nothing out in the open lumen.
  if (d < 0.45) {
    let n = fbmSimplex3d(
      vec3f(q * 2.6, p.y * 1.7) + vec3f(0.0, 0.0, time * 0.03),
      4,
      2.0,
      0.5,
    );
    d -= n * (0.09 + 0.13 * tone);
  }

  // The displacement breaks the Lipschitz bound the marcher relies on, so a
  // full step would cut through a fold. Shortening every step is the fix.
  return d * 0.60;
}

// Branching ridges where a noise field crosses zero — vessels under the
// mucosa. Returns 0..1. `width` sets how fine the branching reads, so the same
// function serves both the large veins and the capillary net.
export fn vessels(p: vec3f, time: f32, width: f32) -> f32 {
  let n = fbmSimplex3d(p + vec3f(0.0, time * 0.012, 0.0), 4, 2.1, 0.55);
  return 1.0 - smoothstep(0.0, width, abs(n));
}
