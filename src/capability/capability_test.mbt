///| Tests for Capability

test "CapabilitySet::new creates empty set" {
  let caps = @capability.CapabilitySet::new()
  assert_false(caps.can_read("/any/path"))
}

test "CapabilitySet::can_read with exact path" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::fs_read("/home/user/file.txt"),
  ])
  assert_true(caps.can_read("/home/user/file.txt"))
  assert_false(caps.can_read("/home/user/other.txt"))
}

test "CapabilitySet::can_read with glob pattern" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::fs_read("/home/**"),
  ])
  assert_true(caps.can_read("/home/user/file.txt"))
  assert_true(caps.can_read("/home/other/deep/path.txt"))
  assert_false(caps.can_read("/etc/passwd"))
}

test "CapabilitySet::can_write respects patterns" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::fs_read("/**"),
    @capability.Capability::fs_write("/tmp/**"),
  ])
  assert_true(caps.can_read("/etc/passwd"))
  assert_true(caps.can_write("/tmp/test.txt"))
  assert_false(caps.can_write("/etc/passwd"))
}

test "CapabilitySet::can_connect checks host and port" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::net_connect("api.github.com", Some(443)),
    @capability.Capability::net_connect("*.example.com", None),
  ])
  assert_true(caps.can_connect("api.github.com", 443))
  assert_false(caps.can_connect("api.github.com", 80))
  assert_true(caps.can_connect("api.example.com", 8080))
  assert_true(caps.can_connect("sub.example.com", 443))
  assert_false(caps.can_connect("evil.com", 443))
}

test "CapabilitySet::can_call_mcp checks tool list" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::mcp_call(["file_read", "file_write"]),
  ])
  assert_true(caps.can_call_mcp("file_read"))
  assert_true(caps.can_call_mcp("file_write"))
  assert_false(caps.can_call_mcp("shell_exec"))
}

test "CapabilitySet::can_call_mcp with wildcard" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::mcp_call(["*"]),
  ])
  assert_true(caps.can_call_mcp("any_tool"))
  assert_true(caps.can_call_mcp("another_tool"))
}

test "CapabilitySet::can_delegate_a2a checks agent list" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::a2a_delegate(["code-agent", "test-agent"]),
  ])
  assert_true(caps.can_delegate_a2a("code-agent"))
  assert_false(caps.can_delegate_a2a("evil-agent"))
}

test "CapabilitySet::can_snapshot and can_rollback" {
  let caps_with = @capability.CapabilitySet::from_array([
    @capability.Capability::git_snapshot(),
    @capability.Capability::git_rollback(),
  ])
  let caps_without = @capability.CapabilitySet::new()

  assert_true(caps_with.can_snapshot())
  assert_true(caps_with.can_rollback())
  assert_false(caps_without.can_snapshot())
  assert_false(caps_without.can_rollback())
}

test "CapabilitySet::can_read_env checks var list" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::env_read(["PATH", "HOME"]),
  ])
  assert_true(caps.can_read_env("PATH"))
  assert_true(caps.can_read_env("HOME"))
  assert_false(caps.can_read_env("SECRET_KEY"))
}

test "CapabilitySet::can_spawn checks command list" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::process_spawn(["ls", "cat", "grep"]),
  ])
  assert_true(caps.can_spawn("ls"))
  assert_true(caps.can_spawn("cat"))
  assert_false(caps.can_spawn("rm"))
  assert_false(caps.can_spawn("sudo"))
}

test "CapabilitySet::minimal preset" {
  let caps = @capability.CapabilitySet::minimal()
  assert_true(caps.can_read("/any/file"))
  assert_false(caps.can_write("/any/file"))
  assert_false(caps.can_snapshot())
}

test "CapabilitySet::sandbox preset" {
  let caps = @capability.CapabilitySet::sandbox()
  assert_true(caps.can_read("/etc/passwd"))
  assert_true(caps.can_write("/tmp/test.txt"))
  assert_false(caps.can_write("/etc/passwd"))
  assert_true(caps.can_snapshot())
  assert_false(caps.can_rollback())
}

test "CapabilitySet::developer preset" {
  let caps = @capability.CapabilitySet::developer()
  assert_true(caps.can_read("/any/file"))
  assert_true(caps.can_write("/any/file"))
  assert_true(caps.can_snapshot())
  assert_true(caps.can_rollback())
  assert_true(caps.can_read_env("ANY_VAR"))
}

test "CapabilitySet::agent preset" {
  let caps = @capability.CapabilitySet::agent(
    ["file_read", "web_search"],
    ["helper-agent"],
    ["api.github.com", "*.openai.com"],
  )
  assert_true(caps.can_call_mcp("file_read"))
  assert_false(caps.can_call_mcp("shell_exec"))
  assert_true(caps.can_delegate_a2a("helper-agent"))
  assert_false(caps.can_delegate_a2a("unknown-agent"))
  assert_true(caps.can_connect("api.github.com", 443))
  assert_true(caps.can_connect("api.openai.com", 443))
  assert_false(caps.can_connect("evil.com", 443))
}

test "CapabilitySet::add creates new set with capability" {
  let caps = @capability.CapabilitySet::minimal()
  assert_false(caps.can_snapshot())

  let caps2 = caps.add(@capability.Capability::git_snapshot())
  assert_true(caps2.can_snapshot())
  // Original unchanged
  assert_false(caps.can_snapshot())
}
