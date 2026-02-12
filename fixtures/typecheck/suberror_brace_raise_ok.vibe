suberror AppError {
  Io(String);
  Parse(Int);
}

let fail = (x: Int) -> Unit with {Error} {
  if x == 0 {
    raise Io("io")
  } else {
    raise Parse(1)
  }
}
