; Functions
(let_declaration
  name: (identifier) @name
  value: (function_expression)) @item

; Let bindings
(let_declaration
  name: (identifier) @name) @item

; Types
(enum_declaration
  name: (type_identifier) @name) @item

(struct_declaration
  name: (type_identifier) @name) @item

(type_alias_declaration
  name: (type_identifier) @name) @item

(trait_declaration
  name: (type_identifier) @name) @item

(impl_declaration
  trait: (type_identifier) @name) @item

; Tests
(test_block
  name: (string) @name) @item

(bench_block
  name: (string) @name) @item

; Modules
(module_declaration
  name: (identifier) @name) @item
