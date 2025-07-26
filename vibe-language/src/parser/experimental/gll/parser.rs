use super::{GraphStructuredStack, SharedPackedParseForest};
use crate::parser::experimental::{ParserState, ParseEffect, Constraint};
use crate::parser::experimental::parser::Token;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt::Debug;

/// Symbol in the grammar
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum GLLSymbol {
    Terminal(String),
    NonTerminal(String),
    Epsilon,
}

/// Grammar rule
#[derive(Debug, Clone)]
pub struct GLLRule {
    pub lhs: String,
    pub rhs: Vec<GLLSymbol>,
}

/// Grammar slot (position in a rule)
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GLLSlot {
    pub rule_index: usize,
    pub position: usize,
}

/// GLL grammar
#[derive(Clone)]
pub struct GLLGrammar {
    pub rules: Vec<GLLRule>,
    pub start_symbol: String,
    pub terminals: HashSet<String>,
    pub nonterminals: HashSet<String>,
    /// Mapping from nonterminal to rule indices
    pub nonterminal_rules: HashMap<String, Vec<usize>>,
}

impl GLLGrammar {
    pub fn new(rules: Vec<GLLRule>, start_symbol: String) -> Self {
        let mut terminals = HashSet::new();
        let mut nonterminals = HashSet::new();
        let mut nonterminal_rules = HashMap::new();

        // Collect terminals and nonterminals
        for (index, rule) in rules.iter().enumerate() {
            nonterminals.insert(rule.lhs.clone());
            nonterminal_rules.entry(rule.lhs.clone())
                .or_insert_with(Vec::new)
                .push(index);

            for symbol in &rule.rhs {
                match symbol {
                    GLLSymbol::Terminal(t) => {
                        terminals.insert(t.clone());
                    }
                    GLLSymbol::NonTerminal(nt) => {
                        nonterminals.insert(nt.clone());
                    }
                    GLLSymbol::Epsilon => {}
                }
            }
        }

        Self {
            rules,
            start_symbol,
            terminals,
            nonterminals,
            nonterminal_rules,
        }
    }

    /// Get the symbol at a specific slot
    pub fn get_symbol_at(&self, slot: &GLLSlot) -> Option<&GLLSymbol> {
        self.rules.get(slot.rule_index)
            .and_then(|rule| rule.rhs.get(slot.position))
    }

    /// Check if a slot is at the end of a rule
    pub fn is_complete(&self, slot: &GLLSlot) -> bool {
        self.rules.get(slot.rule_index)
            .map(|rule| slot.position >= rule.rhs.len())
            .unwrap_or(true)
    }

    /// Get the next slot
    pub fn next_slot(&self, slot: &GLLSlot) -> GLLSlot {
        GLLSlot {
            rule_index: slot.rule_index,
            position: slot.position + 1,
        }
    }
}

/// Descriptor for work to be processed
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Descriptor {
    slot: GLLSlot,
    gss_node: usize,
    input_pos: usize,
    sppf_node: Option<usize>,
}

/// GLL Parser with Morpheus-style verification
pub struct GLLParser {
    pub(crate) grammar: GLLGrammar,
    pub(crate) gss: GraphStructuredStack,
    pub(crate) sppf: SharedPackedParseForest,
    /// Work list of descriptors
    worklist: VecDeque<Descriptor>,
    /// Processed descriptors (to avoid duplicates)
    processed: HashSet<Descriptor>,
    /// Parser state for Morpheus verification
    pub(crate) state: ParserState,
    /// Input tokens
    pub(crate) input: Vec<String>,
    /// Maximum iterations to prevent infinite loops
    max_iterations: usize,
}

impl GLLParser {
    pub fn new(grammar: GLLGrammar) -> Self {
        Self {
            grammar,
            gss: GraphStructuredStack::new(),
            sppf: SharedPackedParseForest::new(),
            worklist: VecDeque::new(),
            processed: HashSet::new(),
            state: ParserState::default(),
            input: Vec::new(),
            max_iterations: 10000, // Default max iterations
        }
    }

