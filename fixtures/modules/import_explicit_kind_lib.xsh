export trait Eq
impl Eq for Int

export type IntBox = Int

export let add_eq = [T: Eq](a: T, b: T) -> Int {
  if a == b {
    1
  } else {
    0
  }
}
