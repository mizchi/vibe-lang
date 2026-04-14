///| Virtual filesystem types

///|
/// File system errors
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
} derive(Debug, Eq)

///|
pub impl Show for FsError with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
/// File type enumeration
pub(all) enum FileType {
  File
  Directory
  Symlink
} derive(Debug, Eq)

///|
pub impl Show for FileType with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
/// File metadata
pub(all) struct FileStat {
  file_type : FileType
  size : Int
  // Future: mtime, atime, ctime, mode, etc.
} derive(Debug, Eq)

///|
/// Default file stat
pub fn FileStat::default() -> FileStat {
  { file_type: FileType::File, size: 0 }
}

///|
/// Directory entry
pub(all) struct DirEntry {
  name : String
  file_type : FileType
} derive(Debug, Eq)
