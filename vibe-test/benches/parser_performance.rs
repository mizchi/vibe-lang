use criterion::{black_box, criterion_group, criterion_main, Criterion};
use vibe_core::parser::parse;

fn parse_simple_expression(c: &mut Criterion) {
    let simple_expr = "let x = 42";
    
    c.bench_function("parse_simple_expression", |b| {
        b.iter(|| {
            let _ = parse(black_box(simple_expr));
        })
    });
}

fn parse_complex_expression(c: &mut Criterion) {
    let complex_expr = r#"
let factorial = rec fact n ->
    if (eq n 0) {
        1
    } else {
        n * (fact (n - 1))
    }

let result = factorial 10
"#;
    
    c.bench_function("parse_complex_expression", |b| {
        b.iter(|| {
            let _ = parse(black_box(complex_expr));
        })
    });
}

fn parse_nested_blocks(c: &mut Criterion) {
    let nested_expr = r#"
let outer = {
    let a = 10
    let b = {
        let x = 5
        let y = {
            let z = 2
            z + 3
        }
        x * y
    }
    a + b
}
"#;
    
    c.bench_function("parse_nested_blocks", |b| {
        b.iter(|| {
            let _ = parse(black_box(nested_expr));
        })
    });
}

fn parse_pattern_matching(c: &mut Criterion) {
    let pattern_expr = r#"
let process = fn lst ->
    match lst {
        [] -> 0
        [x] -> x
        [x, y] -> x + y
        x :: xs -> x + (sum xs)
    }
"#;
    
    c.bench_function("parse_pattern_matching", |b| {
        b.iter(|| {
            let _ = parse(black_box(pattern_expr));
        })
    });
}

fn parse_pipeline_operations(c: &mut Criterion) {
    let pipeline_expr = r#"
let result = [1, 2, 3, 4, 5]
    |> map (fn x -> x * 2)
    |> filter (fn x -> x > 5)
    |> foldLeft 0 (fn acc x -> acc + x)
"#;
    
    c.bench_function("parse_pipeline_operations", |b| {
        b.iter(|| {
            let _ = parse(black_box(pipeline_expr));
        })
    });
}

criterion_group!(
    benches,
    parse_simple_expression,
    parse_complex_expression,
    parse_nested_blocks,
    parse_pattern_matching,
    parse_pipeline_operations
);
criterion_main!(benches);