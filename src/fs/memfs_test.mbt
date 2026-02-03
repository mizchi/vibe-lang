test "MemFs basic operations" {
  let fs = MemFs::new()

  // Create directory
  fs.mkdir("/home")
  assert_true(fs.is_dir("/home"))

  // Write file
  fs.write_string("/home/test.txt", "Hello")
  assert_true(fs.is_file("/home/test.txt"))

  // Read file
  let content = fs.read_string("/home/test.txt")
  assert_eq(content, "Hello")

  // Stat
  let stat = fs.stat("/home/test.txt")
  assert_eq(stat.size, 5)
  assert_eq(stat.file_type, FileType::File)

  // Readdir
  let entries = fs.readdir("/home")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "test.txt")
}

test "MemFs path operations" {
  assert_eq(normalize_path("/a/b/c"), "/a/b/c")
  assert_eq(normalize_path("/a/./b/../c"), "/a/c")
  assert_eq(normalize_path("//a//b//"), "/a/b")

  assert_eq(parent_path("/a/b/c"), "/a/b")
  assert_eq(parent_path("/a"), "/")
  assert_eq(parent_path("/"), "/")

  assert_eq(basename("/a/b/c"), "c")
  assert_eq(basename("/a"), "a")
  assert_eq(basename("/"), "")
}

test "MemFs mkdir_p" {
  let fs = MemFs::new()

  fs.mkdir_p("/a/b/c")
  assert_true(fs.is_dir("/a"))
  assert_true(fs.is_dir("/a/b"))
  assert_true(fs.is_dir("/a/b/c"))
}

test "MemFs remove and rmdir" {
  let fs = MemFs::new()

  fs.mkdir("/dir")
  fs.write_string("/dir/file.txt", "test")

  // Remove file
  fs.remove("/dir/file.txt")
  assert_false(fs.exists("/dir/file.txt"))

  // Remove empty directory
  fs.rmdir("/dir")
  assert_false(fs.exists("/dir"))
}

test "MemFs copy_file" {
  let fs = MemFs::new()

  fs.write_string("/original.txt", "hello world")
  fs.copy_file("/original.txt", "/copy.txt")

  assert_true(fs.exists("/copy.txt"))
  assert_eq(fs.read_string("/copy.txt"), "hello world")
  // Original still exists
  assert_true(fs.exists("/original.txt"))
}

test "MemFs rm_rf" {
  let fs = MemFs::new()

  // Create nested structure
  fs.mkdir_p("/a/b/c")
  fs.write_string("/a/file1.txt", "1")
  fs.write_string("/a/b/file2.txt", "2")
  fs.write_string("/a/b/c/file3.txt", "3")

  // Remove recursively
  fs.rm_rf("/a")

  assert_false(fs.exists("/a"))
  assert_false(fs.exists("/a/b"))
  assert_false(fs.exists("/a/b/c"))
}
