# Pending Tests

This directory contains tests that are temporarily disabled due to incomplete feature implementation.

## Module System Tests (`module_tests.rs`)
- Tests for module import/export functionality
- Requires full module system implementation
- Related issue: Module system type checking and resolution

## WIT Generation Tests (`wit_generation_tests.rs`)
- Tests for WebAssembly Interface Type generation
- Requires component model implementation
- Related issue: WebAssembly Component Model support

## Component Execution Tests (`component_execution_tests.rs`)
- Tests for WebAssembly component execution
- Requires WASI runtime integration
- Related issue: WASI sandbox and component runtime

These tests will be re-enabled as the corresponding features are implemented.