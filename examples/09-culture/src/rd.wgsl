// Gray-Scott reaction-diffusion, and the bit that makes it about a web page.
//
// Pure module. Two chemicals, A and B, live in the red and green channels of a
// texture. Every step reads the whole previous frame and writes a new one,
// which is the thing this example exists to show: a shader that can see what it
// drew last time.
//
// The page enters in two ways. Its measured rectangles are inert — no reaction
// happens inside them, so the culture grows right up to the text and stops —
// and the distance to the nearest rectangle chooses the feed and kill rates,
// so the layout decides which pattern grows where.

import { pcg2d, unitFloat } from "@vgpu/wgsl-std/hash";

// Diffusion rates. B spreads at half the rate of A, which is what makes the
// two separate into structure instead of mixing into a flat grey.
const DIFFUSE_A: f32 = 1.0;
const DIFFUSE_B: f32 = 0.5;

// Signed distance to a measured element, in page space: x runs 0..aspect, y
// runs 0..1 top-origin, same as everywhere else in this repo.
export fn sdObstacle(p: vec2f, box: vec4f) -> f32 {
  let radius = 0.010;
  let d = abs(p - box.xy) - max(box.zw - vec2f(radius), vec2f(0.0));
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

// Feed and kill for a point, chosen by how far it is from the page.
//
// These two numbers are the whole character of a Gray-Scott system: a few
// thousandths either way is the difference between drifting spots that divide
// like cells and a labyrinth of worms that never stops rearranging. Close to an
// element the culture goes to the labyrinth, further out it breaks into spots,
// so the page reads as something the growth is responding to rather than
// something laid on top of it.
export fn reactionRates(distance: f32) -> vec2f {
  let far = smoothstep(0.02, 0.30, distance);
  // Coral near the page, mitosis away from it. Both are classic Gray-Scott
  // regimes and both are robust; the pairs a few thousandths off these are
  // where the reaction dies out instead of settling into a pattern.
  let feed = mix(0.0545, 0.0580, far);
  let kill = mix(0.0620, 0.0630, far);
  return vec2f(feed, kill);
}

// One step of the reaction, given the local concentrations and the Laplacian
// already gathered by the caller.
export fn react(state: vec2f, laplacian: vec2f, rates: vec2f, dt: f32) -> vec2f {
  let a = state.x;
  let b = state.y;
  let reaction = a * b * b;
  let da = DIFFUSE_A * laplacian.x - reaction + rates.x * (1.0 - a);
  let db = DIFFUSE_B * laplacian.y + reaction - (rates.x + rates.y) * b;
  return clamp(state + vec2f(da, db) * dt, vec2f(0.0), vec2f(1.0));
}

// Starting condition: A everywhere, and a scatter of B for the reaction to
// take hold in. Without the scatter the system is at a fixed point and stays
// blank for ever.
export fn seedState(cell: vec2u, salt: u32) -> vec2f {
  let coarse = cell / vec2u(11u, 11u);
  let r = pcg2d(coarse + vec2u(salt, salt * 2654435761u));
  let blob = step(0.972, unitFloat(r.x));
  // Half A and a quarter B, not all of both. Seeding a cell with A = 1 and
  // B = 1 burns every unit of A in one step, leaving B nothing to feed on: the
  // blob collapses instead of spreading, and the whole plate is blank a few
  // hundred steps later.
  return mix(INERT, vec2f(0.5, 0.25), blob);
}

// The reaction's fixed point: all A, no B. Nothing happens here, for ever.
export const INERT: vec2f = vec2f(1.0, 0.0);

// What an inoculation looks like, wherever it comes from.
export const INOCULUM: vec2f = vec2f(0.5, 0.25);
