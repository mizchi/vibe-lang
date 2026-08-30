; Comments
(line_comment) @comment

; Keywords - control flow
"if" @keyword
"else" @keyword
"match" @keyword
"while" @keyword
"for" @keyword
"in" @keyword
"loop" @keyword
"break" @keyword
"continue" @keyword
"handle" @keyword
"throw" @keyword
"with" @keyword

; Keywords - declarations
"let" @keyword
"rec" @keyword
"mut" @keyword
"enum" @keyword
"struct" @keyword
"type" @keyword
"trait" @keyword
"impl" @keyword
"suberror" @keyword
"module" @keyword

; Keywords - import/export
"import" @keyword
"export" @keyword
"as" @keyword

; Keywords - special
"test" @keyword
"bench" @keyword

; Operators
[
  "+"  "-"  "*"  "/"  "%"
  "==" "!=" "<"  "<=" ">"  ">="
  "&&" "||" "!"
  "&"  "|"  "^"  "<<" ">>" "~"
  "|>"
] @operator

[
  "="  "+=" "-=" "*=" "/=" "%="
] @operator

"->" @operator
"=>" @operator
"::" @punctuation.delimiter

; Delimiters
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" "."] @punctuation.delimiter
":" @punctuation.delimiter

; Literals
(integer) @number
(float) @number
(string) @string
(string_fragment) @string
(escape_sequence) @string.escape
(interpolation) @string
(boolean) @boolean
(unit_literal) @constant

; Functions
(call_expression
  function: (primary_expression
    (identifier) @function))

(call_expression
  function: (primary_expression
    (qualified_identifier) @function))

(let_declaration
  name: (identifier) @function
  value: (function_expression))

; Parameters
(parameter
  name: (identifier) @variable.parameter)

; Fields
(struct_field
  name: (identifier) @property)

(record_field
  key: (identifier) @property)

(member_expression
  property: (identifier) @property)

; Types
(type_identifier) @type
(namespace_identifier) @module

(enum_declaration
  name: (type_identifier) @type)

(struct_declaration
  name: (type_identifier) @type)

(type_alias_declaration
  name: (type_identifier) @type)

(trait_declaration
  name: (type_identifier) @type)

(enum_variant
  name: (type_identifier) @type.variant)

; Patterns
(wildcard_pattern) @variable.special

(constructor_pattern
  name: (type_identifier) @type.variant)

; Test/bench names
(test_block
  name: (string) @string)

(bench_block
  name: (string) @string)

; Imports
(import_path) @string

; Identifiers (last, lowest priority)
(identifier) @variable
