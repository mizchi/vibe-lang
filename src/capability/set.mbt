///| Capability set - collection of granted capabilities

/// Set of capabilities granted to an agent
pub struct CapabilitySet {
  capabilities : Array[Capability]
}

/// Create an empty capability set
pub fn CapabilitySet::new() -> CapabilitySet {
  { capabilities: [] }
}

/// Create a capability set from array
pub fn CapabilitySet::from_array(caps : Array[Capability]) -> CapabilitySet {
  { capabilities: caps }
}

/// Add a capability
pub fn CapabilitySet::add(self : CapabilitySet, cap : Capability) -> CapabilitySet {
  let new_caps = self.capabilities.copy()
  new_caps.push(cap)
  { capabilities: new_caps }
}

/// Check if a capability is granted
pub fn CapabilitySet::has(self : CapabilitySet, check : (Capability) -> Bool) -> Bool {
  for cap in self.capabilities {
    if check(cap) {
      return true
    }
  }
  false
}

/// Check if file read is allowed
pub fn CapabilitySet::can_read(self : CapabilitySet, path : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      FsRead(glob) => glob.allow && match_glob(glob.pattern, path)
      _ => false
    }
  })
}

/// Check if file write is allowed
pub fn CapabilitySet::can_write(self : CapabilitySet, path : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      FsWrite(glob) => glob.allow && match_glob(glob.pattern, path)
      _ => false
    }
  })
}

/// Check if file delete is allowed
pub fn CapabilitySet::can_delete(self : CapabilitySet, path : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      FsDelete(glob) => glob.allow && match_glob(glob.pattern, path)
      _ => false
    }
  })
}

/// Check if file execute is allowed
pub fn CapabilitySet::can_execute(self : CapabilitySet, path : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      FsExecute(glob) => glob.allow && match_glob(glob.pattern, path)
      _ => false
    }
  })
}

/// Check if network connect is allowed
pub fn CapabilitySet::can_connect(self : CapabilitySet, host : String, port : Int) -> Bool {
  self.has(fn(cap) {
    match cap {
      NetConnect(pattern) => {
        let host_matches = match_host_pattern(pattern.pattern, host)
        let port_matches = match pattern.port {
          None => true
          Some(p) => p == port
        }
        host_matches && port_matches
      }
      _ => false
    }
  })
}

/// Check if MCP tool call is allowed
pub fn CapabilitySet::can_call_mcp(self : CapabilitySet, tool : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      McpCall(tools) => tools.contains(tool) || tools.contains("*")
      _ => false
    }
  })
}

/// Check if A2A delegation is allowed
pub fn CapabilitySet::can_delegate_a2a(self : CapabilitySet, agent : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      A2ADelegate(agents) => agents.contains(agent) || agents.contains("*")
      _ => false
    }
  })
}

/// Check if git snapshot is allowed
pub fn CapabilitySet::can_snapshot(self : CapabilitySet) -> Bool {
  self.has(fn(cap) {
    match cap {
      GitSnapshot => true
      _ => false
    }
  })
}

/// Check if git rollback is allowed
pub fn CapabilitySet::can_rollback(self : CapabilitySet) -> Bool {
  self.has(fn(cap) {
    match cap {
      GitRollback => true
      _ => false
    }
  })
}

/// Check if clock read is allowed
pub fn CapabilitySet::can_read_clock(self : CapabilitySet) -> Bool {
  self.has(fn(cap) {
    match cap {
      ClockRead => true
      ClockMonotonic => true
      _ => false
    }
  })
}

/// Check if random read is allowed
pub fn CapabilitySet::can_read_random(self : CapabilitySet) -> Bool {
  self.has(fn(cap) {
    match cap {
      RandomRead => true
      _ => false
    }
  })
}

/// Check if env var read is allowed
pub fn CapabilitySet::can_read_env(self : CapabilitySet, env_var : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      EnvRead(vars) => vars.contains(env_var) || vars.contains("*")
      _ => false
    }
  })
}

/// Check if process spawn is allowed
pub fn CapabilitySet::can_spawn(self : CapabilitySet, cmd : String) -> Bool {
  self.has(fn(cap) {
    match cap {
      ProcessSpawn(cmds) => cmds.contains(cmd) || cmds.contains("*")
      _ => false
    }
  })
}

/// Simple glob matching (supports * and **)
fn match_glob(pattern : String, path : String) -> Bool {
  // Handle exact match
  if pattern == path {
    return true
  }
  // Handle "**" (match everything)
  if pattern == "**" || pattern == "/**" {
    return true
  }
  // Handle trailing "/**" (match directory and all children)
  if pattern.has_suffix("/**") {
    let prefix_len = pattern.length() - 3
    let chars = pattern.to_array()
    let mut prefix = ""
    for i = 0; i < prefix_len; i = i + 1 {
      prefix = prefix + chars[i].to_string()
    }
    if path == prefix || path.has_prefix(prefix + "/") {
      return true
    }
  }
  // Handle single "*" wildcard
  if pattern.contains("*") && not(pattern.contains("**")) {
    return match_simple_glob(pattern, path)
  }
  false
}

/// Match simple glob with single * wildcards
fn match_simple_glob(pattern : String, path : String) -> Bool {
  let pattern_chars = pattern.to_array()
  let path_chars = path.to_array()
  let mut pi = 0
  let mut si = 0

  while pi < pattern_chars.length() && si < path_chars.length() {
    if pattern_chars[pi] == '*' {
      // Find next non-wildcard character
      pi = pi + 1
      if pi >= pattern_chars.length() {
        return true // Trailing * matches everything
      }
      let next_char = pattern_chars[pi]
      // Advance string until we find the next char
      while si < path_chars.length() && path_chars[si] != next_char {
        si = si + 1
      }
    } else if pattern_chars[pi] == path_chars[si] {
      pi = pi + 1
      si = si + 1
    } else {
      return false
    }
  }
  // Check if both consumed
  pi >= pattern_chars.length() && si >= path_chars.length()
}

/// Match host pattern (supports * prefix for subdomains)
fn match_host_pattern(pattern : String, host : String) -> Bool {
  if pattern == "*" {
    return true
  }
  if pattern == host {
    return true
  }
  // Handle *.example.com pattern
  if pattern.has_prefix("*.") {
    let chars = pattern.to_array()
    let mut suffix = ""
    for i = 1; i < chars.length(); i = i + 1 {
      suffix = suffix + chars[i].to_string()
    }
    if host.has_suffix(suffix) {
      return true
    }
  }
  false
}
