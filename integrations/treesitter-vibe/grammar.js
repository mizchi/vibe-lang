/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  ASSIGN: 1,
  PIPE: 2,
  OR: 3,
  AND: 4,
  COMPARE: 5,
  BIT_OR: 6,
  BIT_XOR: 7,
  BIT_AND: 8,
  SHIFT: 9,
  ADD: 10,
  MUL: 11,
  UNARY: 12,
  CALL: 13,
  MEMBER: 14,
  INDEX: 15,
};

module.exports = grammar({
  name: "vibe",

  extras: ($) => [/\s/, $.line_comment],

  word: ($) => $.identifier,

  conflicts: ($) => [
    [$.parameter_list, $.unit_literal],
    [$.primary_expression, $.parameter],
    [$.type_parameter, $.primary_expression],
    [$.type_name, $.type_application],
    [$._expression, $.if_expression],
    [$.tuple_type],
  ],

  rules: {
    source_file: ($) => repeat($._statement),

    // ── Statements ──────────────────────────────────────────────

    _statement: ($) =>
      choice(
        $.import_statement,
        $.export_statement,
        $.let_declaration,
        $.enum_declaration,
        $.suberror_declaration,
        $.struct_declaration,
        $.type_alias_declaration,
        $.trait_declaration,
        $.impl_declaration,
        $.test_block,
        $.bench_block,
        $.module_declaration,
        $.alias_declaration,
        $.expression_statement,
      ),

    import_statement: ($) =>
      prec.right(
        seq(
          "import",
          field("path", $.import_path),
          optional($.import_list),
        ),
      ),

    import_path: (_) =>
      token(
        choice(
          // relative: ./foo.vibe, ./foo.vibe#hash
          /\.\/[a-zA-Z0-9_/.]+(\.[a-zA-Z]+)?(#[a-zA-Z0-9_]+)?/,
          // absolute: @vibe/builtin/option.vibe
          /\/[a-zA-Z0-9_/.]+(\.[a-zA-Z]+)?/,
        ),
      ),

    import_list: ($) =>
      seq("{", commaSep1($.import_specifier), "}"),

    import_specifier: ($) =>
      seq(
        field("name", $.identifier),
        optional(seq("as", field("alias", $.identifier))),
      ),

    export_statement: ($) =>
      prec.left(
        choice(
          seq("export", "{", commaSep1($.identifier), "}"),
          seq("export", $.import_path, optional($.import_list)),
        ),
      ),

    let_declaration: ($) =>
      seq(
        optional("export"),
        "let",
        optional("rec"),
        optional("mut"),
        field("name", $.identifier),
        optional(seq(":", field("type", $._type_expression))),
        "=",
        field("value", $._expression),
      ),

    enum_declaration: ($) =>
      seq(
        optional("export"),
        "enum",
        field("name", $.type_identifier),
        optional($.type_parameters),
        "{",
        repeat($.enum_variant),
        "}",
      ),

    enum_variant: ($) =>
      seq(
        field("name", $.type_identifier),
        optional(seq("(", sepBy1(",", $._type_expression), ")")),
        optional(";"),
      ),

    suberror_declaration: ($) =>
      seq(
        optional("export"),
        "suberror",
        field("name", $.type_identifier),
        optional($.type_parameters),
        "{",
        repeat($.enum_variant),
        "}",
      ),

    struct_declaration: ($) =>
      seq(
        optional("export"),
        "struct",
        field("name", $.type_identifier),
        optional($.type_parameters),
        "{",
        repeat($.struct_field),
        "}",
      ),

    struct_field: ($) =>
      seq(
        field("name", $.identifier),
        ":",
        field("type", $._type_expression),
        optional(choice(";", ",")),
      ),

    type_alias_declaration: ($) =>
      seq(
        optional("export"),
        "type",
        field("name", $.type_identifier),
        optional($.type_parameters),
        "=",
        field("type", $._type_expression),
      ),

    trait_declaration: ($) =>
      prec.left(
        seq(
          optional("export"),
          "trait",
          field("name", $.type_identifier),
          optional(seq(":", commaSep1($.type_identifier))),
        ),
      ),

    impl_declaration: ($) =>
      seq(
        "impl",
        optional($.type_parameters),
        field("trait", $.type_identifier),
        "for",
        field("type", $._type_expression),
      ),

    test_block: ($) =>
      seq("test", field("name", $.string), field("body", $.block)),

    bench_block: ($) =>
      seq("bench", field("name", $.string), field("body", $.block)),

    module_declaration: ($) =>
      seq(
        optional("export"),
        "module",
        field("name", $.identifier),
        "{",
        repeat($._statement),
        "}",
      ),

    alias_declaration: ($) =>
      seq(
        field("name", $.namespace_identifier),
        "=",
        field("path", $.import_path),
      ),

    expression_statement: ($) => $._expression,

    // ── Type Expressions ────────────────────────────────────────

    _type_expression: ($) =>
      choice(
        $.type_name,
        $.type_application,
        $.function_type,
        $.tuple_type,
        $.unit_type,
      ),

    type_name: ($) =>
      choice($.type_identifier, $.identifier),

    type_application: ($) =>
      seq($.type_identifier, "[", commaSep1($._type_expression), "]"),

    function_type: ($) =>
      prec.left(
        seq(
          "(",
          commaSep($._type_expression),
          ")",
          "->",
          $._type_expression,
          optional($.effect_annotation),
        ),
      ),

    tuple_type: ($) =>
      seq("(", $._type_expression, ",", sepBy1(",", $._type_expression), ")"),

    unit_type: (_) => seq("(", ")"),

    type_parameters: ($) =>
      seq("[", commaSep1($.type_parameter), "]"),

    type_parameter: ($) =>
      seq(
        field("name", choice($.type_identifier, $.identifier)),
        optional(seq(":", $.trait_bound)),
      ),

    trait_bound: ($) =>
      choice(
        seq($.type_identifier, repeat(seq("+", $.type_identifier))),
        seq("trait", "{", repeat($.trait_method_signature), "}"),
      ),

    trait_method_signature: ($) =>
      seq($.identifier, ":", $._type_expression),

    effect_annotation: ($) =>
      seq("with", "{", commaSep1(choice($.type_identifier, $.identifier)), "}"),

    // ── Expressions ─────────────────────────────────────────────

    _expression: ($) =>
      choice(
        $.primary_expression,
        $.binary_expression,
        $.unary_expression,
        $.call_expression,
        $.member_expression,
        $.index_expression,
        $.pipe_expression,
        $.assignment_expression,
        $.compound_assignment_expression,
        $.function_expression,
        $.if_expression,
        $.match_expression,
        $.while_expression,
        $.for_in_expression,
        $.loop_expression,
        $.handle_expression,
        $.throw_expression,
        $.break_expression,
        $.continue_expression,
        $.block,
      ),

    primary_expression: ($) =>
      choice(
        $.integer,
        $.float,
        $.string,
        $.boolean,
        $.unit_literal,
        $.identifier,
        $.namespace_identifier,
        $.qualified_identifier,
        $.tuple_expression,
        $.array_expression,
        $.record_expression,
        $.map_expression,
        $.struct_expression,
        $.parenthesized_expression,
      ),

    binary_expression: ($) =>
      choice(
        ...[
          ["||", PREC.OR],
          ["&&", PREC.AND],
          ["==", PREC.COMPARE],
          ["!=", PREC.COMPARE],
          ["<", PREC.COMPARE],
          ["<=", PREC.COMPARE],
          [">", PREC.COMPARE],
          [">=", PREC.COMPARE],
          ["|", PREC.BIT_OR],
          ["^", PREC.BIT_XOR],
          ["&", PREC.BIT_AND],
          ["<<", PREC.SHIFT],
          [">>", PREC.SHIFT],
          ["+", PREC.ADD],
          ["-", PREC.ADD],
          ["*", PREC.MUL],
          ["/", PREC.MUL],
          ["%", PREC.MUL],
        ].map(([op, precedence]) =>
          prec.left(
            precedence,
            seq(
              field("left", $._expression),
              field("operator", op),
              field("right", $._expression),
            ),
          ),
        ),
      ),

    unary_expression: ($) =>
      prec(
        PREC.UNARY,
        seq(
          field("operator", choice("-", "!", "~")),
          field("operand", $._expression),
        ),
      ),

    pipe_expression: ($) =>
      prec.left(
        PREC.PIPE,
        seq(
          field("left", $._expression),
          "|>",
          field("right", $._expression),
        ),
      ),

    call_expression: ($) =>
      prec(
        PREC.CALL,
        seq(
          field("function", $._expression),
          "(",
          field("arguments", commaSep($.argument)),
          ")",
        ),
      ),

    argument: ($) =>
      choice(
        $._expression,
        $.labeled_argument,
        $.spread_expression,
      ),

    labeled_argument: ($) =>
      seq(
        field("name", $.identifier),
        choice("~", "?"),
        optional(seq("=", field("value", $._expression))),
      ),

    spread_expression: ($) => seq("...", $._expression),

    member_expression: ($) =>
      prec(
        PREC.MEMBER,
        seq(
          field("object", $._expression),
          ".",
          field("property", choice($.identifier, $.integer)),
        ),
      ),

    index_expression: ($) =>
      prec(
        PREC.INDEX,
        seq(
          field("object", $._expression),
          "[",
          field("index", $._expression),
          "]",
        ),
      ),

    assignment_expression: ($) =>
      prec.right(
        PREC.ASSIGN,
        seq(
          field("left", $.identifier),
          "=",
          field("right", $._expression),
        ),
      ),

    compound_assignment_expression: ($) =>
      prec.right(
        PREC.ASSIGN,
        seq(
          field("left", $.identifier),
          field("operator", choice("+=", "-=", "*=", "/=", "%=")),
          field("right", $._expression),
        ),
      ),

    function_expression: ($) =>
      seq(
        optional($.type_parameters),
        $.parameter_list,
        optional(seq("->", field("return_type", $._type_expression))),
        optional($.effect_annotation),
        field("body", $.block),
      ),

    parameter_list: ($) =>
      seq("(", commaSep($.parameter), ")"),

    parameter: ($) =>
      seq(
        field("name", $.identifier),
        optional(choice("~", "?")),
        optional(seq(":", field("type", $._type_expression))),
        optional(seq("=", field("default", $._expression))),
      ),

    if_expression: ($) =>
      prec.right(
        seq(
          "if",
          field("condition", $._expression),
          field("consequence", $.block),
          optional(seq("else", field("alternative", choice($.block, $.if_expression, $._expression)))),
        ),
      ),

    match_expression: ($) =>
      seq(
        "match",
        field("value", $._expression),
        "{",
        repeat($.match_arm),
        "}",
      ),

    match_arm: ($) =>
      seq(
        field("pattern", $.pattern),
        optional(seq("if", field("guard", $._expression))),
        "=>",
        field("body", $._expression),
        optional(","),
      ),

    while_expression: ($) =>
      seq(
        "while",
        field("condition", $._expression),
        field("body", $.block),
      ),

    for_in_expression: ($) =>
      seq(
        "for",
        field("index", optional(seq($.identifier, ","))),
        field("binding", $.identifier),
        "in",
        field("iterable", $._expression),
        field("body", $.block),
      ),

    loop_expression: ($) =>
      seq(
        "loop",
        optional(seq("(", commaSep1($.loop_binding), ")")),
        field("body", $.block),
      ),

    loop_binding: ($) =>
      seq(
        field("name", $.identifier),
        "=",
        field("value", $._expression),
      ),

    handle_expression: ($) =>
      seq(
        "handle",
        field("body", $.block),
        "{",
        repeat($.match_arm),
        "}",
      ),

    throw_expression: ($) =>
      seq("throw", "(", field("value", $._expression), ")"),

    break_expression: ($) =>
      prec.left(seq("break", optional(field("value", $._expression)))),

    continue_expression: ($) =>
      prec.left(
        seq(
          "continue",
          optional(seq("(", commaSep1($._expression), ")")),
        ),
      ),

    block: ($) =>
      seq("{", repeat($._block_item), "}"),

    _block_item: ($) =>
      choice(
        $.let_expression,
        $._expression,
      ),

    let_expression: ($) =>
      seq(
        "let",
        optional("rec"),
        optional("mut"),
        field("pattern", $._let_pattern),
        optional(seq(":", field("type", $._type_expression))),
        "=",
        field("value", $._expression),
      ),

    _let_pattern: ($) =>
      choice(
        $.identifier,
        $.wildcard_pattern,
        $.constructor_pattern,
        $.tuple_pattern,
        $.record_pattern,
      ),

    // ── Patterns ────────────────────────────────────────────────

    pattern: ($) =>
      choice(
        $.wildcard_pattern,
        $.binding_pattern,
        $.integer,
        $.float,
        $.string,
        $.boolean,
        $.constructor_pattern,
        $.tuple_pattern,
        $.record_pattern,
        $.or_pattern,
      ),

    wildcard_pattern: (_) => "_",

    binding_pattern: ($) => $.identifier,

    constructor_pattern: ($) =>
      seq(
        field("name", $.type_identifier),
        optional(
          choice(
            seq("(", commaSep($.pattern), ")"),
            seq("::", "{", commaSep($.struct_field_pattern), "}"),
          ),
        ),
      ),

    tuple_pattern: ($) =>
      seq("(", $.pattern, ",", commaSep($.pattern), ")"),

    record_pattern: ($) =>
      seq("record", "{", commaSep1($.struct_field_pattern), "}"),

    struct_field_pattern: ($) =>
      seq(
        field("name", $.identifier),
        optional(seq(":", field("pattern", $.pattern))),
      ),

    or_pattern: ($) =>
      prec.left(seq($.pattern, "|", $.pattern)),

    // ── Collection Literals ─────────────────────────────────────

    tuple_expression: ($) =>
      seq("(", $._expression, ",", commaSep1($._expression), ")"),

    array_expression: ($) =>
      seq("[", commaSep(choice($._expression, $.spread_expression)), "]"),

    record_expression: ($) =>
      seq("record", "{", commaSep1($.record_field), "}"),

    map_expression: ($) =>
      seq("map", "{", commaSep1($.record_field), "}"),

    struct_expression: ($) =>
      seq(
        field("name", $.type_identifier),
        "::",
        "{",
        commaSep1($.record_field),
        "}",
      ),

    record_field: ($) =>
      seq(
        field("key", choice($.identifier, $.string)),
        optional(seq(":", field("value", $._expression))),
      ),

    parenthesized_expression: ($) =>
      seq("(", $._expression, ")"),

    // ── Literals ────────────────────────────────────────────────

    integer: (_) => token(choice(/[0-9]+/, /0[xX][0-9a-fA-F]+/)),

    float: (_) => token(/[0-9]+\.[0-9]+f?/),

    string: ($) =>
      seq(
        '"',
        repeat(
          choice(
            $.escape_sequence,
            $.interpolation,
            $.string_fragment,
          ),
        ),
        '"',
      ),

    string_fragment: (_) => token.immediate(prec(1, /[^"\\]+/)),

    escape_sequence: (_) => token.immediate(/\\["\\/ntr0]/),

    interpolation: ($) =>
      seq(
        token.immediate("\\("),
        $._expression,
        ")",
      ),

    boolean: (_) => choice("true", "false"),

    unit_literal: (_) => seq("(", ")"),

    // ── Identifiers ─────────────────────────────────────────────

    identifier: (_) => /[a-z_][a-zA-Z0-9_]*/,

    type_identifier: (_) => /[A-Z][a-zA-Z0-9_]*/,

    namespace_identifier: (_) => /@[a-zA-Z_][a-zA-Z0-9_]*/,

    qualified_identifier: ($) =>
      seq(
        choice($.type_identifier, $.namespace_identifier),
        "::",
        choice($.identifier, $.type_identifier),
      ),

    // ── Comments ────────────────────────────────────────────────

    line_comment: (_) => token(seq("//", /.*/)),
  },
});

/**
 * @param {RuleOrLiteral} rule
 */
function commaSep(rule) {
  return optional(commaSep1(rule));
}

/**
 * @param {RuleOrLiteral} rule
 */
function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)), optional(","));
}

/**
 * @param {string} sep
 * @param {RuleOrLiteral} rule
 */
function sepBy1(sep, rule) {
  return seq(rule, repeat(seq(sep, rule)));
}