    /// Parse input and track effects for Morpheus verification
    pub fn parse(&mut self, input: Vec<String>) -> Result<Vec<usize>, String> {
        self.input = input;
        self.gss.clear();
        self.sppf.clear();
        self.worklist.clear();
        self.processed.clear();
        
        // Track parsing start
        self.track_effect(ParseEffect::SemanticAction("gll_parse_start".to_string()));
        
        // Initialize with start symbol
        let start_rules = self.grammar.nonterminal_rules
            .get(&self.grammar.start_symbol)
            .ok_or("Start symbol not found")?
            .clone(); // Clone to avoid borrow issue
        
        let initial_gss = self.gss.create_node(0, 0);
        
        for rule_index in start_rules {
            let slot = GLLSlot { rule_index, position: 0 };
            let descriptor = Descriptor {
                slot,
                gss_node: initial_gss,
                input_pos: 0,
                sppf_node: None,
            };
            self.add_descriptor(descriptor);
        }
        
        // Main parsing loop with iteration limit
        let mut iterations = 0;
        while let Some(descriptor) = self.worklist.pop_front() {
            iterations += 1;
            if iterations > self.max_iterations {
                return Err(format!("Parse exceeded maximum iterations ({}). Possible infinite recursion detected.", self.max_iterations));
            }
            
            if !self.processed.insert(descriptor.clone()) {
                continue;
            }
            
            // Debug: print descriptor being processed
            #[cfg(test)]
            {
                println!("Processing descriptor: slot={}/{}, gss={}, pos={}, sppf={:?}", 
                    descriptor.slot.rule_index, descriptor.slot.position,
                    descriptor.gss_node, descriptor.input_pos, descriptor.sppf_node);
            }
            
            self.process_descriptor(descriptor)?;
        }
        
        // Track parsing end
        self.track_effect(ParseEffect::SemanticAction("gll_parse_end".to_string()));
        
        // Collect successful parses
        let roots = self.sppf.get_roots().to_vec();
        
        if roots.is_empty() {
            Err("No valid parse found".to_string())
        } else {
            // Add termination constraint
            self.add_constraint(Constraint::Termination { 
                expr: crate::parser::experimental::NodeId(0) 
            });
            
            Ok(roots)
        }
    }

    /// Process a single descriptor
    fn process_descriptor(&mut self, descriptor: Descriptor) -> Result<(), String> {
        let Descriptor { slot, gss_node, input_pos, sppf_node } = descriptor;
        
        if self.grammar.is_complete(&slot) {
            // Complete item - pop from GSS
            self.track_effect(ParseEffect::SemanticAction("gll_complete".to_string()));
            self.pop(gss_node, input_pos, sppf_node);
        } else if let Some(symbol) = self.grammar.get_symbol_at(&slot).cloned() {
            match symbol {
                GLLSymbol::Terminal(term) => {
                    self.track_effect(ParseEffect::Consume(Token::Let)); // Simplified
                    self.process_terminal(&slot, gss_node, input_pos, sppf_node, &term)?;
                }
                GLLSymbol::NonTerminal(nt) => {
                    self.track_effect(ParseEffect::SemanticAction("gll_nonterminal".to_string()));
                    self.process_nonterminal(&slot, gss_node, input_pos, sppf_node, &nt)?;
                }
                GLLSymbol::Epsilon => {
                    self.track_effect(ParseEffect::SemanticAction("gll_epsilon".to_string()));
                    self.process_epsilon(&slot, gss_node, input_pos, sppf_node)?;
                }
            }
        }
        
        Ok(())
    }

    /// Process terminal symbol
    fn process_terminal(
        &mut self,
        slot: &GLLSlot,
        gss_node: usize,
        input_pos: usize,
        sppf_node: Option<usize>,
        terminal: &str,
    ) -> Result<(), String> {
        // Track lookahead
        self.track_effect(ParseEffect::Lookahead(1));
        
        if input_pos < self.input.len() && self.input[input_pos] == terminal {
            // Match successful
            let new_sppf = self.sppf.create_terminal(terminal.to_string(), input_pos, input_pos + 1);
            
            let combined_sppf = if let Some(left) = sppf_node {
                let intermediate = self.sppf.create_intermediate(slot.rule_index, input_pos, input_pos + 1);
                self.sppf.add_children(intermediate, vec![left, new_sppf]);
                intermediate
            } else {
                new_sppf
            };
            
            let next_slot = self.grammar.next_slot(slot);
            let descriptor = Descriptor {
                slot: next_slot,
                gss_node,
                input_pos: input_pos + 1,
                sppf_node: Some(combined_sppf),
            };
            
            self.add_descriptor(descriptor);
        } else {
            // No match - backtrack
            self.track_effect(ParseEffect::Backtrack);
        }
        
        Ok(())
    }

