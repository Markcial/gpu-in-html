// Operators that combine signed distance fields.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// These take distances, not points, so the same functions work for 2D and 3D
// fields. Import shapes from shape2d / shape3d and combine them here.

export fn opUnion(a: f32, b: f32) -> f32 {
  return min(a, b);
}

export fn opSubtract(a: f32, b: f32) -> f32 {
  return max(a, -b);
}

export fn opIntersect(a: f32, b: f32) -> f32 {
  return max(a, b);
}

// Polynomial smooth minimum. `k` is the blend width in the same units as the
// distances — this is what makes separate shapes read as one soft body.
export fn opSmoothUnion(a: f32, b: f32, k: f32) -> f32 {
  let h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-5), 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

export fn opSmoothIntersect(a: f32, b: f32, k: f32) -> f32 {
  let h = clamp(0.5 - 0.5 * (b - a) / max(k, 1e-5), 0.0, 1.0);
  return mix(b, a, h) + k * h * (1.0 - h);
}

export fn opSmoothSubtract(a: f32, b: f32, k: f32) -> f32 {
  let h = clamp(0.5 - 0.5 * (b + a) / max(k, 1e-5), 0.0, 1.0);
  return mix(a, -b, h) + k * h * (1.0 - h);
}

// Grow (positive radius) or shrink (negative) a shape by a uniform margin.
export fn opRound(d: f32, radius: f32) -> f32 {
  return d - radius;
}

// Turn a solid into a shell of the given thickness.
export fn opOnion(d: f32, thickness: f32) -> f32 {
  return abs(d) - thickness;
}
