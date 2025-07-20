use parser::parse;

fn main() {
    // Test various forms
    let test_cases = vec![
        "List",
        "List.cons",
        "(List.cons 1 (list))",
        "Math.add",
        "(Math.add 1 2)",
    ];

    for test in test_cases {
        println!("\nTesting: {test}");
        match parse(test) {
            Ok(expr) => println!("Success: {expr:?}"),
            Err(e) => println!("Error: {e:?}"),
        }
    }
}
