//! Type conversion between XS types and WebAssembly GC types

use super::{CodeGenError, WasmType};
use vibe_language::Type;

/// Convert XS type to WebAssembly type
pub fn xs_type_to_wasm(ty: &Type) -> Result<WasmType, CodeGenError> {
    match ty {
        Type::Int => Ok(WasmType::I64),            // Using i64 for integers
        Type::Bool => Ok(WasmType::I32),           // Bool as i32 (0 or 1)
        Type::Float => Ok(WasmType::F64),          // Float as f64
        Type::String => Ok(WasmType::ArrayRef(0)), // String as array of bytes
        Type::Unit => Ok(WasmType::I32),           // Unit as i32 (always 0)
        Type::List(_elem_ty) => {
            // List as array of elements
            // Type index would be determined during module generation
            Ok(WasmType::ArrayRef(1)) // Placeholder index
        }
        Type::Function(_from, _to) => {
            // Function as closure struct with function reference
            Ok(WasmType::StructRef(2)) // Placeholder index
        }
        Type::Var(name) => {
            // Type variables should be resolved before code generation
            Err(CodeGenError::TypeError(format!(
                "Unresolved type variable: {name}"
            )))
        }
        Type::UserDefined { .. } => {
            // User-defined types need proper struct/class mapping
            // For now, use struct reference with placeholder index
            Ok(WasmType::StructRef(3)) // Placeholder index
        }
        Type::FunctionWithEffect {
            from: _,
            to: _,
            effects: _,
        } => {
            // Function with effects treated the same as regular function in WASM
            // Effects are tracked at compile-time, not runtime
            Ok(WasmType::StructRef(2)) // Same as regular function
        }
        Type::Record { .. } => {
            // Records as struct references
            Ok(WasmType::StructRef(4)) // Placeholder index
        }
    }
}

/// Type index allocator for managing WebAssembly type indices
pub struct TypeIndexAllocator {
    next_index: u32,
    type_map: std::collections::HashMap<String, u32>,
}

impl Default for TypeIndexAllocator {
    fn default() -> Self {
        Self::new()
    }
}

impl TypeIndexAllocator {
    pub fn new() -> Self {
        Self {
            next_index: 0,
            type_map: std::collections::HashMap::new(),
        }
    }

    /// Allocate a new type index
    pub fn allocate(&mut self, name: &str) -> u32 {
        if let Some(&index) = self.type_map.get(name) {
            index
        } else {
            let index = self.next_index;
            self.next_index += 1;
            self.type_map.insert(name.to_string(), index);
            index
        }
    }

    /// Get type index by name
    pub fn get(&self, name: &str) -> Option<u32> {
        self.type_map.get(name).copied()
    }
}

/// Standard type indices for built-in types
pub struct StandardTypes {
    pub string_array: u32,
    pub cons_cell: u32,
    pub closure_base: u32,
}

impl StandardTypes {
    pub fn new(allocator: &mut TypeIndexAllocator) -> Self {
        Self {
            string_array: allocator.allocate("string_array"),
            cons_cell: allocator.allocate("cons_cell"),
            closure_base: allocator.allocate("closure_base"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_type_conversion() {
        assert_eq!(xs_type_to_wasm(&Type::Int).unwrap(), WasmType::I64);
        assert_eq!(xs_type_to_wasm(&Type::Bool).unwrap(), WasmType::I32);

        // Type variables should error
        assert!(xs_type_to_wasm(&Type::Var("T".to_string())).is_err());
    }

    #[test]
    fn test_type_allocator() {
        let mut allocator = TypeIndexAllocator::new();

        let idx1 = allocator.allocate("string");
        let idx2 = allocator.allocate("list");
        let idx3 = allocator.allocate("string"); // Should return same index

        assert_eq!(idx1, 0);
        assert_eq!(idx2, 1);
        assert_eq!(idx3, 0); // Same as idx1

        assert_eq!(allocator.get("string"), Some(0));
        assert_eq!(allocator.get("list"), Some(1));
        assert_eq!(allocator.get("unknown"), None);
    }
}
