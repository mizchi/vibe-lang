import VibeFormal.Typing.Oracle

set_option autoImplicit false

namespace VibeFormal.Typing.Examples

private def named (name : String) (arguments : List Ty) : Ty :=
  .nominal name (TyArgs.ofList arguments)

private def map (key value : Ty) : Ty := named "Map" [key, value]
private def intArray : Ty := named "Array" [.int]

example : Oracle.allCasesPass = true := by
  native_decide

example : Ty.int64Array = intArray := by
  rfl

example : Oracle.mapValueAccepted.expected =
    .accepted (map .string .int) [.string, .int] := by
  rfl

example : Oracle.mapValueMismatch.source =
    "fn bad(m: Map[String,Int]) -> Map[String,Int] { Map::set(m, \"k\", \"bad\") }" := by
  rfl

example : Oracle.mapValueAccepted.source =
    "fn good(m: Map[String,Int]) -> Map[String,Int] { Map::set(m, \"k\", 1) }" := by
  rfl

example : Oracle.boxArgumentMismatch.expected = .rejected .typeMismatch := by
  rfl

example : Oracle.sameTypeVariableAccepted.expected =
    .accepted .int [.int] := by
  rfl

example : Oracle.sameTypeVariableMismatch.expected = .rejected .typeMismatch := by
  rfl

example : Oracle.nestedTypeVariableCorrelation.expected = .rejected .typeMismatch := by
  rfl

example : Oracle.tooFewArguments.expected = .rejected .arityMismatch := by
  rfl

example : Oracle.tooManyArguments.expected = .rejected .arityMismatch := by
  rfl

example : Oracle.mixedArgumentModes.expected = .rejected .mixedArgumentModes := by
  rfl

example : Oracle.cases.length = 25 := by
  rfl

example : Oracle.brokenHeadOnlyAcceptsBoxMismatch = true := by
  native_decide

example : Oracle.brokenUncheckedAcceptsBuiltinMismatch = true := by
  native_decide

example : Oracle.brokenHeadOnlyAcceptsMapValueMismatch = true := by
  native_decide

example : Oracle.brokenUncheckedAcceptsUnknownLabel = true := by
  native_decide

example : Oracle.brokenHeadOnlyAcceptsRepeatedVariableMismatch = true := by
  native_decide

example : Oracle.brokenUncheckedAcceptsMixedArgumentModes = true := by
  native_decide

end VibeFormal.Typing.Examples
