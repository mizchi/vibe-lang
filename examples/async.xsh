// async/await examples

// Basic async function with {Async} effect
let async_id = (x: Int) -> Int with {Async} {
  await x
}

// Async computation
let async_double = (x: Int) -> Int with {Async} {
  await x * 2
}

// Chained async operations
let async_add = (a: Int, b: Int) -> Int with {Async} {
  await a + b
}

// Async with conditional
let async_abs = (x: Int) -> Int with {Async} {
  if x < 0 {
    await 0 - x
  } else {
    await x
  }
}

// Async with Error effect combined
let async_safe_div = (a: Int, b: Int) -> Int with {Async, Error} {
  if b == 0 {
    raise "division by zero"
  } else {
    await a / b
  }
}

// Tests
test "async_id" {
  let result = async_id(42)
  assert(eq(result, 42))
}

test "async_double" {
  let result = async_double(21)
  assert(eq(result, 42))
}

test "async_add" {
  let result = async_add(10, 32)
  assert(eq(result, 42))
}

test "async_abs_positive" {
  let result = async_abs(5)
  assert(eq(result, 5))
}

test "async_abs_negative" {
  let result = async_abs(-7)
  assert(eq(result, 7))
}

test "async_safe_div" {
  let result = async_safe_div(84, 2)
  assert(eq(result, 42))
}

test "async_safe_div_error" {
  let result = try {
    async_safe_div(10, 0)
  } catch {
    -1
  }
  assert(eq(result, -1))
}
