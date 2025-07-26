fn main() {
    use vibe_language::parser::lexer::{Lexer, Token};
    
    let input = "[42]";
    let mut lexer = Lexer::new(input);
    
    println!("Tokenizing: {}", input);
    loop {
        match lexer.next_token() {
            Ok(Some((token, span))) => {
                println!("Token: {:?} at {:?}", token, span);
            }
            Ok(None) => break,
            Err(e) => {
                println!("Error: {:?}", e);
                break;
            }
        }
    }
}