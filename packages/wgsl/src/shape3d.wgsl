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

// Cylinder along the y axis. `height` is the half-height.
export fn sdCappedCylinder(p: vec3f, height: f32, radius: f32) -> f32 {
  let d = abs(vec2f(length(p.xz), p.y)) - vec2f(radius, height);
  return min(max(d.x, d.y), 0.0) + length(max(d, vec2f(0.0)));
}

// A capsule with a different radius at each end — a limb, in one primitive.
// Inigo Quilez's round cone.
export fn sdRoundCone(p: vec3f, a: vec3f, b: vec3f, r1: f32, r2: f32) -> f32 {
  let ba = b - a;
  let l2 = dot(ba, ba);
  let rr = r1 - r2;
  let a2 = l2 - rr * rr;
  let il2 = 1.0 / max(l2, 1e-8);

  let pa = p - a;
  let y = dot(pa, ba);
  let z = y - l2;
  let xv = pa * l2 - ba * y;
  let x2 = dot(xv, xv);
  let y2 = y * y * l2;
  let z2 = z * z * l2;

  let k = sign(rr) * rr * rr * x2;
  if (sign(z) * a2 * z2 > k) {
    return sqrt(x2 + z2) * il2 - r2;
  }
  if (sign(y) * a2 * y2 < k) {
    return sqrt(x2 + y2) * il2 - r1;
  }
  return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
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

// Cylindrical surface coordinates for texturing a shape built around the y
// axis: x wraps once around the axis, y runs along it.
//
// `cellsAround` must be a whole number if you feed this to a tiled noise —
// that count is the tiling period. Pair it with `voronoiTiled` from
// `@gpu-in-html/wgsl/voronoi` and the pattern closes with no seam.
export fn cylindricalUv(p: vec3f, cellsAround: f32, cellsAlong: f32) -> vec2f {
  let angle = atan2(p.z, p.x) / 6.28318530717958647692 + 0.5;
  return vec2f(angle * cellsAround, p.y * cellsAlong);
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
