-- Record test in block

{
    let person = { name: "Alice", age: 30 };
    let name = person.name;
    let age = person.age;
    { person: person, extracted_name: name, extracted_age: age }
}