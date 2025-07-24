//! Standard library module definitions
//!
//! This module defines what functions are available in each lib module
//! and their type signatures for explicit imports.

use std::collections::HashMap;
use crate::Type;

/// Get available functions for a module path
pub fn get_module_functions(path: &[String]) -> Option<HashMap<String, Type>> {
    match path.iter().map(|s| s.as_str()).collect::<Vec<_>>().as_slice() {
        ["lib"] => Some(get_lib_functions()),
        ["lib", "String"] => Some(get_string_functions()),
        ["lib", "List"] => Some(get_list_functions()),
        ["lib", "Int"] => Some(get_int_functions()),
        _ => None,
    }
}

/// Core lib functions
fn get_lib_functions() -> HashMap<String, Type> {
    let mut functions = HashMap::new();
    
    // Basic functions available from lib
    functions.insert(
        "id".to_string(),
        Type::Function(
            Box::new(Type::Var("a".to_string())),
            Box::new(Type::Var("a".to_string())),
        ),
    );
    
    functions.insert(
        "const".to_string(),
        Type::Function(
            Box::new(Type::Var("a".to_string())),
            Box::new(Type::Function(
                Box::new(Type::Var("b".to_string())),
                Box::new(Type::Var("a".to_string())),
            )),
        ),
    );
    
    functions
}

/// String module functions
fn get_string_functions() -> HashMap<String, Type> {
    let mut functions = HashMap::new();
    
    functions.insert(
        "concat".to_string(),
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(Box::new(Type::String), Box::new(Type::String))),
        ),
    );
    
    functions.insert(
        "length".to_string(),
        Type::Function(Box::new(Type::String), Box::new(Type::Int)),
    );
    
    functions.insert(
        "toInt".to_string(),
        Type::Function(Box::new(Type::String), Box::new(Type::Int)),
    );
    
    functions.insert(
        "fromInt".to_string(),
        Type::Function(Box::new(Type::Int), Box::new(Type::String)),
    );
    
    functions.insert(
        "split".to_string(),
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(
                Box::new(Type::String),
                Box::new(Type::List(Box::new(Type::String))),
            )),
        ),
    );
    
    functions.insert(
        "join".to_string(),
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(
                Box::new(Type::List(Box::new(Type::String))),
                Box::new(Type::String),
            )),
        ),
    );
    
    functions
}

/// List module functions  
fn get_list_functions() -> HashMap<String, Type> {
    let mut functions = HashMap::new();
    
    let a = || Type::Var("a".to_string());
    let list_a = || Type::List(Box::new(a()));
    
    functions.insert(
        "cons".to_string(),
        Type::Function(
            Box::new(a()),
            Box::new(Type::Function(Box::new(list_a()), Box::new(list_a()))),
        ),
    );
    
    functions.insert(
        "head".to_string(),
        Type::Function(Box::new(list_a()), Box::new(a())),
    );
    
    functions.insert(
        "tail".to_string(),
        Type::Function(Box::new(list_a()), Box::new(list_a())),
    );
    
    functions.insert(
        "length".to_string(),
        Type::Function(Box::new(list_a()), Box::new(Type::Int)),
    );
    
    functions.insert(
        "map".to_string(),
        Type::Function(
            Box::new(Type::Function(Box::new(a()), Box::new(Type::Var("b".to_string())))),
            Box::new(Type::Function(
                Box::new(list_a()),
                Box::new(Type::List(Box::new(Type::Var("b".to_string())))),
            )),
        ),
    );
    
    functions.insert(
        "filter".to_string(),
        Type::Function(
            Box::new(Type::Function(Box::new(a()), Box::new(Type::Bool))),
            Box::new(Type::Function(Box::new(list_a()), Box::new(list_a()))),
        ),
    );
    
    functions
}

/// Int module functions
fn get_int_functions() -> HashMap<String, Type> {
    let mut functions = HashMap::new();
    
    functions.insert(
        "toString".to_string(),
        Type::Function(Box::new(Type::Int), Box::new(Type::String)),
    );
    
    functions.insert(
        "abs".to_string(),
        Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
    );
    
    functions.insert(
        "min".to_string(),
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        ),
    );
    
    functions.insert(
        "max".to_string(),
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        ),
    );
    
    functions
}