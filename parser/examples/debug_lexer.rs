use parser::lexer::Lexer;

fn main() {
    let test_cases = vec![
        "List",
        "List.cons",
        "list",
        "list.cons",
        "Math.add",
    ];

    for test in test_cases {
        println!("\nTokenizing: {test}");
        let mut lexer = Lexer::new(test);
        
        loop {
            match lexer.next_token() {
                Ok(Some((token, span))) => {
                    println!("  Token: {token:?} at {span:?}");
                },
                Ok(None) => {
                    println!("  EOF");
                    break;
                },
                Err(e) => {
                    println!("  Error: {e:?}");
                    break;
                }
            }
        }
    }
}