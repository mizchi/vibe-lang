// This implementation is based on the fp algorithm described in
// https://research.swtch.com/fp and derived from rsc/fpfmt (BSD-style).

///|
priv struct PmHiLo(UInt64, UInt64)

///|
priv struct Scaler {
  pm : PmHiLo
  s : Int
}

///|
priv struct Unrounded(UInt64)

///|
fn bool_to_uint64(b : Bool) -> UInt64 {
  if b {
    1UL
  } else {
    0UL
  }
}

///|
fn len64(x : UInt64) -> Int {
  if x == 0UL {
    0
  } else {
    64 - x.clz()
  }
}

///|
fn mul64(a : UInt64, b : UInt64) -> (UInt64, UInt64) {
  let aLo = a & 0xffff_ffffUL
  let aHi = a >> 32
  let bLo = b & 0xffff_ffffUL
  let bHi = b >> 32
  let x = aLo * bLo
  let y = aHi * bLo + (x >> 32)
  let z = aLo * bHi + (y & 0xffff_ffffUL)
  let w = aHi * bHi + (y >> 32) + (z >> 32)
  let lo = a * b
  let hi = w
  (hi, lo)
}

///|
fn rotr64(x : UInt64, r : Int) -> UInt64 {
  if r == 0 {
    x
  } else {
    (x >> r) | (x << (64 - r))
  }
}

///|
fn unpack64(f : Double) -> (UInt64, Int) {
  let shift = 11
  let minExp = -(1074 + shift)
  let b : UInt64 = f.reinterpret_as_uint64()
  let mut m = (1UL << 63) | ((b & ((1UL << 52) - 1UL)) << shift)
  let mut e : Int = ((b >> 52) & ((1UL << shift) - 1UL)).to_int()
  if e == 0 {
    m = m & ((1UL << 63) - 1UL)
    e = minExp
    let s = 64 - len64(m)
    return (m << s, e - s)
  }
  (m, e - 1 + minExp)
}

///|
fn log2Pow10(x : Int) -> Int {
  // floor(log2(10**x)) ~= floor(x * 108853 / 2^15)
  (x * 108853) >> 15
}

///|
fn log10_pow2(x : Int) -> Int {
  // floor(log10(2**x)) ~= floor(x * 78913 / 2^18)
  (x * 78913) >> 18
}

///|
fn skewed(e : Int) -> Int {
  // floor(log10(3/4 * 2**e)) ~= floor(e*631305/2^21 - 261663/2^21)
  (e * 631305 - 261663) >> 21
}

///|
fn Unrounded::raw(self : Unrounded) -> UInt64 {
  let Unrounded(v) = self
  v
}

///|
fn Unrounded::floor(self : Unrounded) -> UInt64 {
  (self.raw() + 0UL) >> 2
}

///|
fn Unrounded::round(self : Unrounded) -> UInt64 {
  let u = self.raw()
  (u + 1UL + ((u >> 2) & 1UL)) >> 2
}

///|
fn Unrounded::ceil(self : Unrounded) -> UInt64 {
  (self.raw() + 3UL) >> 2
}

///|
fn Unrounded::nudge(self : Unrounded, delta : Int) -> Unrounded {
  let u = self.raw()
  if delta == 0 {
    self
  } else if delta > 0 {
    Unrounded(u + delta.to_uint64())
  } else {
    Unrounded(u - (-delta).to_uint64())
  }
}

///|
fn prescale(e : Int, p : Int, lp : Int) -> Scaler {
  Scaler::{ pm: fp_pow10_tab[p - fp_pow10_min], s: -(e + lp + 3) }
}

///|
fn uscale(x : UInt64, c : Scaler) -> Unrounded {
  let PmHiLo(pm_hi, pm_lo) = c.pm
  let (hi, mid) = mul64(x, pm_hi)
  let mut sticky = 1UL
  let shift = c.s
  if (hi & ((1UL << (shift & 63)) - 1UL)) == 0UL {
    let (mid2, _) = mul64(x, pm_lo)
    sticky = bool_to_uint64(mid - mid2 > 1UL)
    let mut hi = hi
    if mid < mid2 {
      hi -= 1UL
    }
    return Unrounded((hi >> shift) | sticky)
  }
  Unrounded((hi >> shift) | sticky)
}

