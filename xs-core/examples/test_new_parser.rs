use xs_core::parser::{Lexer, Parser};

fn main() {
    let inputs = vec![
        "42",
        "x + y",
        "if x > 0 { 1 } else { -1 }",
        "let x = 42",
        "fn x -> x * 2",
        "[1, 2, 3]",
        "x | f | g",
        "{ x: 1, y: 2 }",
        "with handler expr",
    ];

    for input in inputs {
        println!("\n=== Parsing: {} ===", input);
        
        // First tokenize
        let mut lexer = Lexer::new(input);
        println!("Tokens:");
        while let Ok(Some((token, span))) = lexer.next_token() {
            println!("  {:?} at {:?}", token, span);
        }
        
        // Then try to parse
        match Parser::new(input) {
            Ok(mut parser) => {
                match parser.parse() {
                    Ok(expr) => println!("Parse result: OK"),
                    Err(e) => println!("Parse error: {:?}", e),
                }
            }
            Err(e) => println!("Parser creation error: {:?}", e),
        }
    }
}