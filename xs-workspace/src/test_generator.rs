//! Automatic test generation from XBin codebase
//! 
//! This module generates test cases for public functions in an XBin codebase
//! by analyzing their type signatures and generating appropriate test inputs.

use std::collections::HashSet;
use crate::{Codebase, Term, Hash};
use xs_core::{Expr, Type, Value, Ident, Literal, Span};

/// Test generation configuration
#[derive(Debug, Clone)]
pub struct TestGenConfig {
    /// Maximum number of test cases per function
    pub max_tests_per_function: usize,
    /// Whether to generate property-based tests
    pub enable_property_tests: bool,
    /// Whether to generate edge case tests
    pub enable_edge_cases: bool,
    /// Whether to skip cached test results
    pub use_cache: bool,
    /// Filter for function names (if None, test all public functions)
    pub name_filter: Option<String>,
}

impl Default for TestGenConfig {
    fn default() -> Self {
        TestGenConfig {
            max_tests_per_function: 10,
            enable_property_tests: true,
            enable_edge_cases: true,
            use_cache: true,
            name_filter: None,
        }
    }
}

/// Generated test case
#[derive(Debug, Clone)]
pub struct GeneratedTest {
    /// Name of the test
    pub name: String,
    /// The function being tested
    pub function_name: String,
    /// The function hash
    pub function_hash: Hash,
    /// Test expression to evaluate
    pub test_expr: Expr,
    /// Expected properties (for property-based tests)
    pub properties: Vec<TestProperty>,
    /// Test category
    pub category: TestCategory,
}

/// Test property to verify
#[derive(Debug)]
pub enum TestProperty {
    /// Result should equal a specific value
    Equals(Value),
    /// Result type should match
    HasType(Type),
    /// Result should satisfy a predicate (name only, predicate not cloneable)
    Satisfies(String),
    /// Function should be pure (same input -> same output)
    IsPure,
    /// Function should not throw errors
    NoErrors,
}

impl Clone for TestProperty {
    fn clone(&self) -> Self {
        match self {
            TestProperty::Equals(v) => TestProperty::Equals(v.clone()),
            TestProperty::HasType(t) => TestProperty::HasType(t.clone()),
            TestProperty::Satisfies(name) => TestProperty::Satisfies(name.clone()),
            TestProperty::IsPure => TestProperty::IsPure,
            TestProperty::NoErrors => TestProperty::NoErrors,
        }
    }
}

/// Test category
#[derive(Debug, Clone, PartialEq)]
pub enum TestCategory {
    /// Basic functionality test
    Basic,
    /// Edge case test
    EdgeCase,
    /// Property-based test
    Property,
    /// Error handling test
    ErrorHandling,
}

/// Test generator for XBin codebase
pub struct TestGenerator {
    config: TestGenConfig,
}

impl TestGenerator {
    /// Create a new test generator
    pub fn new(config: TestGenConfig) -> Self {
        TestGenerator { config }
    }
    
    /// Extract function arguments and final return type
    fn extract_function_args(&self, ty: &Type) -> (Vec<Type>, Type) {
        let mut args = Vec::new();
        let mut current = ty;
        
        loop {
            match current {
                Type::Function(input, output) => {
                    args.push(*input.clone());
                    current = output;
                }
                _ => {
                    return (args, current.clone());
                }
            }
        }
    }

    /// Generate tests for all public functions in the codebase
    pub fn generate_tests(&self, codebase: &Codebase) -> Vec<GeneratedTest> {
        let mut tests = Vec::new();
        let mut visited = HashSet::new();
        
        println!("DEBUG: Codebase has {} named terms", codebase.term_names.len());

        // Iterate through all named terms
        for (name, hash) in &codebase.term_names {
            println!("DEBUG: Processing term: {} with hash: {:?}", name, hash);
            // Apply name filter if specified
            if let Some(filter) = &self.config.name_filter {
                if !name.contains(filter) {
                    continue;
                }
            }

            // Generate tests for this definition
            if let Some(term) = codebase.get_term(hash) {
                println!("DEBUG: Found term with type: {:?}", term.ty);
                let function_tests = self.generate_tests_for_term(
                    name,
                    hash,
                    term,
                    codebase,
                    &mut visited,
                );
                println!("DEBUG: Generated {} tests for {}", function_tests.len(), name);
                tests.extend(function_tests);
            } else {
                println!("DEBUG: No term found for hash: {:?}", hash);
            }
        }

        tests
    }

