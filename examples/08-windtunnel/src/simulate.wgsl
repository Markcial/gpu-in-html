// The compute pass: move twenty thousand particles of air around the page.
//
// This is the first compute shader in the repo, and the first storage buffer.
// The particles live on the GPU for the life of the page — the host seeds the
// buffer once and never reads it back. What the host does supply, every frame,
// is the list of rectangles the browser measured, which is the only thing in
// here that knows the page exists.

import { Particle, curlFlow, obstacleNormal, sdObstacle } from "./flow.wgsl";
import { pcg3d, unitFloat } from "@vgpu/wgsl-std/hash";

// Matches MAX_OBSTACLES in main.ts.
const MAX_OBSTACLES: u32 = 24u;

struct Sim {
  pointer: vec2f,
  aspect: f32,
  time: f32,
  dt: f32,
  count: f32,
  obstacleCount: f32,
  pointerRadius: f32,
  obstacles: array<vec4f, 24>,
}

@group(0) @binding(0) var<uniform> sim: Sim;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;

// How far from a surface the air starts to feel it.
const SKIN: f32 = 0.030;

fn respawn(index: u32, salt: u32, seed: f32) -> Particle {
  let r = pcg3d(vec3u(index, salt, bitcast<u32>(seed)));
  var p: Particle;
  // Enters from the left edge, a little off screen so nothing is seen to appear.
  p.position = vec2f(-0.05 - 0.10 * unitFloat(r.z), unitFloat(r.x));
  p.velocity = vec2f(0.30 + 0.22 * unitFloat(r.y), 0.0);
  p.seed = unitFloat(r.z);
  // Staggered lifetimes, or the whole field would turn over at once.
  p.life = 3.0 + 7.0 * unitFloat(r.y);
  p.padA = 0.0;
  p.padB = 0.0;
  return p;
}

@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
  let index = gid.x;
  if (index >= u32(sim.count)) {
    return;
  }

  var p = particles[index];
  let salt = u32(sim.time * 60.0) + 1u;

  // A fresh buffer is all zeros, which would be twenty thousand particles
  // stacked in one corner with no velocity. Lifetime starts the cycle.
  if (p.life <= 0.0) {
    particles[index] = respawn(index, salt, p.seed + f32(index));
    return;
  }

  var velocity = p.velocity;

  // Free stream plus turbulence, eased towards rather than assigned, so a
  // particle keeps some of the momentum an obstacle gave it.
  let wind = vec2f(0.34, 0.0) + curlFlow(p.position, sim.time) * 0.16;
  velocity += (wind - velocity) * min(sim.dt * 2.6, 1.0);

  // The page. Each measured rectangle deflects the air twice: once by removing
  // the component of velocity heading into the surface, which is what makes
  // the flow slide along an edge rather than stop dead at it, and once by a
  // push down the outward normal that keeps particles out of the interior.
  let obstacles = min(u32(sim.obstacleCount), MAX_OBSTACLES);
  for (var i = 0u; i < obstacles; i++) {
    let box = sim.obstacles[i];
    let d = sdObstacle(p.position, box);
    if (d > SKIN) {
      continue;
    }

    let n = obstacleNormal(p.position, box);
    let into = -dot(velocity, n);
    if (into > 0.0) {
      velocity += n * into * mix(0.35, 1.0, smoothstep(SKIN, 0.0, d));
    }
    velocity += n * (SKIN - max(d, 0.0)) * 14.0;

    // Inside is a state to leave immediately, not to integrate out of.
    if (d < 0.0) {
      p.position += n * (-d + 0.001);
    }
  }

  // The pointer is one more obstacle, and the only one the reader can move.
  let toPointer = p.position - sim.pointer;
  let pd = length(toPointer) - sim.pointerRadius;
  if (pd < SKIN) {
    let n = toPointer / max(length(toPointer), 1e-5);
    let into = -dot(velocity, n);
    if (into > 0.0) {
      velocity += n * into;
    }
    velocity += n * (SKIN - max(pd, 0.0)) * 16.0;
  }

  p.velocity = velocity;
  p.position += velocity * sim.dt;
  p.life -= sim.dt;

  // Off the right edge, or wandered out of frame entirely.
  let escaped = p.position.x > sim.aspect + 0.06
    || p.position.y < -0.25
    || p.position.y > 1.25;
  if (escaped) {
    particles[index] = respawn(index, salt, p.seed + f32(index));
    return;
  }

  particles[index] = p;
}
