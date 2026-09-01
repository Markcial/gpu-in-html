// 3D signed distance fields and domain operators for raymarching.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// Combine these with the operators in `@gpu-in-html/wgsl/sdf`.
//
// Note on what is NOT here: there is no generic `march()` or `normalAt()`.
// Both need to call *your* scene function, and WGSL has no function pointers
// or generics, so a library cannot take one. The march loop belongs in the
// entry shader; everything it needs that does not depend on the scene —
// shapes, domain operators, camera rays — lives here and in camera.wgsl.

export fn sdSphere(p: vec3f, radius: f32) -> f32 {
  return length(p) - radius;
}

export fn sdBox(p: vec3f, half: vec3f) -> f32 {
  let d = abs(p) - half;
  return length(max(d, vec3f(0.0))) + min(max(d.x, max(d.y, d.z)), 0.0);
}

export fn sdRoundBox(p: vec3f, half: vec3f, radius: f32) -> f32 {
  return sdBox(p, half - vec3f(radius)) - radius;
}

// `t` is (major radius, tube radius). Lies in the xz plane.
export fn sdTorus(p: vec3f, t: vec2f) -> f32 {
  let q = vec2f(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}

export fn sdCapsule(p: vec3f, a: vec3f, b: vec3f, radius: f32) -> f32 {
  let pa = p - a;
  let ba = b - a;
  let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h) - radius;
}

// `n` must be normalized; w is the offset along it.
export fn sdPlane(p: vec3f, n: vec3f, w: f32) -> f32 {
  return dot(p, n) + w;
}

export fn sdEllipsoid(p: vec3f, r: vec3f) -> f32 {
  let k0 = length(p / r);
  let k1 = length(p / (r * r));
  return k0 * (k0 - 1.0) / max(k1, 1e-6);
}

// Tile space infinitely with period `c`, so one shape becomes a lattice.
export fn opRepeat(p: vec3f, c: vec3f) -> vec3f {
  return p - c * round(p / c);
}

// Mirror across the given axes. Pass 1.0 to fold an axis, 0.0 to leave it.
export fn opMirror(p: vec3f, axes: vec3f) -> vec3f {
  return mix(p, abs(p), axes);
}

// Twist around the y axis, `amount` radians per unit of height.
export fn opTwist(p: vec3f, amount: f32) -> vec3f {
  let a = p.y * amount;
  let s = sin(a);
  let c = cos(a);
  return vec3f(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

// Rotation matrices, for placing shapes without a full transform stack.
export fn rotX(a: f32) -> mat3x3f {
  let s = sin(a);
  let c = cos(a);
  return mat3x3f(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c);
}

export fn rotY(a: f32) -> mat3x3f {
  let s = sin(a);
  let c = cos(a);
  return mat3x3f(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
}