    /// Process non-terminal symbol
    fn process_nonterminal(
        &mut self,
        slot: &GLLSlot,
        gss_node: usize,
        input_pos: usize,
        sppf_node: Option<usize>,
        nonterminal: &str,
    ) -> Result<(), String> {
        let next_slot = self.grammar.next_slot(slot);
        
        // Create a return node that remembers where to continue after the non-terminal
        // Store the next slot information in the GSS node
        // Use a larger multiplier to handle longer rules (up to 100,000 positions)
        let return_slot_encoded = next_slot.rule_index * 100000 + next_slot.position;
        
        #[cfg(test)]
        println!("process_nonterminal: {} at pos={}, return_slot_encoded={}", nonterminal, input_pos, return_slot_encoded);
        
        // Check if we already have this return node
        if let Some(existing_node) = self.gss.get_node_id(return_slot_encoded, input_pos) {
            // Use existing node and add another edge
            let return_node = existing_node;
            self.gss.add_edge(gss_node, return_node, sppf_node);
            
            // Don't create new descriptors, they should already be in the worklist
        } else {
            // Create new return node
            let return_node = self.gss.create_node(return_slot_encoded, input_pos);
            self.gss.add_edge(gss_node, return_node, sppf_node);
            
            #[cfg(test)]
            println!("  Created return node {} with slot={} at pos={}", return_node, return_slot_encoded, input_pos);
            
            // Try all rules for this non-terminal
            let rule_indices = self.grammar.nonterminal_rules.get(nonterminal).cloned();
            if let Some(rule_indices) = rule_indices {
                for rule_index in rule_indices {
                    let new_slot = GLLSlot { rule_index, position: 0 };
                    let descriptor = Descriptor {
                        slot: new_slot,
                        gss_node: return_node,
                        input_pos,
                        sppf_node: None,
                    };
                    self.add_descriptor(descriptor);
                }
            }
        }
        
        Ok(())
    }

    /// Process epsilon production
    fn process_epsilon(
        &mut self,
        slot: &GLLSlot,
        gss_node: usize,
        input_pos: usize,
        sppf_node: Option<usize>,
    ) -> Result<(), String> {
        let epsilon_node = self.sppf.create_epsilon(input_pos);
        
        let combined_sppf = if let Some(left) = sppf_node {
            let intermediate = self.sppf.create_intermediate(slot.rule_index, input_pos, input_pos);
            self.sppf.add_children(intermediate, vec![left, epsilon_node]);
            intermediate
        } else {
            epsilon_node
        };
        
        let next_slot = self.grammar.next_slot(slot);
        let descriptor = Descriptor {
            slot: next_slot,
            gss_node,
            input_pos,
            sppf_node: Some(combined_sppf),
        };
        
        self.add_descriptor(descriptor);
        Ok(())
    }

    /// Pop operation - return from non-terminal
    fn pop(&mut self, gss_node: usize, input_pos: usize, sppf_node: Option<usize>) {
        #[cfg(test)]
        println!("Pop: gss_node={}, input_pos={}, sppf_node={:?}", gss_node, input_pos, sppf_node);
        
        let gss_node_data = if let Some(node) = self.gss.get_node(gss_node) {
            node.clone()
        } else {
            return;
        };
        
        // The slot in the GSS node contains the encoded rule index
        let encoded_slot = gss_node_data.slot;
        let rule_index = encoded_slot / 100000;
        
        #[cfg(test)]
        println!("  GSS node data: slot={}, position={}", gss_node_data.slot, gss_node_data.position);
        
        if let Some(rule) = self.grammar.rules.get(rule_index) {
            // Create non-terminal SPPF node
            let nt_node = self.sppf.create_nonterminal(
                rule.lhs.clone(),
                gss_node_data.position,
                input_pos,
            );
            
            if let Some(child) = sppf_node {
                self.sppf.add_children(nt_node, vec![child]);
            }
            
            // Check if this is a successful parse of the start symbol
            if rule.lhs == self.grammar.start_symbol && gss_node_data.position == 0 && input_pos == self.input.len() {
                self.sppf.add_root(nt_node);
            }
            
            // Continue with parent nodes
            let edges = self.gss.edges.clone();
            
            // For each parent edge, we need to find the associated SPPF node and continue
            for edge in &edges {
                if edge.to == gss_node {
                    let parent = edge.from;
                    
                    #[cfg(test)]
                    println!("  Found parent edge: {} -> {}", parent, gss_node);
                    
                    if let Some(_parent_node) = self.gss.get_node(parent) {
                        // The current GSS node stores the return slot
                        let return_slot = gss_node_data.slot;
                        let rule_index = return_slot / 100000;
                        let rule_position = return_slot % 100000;
                        
                        #[cfg(test)]
                        println!("  Creating descriptor for parent: rule={}, pos={}, parent_gss={}", 
                            rule_index, rule_position, parent);
                        
                        // Combine SPPF nodes if needed
                        let combined_sppf = if let Some(_edge_sppf) = edge.sppf_node {
                            // Create intermediate node combining edge_sppf and nt_node
                            Some(nt_node) // Simplified for now
                        } else {
                            Some(nt_node)
                        };
                        
                        let descriptor = Descriptor {
                            slot: GLLSlot {
                                rule_index,
                                position: rule_position,
                            },
                            gss_node: parent,
                            input_pos,
                            sppf_node: combined_sppf,
                        };
                        self.add_descriptor(descriptor);
                    }
                }
            }
        }
    }


