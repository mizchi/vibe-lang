///|
/// Sleep for the specified number of milliseconds (wasm target - no-op).
/// Current wasm runtime path does not provide a synchronous sleep primitive.
fn sleep_ms(ms : Int64) -> Unit {
  let _ = ms

}
