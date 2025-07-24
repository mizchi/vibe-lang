# XS MCP Server

Model Context Protocol (MCP) server for XS language, providing AI assistants with tools to analyze, manipulate, and understand XS code.

## Features

- **Code Analysis Tools**:
  - `xs_parse`: Parse XS code and return AST
  - `xs_typecheck`: Type check XS code
  - `xs_search`: Search codebase with various queries
  - `xs_ast_transform`: Apply AST transformations
  - `xs_analyze_dependencies`: Analyze code dependencies
  - `xs_effect_analysis`: Analyze effects and required permissions

- **Resources**:
  - `xs://workspace/definitions`: Access all workspace definitions
  - `xs://workspace/types`: Access type definitions

- **Prompts**:
  - `explain_type`: Explain XS type signatures
  - `generate_test`: Generate test cases for XS code
  - `suggest_refactoring`: Suggest code improvements

## Running the Server

```bash
# Default address (127.0.0.1:3000)
cargo run -p xs-mcp

# Custom address
XS_MCP_ADDR=0.0.0.0:8080 cargo run -p xs-mcp
```

## MCP Client Configuration

Add to your MCP client configuration:

```json
{
  "mcpServers": {
    "xs-language": {
      "command": "cargo",
      "args": ["run", "-p", "xs-mcp"],
      "cwd": "/path/to/xs-lang-v3"
    }
  }
}
```

## Example Usage

### Parse XS Code
```json
{
  "method": "tools/call",
  "params": {
    "tool_name": "xs_parse",
    "arguments": {
      "code": "(let add (fn (x y) (+ x y)))"
    }
  }
}
```

### Analyze Effects
```json
{
  "method": "tools/call",
  "params": {
    "tool_name": "xs_effect_analysis",
    "arguments": {
      "code": "(print \"Hello, World!\")"
    }
  }
}
```

## Protocol

The server implements the Model Context Protocol v1.0 specification:
- Tools for code analysis and manipulation
- Resources for accessing workspace data
- Prompts for common AI tasks
- Standard MCP error handling