    /// Add a descriptor to the worklist
    fn add_descriptor(&mut self, descriptor: Descriptor) {
        if !self.processed.contains(&descriptor) {
            self.worklist.push_back(descriptor);
        }
    }

    /// Track parsing effect for Morpheus verification
    fn track_effect(&mut self, effect: ParseEffect) {
        self.state.effects.push(effect);
    }

    /// Add constraint for verification
    fn add_constraint(&mut self, constraint: Constraint) {
        self.state.constraints.push(constraint);
    }

    /// Get parser state for verification
    pub fn get_state(&self) -> &ParserState {
        &self.state
    }

    /// Get SPPF for analysis
    pub fn get_sppf(&self) -> &SharedPackedParseForest {
        &self.sppf
    }

    /// Get GSS for analysis
    pub fn get_gss(&self) -> &GraphStructuredStack {
        &self.gss
    }
    
    /// Set maximum iterations (for testing)
    pub fn set_max_iterations(&mut self, max: usize) {
        self.max_iterations = max;
    }
    
    /// Parse with AI-friendly error reporting
    pub fn parse_with_errors(&mut self, input: Vec<String>) -> Result<Vec<usize>, crate::parser::experimental::error::ParseError> {
        match self.parse(input.clone()) {
            Ok(roots) => Ok(roots),
            Err(msg) => {
                // Convert simple error to structured error
                use crate::parser::experimental::error_helpers::ErrorReporting;
                
                // Try to determine what went wrong
                let position = if self.input.is_empty() { 0 } else { self.input.len() - 1 }; // Use actual input position
                
                if msg.contains("No valid parse found") {
                    // Determine expected tokens at failure point
                    let expected = self.get_expected_tokens(position);
                    let found = if position < input.len() {
                        input[position].clone()
                    } else {
                        "<EOF>".to_string()
                    };
                    
                    Err(self.unexpected_token_error(expected, found, position))
                } else if self.sppf.is_ambiguous() {
                    Err(self.ambiguity_error(position, self.sppf.count_trees()))
                } else {
                    // Generic syntax error
                    Err(crate::parser::experimental::error::ParseError::syntax(msg, crate::parser::experimental::error::ErrorLocation {
                        file: None,
                        line: 1,
                        column: position + 1,
                        offset: position,
                        length: 1,
                    }))
                }
            }
        }
    }
    
