let answer = 40 + 2
let id = (x: Int) -> Int { x }
export let run = () -> Int { answer }
export let keep = () -> Int { id(1) }
export { run, keep }
