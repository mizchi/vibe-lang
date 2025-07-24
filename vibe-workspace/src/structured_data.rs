//! Structured Data for Pipeline Processing
//!
//! Provides structured data types for nushell-style pipeline operations,
//! enabling filtering, transformation, and inspection of code definitions.

use std::collections::HashMap;
use vibe_core::{Value, XsError};
use crate::namespace::DefinitionPath;
use crate::hash::DefinitionHash;
use chrono::{DateTime, Utc};
use serde::{Serialize, Deserialize};

/// Structured data that can flow through pipelines
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum StructuredData {
    /// A single definition
    Definition(DefinitionData),
    
    /// A list of definitions
    Definitions(Vec<DefinitionData>),
    
    /// A table with rows and columns
    Table {
        columns: Vec<String>,
        rows: Vec<HashMap<String, StructuredValue>>,
    },
    
    /// A single value
    Value(StructuredValue),
    
    /// A list of values
    List(Vec<StructuredValue>),
    
    /// A record (key-value pairs)
    Record(HashMap<String, StructuredValue>),
    
    /// Empty data
    Empty,
}

/// Data about a definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefinitionData {
    pub name: String,
    pub path: DefinitionPath,
    pub hash: DefinitionHash,
    pub type_signature: String,
    pub kind: DefinitionKind,
    pub dependencies: Vec<String>,
    pub metadata: DefinitionMetadata,
}

/// Kind of definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum DefinitionKind {
    Function { arity: usize },
    Value,
    Type,
}

/// Metadata about a definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefinitionMetadata {
    pub created_at: DateTime<Utc>,
    pub author: Option<String>,
    pub documentation: Option<String>,
    pub test_count: usize,
}

/// A structured value that can be in a table cell or record field
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum StructuredValue {
    String(String),
    Int(i64),
    Float(f64),
    Bool(bool),
    DateTime(DateTime<Utc>),
    List(Vec<StructuredValue>),
    Record(HashMap<String, StructuredValue>),
    Null,
}

impl StructuredData {
    /// Convert to a table representation
    pub fn to_table(&self) -> Result<Self, XsError> {
        match self {
            StructuredData::Definition(def) => {
                let mut row = HashMap::new();
                row.insert("name".to_string(), StructuredValue::String(def.name.clone()));
                row.insert("path".to_string(), StructuredValue::String(def.path.to_string()));
                row.insert("hash".to_string(), StructuredValue::String(def.hash.to_hex()));
                row.insert("type".to_string(), StructuredValue::String(def.type_signature.clone()));
                row.insert("kind".to_string(), StructuredValue::String(match &def.kind {
                    DefinitionKind::Function { arity } => format!("function/{arity}"),
                    DefinitionKind::Value => "value".to_string(),
                    DefinitionKind::Type => "type".to_string(),
                }));
                
                Ok(StructuredData::Table {
                    columns: vec!["name".to_string(), "path".to_string(), "hash".to_string(), 
                                  "type".to_string(), "kind".to_string()],
                    rows: vec![row],
                })
            }
            
            StructuredData::Definitions(defs) => {
                let columns = vec!["name".to_string(), "path".to_string(), "hash".to_string(), 
                                  "type".to_string(), "kind".to_string()];
                let mut rows = Vec::new();
                
                for def in defs {
                    let mut row = HashMap::new();
                    row.insert("name".to_string(), StructuredValue::String(def.name.clone()));
                    row.insert("path".to_string(), StructuredValue::String(def.path.to_string()));
                    row.insert("hash".to_string(), StructuredValue::String(def.hash.to_hex()));
                    row.insert("type".to_string(), StructuredValue::String(def.type_signature.clone()));
                    row.insert("kind".to_string(), StructuredValue::String(match &def.kind {
                        DefinitionKind::Function { arity } => format!("function/{arity}"),
                        DefinitionKind::Value => "value".to_string(),
                        DefinitionKind::Type => "type".to_string(),
                    }));
                    rows.push(row);
                }
                
                Ok(StructuredData::Table { columns, rows })
            }
            
            StructuredData::Table { .. } => Ok(self.clone()),
            
            _ => Err(XsError::RuntimeError(
                vibe_core::Span::new(0, 0),
                format!("Cannot convert {self:?} to table")
            )),
        }
    }
    
    /// Get column names if this is tabular data
    pub fn columns(&self) -> Option<Vec<String>> {
        match self {
            StructuredData::Table { columns, .. } => Some(columns.clone()),
            StructuredData::Definitions(_) => {
                Some(vec!["name".to_string(), "path".to_string(), "hash".to_string(), 
                         "type".to_string(), "kind".to_string()])
            }
            _ => None,
        }
    }
    
    /// Check if data is empty
    pub fn is_empty(&self) -> bool {
        match self {
            StructuredData::Empty => true,
            StructuredData::Definitions(defs) => defs.is_empty(),
            StructuredData::List(items) => items.is_empty(),
            StructuredData::Table { rows, .. } => rows.is_empty(),
            _ => false,
        }
    }
}