    /// Generate tests for a specific term
    fn generate_tests_for_term(
        &self,
        name: &str,
        hash: &Hash,
        term: &Term,
        _codebase: &Codebase,
        visited: &mut HashSet<Hash>,
    ) -> Vec<GeneratedTest> {
        // Avoid infinite recursion
        if visited.contains(hash) {
            return vec![];
        }
        visited.insert(hash.clone());

        let mut tests = Vec::new();

        match &term.ty {
            Type::Function(input_ty, output_ty) => {
                println!("DEBUG: Function type: {} -> {}", input_ty, output_ty);
                // Generate tests for functions
                tests.extend(self.generate_function_tests(
                    name,
                    hash,
                    &term.expr,
                    input_ty,
                    output_ty,
                ));
            }
            Type::Int | Type::Bool | Type::String | Type::Float => {
                // Generate tests for constants
                tests.push(self.generate_constant_test(name, hash, &term.expr, &term.ty));
            }
            Type::List(_) => {
                // Generate tests for list constants
                tests.push(self.generate_list_test(name, hash, &term.expr, &term.ty));
            }
            _ => {
                // Skip other types for now
            }
        }

        // Limit number of tests per function
        tests.truncate(self.config.max_tests_per_function);

        tests
    }

    /// Generate tests for a function
    fn generate_function_tests(
        &self,
        name: &str,
        hash: &Hash,
        _expr: &Expr,
        input_ty: &Type,
        output_ty: &Type,
    ) -> Vec<GeneratedTest> {
        let mut tests = Vec::new();
        
        // Analyze function type to determine argument count
        let (arg_types, final_output) = self.extract_function_args(&Type::Function(Box::new(input_ty.clone()), Box::new(output_ty.clone())));
        println!("DEBUG: Function {} has {} arguments", name, arg_types.len());

        // Generate test cases based on argument count
        if arg_types.len() == 1 {
            // Single argument function
            if let Some(basic_inputs) = self.generate_basic_inputs(&arg_types[0]) {
                for (i, input_value) in basic_inputs.iter().enumerate() {
                    let test_expr = self.create_function_call(name, input_value);
                    tests.push(GeneratedTest {
                        name: format!("{}_basic_{}", name, i),
                        function_name: name.to_string(),
                        function_hash: hash.clone(),
                        test_expr,
                        properties: vec![
                            TestProperty::HasType(final_output.clone()),
                            TestProperty::NoErrors,
                        ],
                        category: TestCategory::Basic,
                    });
                }
            }
        } else if arg_types.len() == 2 {
            // Two argument function - generate combinations
            if let (Some(inputs1), Some(inputs2)) = (
                self.generate_basic_inputs(&arg_types[0]),
                self.generate_basic_inputs(&arg_types[1])
            ) {
                // Generate a subset of combinations to avoid explosion
                for (i, (input1, input2)) in inputs1.iter().take(3)
                    .flat_map(|v1| inputs2.iter().take(3).map(move |v2| (v1, v2)))
                    .enumerate()
                {
                    let test_expr = self.create_function_call_multi(name, &[input1.clone(), input2.clone()]);
                    tests.push(GeneratedTest {
                        name: format!("{}_basic_{}", name, i),
                        function_name: name.to_string(),
                        function_hash: hash.clone(),
                        test_expr,
                        properties: vec![
                            TestProperty::HasType(final_output.clone()),
                            TestProperty::NoErrors,
                        ],
                        category: TestCategory::Basic,
                    });
                }
            }
        }

        // Generate edge case tests
        if self.config.enable_edge_cases {
            if arg_types.len() == 1 {
                if let Some(edge_inputs) = self.generate_edge_case_inputs(&arg_types[0]) {
                    for (i, input_value) in edge_inputs.iter().enumerate() {
                        let test_expr = self.create_function_call(name, input_value);
                        tests.push(GeneratedTest {
                            name: format!("{}_edge_{}", name, i),
                            function_name: name.to_string(),
                            function_hash: hash.clone(),
                            test_expr,
                            properties: vec![TestProperty::HasType(final_output.clone())],
                            category: TestCategory::EdgeCase,
                        });
                    }
                }
            } else if arg_types.len() == 2 {
                // Generate edge cases for two-argument functions
                if let (Some(edge1), Some(_edge2)) = (
                    self.generate_edge_case_inputs(&arg_types[0]),
                    self.generate_edge_case_inputs(&arg_types[1])
                ) {
                    // Test edge cases on first argument with normal second argument
                    if let Some(normal2) = self.generate_basic_inputs(&arg_types[1]) {
                        for (i, input1) in edge1.iter().take(2).enumerate() {
                            let test_expr = self.create_function_call_multi(name, &[input1.clone(), normal2[0].clone()]);
                            tests.push(GeneratedTest {
                                name: format!("{}_edge_{}", name, i),
                                function_name: name.to_string(),
                                function_hash: hash.clone(),
                                test_expr,
                                properties: vec![TestProperty::HasType(final_output.clone())],
                                category: TestCategory::EdgeCase,
                            });
                        }
                    }
                }
            }
        }

        // Generate property-based tests
        if self.config.enable_property_tests {
            tests.extend(self.generate_property_tests(name, hash, input_ty, output_ty));
        }

        tests
    }

