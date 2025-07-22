//! Pipeline Processing for XS Shell
//!
//! Implements nushell-style pipeline operations for processing structured data.

use std::collections::HashMap;
use xs_core::{XsError, Span};
use crate::structured_data::{StructuredData, StructuredValue};

/// Pipeline operator that transforms structured data
pub trait PipelineOperator {
    /// Apply the operator to the input data
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError>;
    
    /// Get a description of this operator
    fn description(&self) -> String;
}

/// Filter rows based on a predicate
pub struct FilterOperator {
    predicate: Box<dyn Fn(&HashMap<String, StructuredValue>) -> bool>,
    description: String,
}

impl FilterOperator {
    pub fn new<F>(predicate: F, description: String) -> Self
    where
        F: Fn(&HashMap<String, StructuredValue>) -> bool + 'static,
    {
        Self {
            predicate: Box::new(predicate),
            description,
        }
    }
    
    /// Create a filter that checks if a field equals a value
    pub fn equals(field: String, value: StructuredValue) -> Self {
        let desc = format!("filter {field} == {value:?}");
        Self::new(
            move |row| {
                row.get(&field)
                    .map(|v| match (&value, v) {
                        (StructuredValue::String(s1), StructuredValue::String(s2)) => s1 == s2,
                        (StructuredValue::Int(n1), StructuredValue::Int(n2)) => n1 == n2,
                        (StructuredValue::Bool(b1), StructuredValue::Bool(b2)) => b1 == b2,
                        _ => false,
                    })
                    .unwrap_or(false)
            },
            desc,
        )
    }
    
    /// Create a filter that checks if a field contains a substring
    pub fn contains(field: String, substring: String) -> Self {
        let desc = format!("filter {field} contains '{substring}'");
        Self::new(
            move |row| {
                row.get(&field)
                    .and_then(|v| v.as_string())
                    .map(|s| s.contains(&substring))
                    .unwrap_or(false)
            },
            desc,
        )
    }
    
    /// Create a filter for function definitions
    pub fn is_function() -> Self {
        Self::new(
            |row| {
                row.get("kind")
                    .and_then(|v| v.as_string())
                    .map(|s| s.starts_with("function"))
                    .unwrap_or(false)
            },
            "filter kind == function".to_string(),
        )
    }
}

impl PipelineOperator for FilterOperator {
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError> {
        match input {
            StructuredData::Table { columns, rows } => {
                let filtered: Vec<_> = rows.into_iter()
                    .filter(|row| (self.predicate)(row))
                    .collect();
                Ok(StructuredData::Table { columns, rows: filtered })
            }
            
            StructuredData::Definitions(_) => {
                // Convert to table, filter, then back
                let table = input.to_table()?;
                self.apply(table)
            }
            
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                "Cannot filter non-tabular data".to_string()
            )),
        }
    }
    
    fn description(&self) -> String {
        self.description.clone()
    }
}

/// Map/transform each row
pub struct MapOperator {
    transformer: Box<dyn Fn(HashMap<String, StructuredValue>) -> HashMap<String, StructuredValue>>,
    description: String,
}

impl MapOperator {
    pub fn new<F>(transformer: F, description: String) -> Self
    where
        F: Fn(HashMap<String, StructuredValue>) -> HashMap<String, StructuredValue> + 'static,
    {
        Self {
            transformer: Box::new(transformer),
            description,
        }
    }
    
    /// Select specific columns
    pub fn select(columns: Vec<String>) -> Self {
        let desc = format!("select {}", columns.join(", "));
        Self::new(
            move |mut row| {
                let mut new_row = HashMap::new();
                for col in &columns {
                    if let Some(val) = row.remove(col) {
                        new_row.insert(col.clone(), val);
                    }
                }
                new_row
            },
            desc,
        )
    }
    
    /// Add a computed column
    pub fn add_column<F>(name: String, compute: F) -> Self
    where
        F: Fn(&HashMap<String, StructuredValue>) -> StructuredValue + 'static,
    {
        let desc = format!("add column {name}");
        Self::new(
            move |mut row| {
                let value = compute(&row);
                row.insert(name.clone(), value);
                row
            },
            desc,
        )
    }
}

