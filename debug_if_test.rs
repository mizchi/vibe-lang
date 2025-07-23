use xs_core::parser_v2::{Lexer, Token};

fn main() {
    let input = "if x > 0 { 1 } else { -1 }";
    let mut lexer = Lexer::new(input);
    
    println!("Tokenizing: {}", input);
    while let Ok(Some((token, span))) = lexer.next_token() {
        println!("Token: {:?} at {:?}", token, span);
    }
}