    /// Generate basic input values for a type
    fn generate_basic_inputs(&self, ty: &Type) -> Option<Vec<Value>> {
        println!("DEBUG: Generating inputs for type: {:?}", ty);
        match ty {
            Type::Int => Some(vec![
                Value::Int(0),
                Value::Int(1),
                Value::Int(-1),
                Value::Int(42),
                Value::Int(100),
            ]),
            Type::Bool => Some(vec![
                Value::Bool(true),
                Value::Bool(false),
            ]),
            Type::String => Some(vec![
                Value::String("".to_string()),
                Value::String("hello".to_string()),
                Value::String("test string".to_string()),
                Value::String("multi\nline".to_string()),
            ]),
            Type::Float => Some(vec![
                Value::Float(0.0),
                Value::Float(1.0),
                Value::Float(-1.0),
                Value::Float(3.14),
                Value::Float(2.718),
            ]),
            Type::List(elem_ty) => {
                // Generate list inputs based on element type
                if let Some(elem_inputs) = self.generate_basic_inputs(elem_ty) {
                    let mut list_inputs = vec![
                        Value::List(vec![]), // Empty list
                    ];
                    
                    // Single element lists
                    for elem in elem_inputs.iter().take(2) {
                        list_inputs.push(Value::List(vec![elem.clone()]));
                    }
                    
                    // Two element list
                    if elem_inputs.len() >= 2 {
                        list_inputs.push(Value::List(vec![
                            elem_inputs[0].clone(),
                            elem_inputs[1].clone(),
                        ]));
                    }
                    
                    Some(list_inputs)
                } else {
                    None
                }
            }
            Type::Function(_, _) => {
                // For higher-order functions, we need predefined test functions
                // This is more complex and would require a function library
                None
            }
            Type::Var(_) => {
                // For type variables, default to Int test inputs
                println!("DEBUG: Type variable detected, using Int inputs");
                Some(vec![
                    Value::Int(0),
                    Value::Int(1),
                    Value::Int(-1),
                    Value::Int(42),
                    Value::Int(100),
                ])
            }
            _ => None,
        }
    }

    /// Generate edge case inputs for a type
    fn generate_edge_case_inputs(&self, ty: &Type) -> Option<Vec<Value>> {
        match ty {
            Type::Int => Some(vec![
                Value::Int(i64::MAX),
                Value::Int(i64::MIN),
                Value::Int(0),
            ]),
            Type::String => Some(vec![
                Value::String("".to_string()),
                Value::String(" ".to_string()),
                Value::String("\n\t\r".to_string()),
                Value::String("🦀🔥💻".to_string()), // Unicode
            ]),
            Type::Float => Some(vec![
                Value::Float(f64::INFINITY),
                Value::Float(f64::NEG_INFINITY),
                Value::Float(f64::NAN),
                Value::Float(f64::MIN_POSITIVE),
                Value::Float(f64::MAX),
            ]),
            Type::List(_) => Some(vec![
                Value::List(vec![]), // Empty list is always an edge case
            ]),
            Type::Var(_) => {
                // For type variables, default to Int edge cases
                Some(vec![
                    Value::Int(i64::MAX),
                    Value::Int(i64::MIN),
                    Value::Int(0),
                ])
            }
            _ => None,
        }
    }

