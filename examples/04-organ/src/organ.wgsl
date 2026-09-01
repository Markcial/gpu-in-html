// The organ wall, seen from inside.
//
// Pure module. This is the same cylinder as the arm example, turned inside
// out: the camera sits in the lumen and the field is positive in the open
// space and negative in the tissue. Marching it from the inside is the whole
// trick — everything else follows from the camera being in the negative space
// of an ordinary tube.
//
// Nothing here travels. The relief is fixed to the wall and the only motion is
// a pulse that moves the entire surface at once. A wave with a spatial phase
// slides features through the frame, which reads as peristalsis rather than as
// tissue that is simply alive.

import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";
import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";
import { voronoiTiled, cellRandom } from "@gpu-in-html/wgsl/voronoi";

const TAU: f32 = 6.28318530717958647692;

// Beats per second. 0.8 is 48 bpm — a resting rate. main.ts reports the same
// number, so keep the two in step.
export const BEAT_RATE: f32 = 0.8;

// How many bumps go around the circumference and along each unit of length.
// The first must be a whole number: it is the Voronoi's tiling period.
const BUMPS_AROUND: f32 = 15.0;
const BUMPS_ALONG: f32 = 2.2;

// Where the lumen's axis sits at a given height. The tube wanders, so the wall
// is never a flat plane facing the lens.
export fn tubeCenter(y: f32) -> vec2f {
  return vec2f(
    sin(y * 0.41) * 0.60 + sin(y * 0.17 + 1.7) * 0.34,
    cos(y * 0.33) * 0.54 + sin(y * 0.23 + 0.6) * 0.29,
  );
}

// A heartbeat, in 0..1, from a phase measured in beats.
//
// Two pulses — a strong one and a weaker one just after — then a long pause. A
// plain sine gives an even in-and-out that reads as breathing; the asymmetry
// and the gap are what make it read as a beat.
export fn heartbeat(beats: f32) -> f32 {
  let phase = fract(beats);
  let systole = exp(-pow((phase - 0.10) * 13.0, 2.0));
  let second = exp(-pow((phase - 0.27) * 15.0, 2.0)) * 0.5;
  return systole + second;
}

// Bumps, spread evenly over the wall and fixed to it.
//
// The seed points come from a Voronoi rather than from fbm on purpose. Noise
// clumps: it gives lumpy regions with bare patches between them. A Voronoi's
// feature points are close to evenly spaced, so domes placed on them scatter
// across the whole surface the way nodules on a real membrane do.
//
// The angular axis wraps, so the field closes with no seam where the wall
// meets itself.
fn bumpField(angle: f32, y: f32) -> f32 {
  let uv = vec2f((angle / TAU + 0.5) * BUMPS_AROUND, y * BUMPS_ALONG);
  let cell = voronoiTiled(uv, BUMPS_AROUND);
  let size = 0.30 + 0.14 * cellRandom(cell.cell, 5u);
  let height = 0.55 + 0.45 * cellRandom(cell.cell, 61u);
  let dome = smoothstep(size, 0.0, cell.f1) * height;

  // f1 is continuous but its gradient is not: it kinks wherever the nearest
  // feature changes. Displacing a surface by it directly creases along every
  // cell border, and those creases render as hard straight lines across the
  // wall. f2 - f1 goes to zero exactly on those borders, so fading the dome
  // out with it guarantees the displacement is flat wherever the kink is.
  return dome * smoothstep(0.0, 0.26, cell.f2 - cell.f1);
}

// Signed distance from a point in the lumen to the wall: positive in the open
// space, shrinking to zero at the tissue.
//
// `tone` (0..1) is muscular tone: it deepens the pulse and the folds.
export fn lumenSdf(p: vec3f, time: f32, tone: f32) -> f32 {
  let centre = tubeCenter(p.y);
  let q = p.xz - centre;
  let r = length(q);
  let angle = atan2(q.y, q.x);

  // The radius has to leave real open space in front of the lens. At the
  // camera the wall is exactly `radius` away, so a tight tube plus a wide
  // field of view means the wall fills the frame.
  var radius = 1.75;

  // The pulse. No spatial term, so the whole wall moves as one body.
  radius += 0.06 * heartbeat(time * BEAT_RATE) * (0.55 + tone * 0.70);

  // Longitudinal folds. Static, and shallow — the wall is smooth between its
  // bumps, not corrugated.
  radius -= (0.05 + 0.08 * tone) * (0.5 + 0.5 * cos(angle * 7.0 + p.y * 0.45));

  var d = radius - r;

  // Relief, only worth evaluating near the wall — it is the most expensive
  // term in the march and does nothing out in the open lumen.
  if (d < 0.45) {
    d -= bumpField(angle, p.y) * (0.11 + 0.06 * tone);
    // A little noise so the domes are not perfectly regular. Small: the tissue
    // between bumps should read as smooth.
    d -= fbmSimplex3d(vec3f(q * 2.6, p.y * 1.7), 3, 2.0, 0.5) * 0.030;
  }

  // The displacement breaks the Lipschitz bound the marcher relies on, so a
  // full step would cut through a bump. Shortening every step is the fix, and
  // it has to be short enough for the rays that graze the wall at the edge of
  // frame — those travel furthest per unit of surface crossed and are the
  // first to tunnel through a dome and leave a hard streak behind.
  return d * 0.48;
}