impl StructuredValue {
    /// Convert from XS Value
    pub fn from_value(value: &Value) -> Self {
        match value {
            Value::Int(n) => StructuredValue::Int(*n),
            Value::Float(f) => StructuredValue::Float(*f),
            Value::Bool(b) => StructuredValue::Bool(*b),
            Value::String(s) => StructuredValue::String(s.clone()),
            Value::List(items) => {
                StructuredValue::List(items.iter().map(Self::from_value).collect())
            }
            _ => StructuredValue::String(format!("{value:?}")),
        }
    }
    
    /// Try to convert to XS Value
    pub fn to_value(&self) -> Result<Value, XsError> {
        match self {
            StructuredValue::String(s) => Ok(Value::String(s.clone())),
            StructuredValue::Int(n) => Ok(Value::Int(*n)),
            StructuredValue::Float(f) => Ok(Value::Float(*f)),
            StructuredValue::Bool(b) => Ok(Value::Bool(*b)),
            StructuredValue::List(items) => {
                let values: Result<Vec<_>, _> = items.iter()
                    .map(|item| item.to_value())
                    .collect();
                Ok(Value::List(values?))
            }
            StructuredValue::Record(_fields) => {
                // Records are not supported in Value enum
                Err(XsError::RuntimeError(
                    vibe_core::Span::new(0, 0),
                    "Record values are not supported".to_string()
                ))
            }
            _ => Err(XsError::RuntimeError(
                vibe_core::Span::new(0, 0),
                format!("Cannot convert {self:?} to Value")
            )),
        }
    }
    
    /// Get as string if possible
    pub fn as_string(&self) -> Option<&str> {
        match self {
            StructuredValue::String(s) => Some(s),
            _ => None,
        }
    }
    
    /// Get as integer if possible
    pub fn as_int(&self) -> Option<i64> {
        match self {
            StructuredValue::Int(n) => Some(*n),
            _ => None,
        }
    }
    
    /// Get as boolean if possible
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            StructuredValue::Bool(b) => Some(*b),
            _ => None,
        }
    }
}

/// Format structured data for display
pub fn format_structured_data(data: &StructuredData) -> String {
    match data {
        StructuredData::Empty => "<empty>".to_string(),
        
        StructuredData::Value(val) => format_value(val),
        
        StructuredData::List(items) => {
            let formatted: Vec<String> = items.iter()
                .map(format_value)
                .collect();
            format!("[{}]", formatted.join(", "))
        }
        
        StructuredData::Record(fields) => {
            let formatted: Vec<String> = fields.iter()
                .map(|(k, v)| format!("{}: {}", k, format_value(v)))
                .collect();
            format!("{{{}}}", formatted.join(", "))
        }
        
        StructuredData::Definition(def) => {
            format!("{} : {} [{}]", def.name, def.type_signature, &def.hash.to_hex()[..8])
        }
        
        StructuredData::Definitions(defs) => {
            if defs.is_empty() {
                "<no definitions>".to_string()
            } else {
                let lines: Vec<String> = defs.iter()
                    .map(|def| format!("{} : {} [{}]", def.name, def.type_signature, &def.hash.to_hex()[..8]))
                    .collect();
                lines.join("\n")
            }
        }
        
        StructuredData::Table { columns, rows } => {
            format_table(columns, rows)
        }
    }
}

fn format_value(val: &StructuredValue) -> String {
    match val {
        StructuredValue::String(s) => s.clone(),
        StructuredValue::Int(n) => n.to_string(),
        StructuredValue::Float(f) => f.to_string(),
        StructuredValue::Bool(b) => b.to_string(),
        StructuredValue::DateTime(dt) => dt.to_rfc3339(),
        StructuredValue::List(items) => {
            let formatted: Vec<String> = items.iter()
                .map(format_value)
                .collect();
            format!("[{}]", formatted.join(", "))
        }
        StructuredValue::Record(fields) => {
            let formatted: Vec<String> = fields.iter()
                .map(|(k, v)| format!("{}: {}", k, format_value(v)))
                .collect();
            format!("{{{}}}", formatted.join(", "))
        }
        StructuredValue::Null => "null".to_string(),
    }
}

fn format_table(columns: &[String], rows: &[HashMap<String, StructuredValue>]) -> String {
    if rows.is_empty() {
        return "<empty table>".to_string();
    }
    
    // Calculate column widths
    let mut widths: Vec<usize> = columns.iter()
        .map(|col| col.len())
        .collect();
    
    for row in rows {
        for (i, col) in columns.iter().enumerate() {
            if let Some(val) = row.get(col) {
                let len = format_value(val).len();
                if len > widths[i] {
                    widths[i] = len;
                }
            }
        }
    }
    
    // Format header
    let mut result = String::new();
    for (i, col) in columns.iter().enumerate() {
        if i > 0 {
            result.push_str(" | ");
        }
        result.push_str(&format!("{:width$}", col, width = widths[i]));
    }
    result.push('\n');
    
    // Add separator
    for (i, width) in widths.iter().enumerate() {
        if i > 0 {
            result.push_str("-+-");
        }
        result.push_str(&"-".repeat(*width));
    }
    result.push('\n');
    
    // Format rows
    for row in rows {
        for (i, col) in columns.iter().enumerate() {
            if i > 0 {
                result.push_str(" | ");
            }
            let val = row.get(col)
                .map(format_value)
                .unwrap_or_else(|| "".to_string());
            result.push_str(&format!("{:width$}", val, width = widths[i]));
        }
        result.push('\n');
    }
    
    result
}