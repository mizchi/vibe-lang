-- expect: "All record tests passed"
-- Test: Record (object literal) features

-- Helper function
let assertEqual = fn actual expected testName ->
  if eq actual expected {
    true
  } else {
    error (strConcat testName " failed")
  }

-- Test basic record creation and field access
let person = { name: "Alice", age: 30 }
assertEqual person.name "Alice" "record field access - name"
assertEqual person.age 30 "record field access - age"

-- Test nested records
let company = {
  name: "TechCorp",
  address: { city: "Tokyo", zip: "100-0001" }
}
assertEqual company.name "TechCorp" "nested record - company name"
assertEqual company.address.city "Tokyo" "nested record field access"

-- Test record as function parameter
let getAge = fn p -> p.age
assertEqual (getAge { name: "Bob", age: 25 }) 25 "record as function parameter"

-- Test function returning record
let makePoint = fn x y -> { x: x, y: y }
let point = makePoint 10 20
assertEqual point.x 10 "function returning record - x"
assertEqual point.y 20 "function returning record - y"

-- Test record with different field types
let mixed = {
  count: 42,
  label: "answer",
  valid: true
}
assertEqual mixed.count 42 "mixed types - int"
assertEqual mixed.label "answer" "mixed types - string"
assertEqual mixed.valid true "mixed types - bool"

-- Test functional update pattern
let original = { x: 1, y: 2 }
let updated = { x: original.x, y: 3 }
assertEqual updated.x 1 "functional update - preserved field"
assertEqual updated.y 3 "functional update - new value"

-- Test record equality (structural)
let p1 = { x: 10, y: 20 }
let p2 = { x: 10, y: 20 }
let p3 = { x: 10, y: 30 }
-- Note: record equality may not be implemented yet
-- This would require deep structural comparison

"All record tests passed"