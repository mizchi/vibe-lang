///| Preset capability configurations

/// Create a minimal capability set (read-only filesystem)
pub fn CapabilitySet::minimal() -> CapabilitySet {
  CapabilitySet::from_array([
    FsRead({ pattern: "/**", allow: true }),
    ClockMonotonic,
  ])
}

/// Create a sandbox capability set (read-write in /tmp only)
pub fn CapabilitySet::sandbox() -> CapabilitySet {
  CapabilitySet::from_array([
    FsRead({ pattern: "/**", allow: true }),
    FsWrite({ pattern: "/tmp/**", allow: true }),
    FsDelete({ pattern: "/tmp/**", allow: true }),
    ClockMonotonic,
    RandomRead,
    GitSnapshot,
  ])
}

/// Create a developer capability set (full filesystem, limited network)
pub fn CapabilitySet::developer() -> CapabilitySet {
  CapabilitySet::from_array([
    FsRead({ pattern: "/**", allow: true }),
    FsWrite({ pattern: "/**", allow: true }),
    FsDelete({ pattern: "/**", allow: true }),
    FsExecute({ pattern: "/**", allow: true }),
    ClockRead,
    ClockMonotonic,
    RandomRead,
    GitSnapshot,
    GitRollback,
    GitBranch,
    EnvRead(["*"]),
  ])
}

/// Create an agent capability set (with MCP/A2A)
pub fn CapabilitySet::agent(
  mcp_tools : Array[String],
  a2a_agents : Array[String],
  allowed_hosts : Array[String]
) -> CapabilitySet {
  let caps : Array[Capability] = [
    FsRead({ pattern: "/**", allow: true }),
    FsWrite({ pattern: "/**", allow: true }),
    FsDelete({ pattern: "/**", allow: true }),
    ClockRead,
    ClockMonotonic,
    RandomRead,
    GitSnapshot,
    GitRollback,
    GitBranch,
    McpCall(mcp_tools),
    A2ADelegate(a2a_agents),
    A2AReceive,
  ]
  // Add network capabilities
  for host in allowed_hosts {
    caps.push(NetConnect({ pattern: host, port: None }))
  }
  CapabilitySet::from_array(caps)
}

/// Create an unrestricted capability set (for testing only)
pub fn CapabilitySet::unrestricted() -> CapabilitySet {
  CapabilitySet::from_array([
    FsRead({ pattern: "/**", allow: true }),
    FsWrite({ pattern: "/**", allow: true }),
    FsDelete({ pattern: "/**", allow: true }),
    FsExecute({ pattern: "/**", allow: true }),
    NetConnect({ pattern: "*", port: None }),
    NetListen(0), // Any port
    McpCall(["*"]),
    McpServe,
    A2ADelegate(["*"]),
    A2AReceive,
    GitSnapshot,
    GitRollback,
    GitBranch,
    ClockRead,
    ClockMonotonic,
    RandomRead,
    EnvRead(["*"]),
    EnvWrite(["*"]),
    ProcessSpawn(["*"]),
  ])
}
