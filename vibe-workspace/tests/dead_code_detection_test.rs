//! Tests for dead code detection functionality

use vibe_workspace::code_repository::CodeRepository;
use vibe_workspace::{Hash, Term};
use std::collections::HashSet;

/// Create a complex dependency graph for testing
fn setup_complex_codebase(repo: &mut CodeRepository) {
    // Core utilities (reachable from multiple places)
    let util_hash = Hash::from_hex("1111111111111111111111111111111111111111111111111111111111111111").unwrap();
    let util_term = Term {
        hash: util_hash.clone(),
        name: Some("Core.util".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(1), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: HashSet::new(),
    };
    repo.store_term(&util_term, &HashSet::new()).unwrap();
    
    // Main.entry (root)
    let mut main_deps = HashSet::new();
    main_deps.insert(util_hash.clone());
    let main_hash = Hash::from_hex("2222222222222222222222222222222222222222222222222222222222222222").unwrap();
    let main_term = Term {
        hash: main_hash.clone(),
        name: Some("Main.entry".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(2), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: main_deps.clone(),
    };
    repo.store_term(&main_term, &main_deps).unwrap();
    
    // Helper.process (reachable from Main)
    let mut helper_deps = HashSet::new();
    helper_deps.insert(util_hash.clone());
    let helper_hash = Hash::from_hex("3333333333333333333333333333333333333333333333333333333333333333").unwrap();
    let helper_term = Term {
        hash: helper_hash.clone(),
        name: Some("Helper.process".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(3), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: helper_deps.clone(),
    };
    repo.store_term(&helper_term, &helper_deps).unwrap();
    
    // Update Main to depend on Helper
    main_deps.insert(helper_hash.clone());
    let main_term_updated = Term {
        hash: main_hash.clone(),
        name: Some("Main.entry".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(2), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: main_deps.clone(),
    };
    repo.store_term(&main_term_updated, &main_deps).unwrap();
    
    // Dead.function1 (unreachable)
    let dead1_hash = Hash::from_hex("4444444444444444444444444444444444444444444444444444444444444444").unwrap();
    let dead1_term = Term {
        hash: dead1_hash.clone(),
        name: Some("Dead.function1".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(4), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: HashSet::new(),
    };
    repo.store_term(&dead1_term, &HashSet::new()).unwrap();
    
    // Dead.function2 (depends on Dead.function1, also unreachable)
    let mut dead2_deps = HashSet::new();
    dead2_deps.insert(dead1_hash.clone());
    let dead2_hash = Hash::from_hex("5555555555555555555555555555555555555555555555555555555555555555").unwrap();
    let dead2_term = Term {
        hash: dead2_hash.clone(),
        name: Some("Dead.function2".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(5), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: dead2_deps.clone(),
    };
    repo.store_term(&dead2_term, &dead2_deps).unwrap();
    
    // Test.suite (separate namespace, reachable from Test)
    let test_hash = Hash::from_hex("6666666666666666666666666666666666666666666666666666666666666666").unwrap();
    let test_term = Term {
        hash: test_hash.clone(),
        name: Some("Test.suite".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(6), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: HashSet::new(),
    };
    repo.store_term(&test_term, &HashSet::new()).unwrap();
}

#[test]
fn test_basic_dead_code_detection() {
    let mut repo = CodeRepository::in_memory().unwrap();
    repo.start_session().unwrap();
    
    setup_complex_codebase(&mut repo);
    
    // Analyze from Main namespace only
    let analysis = repo.analyze_reachability(&["Main".to_string()]).unwrap();
    
    // Main.entry, Helper.process, and Core.util should be reachable
    assert_eq!(analysis.reachable.len(), 3);
    
    // Dead.function1, Dead.function2, and Test.suite should be dead code
    assert_eq!(analysis.dead_code.len(), 3);
    
    // Verify specific items
    let main_hash = Hash::from_hex("2222222222222222222222222222222222222222222222222222222222222222").unwrap();
    let dead1_hash = Hash::from_hex("4444444444444444444444444444444444444444444444444444444444444444").unwrap();
    let test_hash = Hash::from_hex("6666666666666666666666666666666666666666666666666666666666666666").unwrap();
    
    assert!(analysis.reachable.contains(&main_hash));
    assert!(analysis.dead_code.contains(&dead1_hash));
    assert!(analysis.dead_code.contains(&test_hash));
}

#[test]
fn test_multiple_namespace_reachability() {
    let mut repo = CodeRepository::in_memory().unwrap();
    repo.start_session().unwrap();
    
    setup_complex_codebase(&mut repo);
    
    // Analyze from both Main and Test namespaces
    let analysis = repo.analyze_reachability(&["Main".to_string(), "Test".to_string()]).unwrap();
    
    // Now Test.suite should also be reachable
    assert_eq!(analysis.reachable.len(), 4); // Main.entry, Helper.process, Core.util, Test.suite
    assert_eq!(analysis.dead_code.len(), 2); // Only Dead.function1 and Dead.function2
    
    let test_hash = Hash::from_hex("6666666666666666666666666666666666666666666666666666666666666666").unwrap();
    assert!(analysis.reachable.contains(&test_hash));
}

#[test]
fn test_reference_counting() {
    let mut repo = CodeRepository::in_memory().unwrap();
    repo.start_session().unwrap();
    
    setup_complex_codebase(&mut repo);
    
    let analysis = repo.analyze_reachability(&["Main".to_string()]).unwrap();
    
    // Core.util is referenced by both Main.entry and Helper.process
    let util_hash = Hash::from_hex("1111111111111111111111111111111111111111111111111111111111111111").unwrap();
    assert_eq!(analysis.reference_count.get(&util_hash), Some(&2));
    
    // Helper.process is referenced only by Main.entry
    let helper_hash = Hash::from_hex("3333333333333333333333333333333333333333333333333333333333333333").unwrap();
    assert_eq!(analysis.reference_count.get(&helper_hash), Some(&1));
}

#[test]
fn test_circular_dependencies() {
    let mut repo = CodeRepository::in_memory().unwrap();
    repo.start_session().unwrap();
    
    // Create circular dependency: A -> B -> C -> A
    let a_hash = Hash::from_hex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").unwrap();
    let b_hash = Hash::from_hex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").unwrap();
    let c_hash = Hash::from_hex("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc").unwrap();
    
    // Store A first (no deps initially)
    let a_term = Term {
        hash: a_hash.clone(),
        name: Some("Circular.a".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(1), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: HashSet::new(),
    };
    repo.store_term(&a_term, &HashSet::new()).unwrap();
    
    // B depends on A
    let mut b_deps = HashSet::new();
    b_deps.insert(a_hash.clone());
    let b_term = Term {
        hash: b_hash.clone(),
        name: Some("Circular.b".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(2), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: b_deps.clone(),
    };
    repo.store_term(&b_term, &b_deps).unwrap();
    
    // C depends on B
    let mut c_deps = HashSet::new();
    c_deps.insert(b_hash.clone());
    let c_term = Term {
        hash: c_hash.clone(),
        name: Some("Circular.c".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(3), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: c_deps.clone(),
    };
    repo.store_term(&c_term, &c_deps).unwrap();
    
    // Update A to depend on C (creating cycle)
    let mut a_deps_updated = HashSet::new();
    a_deps_updated.insert(c_hash.clone());
    let a_term_updated = Term {
        hash: a_hash.clone(),
        name: Some("Circular.a".to_string()),
        expr: vibe_core::Expr::Literal(vibe_core::Literal::Int(1), vibe_core::Span::new(0, 1)),
        ty: vibe_core::Type::Int,
        dependencies: a_deps_updated.clone(),
    };
    repo.store_term(&a_term_updated, &a_deps_updated).unwrap();
    
    // All circular dependencies should be reachable if any one is
    let analysis = repo.analyze_reachability(&["Circular".to_string()]).unwrap();
    
    assert!(analysis.reachable.contains(&a_hash));
    assert!(analysis.reachable.contains(&b_hash));
    assert!(analysis.reachable.contains(&c_hash));
    assert_eq!(analysis.dead_code.len(), 0);
}

#[test]
fn test_dead_code_removal_safety() {
    let mut repo = CodeRepository::in_memory().unwrap();
    repo.start_session().unwrap();
    
    setup_complex_codebase(&mut repo);
    
    // First analysis
    let analysis = repo.analyze_reachability(&["Main".to_string()]).unwrap();
    let initial_dead_count = analysis.dead_code.len();
    
    // Remove dead code
    let removed = repo.remove_dead_code(&analysis.dead_code).unwrap();
    assert_eq!(removed, initial_dead_count);
    
    // Re-analyze - should have no dead code now
    let analysis2 = repo.analyze_reachability(&["Main".to_string()]).unwrap();
    assert_eq!(analysis2.dead_code.len(), 0);
    
    // Verify reachable code is still there
    let main_hash = Hash::from_hex("2222222222222222222222222222222222222222222222222222222222222222").unwrap();
    assert!(repo.get_definition(&main_hash).unwrap().is_some());
}

#[test]
fn test_empty_namespace_analysis() {
    let mut repo = CodeRepository::in_memory().unwrap();
    repo.start_session().unwrap();
    
    setup_complex_codebase(&mut repo);
    
    // Analyze from non-existent namespace
    let analysis = repo.analyze_reachability(&["NonExistent".to_string()]).unwrap();
    
    // Everything should be dead code
    assert_eq!(analysis.reachable.len(), 0);
    assert!(analysis.dead_code.len() > 0);
}