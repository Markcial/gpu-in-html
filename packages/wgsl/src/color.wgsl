// Colour: transfer functions, perceptual space, palettes, and tonemapping.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// Everything here works in linear light unless the name says otherwise. Do the
// arithmetic linear, tonemap once, and encode to sRGB as the last step before
// writing the fragment.

export const TAU_COLOR: f32 = 6.28318530717958647692;

// Cosine gradient palette (Inigo Quilez). `t` wraps, so animating it loops
// seamlessly. a = bias, b = amplitude, c = frequency, d = phase.
export fn palette(t: f32, a: vec3f, b: vec3f, c: vec3f, d: vec3f) -> vec3f {
  return a + b * cos(TAU_COLOR * (c * t + d));
}

// The house palette the examples reuse, so they read as one family.
export fn paletteDefault(t: f32) -> vec3f {
  return palette(
    t,
    vec3f(0.5),
    vec3f(0.5),
    vec3f(1.0),
    vec3f(0.0, 0.33, 0.67),
  );
}

export fn linearToSrgb(c: vec3f) -> vec3f {
  let low = c * 12.92;
  let high = 1.055 * pow(max(c, vec3f(0.0)), vec3f(1.0 / 2.4)) - 0.055;
  return select(high, low, c <= vec3f(0.0031308));
}

export fn srgbToLinear(c: vec3f) -> vec3f {
  let low = c / 12.92;
  let high = pow((max(c, vec3f(0.0)) + 0.055) / 1.055, vec3f(2.4));
  return select(high, low, c <= vec3f(0.04045));
}

// Signed cube root, so the Oklab transform survives negative intermediates.
fn cbrt(x: f32) -> f32 {
  return sign(x) * pow(abs(x), 1.0 / 3.0);
}

// Oklab (Björn Ottosson). Mixing and gradients look right in this space:
// interpolating two colours here keeps lightness and chroma perceptually even
// instead of dipping through grey the way linear RGB does.
export fn linearToOklab(c: vec3f) -> vec3f {
  let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
  let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
  let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;

  let l_ = cbrt(l);
  let m_ = cbrt(m);
  let s_ = cbrt(s);

  return vec3f(
    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
  );
}

export fn oklabToLinear(lab: vec3f) -> vec3f {
  let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
  let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
  let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;

  let l = l_ * l_ * l_;
  let m = m_ * m_ * m_;
  let s = s_ * s_ * s_;

  return vec3f(
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  );
}

// Oklch is Oklab in polar form: (lightness, chroma, hue in turns). Rotating
// hue is a single add here.
export fn oklchToOklab(lch: vec3f) -> vec3f {
  let h = lch.z * TAU_COLOR;
  return vec3f(lch.x, lch.y * cos(h), lch.y * sin(h));
}

export fn oklabToOklch(lab: vec3f) -> vec3f {
  return vec3f(lab.x, length(lab.yz), atan2(lab.z, lab.y) / TAU_COLOR);
}

// Perceptually even mix between two linear colours, via Oklab.
export fn mixOklab(a: vec3f, b: vec3f, t: f32) -> vec3f {
  return oklabToLinear(mix(linearToOklab(a), linearToOklab(b), t));
}

// ACES filmic curve, Narkowicz's fit. Cheap, and it keeps highlights from
// clipping to flat white.
export fn tonemapAces(x: vec3f) -> vec3f {
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3f(0.0), vec3f(1.0));
}
