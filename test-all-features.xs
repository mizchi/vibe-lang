-- Test all new features

-- Basic arithmetic with infix operators
let x = 1 + 2 * 3

-- Function definition with lowerCamelCase
let addOne x = x + 1

-- Pipeline operator
let result = 5 | addOne | addOne

-- Record types
let person = { name: "Alice", age: 30 }
let name = person.name

-- Block expressions
let y = {
  let tmp = 10
  tmp * 2
}

-- Hole completion (commented out as it's interactive)
-- let z = @

-- Effects with do block
do {
  perform print "Starting computation"
  perform print "Result: 7"
}

result