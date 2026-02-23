///|
fn stack_index_of_path(stack : Array[String], path : String) -> Int? {
  for i, p in stack {
    if p == path {
      return Some(i)
    }
  }
  None
}

///|
fn cycle_path_from_stack(
  stack : Array[String],
  start_idx : Int,
) -> Array[String] {
  let out : Array[String] = []
  for i in start_idx..<stack.length() {
    out.push(stack[i])
  }
  if start_idx >= 0 && start_idx < stack.length() {
    out.push(stack[start_idx])
  }
  out
}

///|
fn render_import_cycle(cycle : Array[String]) -> String {
  let mut out = ""
  for i, p in cycle {
    if i > 0 {
      out += " -> "
    }
    out += p
  }
  out
}

///|
fn detect_import_cycle_from(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  ast_query : @ripple.Query[String, HashedModule],
  path : String,
  stack : Array[String],
  done : Map[String, Bool],
) -> Array[String]? {
  match stack_index_of_path(stack, path) {
    Some(idx) => return Some(cycle_path_from_stack(stack, idx))
    None => ()
  }
  if done.contains(path) {
    return None
  }
  stack.push(path)
  let ast = ast_query.fetch(rt, path).unwrap()
  let base_dir = @path.Path(path).dirname().to_string()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(source~, ..) | @core.Stmt::ReExport(source~, ..) =>
        match source {
          @core.ModuleRef::Path(path=raw_path) => {
            let path_obj = normalize_path_obj(base_dir, raw_path)
            let next_path = match sources.get(rt, path_obj.normalized) {
              Some(_) => Some(path_obj.normalized)
              None =>
                match sources.get(rt, raw_path) {
                  Some(_) => Some(raw_path)
                  None => None
                }
            }
            match next_path {
              Some(next) =>
                match
                  detect_import_cycle_from(
                    rt, sources, ast_query, next, stack, done,
                  ) {
                  Some(cycle) => return Some(cycle)
                  None => ()
                }
              None => ()
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  let _ = stack.pop()
  done[path] = true
  None
}

///|
fn detect_import_cycle(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  ast_query : @ripple.Query[String, HashedModule],
  root_path : String,
) -> Array[String]? {
  let stack : Array[String] = []
  let done : Map[String, Bool] = {}
  detect_import_cycle_from(rt, sources, ast_query, root_path, stack, done)
}

///|
/// Build a directory-level (module-level) dependency graph from the file-level
/// import graph and detect cycles among directories.
fn detect_module_cycle_from(
  dir : String,
  dir_edges : Map[String, Array[String]],
  stack : Array[String],
  done : Map[String, Bool],
) -> Array[String]? {
  match stack_index_of_path(stack, dir) {
    Some(idx) => return Some(cycle_path_from_stack(stack, idx))
    None => ()
  }
  if done.contains(dir) {
    return None
  }
  stack.push(dir)
  match dir_edges.get(dir) {
    Some(deps) =>
      for dep in deps {
        match detect_module_cycle_from(dep, dir_edges, stack, done) {
          Some(cycle) => return Some(cycle)
          None => ()
        }
      }
    None => ()
  }
  let _ = stack.pop()
  done[dir] = true
  None
}

///|
/// Detect module-level (directory-level) import cycles starting from root_path.
/// Collects directory edges by walking the file-level import graph, then runs
/// cycle detection on the collapsed directory DAG.
fn detect_module_cycle(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  ast_query : @ripple.Query[String, HashedModule],
  root_path : String,
) -> Array[String]? {
  // Collect all file-level edges reachable from root_path
  let dir_edges : Map[String, Array[String]] = {}
  let file_visited : Map[String, Bool] = {}
  let file_queue : Array[String] = [root_path]
  while file_queue.length() > 0 {
    let path = file_queue.unsafe_pop()
    if file_visited.contains(path) {
      continue
    }
    file_visited[path] = true
    let file_dir = @path.Path(path).dirname().to_string()
    let ast = ast_query.fetch(rt, path).unwrap()
    let base_dir = @path.Path(path).dirname().to_string()
    for stmt in ast.stmts {
      match stmt {
        @core.Stmt::Import(source~, ..) | @core.Stmt::ReExport(source~, ..) =>
          match source {
            @core.ModuleRef::Path(path=raw_path) => {
              let path_obj = normalize_path_obj(base_dir, raw_path)
              let next_path = match sources.get(rt, path_obj.normalized) {
                Some(_) => Some(path_obj.normalized)
                None =>
                  match sources.get(rt, raw_path) {
                    Some(_) => Some(raw_path)
                    None => None
                  }
              }
              match next_path {
                Some(next) => {
                  let next_dir = @path.Path(next).dirname().to_string()
                  if file_dir != next_dir {
                    let edges = match dir_edges.get(file_dir) {
                      Some(arr) => arr
                      None => {
                        let arr : Array[String] = []
                        dir_edges[file_dir] = arr
                        arr
                      }
                    }
                    if not(array_has_string(edges, next_dir)) {
                      edges.push(next_dir)
                    }
                  }
                  file_queue.push(next)
                }
                None => ()
              }
            }
            _ => ()
          }
        _ => ()
      }
    }
  }
  // Run cycle detection on the directory graph
  let root_dir = @path.Path(root_path).dirname().to_string()
  let stack : Array[String] = []
  let done : Map[String, Bool] = {}
  detect_module_cycle_from(root_dir, dir_edges, stack, done)
}
