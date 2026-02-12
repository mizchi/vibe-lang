suberror AppError(String);

let boom = (x: Int) -> Int with {Error} {
  if x == 0 {
    raise AppError("boom")
  } else {
    x
  }
}

let safe = (x: Int) -> Int {
  try { boom(x) } catch { 0 }
}

safe(1)
