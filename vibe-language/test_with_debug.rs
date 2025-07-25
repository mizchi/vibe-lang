use vibe_language::parser::Parser;

fn main() {
    let input = "with myHandler { doSomething }";
    println!("Input: {}", input);
    
    match Parser::new(input) {
        Ok(mut parser) => {
            println!("Parser created successfully");
            match parser.parse() {
                Ok(expr) => println!("Parse successful: {:?}", expr),
                Err(e) => println!("Parse error: {:?}", e),
            }
        }
        Err(e) => println!("Parser creation error: {:?}", e),
    }
}