impl PipelineOperator for MapOperator {
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError> {
        match input {
            StructuredData::Table { mut columns, rows } => {
                let transformed: Vec<_> = rows.into_iter()
                    .map(|row| (self.transformer)(row))
                    .collect();
                
                // Update columns if needed
                if let Some(first_row) = transformed.first() {
                    columns = first_row.keys().cloned().collect();
                }
                
                Ok(StructuredData::Table { columns, rows: transformed })
            }
            
            StructuredData::Definitions(defs) => {
                // Convert to table, map, then back
                let table = StructuredData::Definitions(defs).to_table()?;
                self.apply(table)
            }
            
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                "Cannot map non-tabular data".to_string()
            )),
        }
    }
    
    fn description(&self) -> String {
        self.description.clone()
    }
}

/// Sort rows by a field
pub struct SortOperator {
    field: String,
    descending: bool,
}

impl SortOperator {
    pub fn new(field: String, descending: bool) -> Self {
        Self { field, descending }
    }
}

impl PipelineOperator for SortOperator {
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError> {
        match input {
            StructuredData::Table { columns, mut rows } => {
                rows.sort_by(|a, b| {
                    let a_val = a.get(&self.field);
                    let b_val = b.get(&self.field);
                    
                    let ordering = match (a_val, b_val) {
                        (Some(StructuredValue::String(s1)), Some(StructuredValue::String(s2))) => s1.cmp(s2),
                        (Some(StructuredValue::Int(n1)), Some(StructuredValue::Int(n2))) => n1.cmp(n2),
                        (Some(StructuredValue::Float(f1)), Some(StructuredValue::Float(f2))) => {
                            f1.partial_cmp(f2).unwrap_or(std::cmp::Ordering::Equal)
                        }
                        _ => std::cmp::Ordering::Equal,
                    };
                    
                    if self.descending {
                        ordering.reverse()
                    } else {
                        ordering
                    }
                });
                
                Ok(StructuredData::Table { columns, rows })
            }
            
            StructuredData::Definitions(defs) => {
                let table = StructuredData::Definitions(defs).to_table()?;
                self.apply(table)
            }
            
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                "Cannot sort non-tabular data".to_string()
            )),
        }
    }
    
    fn description(&self) -> String {
        format!("sort by {} {}", 
                self.field, 
                if self.descending { "desc" } else { "asc" })
    }
}

/// Take first N rows
pub struct TakeOperator {
    count: usize,
}

impl TakeOperator {
    pub fn new(count: usize) -> Self {
        Self { count }
    }
}

impl PipelineOperator for TakeOperator {
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError> {
        match input {
            StructuredData::Table { columns, rows } => {
                let taken: Vec<_> = rows.into_iter()
                    .take(self.count)
                    .collect();
                Ok(StructuredData::Table { columns, rows: taken })
            }
            
            StructuredData::Definitions(defs) => {
                let taken: Vec<_> = defs.into_iter()
                    .take(self.count)
                    .collect();
                Ok(StructuredData::Definitions(taken))
            }
            
            StructuredData::List(items) => {
                let taken: Vec<_> = items.into_iter()
                    .take(self.count)
                    .collect();
                Ok(StructuredData::List(taken))
            }
            
            _ => Ok(input),
        }
    }
    
    fn description(&self) -> String {
        format!("take {}", self.count)
    }
}

/// Group by a field
pub struct GroupByOperator {
    field: String,
}

impl GroupByOperator {
    pub fn new(field: String) -> Self {
        Self { field }
    }
}

impl PipelineOperator for GroupByOperator {
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError> {
        match input {
            StructuredData::Table { columns: _, rows } => {
                let mut groups: HashMap<String, Vec<HashMap<String, StructuredValue>>> = HashMap::new();
                
                for row in rows {
                    let key = row.get(&self.field)
                        .map(format_value_simple)
                        .unwrap_or_else(|| "<null>".to_string());
                    
                    groups.entry(key).or_default().push(row);
                }
                
                // Convert groups to a new table format
                let mut result_rows = Vec::new();
                for (key, group_rows) in groups {
                    let mut row = HashMap::new();
                    row.insert(self.field.clone(), StructuredValue::String(key));
                    row.insert("count".to_string(), StructuredValue::Int(group_rows.len() as i64));
                    
                    // Add the grouped rows as a list
                    let group_list = StructuredValue::List(
                        group_rows.into_iter()
                            .map(StructuredValue::Record)
                            .collect()
                    );
                    row.insert("items".to_string(), group_list);
                    
                    result_rows.push(row);
                }
                
                Ok(StructuredData::Table {
                    columns: vec![self.field.clone(), "count".to_string(), "items".to_string()],
                    rows: result_rows,
                })
            }
            
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                "Cannot group non-tabular data".to_string()
            )),
        }
    }
    
    fn description(&self) -> String {
        format!("group by {}", self.field)
    }
}

