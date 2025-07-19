# AI-Friendly Error Messages Evaluation

## Design Goals
- **Structured error information** for machine parsing
- **Clear categorization** (syntax, type, scope, pattern, etc.)
- **Actionable suggestions** with confidence levels
- **Context-aware** error messages with code snippets

## Implemented Features

### 1. Error Context Structure
```rust
pub struct ErrorContext {
    pub message: String,
    pub category: ErrorCategory,
    pub snippet: Option<CodeSnippet>,
    pub suggestions: Vec<Suggestion>,
    pub related: Vec<RelatedInfo>,
    pub metadata: ErrorMetadata,
}
```

### 2. Error Categories
- **SYNTAX**: Parse errors
- **TYPE**: Type mismatches, inference failures
- **SCOPE**: Undefined variables, scope violations
- **PATTERN**: Pattern matching errors
- **MODULE**: Import/export issues
- **RUNTIME**: Execution errors

### 3. Suggestion System
```rust
pub struct Suggestion {
    pub description: String,
    pub replacement: Option<String>,
    pub confidence: SuggestionConfidence,
}
```

Confidence levels:
- **High**: Automatic fixes (e.g., typo corrections)
- **Medium**: Likely fixes (e.g., type conversions)
- **Low**: Possible alternatives

### 4. Type Conversion Suggestions
For type mismatches, the system suggests:
- `String -> Int`: Use `int_of_string`
- `Int -> String`: Use `string_of_int`
- `Float -> Int`: Use `int_of_float`
- `List -> Int`: Use `length` function

### 5. Variable Name Suggestions
Using Levenshtein distance algorithm:
- Finds similar variable names within edit distance of 2
- Suggests top 3 candidates
- Example: `mpa` → suggests `map`, `map2`, `max`

## Example Error Messages

### Type Mismatch
```
ERROR[TYPE]: Type mismatch: expected type 'Int', but found type 'String'
Location: line 3, column 5
Code: (+ x y)
Type mismatch: expected Int, found String
Suggestions:
  1. Convert string to integer using 'int_of_string'
     Replace with: (int_of_string <expr>)
```

### Undefined Variable
```
ERROR[SCOPE]: Undefined variable: 'mpa'
Undefined: 'mpa'
Similar: map, max, map2
Suggestions:
  1. Did you mean 'map'?
     Replace with: map
```

### Pattern Mismatch
```
ERROR[PATTERN]: Pattern expects type '(List a)' but value has type 'Cons'
Suggestions:
  1. Use (list) pattern for empty lists or (list h t) for cons patterns
     Replace with: (match expr ((list) ...) ((list h t) ...))
```

## Benefits for AI

1. **Machine-readable format**: Structured data makes it easy for AI to parse and understand errors
2. **Categorization**: AI can learn patterns of common errors by category
3. **Actionable fixes**: Direct suggestions reduce the search space for corrections
4. **Context preservation**: Code snippets help AI understand the error location
5. **Confidence levels**: AI can prioritize high-confidence suggestions

## Future Improvements

1. **Multi-language support**: Currently English-only, but structure supports i18n
2. **Learning from fixes**: Track which suggestions are accepted
3. **Custom error handlers**: Allow AI to register domain-specific error patterns
4. **Error clustering**: Group related errors for batch fixes
5. **Performance metrics**: Measure error resolution time and success rate

## Token Efficiency

Error messages are designed to be concise while informative:
- Short category tags (TYPE, SCOPE, etc.)
- Minimal boilerplate text
- Direct replacement suggestions
- No redundant information

This design reduces token usage while maintaining clarity for both AI and human readers.