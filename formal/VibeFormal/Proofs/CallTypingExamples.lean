import VibeFormal.Typing.Oracle

set_option autoImplicit false

namespace VibeFormal.Typing.Examples

example : Oracle.allCasesPass = true := by
  native_decide

example : Oracle.boxArgumentMismatch.expected = .rejected .typeMismatch := by
  rfl

example : Oracle.brokenHeadOnlyAcceptsBoxMismatch = true := by
  native_decide

example : Oracle.brokenUncheckedAcceptsBuiltinMismatch = true := by
  native_decide

example : Oracle.brokenHeadOnlyAcceptsMapValueMismatch = true := by
  native_decide

example : Oracle.brokenUncheckedAcceptsUnknownLabel = true := by
  native_decide

end VibeFormal.Typing.Examples
