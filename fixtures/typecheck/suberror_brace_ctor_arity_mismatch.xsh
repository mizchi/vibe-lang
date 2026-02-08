suberror AppError {
  Io(String);
}

let fail = () -> Unit with {Error} {
  raise Io()
}
