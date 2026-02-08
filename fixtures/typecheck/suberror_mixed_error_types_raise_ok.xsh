suberror AppError(String);
suberror ParseError {
  Parse(Int);
}

let fail = (x: Int) -> Unit with {Error} {
  if x == 0 {
    raise AppError("boom")
  } else {
    raise Parse(x)
  }
}
