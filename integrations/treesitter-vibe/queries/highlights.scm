; Keywords
"let" @keyword
"rec" @keyword
"mut" @keyword
"if" @keyword
"else" @keyword
"match" @keyword
"while" @keyword
"for" @keyword
"in" @keyword
"loop" @keyword
"break" @keyword
"continue" @keyword
"with" @keyword
"handle" @keyword
"throw" @keyword

"enum" @keyword.type
"struct" @keyword.type
"type" @keyword.type
"trait" @keyword.type
"impl" @keyword.type
"suberror" @keyword.type
"module" @keyword.type

"import" @keyword.import
"export" @keyword.import
"as" @keyword.import

"test" @keyword.directive
"bench" @keyword.directive
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

"->" @keyword.operator
"=>" @keyword.operator
"::" @punctuation.delimiter

; Delimiters
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" "."] @punctuation.delimiter
":" @punctuation.delimiter

; Literals
(integer) @number
(float) @number.float
(string) @string
(string_fragment) @string
(escape_sequence) @string.escape
(interpolation) @embedded
(boolean) @boolean
(unit_literal) @constant.builtin

; Identifiers
(identifier) @variable
(type_identifier) @type
(namespace_identifier) @module

; Functions
(call_expression
  function: (primary_expression
    (identifier) @function.call))

(call_expression
  function: (primary_expression
    (qualified_identifier) @function.call))

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

; Patterns
(wildcard_pattern) @variable.builtin

(constructor_pattern
  name: (type_identifier) @constructor)

; Declarations
(enum_declaration
  name: (type_identifier) @type.definition)

(struct_declaration
  name: (type_identifier) @type.definition)

(type_alias_declaration
  name: (type_identifier) @type.definition)

(trait_declaration
  name: (type_identifier) @type.definition)

(enum_variant
  name: (type_identifier) @constructor)

(test_block
  name: (string) @string.special)

(bench_block
  name: (string) @string.special)

; Imports
(import_path) @string.special.path

; Comments
(line_comment) @comment
