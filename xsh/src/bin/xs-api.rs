//! XS API command-line tool for AI integration
//!
//! Usage:
//!   xs-api <json-command>
//!   echo '{"command":"list"}' | xs-api
//!
//! All responses are in JSON format for easy parsing by AI tools.

use anyhow::Result;
use std::io::{self, Read};
use std::path::PathBuf;
use xsh::{api, shell::ShellState};

fn main() -> Result<()> {
    // Initialize shell state
    let storage_path = PathBuf::from(".xs-codebase");
    let mut state = ShellState::new(storage_path)?;

    // Get command from args or stdin
    let command_json = if let Some(cmd) = std::env::args().nth(1) {
        cmd
    } else {
        let mut buffer = String::new();
        io::stdin().read_to_string(&mut buffer)?;
        buffer
    };

    // Parse and execute command
    match api::parse_api_command(&command_json) {
        Ok(command) => {
            let response = api::process_api_command(&mut state, command);
            println!("{response}");
        }
        Err(e) => {
            let error_response = api::ApiResponse::error(e);
            println!("{}", serde_json::to_string_pretty(&error_response).unwrap());
        }
    }

    Ok(())
}
