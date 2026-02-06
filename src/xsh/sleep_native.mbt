///|
/// Sleep for the specified number of milliseconds (native target)
fn sleep_ms(ms : Int64) -> Unit {
  // Use usleep (microseconds) - available on Unix-like systems
  let _ = usleep((ms * 1000L).to_int())

}

///|
extern "C" fn usleep(usec : Int) -> Int = "usleep"
