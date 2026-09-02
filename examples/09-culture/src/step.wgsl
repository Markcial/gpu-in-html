// One step of the culture. Reads the previous state, writes the next one.
//
// This is the first shader in the repo that reads its own output. The host
// keeps two identical rgba16float targets and swaps them: this pass samples
// `state` (last frame) and renders into the other one, which becomes `state`
// for the next call. Ten of these run per displayed frame, because a reaction
// stepped once per frame at sixty hertz moves too slowly to watch.
//
// rgba16float matters. In rgba8unorm a concentration has 256 levels, the
// per-step deltas here are smaller than one of them, and the whole system
// quantises to a standstill within a second.

import { INERT, INOCULUM, react, reactionRates, sdObstacle, seedState } from "./rd.wgsl";

const MAX_OBSTACLES: u32 = 24u;

struct Params {
  resolution: vec2f,
  time: f32,
  aspect: f32,
  reset: f32,
  obstacleCount: f32,
  pointerRadius: f32,
  seedStrength: f32,
  pointer: vec2f,
  focused: vec4f,
  obstacles: array<vec4f, 24>,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var state: texture_2d<f32>;

// Texel fetch rather than a sampler: a Laplacian wants the nine neighbours
// exactly, and a filtered sample halfway between two of them would quietly
// smooth the system on top of its own diffusion.
fn sample(cell: vec2i, size: vec2i) -> vec2f {
  let c = clamp(cell, vec2i(0), size - vec2i(1));
  return textureLoad(state, c, 0).xy;
}

// The usual nine-point stencil: 0.2 on the edges, 0.05 on the corners, -1 at
// the centre. Weights sum to zero, so a flat field has zero Laplacian.
fn laplacian(cell: vec2i, size: vec2i, here: vec2f) -> vec2f {
  var sum = here * -1.0;
  sum += (sample(cell + vec2i(1, 0), size)
    + sample(cell + vec2i(-1, 0), size)
    + sample(cell + vec2i(0, 1), size)
    + sample(cell + vec2i(0, -1), size)) * 0.2;
  sum += (sample(cell + vec2i(1, 1), size)
    + sample(cell + vec2i(1, -1), size)
    + sample(cell + vec2i(-1, 1), size)
    + sample(cell + vec2i(-1, -1), size)) * 0.05;
  return sum;
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let size = vec2i(textureDimensions(state, 0));
  let cell = vec2i(uv * vec2f(size));

  if (params.reset > 0.5) {
    let seeded = seedState(vec2u(max(cell, vec2i(0))), u32(params.time * 97.0) + 1u);
    return vec4f(seeded, 0.0, 1.0);
  }

  let p = vec2f(uv.x * params.aspect, uv.y);

  // Distance to the page. One pass over the rectangles serves both jobs: the
  // inert interiors and the rates outside them.
  var distance = 1e9;
  let count = min(u32(params.obstacleCount), MAX_OBSTACLES);
  for (var i = 0u; i < count; i++) {
    distance = min(distance, sdObstacle(p, params.obstacles[i]));
  }

  // Inside an element nothing reacts. Held at the fixed point rather than
  // faded out, so the boundary is a hard edge the culture cannot cross.
  if (distance < 0.0) {
    return vec4f(INERT, 0.0, 1.0);
  }

  var here = sample(cell, size);
  let lap = laplacian(cell, size, here);
  var next = react(here, lap, reactionRates(distance), 1.0);

  // The pointer inoculates the medium. Both chemicals are set, not just B: a
  // cell handed B without giving back some A has nothing to feed on.
  let underPointer = 1.0 - smoothstep(params.pointerRadius * 0.4, params.pointerRadius, length(p - params.pointer));
  next = mix(next, INOCULUM, underPointer * params.seedStrength);

  // A focused field inoculates the medium beside it. The seed cannot go on the
  // field itself: the field sits inside a rectangle the reaction treats as
  // inert, so anything written there is overwritten by the fixed point on the
  // very next step. The host places the point just outside the containing box,
  // level with the field, and hands it over as xy plus a radius in z.
  if (params.focused.z > 0.0) {
    let reach = 1.0 - smoothstep(params.focused.z * 0.45, params.focused.z, length(p - params.focused.xy));
    next = mix(next, INOCULUM, reach);
  }

  return vec4f(next, 0.0, 1.0);
}
