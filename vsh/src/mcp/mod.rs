//! MCP (Model Context Protocol) Server for XS Language
//!
//! This module provides MCP server capabilities for AI tools to interact
//! with XS language features including type checking, code analysis, and
//! AST manipulation.

pub mod protocol;
pub mod server;
pub mod handlers;
pub mod tools;

pub use server::McpServer;
pub use protocol::{McpRequest, McpResponse};