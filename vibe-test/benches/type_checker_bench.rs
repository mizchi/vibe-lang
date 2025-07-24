//! Type checker performance benchmarks with focus on incremental checking
//!
//! This benchmark suite tests various type checking scenarios to help optimize
//! the type checker performance, especially for incremental compilation.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::parser::parse;
// use vibe_workspace::XsDatabase; // Temporarily disabled due to incomplete implementation

fn generate_nested_let(depth: usize) -> String {
    let mut expr = "42".to_string();
    for i in (0..depth).rev() {
        expr = format!("(let x{i} {i} {expr})");
    }
    expr
}

fn generate_nested_lambda(depth: usize) -> String {
    let mut params = Vec::new();
    let mut body = "0".to_string();

    for i in 0..depth {
        params.push(format!("x{i}"));
        body = format!("(+ {body} x{i})");
    }

    let mut expr = body;
    for param in params.iter().rev() {
        expr = format!("(fn ({param}) {expr})");
    }

    // Apply with arguments
    let mut application = expr;
    for i in 0..depth {
        application = format!("({} {})", application, i + 1);
    }

    application
}

fn generate_polymorphic_functions(count: usize) -> String {
    let mut functions = Vec::new();

    // Generate identity functions with different names
    for i in 0..count {
        functions.push(format!("(let id{i} (fn (x) x)"));
    }

    // Use them polymorphically
    let mut usage = String::new();
    for i in 0..count {
        if i > 0 {
            usage.push(' ');
        }
        usage.push_str(&format!("(+ (id{} {}) (id{} true))", i, i * 10, i));
    }

    let mut expr = usage;
    for func in functions.iter().rev() {
        expr = format!("{func} {expr})");
    }

    expr
}

fn benchmark_type_checker_scaling(c: &mut Criterion) {
    let mut group = c.benchmark_group("type_checker_scaling");

    // Test nested let bindings
    for depth in [5, 10, 20, 50].iter() {
        let program = generate_nested_let(*depth);
        let ast = parse(&program).unwrap();

        group.bench_with_input(BenchmarkId::new("nested_let", depth), depth, |b, _| {
            b.iter(|| {
                let mut checker = TypeChecker::new();
                let mut env = TypeEnv::new();
                checker.check(black_box(&ast), &mut env)
            })
        });
    }

    // Test nested lambda applications
    for depth in [3, 5, 7, 10].iter() {
        let program = generate_nested_lambda(*depth);
        let ast = parse(&program).unwrap();

        group.bench_with_input(BenchmarkId::new("nested_lambda", depth), depth, |b, _| {
            b.iter(|| {
                let mut checker = TypeChecker::new();
                let mut env = TypeEnv::new();
                checker.check(black_box(&ast), &mut env)
            })
        });
    }

    group.finish();
}

fn benchmark_polymorphic_inference(c: &mut Criterion) {
    let mut group = c.benchmark_group("polymorphic_inference");

    for count in [5, 10, 20, 40].iter() {
        let program = generate_polymorphic_functions(*count);
        let ast = parse(&program).unwrap();

        group.bench_with_input(
            BenchmarkId::new("polymorphic_functions", count),
            count,
            |b, _| {
                b.iter(|| {
                    let mut checker = TypeChecker::new();
                    let mut env = TypeEnv::new();
                    checker.check(black_box(&ast), &mut env)
                })
            },
        );
    }

    group.finish();
}

fn benchmark_incremental_type_checking(c: &mut Criterion) {
    let mut group = c.benchmark_group("incremental_type_checking");

    // Initial program
    let initial = r#"
        (let add (fn (x) (fn (y) (+ x y)))
        (let double (fn (x) (* x 2))
        (let compose (fn (f) (fn (g) (fn (x) (f (g x)))))
            42)))
    "#;

    // Modified program (only changes the literal at the end)
    let modified = r#"
        (let add (fn (x) (fn (y) (+ x y)))
        (let double (fn (x) (* x 2))
        (let compose (fn (f) (fn (g) (fn (x) (f (g x)))))
            100)))
    "#;

    group.bench_function("full_recheck", |b| {
        b.iter(|| {
            let ast1 = parse(black_box(initial)).unwrap();
            let ast2 = parse(black_box(modified)).unwrap();

            let mut checker = TypeChecker::new();
            let mut env1 = TypeEnv::new();
            checker.check(&ast1, &mut env1).unwrap();

            let mut env2 = TypeEnv::new();
            checker.check(&ast2, &mut env2).unwrap();
        })
    });

    // Temporarily disabled due to incomplete salsa implementation
    /*
    group.bench_function("incremental_with_salsa", |b| {
        b.iter(|| {
            let mut db = XsDatabase::default();

            // Initial check
            db.check_module(black_box(initial.to_string())).unwrap();

            // Incremental check after modification
            db.check_module(black_box(modified.to_string())).unwrap();
        })
    });
    */

    group.finish();
}

fn benchmark_type_instantiation(c: &mut Criterion) {
    let mut group = c.benchmark_group("type_instantiation");

    // Program with many instantiations of the same polymorphic function
    let program_template = |n: usize| {
        let mut uses = Vec::new();
        for i in 0..n {
            uses.push(format!("(id {i})"));
        }
        format!("(let id (fn (x) x) (list {}))", uses.join(" "))
    };

    for count in [10, 50, 100, 200].iter() {
        let program = program_template(*count);
        let ast = parse(&program).unwrap();

        group.bench_with_input(BenchmarkId::new("instantiations", count), count, |b, _| {
            b.iter(|| {
                let mut checker = TypeChecker::new();
                let mut env = TypeEnv::new();
                checker.check(black_box(&ast), &mut env)
            })
        });
    }

    group.finish();
}

fn benchmark_recursive_type_checking(c: &mut Criterion) {
    let programs = vec![
        (
            "simple_rec",
            r#"(rec fact (fn (n) (if (= n 0) 1 (* n (fact (- n 1))))))"#,
        ),
        (
            "mutual_rec",
            r#"
            (letRec even (fn (n) (if (= n 0) true (odd (- n 1))))
            (letRec odd (fn (n) (if (= n 0) false (even (- n 1))))
                (even 10)))
        "#,
        ),
        (
            "complex_rec",
            r#"
            (rec fib (fn (n) 
                (if (<= n 1) 
                    n 
                    (+ (fib (- n 1)) (fib (- n 2))))))
        "#,
        ),
    ];

    let mut group = c.benchmark_group("recursive_type_checking");

    for (name, program) in programs {
        let ast = parse(program).unwrap();

        group.bench_function(name, |b| {
            b.iter(|| {
                let mut checker = TypeChecker::new();
                let mut env = TypeEnv::new();
                checker.check(black_box(&ast), &mut env)
            })
        });
    }

    group.finish();
}

criterion_group!(
    benches,
    benchmark_type_checker_scaling,
    benchmark_polymorphic_inference,
    benchmark_incremental_type_checking,
    benchmark_type_instantiation,
    benchmark_recursive_type_checking
);
criterion_main!(benches);