// Texture space for the wall, anchored to an undeformed cylinder.
//
// Everything that decorates the surface — colour, vessels, micro-relief — has
// to be sampled here rather than at the world-space hit point. The wall pulses,
// so the hit point slides in and out radially; sample world space and the whole
// pattern swims across the tissue as it moves. Projecting back to a fixed
// radius throws away exactly the component that moves.
export fn skin(p: vec3f) -> vec3f {
  let q = p.xz - tubeCenter(p.y);
  let angle = atan2(q.y, q.x);
  return vec3f(cos(angle) * 1.75, p.y, sin(angle) * 1.75);
}

// Branching ridges where a noise field crosses zero. Good enough for the
// diffuse capillary blush, where the eye reads texture rather than structure.
//
// It is the wrong tool for actual vessels, and visibly so: the zero set of a
// scalar field is a set of *closed contours*, so the "vessels" loop back on
// themselves and their ends simply stop. `venousNetwork` below exists for that
// reason.
//
// Static by design: vessels are anatomy, not weather.
export fn vessels(p: vec3f, width: f32) -> f32 {
  let n = fbmSimplex3d(p, 4, 2.1, 0.55);
  return 1.0 - smoothstep(0.0, width, abs(n));
}

fn cellRand2(cell: vec2i, salt: u32) -> f32 {
  return unitFloat(pcg2d(bitcast<vec2u>(cell) + vec2u(salt, salt * 2654435761u)).x);
}

fn rotate2(v: vec2f, a: f32) -> vec2f {
  let s = sin(a);
  let c = cos(a);
  return vec2f(c * v.x - s * v.y, s * v.x + c * v.y);
}

// A capsule whose radius changes along its length — one vessel segment.
fn taperedSegment(p: vec2f, a: vec2f, b: vec2f, ra: f32, rb: f32) -> f32 {
  let pa = p - a;
  let ba = b - a;
  let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
  return length(pa - ba * h) - mix(ra, rb, h);
}

// One vessel: a trunk that forks twice, every tip tapering to zero radius.
//
// The topology is the point. A tree has no cycles, so the network cannot close
// a circuit back on itself, and a tip whose radius reaches zero thins away
// instead of stopping dead — the two things the level-set field above gets
// wrong.
fn veinTree(p: vec2f, root: vec2f, dir: vec2f, len: f32, width: f32) -> f32 {
  let spread = 0.55;

  let fork = root + dir * len;
  var d = taperedSegment(p, root, fork, width, width * 0.70);

  let dirL = rotate2(dir, spread);
  let dirR = rotate2(dir, -spread);
  let forkL = fork + dirL * len * 0.72;
  let forkR = fork + dirR * len * 0.66;
  d = min(d, taperedSegment(p, fork, forkL, width * 0.70, width * 0.44));
  d = min(d, taperedSegment(p, fork, forkR, width * 0.70, width * 0.44));

  d = min(d, taperedSegment(p, forkL, forkL + rotate2(dirL, spread) * len * 0.52, width * 0.44, 0.0));
  d = min(d, taperedSegment(p, forkL, forkL + rotate2(dirL, -spread) * len * 0.48, width * 0.44, 0.0));
  d = min(d, taperedSegment(p, forkR, forkR + rotate2(dirR, spread) * len * 0.46, width * 0.44, 0.0));
  d = min(d, taperedSegment(p, forkR, forkR + rotate2(dirR, -spread) * len * 0.54, width * 0.44, 0.0));

  return d;
}

// A network of those on a wrapped lattice, returned as a 0..1 mask.
//
// Trees rooted in the neighbouring cells reach into this one, so coverage
// carries across the grid instead of stopping at cell edges, and the x index
// is wrapped before hashing so the field closes around the cylinder with no
// seam. Nothing here moves: this is anatomy.
export fn venousNetwork(uv: vec2f, period: f32) -> f32 {
  let base = vec2i(floor(uv));
  let wrap = max(i32(period), 1);
  var d = 1.0e9;

  for (var y = -1; y <= 1; y++) {
    for (var x = -1; x <= 1; x++) {
      let cell = base + vec2i(x, y);
      let hashed = vec2i(((cell.x % wrap) + wrap) % wrap, cell.y);

      let root = vec2f(f32(cell.x), f32(cell.y))
        + vec2f(cellRand2(hashed, 11u), cellRand2(hashed, 23u));
      let angle = cellRand2(hashed, 37u) * 6.28318530717958647692;
      let len = 0.34 + 0.16 * cellRand2(hashed, 53u);
      let width = 0.020 + 0.012 * cellRand2(hashed, 71u);

      d = min(d, veinTree(uv, root, vec2f(cos(angle), sin(angle)), len, width));
    }
  }

  // A soft edge, because these sit under the mucosa rather than on it.
  return 1.0 - smoothstep(-0.010, 0.022, d);
}