    /// Get expected tokens at a given position (simplified)
    fn get_expected_tokens(&self, _position: usize) -> Vec<String> {
        let mut expected = Vec::new();
        
        // Collect terminals from the grammar
        for terminal in &self.grammar.terminals {
            expected.push(terminal.clone());
        }
        
        // Add common expectations
        if expected.is_empty() {
            expected = vec!["identifier".to_string(), "number".to_string(), "operator".to_string()];
        }
        
        expected
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_simple_grammar() -> GLLGrammar {
        // S -> a S b | ε
        let rules = vec![
            GLLRule {
                lhs: "S".to_string(),
                rhs: vec![
                    GLLSymbol::Terminal("a".to_string()),
                    GLLSymbol::NonTerminal("S".to_string()),
                    GLLSymbol::Terminal("b".to_string()),
                ],
            },
            GLLRule {
                lhs: "S".to_string(),
                rhs: vec![GLLSymbol::Epsilon],
            },
        ];
        
        GLLGrammar::new(rules, "S".to_string())
    }

    fn create_ambiguous_grammar() -> GLLGrammar {
        // E -> E + E | E * E | n
        let rules = vec![
            GLLRule {
                lhs: "E".to_string(),
                rhs: vec![
                    GLLSymbol::NonTerminal("E".to_string()),
                    GLLSymbol::Terminal("+".to_string()),
                    GLLSymbol::NonTerminal("E".to_string()),
                ],
            },
            GLLRule {
                lhs: "E".to_string(),
                rhs: vec![
                    GLLSymbol::NonTerminal("E".to_string()),
                    GLLSymbol::Terminal("*".to_string()),
                    GLLSymbol::NonTerminal("E".to_string()),
                ],
            },
            GLLRule {
                lhs: "E".to_string(),
                rhs: vec![GLLSymbol::Terminal("n".to_string())],
            },
        ];
        
        GLLGrammar::new(rules, "E".to_string())
    }

    #[test]
    fn test_simple_parse() {
        let grammar = create_simple_grammar();
        let mut parser = GLLParser::new(grammar);
        
        println!("Grammar rules:");
        for (i, rule) in parser.grammar.rules.iter().enumerate() {
            println!("  Rule {}: {} -> {:?}", i, rule.lhs, rule.rhs);
        }
        
        let input = vec!["a".to_string(), "b".to_string()];
        println!("Input: {:?}", input);
        
        let result = parser.parse(input);
        
        if let Err(ref e) = result {
            println!("Parse error: {}", e);
            parser.gss.debug_print();
        }
        
        assert!(result.is_ok(), "Parse failed: {:?}", result);
        let roots = result.unwrap();
        assert!(!roots.is_empty());
    }

    #[test]
    fn test_ambiguous_parse() {
        let grammar = create_ambiguous_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // n + n * n can be parsed as (n + n) * n or n + (n * n)
        let input = vec!["n".to_string(), "+".to_string(), "n".to_string(), "*".to_string(), "n".to_string()];
        let result = parser.parse(input);
        
        assert!(result.is_ok());
        let sppf = parser.get_sppf();
        assert!(sppf.is_ambiguous());
    }

    #[test]
    fn test_effect_tracking() {
        let grammar = create_simple_grammar();
        let mut parser = GLLParser::new(grammar);
        
        let input = vec!["a".to_string(), "b".to_string()];
        let _ = parser.parse(input);
        
        let state = parser.get_state();
        assert!(!state.effects.is_empty());
        
        // Should have semantic actions
        assert!(state.effects.iter().any(|e| matches!(e, ParseEffect::SemanticAction(_))));
        
        // Should have lookahead
        assert!(state.effects.iter().any(|e| matches!(e, ParseEffect::Lookahead(_))));
    }
    
    #[test]
    fn test_infinite_recursion_detection() {
        // Create a pathological grammar that generates exponential parse paths
        // S -> S S S | S S | a
        // This grammar can parse "aaa" in many different ways
        let rules = vec![
            GLLRule {
                lhs: "S".to_string(),
                rhs: vec![
                    GLLSymbol::NonTerminal("S".to_string()),
                    GLLSymbol::NonTerminal("S".to_string()),
                    GLLSymbol::NonTerminal("S".to_string()),
                ],
            },
            GLLRule {
                lhs: "S".to_string(),
                rhs: vec![
                    GLLSymbol::NonTerminal("S".to_string()),
                    GLLSymbol::NonTerminal("S".to_string()),
                ],
            },
            GLLRule {
                lhs: "S".to_string(),
                rhs: vec![GLLSymbol::Terminal("a".to_string())],
            },
        ];
        
        let grammar = GLLGrammar::new(rules, "S".to_string());
        let mut parser = GLLParser::new(grammar);
        
        // Set a low iteration limit for testing
        parser.set_max_iterations(1000);
        
        // Input that causes exponential parse paths
        let input = vec!["a".to_string(); 10]; // 10 'a's
        let result = parser.parse(input);
        
        // Should fail with max iterations error due to exponential explosion
        assert!(result.is_err());
        let error_msg = result.unwrap_err();
        assert!(error_msg.contains("maximum iterations"), "Error was: {}", error_msg);
    }

    #[test]
    fn test_large_position_handling() {
        // Test that the parser can handle positions greater than 999
        // Create a rule with many tokens (more than 1000)
        let mut rhs = vec![];
        for i in 0..1500 {
            rhs.push(GLLSymbol::Terminal(format!("t{}", i)));
        }
        
        let rules = vec![
            GLLRule { lhs: "S".to_string(), rhs: rhs.clone() },
        ];
        
        let grammar = GLLGrammar::new(rules, "S".to_string());
        let mut parser = GLLParser::new(grammar);
        
        // Create matching input
        let mut input = vec![];
        for i in 0..1500 {
            input.push(format!("t{}", i));
        }
        
        let result = parser.parse(input);
        
        // Should successfully parse without encoding issues
        assert!(result.is_ok());
    }
}