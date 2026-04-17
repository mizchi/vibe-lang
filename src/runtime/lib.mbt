///|
pub(all) enum ParserMode {
  VibeMode
  PosixMode
  PosixStrictMode
} derive(Debug, Eq)

///|
pub impl Show for ParserMode with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}
