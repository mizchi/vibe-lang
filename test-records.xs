-- Test record functionality

-- Basic record literal
let person = { name: "Alice", age: 30 }

-- Record field access
let name = person.name
let age = person.age

-- Nested records
let company = {
    name: "TechCorp",
    address: {
        street: "123 Main St",
        city: "Tokyo",
        zip: "100-0001"
    }
}

-- Nested field access
let city = company.address.city

-- Record update
let olderPerson = person { age: 31 }

-- Multiple field update
let movedPerson = person { 
    name: "Alice Smith",
    age: 32 
}

-- Block with record
let result = {
    let x = 10;
    let y = 20;
    { sum: x + y, product: x * y }
}

-- Pipeline with records (when implemented)
-- let processed = person | fn p -> p { age: p.age + 1 }

-- Display results
person