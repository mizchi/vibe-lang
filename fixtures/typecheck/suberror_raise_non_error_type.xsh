enum NotError {
  NotError(String);
}

let bad = () -> Unit with {Error} {
  raise NotError("boom")
}
