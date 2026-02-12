use ./path / ref.xsh {
  type PathRef,
  type DynamicPath,
  dynamic
}
use ./path / runtime.xsh {
  resolve
}
test "path/runtime resolve is Env effectful" {
  let path = do {
    resolve(dynamic("./xsh/std/string.xsh"))
  }
  assert(path.is_absolute())
}
test "path/runtime DynamicPath::resolve is available" {
  let path = do {
    dynamic("./xsh/std/string.xsh").resolve()
  }
  assert(path.is_absolute())
}
