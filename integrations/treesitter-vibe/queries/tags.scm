; Functions
(let_declaration
  name: (identifier) @name
  value: (function_expression)) @definition.function

; Types
(enum_declaration
  name: (type_identifier) @name) @definition.type

(struct_declaration
  name: (type_identifier) @name) @definition.type

(type_alias_declaration
  name: (type_identifier) @name) @definition.type

(trait_declaration
  name: (type_identifier) @name) @definition.interface

; Tests
(test_block
  name: (string) @name) @definition.method

; Variables
(let_declaration
  name: (identifier) @name) @definition.variable

; Calls
(call_expression
  function: (primary_expression
    (identifier) @name)) @reference.call

(call_expression
  function: (primary_expression
    (qualified_identifier) @name)) @reference.call
