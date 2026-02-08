suberror AppError {
  Parse(Int);
}

let fail = () -> Unit with {Error} {
  raise Parse("oops")
}
