// 2D signed distance fields.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// Every sd* function returns signed distance in the same units as `p`:
// negative inside, zero on the boundary, positive outside. Feed the result to
// shaping.sdFill / shaping.sdStroke to draw it, or combine shapes first with
// the operators in `@gpu-in-html/wgsl/sdf` — those work on distances, so they
// are shared with shape3d.

export fn sdCircle(p: vec2f, radius: f32) -> f32 {
  return length(p) - radius;
}

export fn sdBox(p: vec2f, half: vec2f) -> f32 {
  let d = abs(p) - half;
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
}

export fn sdRoundedBox(p: vec2f, half: vec2f, radius: f32) -> f32 {
  // Clamp so an over-large radius degrades to a capsule instead of inverting.
  let r = min(radius, min(half.x, half.y));
  return sdBox(p, half - vec2f(r)) - r;
}

export fn sdSegment(p: vec2f, a: vec2f, b: vec2f) -> f32 {
  let pa = p - a;
  let ba = b - a;
  let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

// Regular n-pointed star, `radius` to the outer points.
export fn sdStar(p: vec2f, radius: f32, points: f32, inset: f32) -> f32 {
  let wedge = 3.14159265358979323846 / points;
  let a = atan2(p.y, p.x);
  let folded = abs(a - wedge * 2.0 * round(a / (wedge * 2.0)));
  let q = vec2f(cos(folded), sin(folded)) * length(p);
  let inner = radius * clamp(inset, 0.05, 0.95);
  return sdSegment(q, vec2f(radius, 0.0), vec2f(cos(wedge), sin(wedge)) * inner)
    - radius * 0.02;
}
