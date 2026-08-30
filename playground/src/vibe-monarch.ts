import type * as monaco from "monaco-editor";

export const vibeLanguageConfig: monaco.languages.LanguageConfiguration = {
  comments: {
    lineComment: "//",
  },
  brackets: [
    ["{", "}"],
    ["[", "]"],
    ["(", ")"],
  ],
  autoClosingPairs: [
    { open: "{", close: "}" },
    { open: "[", close: "]" },
    { open: "(", close: ")" },
    { open: '"', close: '"', notIn: ["string"] },
    { open: "'", close: "'", notIn: ["string", "comment"] },
  ],
  surroundingPairs: [
    { open: "{", close: "}" },
    { open: "[", close: "]" },
    { open: "(", close: ")" },
    { open: '"', close: '"' },
    { open: "'", close: "'" },
  ],
  indentationRules: {
    increaseIndentPattern: /\{\s*$/,
    decreaseIndentPattern: /^\s*\}/,
  },
};

export const vibeMonarchLanguage: monaco.languages.IMonarchLanguage = {
  defaultToken: "",
  tokenPostfix: ".vibe",

  keywords: [
    "let",
    "rec",
    "mut",
    "fn",
    "if",
    "else",
    "match",
    "while",
    "for",
    "in",
    "loop",
    "do",
    "break",
    "continue",
    "return",
    "with",
    "handle",
    "throw",
    "raise",
    "yield",
    "enum",
    "struct",
    "type",
    "trait",
    "impl",
    "export",
    "import",
    "declare",
    "test",
    "bench",
    "derive",
    "as",
    "module",
    "suberror",
    "open",
    "from",
    "record",
    "map",
  ],

  builtinConstants: ["true", "false"],

  operators: [
    "=",
    ">",
    "<",
    "!",
    "==",
    "!=",
    "<=",
    ">=",
    "&&",
    "||",
    "+",
    "-",
    "*",
    "/",
    "%",
    "&",
    "|",
    "^",
    "~",
    "<<",
    ">>",
    "+=",
    "-=",
    "*=",
    "/=",
    "%=",
    "->",
    "=>",
    "|>",
    "::",
    "..",
    "...",
  ],

  symbols: /[=><!~?:&|+\-*\/\^%]+/,

  escapes: /\\(?:["\\/ntr0])/,

  tokenizer: {
    root: [
      // comments
      [/\/\/.*$/, "comment"],

      // strings
      [/r"/, "string", "@rawstring"],
      [/"/, "string", "@string"],

      // character literals
      [/'(?:\\.|[^'\\])'/, "string.char"],

      // numbers
      [/0[xX][0-9a-fA-F]+/, "number.hex"],
      [/[0-9]+\.[0-9]+f?/, "number.float"],
      [/[0-9]+/, "number"],

      // namespace identifiers
      [/@[a-zA-Z_][a-zA-Z0-9_]*/, "namespace"],

      // type identifiers (capitalized)
      [
        /[A-Z][a-zA-Z0-9_]*/,
        {
          cases: {
            "@keywords": "keyword",
            "@default": "type.identifier",
          },
        },
      ],

      // identifiers and keywords
      [
        /[a-z_][a-zA-Z0-9_]*/,
        {
          cases: {
            "@keywords": "keyword",
            "@builtinConstants": "constant.language",
            "@default": "identifier",
          },
        },
      ],

      // whitespace
      { include: "@whitespace" },

      // delimiters and operators
      [/[{}()\[\]]/, "@brackets"],
      [/[;,.]/, "delimiter"],
      [
        /@symbols/,
        {
          cases: {
            "@operators": "operator",
            "@default": "",
          },
        },
      ],
    ],

    string: [
      [/[^\\"]+/, "string"],
      [/@escapes/, "string.escape"],
      [/\\\(/, "string.escape", "@interpolation_paren"],
      [/\\\{/, "string.escape", "@interpolation_brace"],
      [/"/, "string", "@pop"],
    ],

    rawstring: [
      [/[^"]+/, "string"],
      [/"/, "string", "@pop"],
    ],

    interpolation_paren: [
      [/\)/, "string.escape", "@pop"],
      { include: "root" },
    ],

    interpolation_brace: [
      [/\}/, "string.escape", "@pop"],
      { include: "root" },
    ],

    whitespace: [[/\s+/, "white"]],
  },
};
