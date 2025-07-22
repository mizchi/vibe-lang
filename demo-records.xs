; Demonstration of record (object literal) features

; 1. Basic record creation
(let person { name: "Alice", age: 30, city: "Tokyo" })

; 2. Field access
(let name person.name)
(let age person.age)

; 3. Nested records
(let company {
  name: "TechCorp",
  address: {
    street: "123 Main St",
    city: "San Francisco",
    zip: "94105"
  },
  employees: 50
})

; 4. Access nested fields
(let companyCity company.address.city)

; 5. Records with different types
(let mixed {
  count: 42,
  label: "answer",
  valid: true,
  items: (list 1 2 3)
})

; 6. Function that takes a record
(let getFullName (fn (person)
  (strConcat person.firstName (strConcat " " person.lastName))))

(let fullName (getFullName { firstName: "John", lastName: "Doe" }))

; 7. Function that returns a record
(let makePoint (fn (x y)
  { x: x, y: y }))

(let point (makePoint 10 20))

; 8. Record pattern matching (if supported)
; Currently, pattern matching on records may not be implemented
; This is a potential future feature

; 9. Update record fields (functional update)
; This creates a new record with updated fields
(let updatedPerson (let newAge 31 in
  { name: person.name, age: newAge, city: person.city }))

; 10. List of records
(let people (list
  { name: "Alice", age: 30 },
  { name: "Bob", age: 25 },
  { name: "Charlie", age: 35 }))

; Access first person's name
(let firstPerson (match people
  ((list p ... rest) p)
  (_ { name: "Nobody", age: 0 })))

(let firstName firstPerson.name)

; Show some results
(list name companyCity fullName point.x firstName)