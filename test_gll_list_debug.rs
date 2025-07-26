use vibe_language::parser::experimental::unified_vibe_parser::UnifiedVibeParser;

fn main() {
    let mut parser = UnifiedVibeParser::new();
    let input = "[42]";
    
    println!("Parsing: {}", input);
    
    match parser.parse(input) {
        Ok(exprs) => {
            println!("Parsed {} expressions", exprs.len());
            for (i, expr) in exprs.iter().enumerate() {
                println!("Expression {}: {:?}", i, expr);
            }
        }
        Err(e) => {
            println!("Parse error: {:?}", e);
        }
    }
}