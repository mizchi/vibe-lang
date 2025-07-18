use crate::parse;

fn main() {
    let result = parse("(list)");
    println!("Parse result: {:?}", result);
}