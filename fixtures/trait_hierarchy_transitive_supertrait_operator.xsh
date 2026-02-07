trait Eq
trait Ord: Eq
trait TotalOrd: Ord
impl TotalOrd for Int

let same = [T: TotalOrd](a: T, b: T) -> Bool {
  a == b
}

same(1, 1)

__DATA__
{"last":"true"}
