let id = (x: Int) -> Int {
  x
}
export let keep = () -> Int {
  id(1)
}
let answer: Int = 42
export let run = () -> Int {
  answer
}
export {
  run, keep
}

