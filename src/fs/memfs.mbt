///| In-memory filesystem implementation

///| Inode types
priv enum InodeData {
  File(Bytes)
  Directory(Map[String, Int])  // name -> inode_id
}

///| Inode structure
struct Inode {
  mut data : InodeData
}

///| In-memory filesystem
pub struct MemFs {
  priv inodes : Array[Inode]
  mut next_id : Int
}

///| Create a new empty filesystem
pub fn MemFs::new() -> MemFs {
  let fs = MemFs::{ inodes: [], next_id: 0 }
  // Create root directory
  let root_id = fs.alloc_inode(InodeData::Directory({}))
  guard root_id == 0
  fs
}

fn MemFs::alloc_inode(self : MemFs, data : InodeData) -> Int {
  let id = self.next_id
  self.next_id += 1
  self.inodes.push(Inode::{ data })
  id
}

fn MemFs::get_inode(self : MemFs, id : Int) -> Inode? {
  if id >= 0 && id < self.inodes.length() {
    Some(self.inodes[id])
  } else {
    None
  }
}

///| Resolve path to inode id
fn MemFs::resolve(self : MemFs, path : String) -> Int? {
  let normalized = normalize_path(path)
  if normalized == "/" {
    return Some(0)
  }
  let mut current = 0
  // Skip first '/' and split by '/'
  let path_without_slash = if normalized.length() > 1 {
    let buf = StringBuilder::new()
    for i in 1..<normalized.length() {
      buf.write_char(normalized[i].to_int().unsafe_to_char())
    }
    buf.to_string()
  } else {
    ""
  }
  for part in path_without_slash.split("/") {
    let part_str = part.to_string()
    if part_str.is_empty() {
      continue
    }
    match self.get_inode(current) {
      Some(inode) =>
        match inode.data {
          Directory(entries) =>
            match entries.get(part_str) {
              Some(next_id) => current = next_id
              None => return None
            }
          File(_) => return None
        }
      None => return None
    }
  }
  Some(current)
}

///| FileSystemBackend implementation
pub impl FileSystemBackend for MemFs with read_file(self, path) {
  match self.resolve(path) {
    None => raise FsError::NotFound(path)
    Some(id) =>
      match self.get_inode(id) {
        Some(inode) =>
          match inode.data {
            File(data) => data
            Directory(_) => raise FsError::IsADirectory(path)
          }
        None => raise FsError::NotFound(path)
      }
  }
}

pub impl FileSystemBackend for MemFs with read_string(self, path) {
  let bytes = self.read_file(path)
  // Simple UTF-8 decode
  let buf = StringBuilder::new()
  for b in bytes {
    buf.write_char(b.to_int().unsafe_to_char())
  }
  buf.to_string()
}

pub impl FileSystemBackend for MemFs with exists(self, path) {
  self.resolve(path) is Some(_)
}

pub impl FileSystemBackend for MemFs with is_file(self, path) {
  match self.resolve(path) {
    Some(id) =>
      match self.get_inode(id) {
        Some(inode) => inode.data is File(_)
        None => false
      }
    None => false
  }
}

pub impl FileSystemBackend for MemFs with is_dir(self, path) {
  match self.resolve(path) {
    Some(id) =>
      match self.get_inode(id) {
        Some(inode) => inode.data is Directory(_)
        None => false
      }
    None => false
  }
}

pub impl FileSystemBackend for MemFs with stat(self, path) {
  match self.resolve(path) {
    None => raise FsError::NotFound(path)
    Some(id) =>
      match self.get_inode(id) {
        Some(inode) =>
          match inode.data {
            File(data) => FileStat::{ file_type: FileType::File, size: data.length() }
            Directory(_) => FileStat::{ file_type: FileType::Directory, size: 0 }
          }
        None => raise FsError::NotFound(path)
      }
  }
}

pub impl FileSystemBackend for MemFs with readdir(self, path) {
  match self.resolve(path) {
    None => raise FsError::NotFound(path)
    Some(id) =>
      match self.get_inode(id) {
        Some(inode) =>
          match inode.data {
            Directory(entries) => {
              let result : Array[DirEntry] = []
              for name, child_id in entries {
                match self.get_inode(child_id) {
                  Some(child) => {
                    let file_type = match child.data {
                      File(_) => FileType::File
                      Directory(_) => FileType::Directory
                    }
                    result.push(DirEntry::{ name, file_type })
                  }
                  None => ()
                }
              }
              result
            }
            File(_) => raise FsError::NotADirectory(path)
          }
        None => raise FsError::NotFound(path)
      }
  }
}

pub impl FileSystemBackend for MemFs with write_file(self, path, data) {
  let normalized = normalize_path(path)
  let parent = parent_path(normalized)
  let name = basename(normalized)

  // Get or validate parent
  let parent_id = match self.resolve(parent) {
    None => raise FsError::NotFound(parent)
    Some(id) => id
  }

  // Check parent is directory
  let parent_inode = match self.get_inode(parent_id) {
    None => raise FsError::NotFound(parent)
    Some(inode) => inode
  }
  match parent_inode.data {
    File(_) => raise FsError::NotADirectory(parent)
    Directory(entries) => {
      match entries.get(name) {
        Some(existing_id) =>
          // Overwrite existing file
          match self.get_inode(existing_id) {
            Some(inode) =>
              match inode.data {
                File(_) => inode.data = InodeData::File(data)
                Directory(_) => raise FsError::IsADirectory(path)
              }
            None => raise FsError::IoError("corrupted inode")
          }
        None => {
          // Create new file
          let new_id = self.alloc_inode(InodeData::File(data))
          entries.set(name, new_id)
        }
      }
    }
  }
}

