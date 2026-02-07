// Type parameter T correctly captured in nested function
let make = [T]() -> T {
  let inner = () -> T { 0 }
  inner()
}
make()

__DATA__
{"last": "0"}
