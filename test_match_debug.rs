use vibe_language::parser::experimental::unified_vibe_parser::UnifiedVibeParser;

fn main() {
    let mut parser = UnifiedVibeParser::new();
    let input = "match true { true -> 1 false -> 0 }";
    
    println!("Parsing: {}", input);
    
    match parser.parse(input) {
        Ok(ast) => {
            println!("Success! AST: {:?}", ast);
        }
        Err(e) => {
            println!("Parse error: {:?}", e);
        }
    }
}