// The render pass: one instanced quad per particle, stretched along its own
// velocity so a fast particle draws a long streak and a stalled one draws a
// dot.
//
// There is no vertex buffer and no geometry. The quad's six corners come from
// @builtin(vertex_index) and the particle comes from @builtin(instance_index)
// straight out of the same storage buffer the compute pass just wrote. Nothing
// about a particle ever travels back through the host.
//
// The buffer is bound read-only here. WebGPU forbids writable storage in a
// vertex stage, and it would be wrong anyway: the simulation owns the state,
// the renderer only reads it.

import { Particle } from "./flow.wgsl";

struct Render {
  aspect: f32,
  stretch: f32,
  width: f32,
  fade: f32,
}

@group(0) @binding(0) var<uniform> render: Render;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;

struct VertexOut {
  @builtin(position) position: vec4f,
  @location(0) across: f32,
  @location(1) along: f32,
  @location(2) shade: f32,
}

@vertex
fn vs_main(@builtin(vertex_index) corner: u32, @builtin(instance_index) index: u32) -> VertexOut {
  let p = particles[index];

  let speed = length(p.velocity);
  let heading = select(vec2f(1.0, 0.0), p.velocity / max(speed, 1e-5), speed > 1e-5);
  let across = vec2f(-heading.y, heading.x);

  // Two triangles over the same four corners.
  var quad = array<vec2f, 6>(
    vec2f(-1.0, -1.0),
    vec2f(1.0, -1.0),
    vec2f(-1.0, 1.0),
    vec2f(1.0, -1.0),
    vec2f(1.0, 1.0),
    vec2f(-1.0, 1.0),
  );
  let c = quad[corner];

  let half = clamp(speed * render.stretch, render.width * 1.5, 0.055);
  let page = p.position + heading * (c.x * half) + across * (c.y * render.width);

  // Page space to clip space. y is top-origin on the way in and bottom-origin
  // on the way out, which is the flip.
  var out: VertexOut;
  out.position = vec4f(page.x / render.aspect * 2.0 - 1.0, 1.0 - page.y * 2.0, 0.0, 1.0);
  out.across = c.y;
  out.along = c.x;
  out.shade = clamp(speed * 1.5, 0.06, 1.0);

  // Particles fade in and out over their life rather than blinking.
  let ends = smoothstep(0.0, 0.7, p.life) * smoothstep(0.0, 0.35, p.position.x + 0.05);
  out.shade *= ends;
  return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
  // Round the ends and soften the sides, so a streak is a smear and not a bar.
  let profile = (1.0 - in.across * in.across) * (1.0 - in.along * in.along * 0.85);
  let a = profile * in.shade * render.fade;

  // Fast air runs cooler and brighter. Additive blending, so the colour is
  // already premultiplied by the alpha it is written with.
  let tint = mix(vec3f(0.32, 0.46, 0.78), vec3f(0.78, 0.90, 1.0), in.shade);
  return vec4f(tint * a, a);
}
