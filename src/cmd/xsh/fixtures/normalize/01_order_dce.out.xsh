use ./dep.xsh {
  dep
}
 trait Eq
 impl Eq for Int
let helper = () -> Int {
  1
}
export let run = () -> Int {
  helper()
}
export let run_io = () -> Int with {
  Error
} {
  run()
}
export {
  run, run_io
}