///|
fn trim_zeros(x : UInt64, p : Int) -> (UInt64, Int) {
  let max_uint64 = 0xffff_ffff_ffff_ffffUL
  let inv5p8 = 0xc767_074b_22e9_0e21UL
  let inv5p4 = 0xd288_ce70_3afb_7e91UL
  let inv5p2 = 0x8f5c_28f5_c28f_5c29UL
  let inv5 = 0xcccc_cccc_cccc_cccdUL
  let mut x = x
  let mut p = p
  let d1 = rotr64(x * inv5, 1)
  if d1 <= max_uint64 / 10UL {
    x = d1
    p += 1
  } else {
    return (x, p)
  }
  let d8 = rotr64(x * inv5p8, 8)
  if d8 <= max_uint64 / 100_000_000UL {
    x = d8
    p += 8
  }
  let d4 = rotr64(x * inv5p4, 4)
  if d4 <= max_uint64 / 10_000UL {
    x = d4
    p += 4
  }
  let d2 = rotr64(x * inv5p2, 2)
  if d2 <= max_uint64 / 100UL {
    x = d2
    p += 2
  }
  let d = rotr64(x * inv5, 1)
  if d <= max_uint64 / 10UL {
    x = d
    p += 1
  }
  (x, p)
}

///|
fn fp_short(f : Double) -> (UInt64, Int) {
  let (m, e) = unpack64(f)
  let minExp = -1085
  let mut z = 11
  let mut p = 0
  let mut min : UInt64 = 0UL
  if m == 1UL << 63 && e > minExp {
    p = -skewed(e + z)
    min = m - (1UL << (z - 2))
  } else {
    if e < minExp {
      z = 11 + (minExp - e)
    }
    p = -log10_pow2(e + z)
    min = m - (1UL << (z - 1))
  }
  let max = m + (1UL << (z - 1))
  let odd = ((m >> z) & 1UL).to_int()
  let pre = prescale(e, p, log2Pow10(p))
  let dmin = uscale(min, pre).nudge(odd).ceil()
  let dmax = uscale(max, pre).nudge(-odd).floor()
  let d10 = dmax / 10UL
  if d10 * 10UL >= dmin {
    return trim_zeros(d10, -(p - 1))
  }
  let mut d = dmin
  if d < dmax {
    d = uscale(m, pre).round()
  }
  (d, -p)
}

///|
fn zeros_string(count : Int) -> String {
  if count <= 0 {
    return ""
  }
  let sb = StringBuilder::new(size_hint=count)
  for _ in 0..<count {
    sb.write_char('0')
  }
  sb.to_string()
}

///|
fn fp_format(d : UInt64, p : Int) -> String {
  let digits = d.to_string()
  let nd = digits.length()
  let exp = p + nd - 1
  if exp >= -6 && exp < 21 {
    if exp < 0 {
      return "0." + zeros_string(-exp - 1) + digits
    }
    if exp + 1 >= nd {
      return digits + zeros_string(exp + 1 - nd)
    }
    let left = digits.unsafe_substring(start=0, end=exp + 1)
    let right = digits.unsafe_substring(start=exp + 1, end=nd)
    return left + "." + right
  }
  let exp_sign = if exp < 0 { "-" } else { "+" }
  let exp_abs = exp.abs().to_string()
  if nd == 1 {
    return digits + "e" + exp_sign + exp_abs
  }
  let head = digits.unsafe_substring(start=0, end=1)
  let tail = digits.unsafe_substring(start=1, end=nd)
  head + "." + tail + "e" + exp_sign + exp_abs
}

///|
/// Converts a double-precision floating-point number to its shortest
/// decimal representation using the fp algorithm, and then formats it
/// using JavaScript-style rules.
pub fn double_to_string(val : Double) -> String {
  if val == 0.0 {
    return "0"
  }
  let bits = val.reinterpret_as_uint64()
  let sign = bits >> 63 != 0UL
  let exponent : Int = ((bits >> 52) & 0x7ffUL).to_int()
  let mantissa : UInt64 = bits & ((1UL << 52) - 1UL)
  if exponent == 0x7ff {
    return if mantissa != 0UL {
      "NaN"
    } else if sign {
      "-Infinity"
    } else {
      "Infinity"
    }
  }
  let abs = if sign { -val } else { val }
  let (d, p) = fp_short(abs)
  let body = fp_format(d, p)
  if sign {
    "-" + body
  } else {
    body
  }
}
