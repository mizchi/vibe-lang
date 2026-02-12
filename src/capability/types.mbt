///| Capability-based security for vibe runtime

///|
/// Glob pattern for path matching
pub(all) struct PathGlob {
  pattern : String
  /// true = allow, false = deny
  allow : Bool
}

///|
/// Host pattern for network matching
pub(all) struct HostPattern {
  /// Host pattern (e.g., "*.example.com", "api.github.com")
  pattern : String
  /// Optional port restriction (None = any port)
  port : Int?
}

///|
/// Individual capability types
pub enum Capability {
  // Filesystem capabilities
  FsRead(PathGlob) // Read files matching glob
  FsWrite(PathGlob) // Write files matching glob
  FsDelete(PathGlob) // Delete files matching glob
  FsExecute(PathGlob) // Execute files matching glob

  // Network capabilities
  NetConnect(HostPattern) // Connect to specific hosts
  NetListen(Int) // Listen on specific port

  // MCP capabilities
  McpCall(Array[String]) // Call specific MCP tools
  McpServe // Serve as MCP server

  // A2A capabilities
  A2ADelegate(Array[String]) // Delegate to specific agents
  A2AReceive // Receive delegated tasks

  // Git operations
  GitSnapshot // Create snapshots
  GitRollback // Rollback to snapshots
  GitBranch // Create/switch branches

  // System capabilities
  ClockRead // Read wall clock
  ClockMonotonic // Read monotonic clock
  RandomRead // Generate random bytes
  EnvRead(Array[String]) // Read specific env vars
  EnvWrite(Array[String]) // Write specific env vars
  ProcessSpawn(Array[String]) // Spawn specific commands
}

///|
/// Create a read capability for a path pattern
pub fn Capability::fs_read(pattern : String) -> Capability {
  FsRead({ pattern, allow: true })
}

///|
/// Create a write capability for a path pattern
pub fn Capability::fs_write(pattern : String) -> Capability {
  FsWrite({ pattern, allow: true })
}

///|
/// Create a network connect capability
pub fn Capability::net_connect(host : String, port : Int?) -> Capability {
  NetConnect({ pattern: host, port })
}

///|
/// Create an MCP call capability
pub fn Capability::mcp_call(tools : Array[String]) -> Capability {
  McpCall(tools)
}

///|
/// Create an A2A delegate capability
pub fn Capability::a2a_delegate(agents : Array[String]) -> Capability {
  A2ADelegate(agents)
}

///|
/// Create an env read capability
pub fn Capability::env_read(vars : Array[String]) -> Capability {
  EnvRead(vars)
}

///|
/// Create a process spawn capability
pub fn Capability::process_spawn(commands : Array[String]) -> Capability {
  ProcessSpawn(commands)
}

///|
/// Create git snapshot capability
pub fn Capability::git_snapshot() -> Capability {
  GitSnapshot
}

///|
/// Create git rollback capability
pub fn Capability::git_rollback() -> Capability {
  GitRollback
}

///|
/// Create git branch capability
pub fn Capability::git_branch() -> Capability {
  GitBranch
}

///|
/// Create clock read capability
pub fn Capability::clock_read() -> Capability {
  ClockRead
}

///|
/// Create random read capability
pub fn Capability::random_read() -> Capability {
  RandomRead
}
