import { trait Hashable } from ./trait_chain_base.xsh

export trait Keyed: Hashable
impl Keyed for Int

export let use_keyed = [T: Keyed](x: T) -> Int {
  let _ = x
  1
}
