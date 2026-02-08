suberror AppError(String);

let fail = () -> Unit with {Error} {
  raise Parse(1)
}
