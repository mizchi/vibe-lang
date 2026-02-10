///|
fn build_git_ref_test_graph_index(
  path : String,
  source : String,
) -> AdvancedGraphIndex {
  let db = @xsh.XshDb::new()
  db.set_source(path, source)
  build_advanced_graph_index(
    db,
    [path],
    base_commit="deadbeef",
    created_at="2026-02-08T00:00:00Z",
  )
}

///|
fn ensure_dir_if_missing(path : String) -> Unit {
  if not(@os_fs.path_exists(path)) {
    let _ = @os_fs.create_dir(path) catch { _ => () }
  }
}

///|
fn remove_if_exists(path : String) -> Unit {
  if not(@os_fs.path_exists(path)) {
    return
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if is_file {
    ignore(@os_fs.remove_file(path) catch { _ => () })
    return
  }
  let is_dir = @os_fs.is_dir(path) catch { _ => false }
  if is_dir {
    let entries = @os_fs.read_dir(path) catch { _ => [] }
    for name in entries {
      remove_if_exists(path + "/" + name)
    }
    ignore(@os_fs.remove_dir(path) catch { _ => () })
  }
}

///|
test "advanced graph git ref snapshot roundtrip" {
  let repo_root = "/tmp/advanced_graph_git_ref_repo"
  let git_dir = repo_root + "/.git"
  remove_if_exists(repo_root)
  ensure_dir_if_missing(repo_root)
  ensure_dir_if_missing(git_dir)
  ensure_dir_if_missing(git_dir + "/objects")
  let source =
    #|let add = (x: Int, y: Int) -> Int { x + y }
    #|let id = (x: Int) -> Int { x }
  let index = build_git_ref_test_graph_index(
    "/tmp/advanced_graph_git_ref_main.xsh", source,
  )
  let scope = "tests/snapshot-roundtrip"
  let hash = match
    write_advanced_graph_index_to_git_ref(git_dir, scope, index) {
    Ok(v) => v
    Err(err) => fail("write git ref snapshot failed: " + err)
  }
  assert_eq(hash.length(), 40)
  let restored = match read_advanced_graph_index_from_git_ref(git_dir, scope) {
    Ok(v) => v
    Err(err) => fail("read git ref snapshot failed: " + err)
  }
  assert_eq(restored.to_json().stringify(), index.to_json().stringify())
}

///|
test "advanced graph git ref delta roundtrip" {
  let repo_root = "/tmp/advanced_graph_git_ref_repo"
  let git_dir = repo_root + "/.git"
  remove_if_exists(repo_root)
  ensure_dir_if_missing(repo_root)
  ensure_dir_if_missing(git_dir)
  ensure_dir_if_missing(git_dir + "/objects")
  let base_source =
    #|let value = 1
    #|let keep = (x: Int) -> Int { x }
  let next_source =
    #|let value = 2
    #|let keep = (x: Int) -> Int { x + 1 }
    #|let added = 3
  let base = build_git_ref_test_graph_index(
    "/tmp/advanced_graph_git_ref_delta_main.xsh", base_source,
  )
  let next = build_git_ref_test_graph_index(
    "/tmp/advanced_graph_git_ref_delta_main.xsh", next_source,
  )
  let delta = advanced_graph_diff(base, next)
  let scope = "tests/delta-roundtrip"
  let hash = match
    write_advanced_graph_delta_to_git_ref(git_dir, scope, delta) {
    Ok(v) => v
    Err(err) => fail("write git ref delta failed: " + err)
  }
  assert_eq(hash.length(), 40)
  let restored = match read_advanced_graph_delta_from_git_ref(git_dir, scope) {
    Ok(v) => v
    Err(err) => fail("read git ref delta failed: " + err)
  }
  let applied = apply_advanced_graph_delta(base, restored)
  assert_eq(applied.to_json().stringify(), next.to_json().stringify())
}

///|
test "advanced graph git ref delta chain replay" {
  let repo_root = "/tmp/advanced_graph_git_ref_repo"
  let git_dir = repo_root + "/.git"
  remove_if_exists(repo_root)
  ensure_dir_if_missing(repo_root)
  ensure_dir_if_missing(git_dir)
  ensure_dir_if_missing(git_dir + "/objects")
  let path = "/tmp/advanced_graph_git_ref_chain_main.xsh"
  let base = build_git_ref_test_graph_index(
    path,
    (
      #|let value = 1
      #|let keep = (x: Int) -> Int { x }
    ),
  )
  let mid = build_git_ref_test_graph_index(
    path,
    (
      #|let value = 2
      #|let keep = (x: Int) -> Int { x + 1 }
    ),
  )
  let latest = build_git_ref_test_graph_index(
    path,
    (
      #|let value = 3
      #|let keep = (x: Int) -> Int { x + 2 }
      #|let added = 10
    ),
  )
  let delta_1 = advanced_graph_diff(base, mid)
  let delta_2 = advanced_graph_diff(mid, latest)
  let scope = "tests/delta-chain"
  let _ = match write_advanced_graph_delta_to_git_ref(git_dir, scope, delta_1) {
    Ok(v) => v
    Err(err) => fail("write first delta failed: " + err)
  }
  let _ = match write_advanced_graph_delta_to_git_ref(git_dir, scope, delta_2) {
    Ok(v) => v
    Err(err) => fail("write second delta failed: " + err)
  }
  let latest_delta = match
    read_advanced_graph_delta_from_git_ref(git_dir, scope) {
    Ok(v) => v
    Err(err) => fail("read latest delta failed: " + err)
  }
  let replay_latest_only = apply_advanced_graph_delta(mid, latest_delta)
  assert_eq(
    replay_latest_only.to_json().stringify(),
    latest.to_json().stringify(),
  )
  let chain = match
    read_advanced_graph_delta_chain_from_git_ref(git_dir, scope) {
    Ok(v) => v
    Err(err) => fail("read delta chain failed: " + err)
  }
  assert_eq(chain.length(), 2)
  let replay_1 = apply_advanced_graph_delta(base, chain[0])
  let replay_2 = apply_advanced_graph_delta(replay_1, chain[1])
  assert_eq(replay_2.to_json().stringify(), latest.to_json().stringify())
}
