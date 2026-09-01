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

// Radians per second of the breathing dilation. main.ts reads the same phase
// for its perfusion readout, so keep the two in step.
export const BREATH_RATE: f32 = 0.16;

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

  // Peristalsis: constriction rings travelling along the tube. These and the
  // breath below are the only things that move at all — the camera is fixed —
  // and they are deliberately near the threshold of noticing. Anything faster
  // reads as an animation playing rather than as tissue that happens to be
  // alive.
  // Amplitude matters more than rate here. At 0.26 against a radius of 1.75
  // the wall swells by an eighth of the lumen, and a bulge that large sweeping
  // through frame is read as motion no matter how slowly it travels.
  // The rate is what to watch, not just the amplitude. The wave's spatial
  // frequency is 0.85 rad per unit and roughly 1.4 units of wall are in frame,
  // so a phase rate of 0.09 slides the whole ring pattern across a quarter of
  // the frame in three seconds. At 0.035 it takes long enough that you notice
  // it only if you watch, which is the target.
  radius += 0.07 * sin(p.y * 0.85 + time * 0.035) * (0.30 + tone);

  // A slow global dilation, like breathing.
  radius += 0.018 * sin(time * BREATH_RATE);

  // Longitudinal folds running down the wall.
  radius -= (0.12 + 0.20 * tone) * (0.5 + 0.5 * cos(angle * 7.0 + p.y * 0.45));

  var d = radius - r;

  // Mucosal texture, only worth evaluating near the wall — it is the most
  // expensive term in the march and does nothing out in the open lumen.
  //
  // Note there is no time in this term. The wall's *shape* moves — it breathes
  // and peristalsis runs along it — but its texture does not travel through
  // it. Scrolling the noise as well makes the surface boil, and against
  // high-frequency shading that boiling is most of what reads as "too much
  // movement" even when every rate is already slow.
  if (d < 0.45) {
    let n = fbmSimplex3d(vec3f(q * 2.6, p.y * 1.7), 4, 2.0, 0.5);
    d -= n * (0.09 + 0.13 * tone);
  }

  // The displacement breaks the Lipschitz bound the marcher relies on, so a
  // full step would cut through a fold. Shortening every step is the fix.
  return d * 0.60;
}

// Texture space for the wall, anchored to an undeformed cylinder.
//
// Everything that decorates the surface — colour, vessels, micro-relief — has
// to be sampled here rather than at the world-space hit point. The wall moves:
// it breathes and peristalsis runs along it, so the hit point slides in and
// out radially. Sample world space and the whole pattern swims across the
// tissue as it moves, which reads as boiling static and, worse, as a surface
// the texture is not attached to. Projecting back to a fixed radius throws
// away exactly the component that moves.
export fn skin(p: vec3f) -> vec3f {
  let q = p.xz - tubeCenter(p.y);
  let angle = atan2(q.y, q.x);
  return vec3f(cos(angle) * 1.75, p.y, sin(angle) * 1.75);
}

// Branching ridges where a noise field crosses zero — vessels under the
// mucosa. Returns 0..1. `width` sets how fine the branching reads, so the same
// function serves both the large veins and the capillary net.
//
// Static by design: vessels are anatomy, not weather. Drifting them makes the
// whole surface crawl.
export fn vessels(p: vec3f, width: f32) -> f32 {
  let n = fbmSimplex3d(p, 4, 2.1, 0.55);
  return 1.0 - smoothstep(0.0, width, abs(n));
}