    /// Generate property-based tests
    fn generate_property_tests(
        &self,
        name: &str,
        hash: &Hash,
        input_ty: &Type,
        output_ty: &Type,
    ) -> Vec<GeneratedTest> {
        let mut tests = Vec::new();
        
        let (arg_types, final_output) = self.extract_function_args(&Type::Function(Box::new(input_ty.clone()), Box::new(output_ty.clone())));

        // Pure function test - same input should give same output
        if arg_types.len() == 1 {
            if let Some(test_input) = self.generate_basic_inputs(&arg_types[0]).and_then(|v| v.first().cloned()) {
                let test_expr = self.create_function_call(name, &test_input);
                tests.push(GeneratedTest {
                    name: format!("{}_pure", name),
                    function_name: name.to_string(),
                    function_hash: hash.clone(),
                    test_expr,
                    properties: vec![
                        TestProperty::IsPure,
                        TestProperty::HasType(final_output.clone()),
                    ],
                    category: TestCategory::Property,
                });
            }
        } else if arg_types.len() == 2 {
            if let (Some(inputs1), Some(inputs2)) = (
                self.generate_basic_inputs(&arg_types[0]),
                self.generate_basic_inputs(&arg_types[1])
            ) {
                if let (Some(input1), Some(input2)) = (inputs1.first(), inputs2.first()) {
                    let test_expr = self.create_function_call_multi(name, &[input1.clone(), input2.clone()]);
                    tests.push(GeneratedTest {
                        name: format!("{}_pure", name),
                        function_name: name.to_string(),
                        function_hash: hash.clone(),
                        test_expr,
                        properties: vec![
                            TestProperty::IsPure,
                            TestProperty::HasType(final_output.clone()),
                        ],
                        category: TestCategory::Property,
                    });
                }
            }
        }

        // Add type-specific property tests
        match (input_ty, output_ty) {
            (Type::Int, Type::Int) => {
                // For Int -> Int functions, test properties like:
                // - f(0) might be identity
                // - f(x) + f(y) might relate to f(x+y)
                // These would be function-specific
            }
            (Type::List(_), Type::Int) => {
                // For List -> Int functions (like length), test:
                // - Result is non-negative
                // - Empty list gives 0 (for length-like functions)
            }
            _ => {}
        }

        tests
    }

    /// Generate test for a constant
    fn generate_constant_test(
        &self,
        name: &str,
        hash: &Hash,
        expr: &Expr,
        ty: &Type,
    ) -> GeneratedTest {
        GeneratedTest {
            name: format!("{}_value", name),
            function_name: name.to_string(),
            function_hash: hash.clone(),
            test_expr: expr.clone(),
            properties: vec![
                TestProperty::HasType(ty.clone()),
                TestProperty::NoErrors,
            ],
            category: TestCategory::Basic,
        }
    }

    /// Generate test for a list constant
    fn generate_list_test(
        &self,
        name: &str,
        hash: &Hash,
        expr: &Expr,
        ty: &Type,
    ) -> GeneratedTest {
        GeneratedTest {
            name: format!("{}_list", name),
            function_name: name.to_string(),
            function_hash: hash.clone(),
            test_expr: expr.clone(),
            properties: vec![
                TestProperty::HasType(ty.clone()),
                TestProperty::NoErrors,
            ],
            category: TestCategory::Basic,
        }
    }

    /// Create a function call expression
    fn create_function_call(&self, func_name: &str, input: &Value) -> Expr {
        let func_expr = Expr::Ident(Ident(func_name.to_string()), Span::new(0, 0));
        let arg_expr = value_to_expr(input);
        
        Expr::Apply {
            func: Box::new(func_expr),
            args: vec![arg_expr],
            span: Span::new(0, 0),
        }
    }
    
    /// Create a function call expression with multiple arguments
    fn create_function_call_multi(&self, func_name: &str, inputs: &[Value]) -> Expr {
        let func_expr = Expr::Ident(Ident(func_name.to_string()), Span::new(0, 0));
        let arg_exprs: Vec<Expr> = inputs.iter().map(value_to_expr).collect();
        
        Expr::Apply {
            func: Box::new(func_expr),
            args: arg_exprs,
            span: Span::new(0, 0),
        }
    }
}

/// Convert a Value to an Expr
fn value_to_expr(value: &Value) -> Expr {
    match value {
        Value::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(0, 0)),
        Value::Float(f) => Expr::Literal(Literal::Float((*f).into()), Span::new(0, 0)),
        Value::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(0, 0)),
        Value::String(s) => Expr::Literal(Literal::String(s.clone()), Span::new(0, 0)),
        Value::List(items) => {
            let item_exprs: Vec<Expr> = items.iter().map(value_to_expr).collect();
            Expr::List(item_exprs, Span::new(0, 0))
        }
        _ => {
            // For other types, create a placeholder
            Expr::Ident(Ident("<unsupported>".to_string()), Span::new(0, 0))
        }
    }
}