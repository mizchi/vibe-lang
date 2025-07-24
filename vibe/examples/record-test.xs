-- Test record literal and field access

-- Simple record
let person = { name: "Alice", age: 30, city: "Tokyo" } in

-- Field access
let name = person.name in
let age = person.age in

-- Nested record
let address = { street: "Main St", number: 123 } in
let company = { name: "Tech Corp", address: address } in

-- Nested field access
let companyName = company.name in
let street = company.address.street in

-- Function with record parameter
let getName p = p.name in
let aliceName = getName person in

-- Print results
let dummy1 = IO.print "Person name:" in
let dummy2 = IO.print name in
let dummy3 = IO.print "\nPerson age:" in
let dummy4 = IO.print age in
let dummy5 = IO.print "\nCompany name:" in
let dummy6 = IO.print companyName in
let dummy7 = IO.print "\nCompany street:" in
let dummy8 = IO.print street in
let dummy9 = IO.print "\nget-name result:" in
let dummy10 = IO.print aliceName in

IO.print "\nRecord test completed!"