pub impl FileSystemBackend for MemFs with write_string(self, path, content) {
  let bytes = Bytes::from_array(
    FixedArray::makei(content.length(), fn(i) { content[i].to_int().to_byte() }),
  )
  self.write_file(path, bytes)
}

pub impl FileSystemBackend for MemFs with mkdir(self, path) {
  let normalized = normalize_path(path)
  if normalized == "/" {
    raise FsError::AlreadyExists(path)
  }

  let parent = parent_path(normalized)
  let name = basename(normalized)

  let parent_id = match self.resolve(parent) {
    None => raise FsError::NotFound(parent)
    Some(id) => id
  }

  let parent_inode = match self.get_inode(parent_id) {
    None => raise FsError::NotFound(parent)
    Some(inode) => inode
  }

  match parent_inode.data {
    File(_) => raise FsError::NotADirectory(parent)
    Directory(entries) => {
      if entries.contains(name) {
        raise FsError::AlreadyExists(path)
      }
      let new_id = self.alloc_inode(InodeData::Directory({}))
      entries.set(name, new_id)
    }
  }
}

pub impl FileSystemBackend for MemFs with mkdir_p(self, path) {
  let normalized = normalize_path(path)
  if normalized == "/" {
    return
  }

  // Skip first '/' and get the rest
  let path_without_slash = if normalized.length() > 1 {
    let buf = StringBuilder::new()
    for i in 1..<normalized.length() {
      buf.write_char(normalized[i].to_int().unsafe_to_char())
    }
    buf.to_string()
  } else {
    ""
  }
  let parts : Array[String] = []
  for part in path_without_slash.split("/") {
    parts.push(part.to_string())
  }
  let mut current_path = ""

  for part in parts {
    current_path = current_path + "/" + part
    if not(self.exists(current_path)) {
      self.mkdir(current_path)
    } else if not(self.is_dir(current_path)) {
      raise FsError::NotADirectory(current_path)
    }
  }
}

pub impl FileSystemBackend for MemFs with remove(self, path) {
  let normalized = normalize_path(path)
  if normalized == "/" {
    raise FsError::PermissionDenied("cannot remove root")
  }

  let parent = parent_path(normalized)
  let name = basename(normalized)

  let parent_id = match self.resolve(parent) {
    None => raise FsError::NotFound(parent)
    Some(id) => id
  }

  let parent_inode = match self.get_inode(parent_id) {
    None => raise FsError::NotFound(parent)
    Some(inode) => inode
  }

  match parent_inode.data {
    File(_) => raise FsError::NotADirectory(parent)
    Directory(entries) => {
      match entries.get(name) {
        None => raise FsError::NotFound(path)
        Some(id) =>
          match self.get_inode(id) {
            Some(inode) =>
              match inode.data {
                File(_) => entries.remove(name)
                Directory(_) => raise FsError::IsADirectory(path)
              }
            None => raise FsError::NotFound(path)
          }
      }
    }
  }
}

pub impl FileSystemBackend for MemFs with rmdir(self, path) {
  let normalized = normalize_path(path)
  if normalized == "/" {
    raise FsError::PermissionDenied("cannot remove root")
  }

  let parent = parent_path(normalized)
  let name = basename(normalized)

  let parent_id = match self.resolve(parent) {
    None => raise FsError::NotFound(parent)
    Some(id) => id
  }

  let parent_inode = match self.get_inode(parent_id) {
    None => raise FsError::NotFound(parent)
    Some(inode) => inode
  }

  match parent_inode.data {
    File(_) => raise FsError::NotADirectory(parent)
    Directory(entries) => {
      match entries.get(name) {
        None => raise FsError::NotFound(path)
        Some(id) =>
          match self.get_inode(id) {
            Some(inode) =>
              match inode.data {
                File(_) => raise FsError::NotAFile(path)
                Directory(children) =>
                  if children.is_empty() {
                    entries.remove(name)
                  } else {
                    raise FsError::NotEmpty(path)
                  }
              }
            None => raise FsError::NotFound(path)
          }
      }
    }
  }
}

pub impl FileSystemBackend for MemFs with rename(self, old_path, new_path) {
  // Simple implementation: copy data and remove old
  let old_normalized = normalize_path(old_path)
  let new_normalized = normalize_path(new_path)

  if old_normalized == new_normalized {
    return
  }

  if self.is_file(old_normalized) {
    let data = self.read_file(old_normalized)
    self.write_file(new_normalized, data)
    self.remove(old_normalized)
  } else if self.is_dir(old_normalized) {
    raise FsError::IoError("directory rename not yet implemented")
  } else {
    raise FsError::NotFound(old_path)
  }
}

pub impl FileSystemBackend for MemFs with copy_file(self, src, dst) {
  let src_normalized = normalize_path(src)
  let dst_normalized = normalize_path(dst)

  if not(self.is_file(src_normalized)) {
    if self.is_dir(src_normalized) {
      raise FsError::IsADirectory(src)
    }
    raise FsError::NotFound(src)
  }

  let data = self.read_file(src_normalized)
  self.write_file(dst_normalized, data)
}

pub impl FileSystemBackend for MemFs with rm_rf(self, path) {
  let normalized = normalize_path(path)
  if normalized == "/" {
    raise FsError::PermissionDenied("cannot remove root")
  }

  if not(self.exists(normalized)) {
    raise FsError::NotFound(path)
  }

  if self.is_file(normalized) {
    self.remove(normalized)
    return
  }

  // Directory: recursively delete contents
  let entries = self.readdir(normalized)
  for entry in entries {
    let child_path = normalized + "/" + entry.name
    self.rm_rf(child_path)
  }
  self.rmdir(normalized)
}
