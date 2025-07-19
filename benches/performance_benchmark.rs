//! Performance benchmarks for XS language components

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use parser::parse;
use checker::TypeChecker;
use interpreter::eval;
use xs_core::Environment;

fn benchmark_parser(c: &mut Criterion) {
    let simple_expr = "(+ 1 2)";
    let complex_expr = r#"(let f (lambda (x) 
        (let g (lambda (y) (+ x y))
            (g (+ x 1))))
        (f 10))"#;
    
    c.bench_function("parse_simple", |b| {
        b.iter(|| parse(black_box(simple_expr)))
    });
    
    c.bench_function("parse_complex", |b| {
        b.iter(|| parse(black_box(complex_expr)))
    });
}

fn benchmark_type_checker(c: &mut Criterion) {
    let simple_ast = parse("(+ 1 2)").unwrap();
    let complex_ast = parse(r#"(let f (lambda (x) 
        (let g (lambda (y) (+ x y))
            (g (+ x 1))))
        (f 10))"#).unwrap();
    
    c.bench_function("typecheck_simple", |b| {
        b.iter(|| {
            let mut checker = TypeChecker::new();
            let mut env = checker.new_env();
            checker.check(&black_box(&simple_ast), &mut env)
        })
    });
    
    c.bench_function("typecheck_complex", |b| {
        b.iter(|| {
            let mut checker = TypeChecker::new();
            let mut env = checker.new_env();
            checker.check(&black_box(&complex_ast), &mut env)
        })
    });
}

fn benchmark_interpreter(c: &mut Criterion) {
    let simple_ast = parse("(+ 1 2)").unwrap();
    let complex_ast = parse(r#"(let f (lambda (x) 
        (let g (lambda (y) (+ x y))
            (g (+ x 1))))
        (f 10))"#).unwrap();
    
    // Type check first
    let mut checker = TypeChecker::new();
    let mut env = checker.new_env();
    checker.check(&simple_ast, &mut env).unwrap();
    let mut env2 = checker.new_env();
    checker.check(&complex_ast, &mut env2).unwrap();
    
    c.bench_function("eval_simple", |b| {
        b.iter(|| {
            eval(&black_box(&simple_ast))
        })
    });
    
    c.bench_function("eval_complex", |b| {
        b.iter(|| {
            eval(&black_box(&complex_ast))
        })
    });
}

fn benchmark_full_pipeline(c: &mut Criterion) {
    let program = r#"(let double (lambda (x) (* x 2))
        (let nums (list 1 2 3 4 5)
            (map double nums)))"#;
    
    c.bench_function("full_pipeline", |b| {
        b.iter(|| {
            // Parse
            let ast = parse(black_box(program)).unwrap();
            
            // Type check
            let mut checker = TypeChecker::new();
            let mut env = checker.new_env();
            checker.check(&ast, &mut env).unwrap();
            
            // Evaluate
            eval(&ast)
        })
    });
}

criterion_group!(
    benches,
    benchmark_parser,
    benchmark_type_checker,
    benchmark_interpreter,
    benchmark_full_pipeline
);
criterion_main!(benches);