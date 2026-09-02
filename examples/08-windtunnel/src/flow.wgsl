// Air over a web page.
//
// Pure module, shared by all three shaders in this example: the compute pass
// that moves the particles, the render pass that draws them, and the fullscreen
// pass that lights the obstacles.
//
// Everything works in "page space": x runs 0..aspect, y runs 0..1 top-origin,
// which is the uv space vgpu hands a fragment shader with the x axis stretched
// so that a circle is round. Every DOM rectangle the host measures arrives in
// that space as vec4f(centreX, centreY, halfX, halfY).

import { simplex2d } from "@vgpu/wgsl-std/noise/simplex";

// Signed distance to a measured element. The corner radius is a constant
// rather than a per-element uniform: the page's own border-radius is a few
// pixels, and at this scale nothing can tell the difference.
export fn sdObstacle(p: vec2f, box: vec4f) -> f32 {
  let radius = 0.010;
  let d = abs(p - box.xy) - max(box.zw - vec2f(radius), vec2f(0.0));
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

// Outward normal of an element's surface. Central differences rather than the
// closed form, because the closed form of a rounded box's gradient has to
// branch on which region the point is in and this does not.
export fn obstacleNormal(p: vec2f, box: vec4f) -> vec2f {
  let e = vec2f(0.0012, 0.0);
  let g = vec2f(
    sdObstacle(p + e.xy, box) - sdObstacle(p - e.xy, box),
    sdObstacle(p + e.yx, box) - sdObstacle(p - e.yx, box),
  );
  let len = length(g);
  return select(vec2f(0.0, -1.0), g / len, len > 1e-6);
}

// Stream function for the background turbulence. Taking the curl of a scalar
// field instead of sampling two noise channels is what keeps the flow
// divergence-free: air neither piles up nor thins out on its own, so the only
// thing that gathers or parts the particles is the page.
fn streamFunction(p: vec2f, t: f32) -> f32 {
  return simplex2d(vec2f(p.x * 1.7 + t * 0.035, p.y * 2.6)) * 0.50
    + simplex2d(vec2f(p.x * 4.3 - t * 0.055, p.y * 5.4)) * 0.20;
}

export fn curlFlow(p: vec2f, t: f32) -> vec2f {
  let e = 0.012;
  let dx = streamFunction(p + vec2f(e, 0.0), t) - streamFunction(p - vec2f(e, 0.0), t);
  let dy = streamFunction(p + vec2f(0.0, e), t) - streamFunction(p - vec2f(0.0, e), t);
  // curl of (0, 0, psi) in 2D: rotate the gradient a quarter turn.
  return vec2f(dy, -dx) / (2.0 * e);
}

// One particle of air. Thirty-two bytes, so the host can seed the buffer with a
// plain Float32Array of eight floats per particle and the two pads keep the
// stride honest without anyone having to think about it again.
export struct Particle {
  position: vec2f,
  velocity: vec2f,
  seed: f32,
  life: f32,
  padA: f32,
  padB: f32,
}