/// Count rows
pub struct CountOperator;

impl PipelineOperator for CountOperator {
    fn apply(&self, input: StructuredData) -> Result<StructuredData, XsError> {
        let count = match &input {
            StructuredData::Table { rows, .. } => rows.len(),
            StructuredData::Definitions(defs) => defs.len(),
            StructuredData::List(items) => items.len(),
            StructuredData::Empty => 0,
            _ => 1,
        };
        
        Ok(StructuredData::Value(StructuredValue::Int(count as i64)))
    }
    
    fn description(&self) -> String {
        "count".to_string()
    }
}

// Helper function
fn format_value_simple(val: &StructuredValue) -> String {
    match val {
        StructuredValue::String(s) => s.clone(),
        StructuredValue::Int(n) => n.to_string(),
        StructuredValue::Float(f) => f.to_string(),
        StructuredValue::Bool(b) => b.to_string(),
        _ => format!("{val:?}"),
    }
}

/// Parse a pipeline command
pub fn parse_pipeline_operator(cmd: &str) -> Result<Box<dyn PipelineOperator>, XsError> {
    let parts: Vec<&str> = cmd.split_whitespace().collect();
    if parts.is_empty() {
        return Err(XsError::RuntimeError(
            Span::new(0, 0),
            "Empty pipeline command".to_string()
        ));
    }
    
    match parts[0] {
        "filter" => {
            if parts.len() < 3 {
                return Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "filter requires field and value".to_string()
                ));
            }
            
            let field = parts[1].to_string();
            
            // Check for different filter types
            if parts.len() >= 4 && parts[2] == "contains" {
                let value = parts[3..].join(" ");
                Ok(Box::new(FilterOperator::contains(field, value)))
            } else if parts[2] == "==" || parts[2] == "=" {
                let value = parts[3..].join(" ");
                Ok(Box::new(FilterOperator::equals(
                    field,
                    StructuredValue::String(value)
                )))
            } else {
                Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    format!("Unknown filter operator: {}", parts[2])
                ))
            }
        }
        
        "select" => {
            if parts.len() < 2 {
                return Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "select requires at least one column".to_string()
                ));
            }
            
            let columns: Vec<String> = parts[1..]
                .iter()
                .map(|s| s.to_string())
                .collect();
            Ok(Box::new(MapOperator::select(columns)))
        }
        
        "sort" => {
            if parts.len() < 2 {
                return Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "sort requires a field name".to_string()
                ));
            }
            
            let field = parts[1].to_string();
            let descending = parts.len() > 2 && (parts[2] == "desc" || parts[2] == "reverse");
            Ok(Box::new(SortOperator::new(field, descending)))
        }
        
        "take" => {
            if parts.len() < 2 {
                return Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "take requires a count".to_string()
                ));
            }
            
            let count = parts[1].parse::<usize>()
                .map_err(|_| XsError::RuntimeError(
                    Span::new(0, 0),
                    format!("Invalid count: {}", parts[1])
                ))?;
            Ok(Box::new(TakeOperator::new(count)))
        }
        
        "group" => {
            if parts.len() < 3 || parts[1] != "by" {
                return Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "group requires 'by' and a field name".to_string()
                ));
            }
            
            let field = parts[2].to_string();
            Ok(Box::new(GroupByOperator::new(field)))
        }
        
        "count" => {
            Ok(Box::new(CountOperator))
        }
        
        _ => Err(XsError::RuntimeError(
            Span::new(0, 0),
            format!("Unknown pipeline command: {}", parts[0])
        )),
    }
}