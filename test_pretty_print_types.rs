use xs_core::{Expr, Type, Ident, Literal, Span};
use xs_core::pretty_print::PrettyPrinter;

fn main() {
    let printer = PrettyPrinter::new();
    
    // Test Let with type annotation
    let expr = Expr::Let {
        name: Ident("x".to_string()),
        type_ann: Some(Type::Int),
        value: Box::new(Expr::Literal(Literal::Int(42), Span::new(0, 2))),
        span: Span::new(0, 10),
    };
    
    println!("Let with type: {}", printer.pretty_print(&expr));
    
    // Test Let without type annotation
    let expr2 = Expr::Let {
        name: Ident("y".to_string()),
        type_ann: None,
        value: Box::new(Expr::Literal(Literal::String("hello".to_string()), Span::new(0, 5))),
        span: Span::new(0, 15),
    };
    
    println!("Let without type: {}", printer.pretty_print(&expr2));
    
    // Test Rec with return type
    let expr3 = Expr::Rec {
        name: Ident("factorial".to_string()),
        params: vec![(Ident("n".to_string()), Some(Type::Int))],
        return_type: Some(Type::Int),
        body: Box::new(Expr::Literal(Literal::Int(1), Span::new(0, 1))),
        span: Span::new(0, 50),
    };
    
    println!("Rec with return type: {}", printer.pretty_print(&expr3));
}