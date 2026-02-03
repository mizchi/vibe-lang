///| Virtual filesystem types

///| File system errors
pub(all) suberror FsError {
  NotFound(String)
  AlreadyExists(String)
  NotADirectory(String)
  NotAFile(String)
  IsADirectory(String)
  NotEmpty(String)
  PermissionDenied(String)
  InvalidPath(String)
  IoError(String)
} derive(Show, Eq)

///| File type enumeration
pub(all) enum FileType {
  File
  Directory
  Symlink
} derive(Show, Eq)

///| File metadata
pub(all) struct FileStat {
  file_type : FileType
  size : Int
  // Future: mtime, atime, ctime, mode, etc.
} derive(Show, Eq)

///| Default file stat
pub fn FileStat::default() -> FileStat {
  { file_type: FileType::File, size: 0 }
}

///| Directory entry
pub(all) struct DirEntry {
  name : String
  file_type : FileType
} derive(Show, Eq)
