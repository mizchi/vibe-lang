suberror AppError(String);

let rethrow = [E: Error](e: E) -> Unit with {Error} {
  raise e
}

let fail = () -> Unit with {Error} {
  rethrow(AppError("boom"))
}
