import VibeFormal.Typing.Call

set_option autoImplicit false

namespace VibeFormal.Typing.Oracle

private def positional (type : Ty) : Argument := .positional type
private def labeled (label : String) (type : Ty) : Argument := .labeled label type
private def parameter (type : Ty) : Parameter := ⟨none, type⟩
private def labeledParameter (label : String) (type : Ty) : Parameter := ⟨some label, type⟩

private def named (name : String) (arguments : List Ty) : Ty :=
  .nominal name (TyArgs.ofList arguments)
private def box (element : Ty) : Ty := named "Box" [element]
private def map (key value : Ty) : Ty := named "Map" [key, value]
private def builder (element : Ty) : Ty := named "ArrayBuilder" [element]
private def result (ok error : Ty) : Ty := named "Result" [ok, error]
private def option (element : Ty) : Ty := named "Option" [element]

private def identitySignature : Signature :=
  ⟨"identity", 1, [parameter (.var 0)], .var 0⟩

private def getIntSignature : Signature :=
  ⟨"get_int", 0, [parameter (box .int)], .int⟩

private def mapSetSignature : Signature :=
  ⟨"Map::set", 2,
    [parameter (map (.var 0) (.var 1)), parameter (.var 0),
      parameter (.var 1)],
    .unit⟩

private def builderPushSignature : Signature :=
  ⟨"ArrayBuilder::push", 1,
    [parameter (builder (.var 0)), parameter (.var 0)],
    .unit⟩

private def useResultSignature : Signature :=
  ⟨"use_result", 0, [parameter (result .int .string)], .int⟩

private def bytesPushSignature : Signature :=
  ⟨"Bytes::push", 0, [parameter .bytes, parameter .int], .unit⟩

private def int64ArraySetSignature : Signature :=
  ⟨"Int64Array::set", 0,
    [parameter .int64Array, parameter .int, parameter .int],
    .unit⟩

private def labeledSignature : Signature :=
  ⟨"labeled", 0,
    [labeledParameter "x" .int, labeledParameter "y" .string],
    .int⟩

structure OracleCase where
  name : String
  issue : String
  source : String
  signature : Signature
  arguments : List Argument
  expected : CallOutcome

def genericIdentity : OracleCase := {
  name := "generic-identity"
  issue := "#990"
  source := "fn identity[T](x: T) -> T { x } fn main() -> Int { identity(1) }"
  signature := identitySignature
  arguments := [positional .int]
  expected := .accepted .int [.int]
}

def labeledReordered : OracleCase := {
  name := "labeled-reordered"
  issue := "#986"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn main() -> Int { f(y=\"ok\", x=1) }"
  signature := labeledSignature
  arguments := [labeled "y" .string, labeled "x" .int]
  expected := .accepted .int []
}

def labeledPositional : OracleCase := {
  name := "labeled-positional"
  issue := "#986"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn main() -> Int { f(1, \"ok\") }"
  signature := labeledSignature
  arguments := [positional .int, positional .string]
  expected := .accepted .int []
}

def builderElementMismatch : OracleCase := {
  name := "array-builder-element-mismatch"
  issue := "#938"
  source := "fn bad(b: ArrayBuilder[Int]) -> Unit { ArrayBuilder::push(b, \"bad\") }"
  signature := builderPushSignature
  arguments := [positional (builder .int), positional .string]
  expected := .rejected .typeMismatch
}

def railwayConstructorMismatch : OracleCase := {
  name := "result-option-mismatch"
  issue := "#941"
  source := "fn use_result(x: Result[Int,String]) -> Int { 0 } fn bad(o: Option[Int]) -> Int { use_result(o) }"
  signature := useResultSignature
  arguments := [positional (option .int)]
  expected := .rejected .typeMismatch
}

def boxArgumentMismatch : OracleCase := {
  name := "box-type-argument-mismatch"
  issue := "#981"
  source := "struct Box[T] { v: T } fn get_int(x: Box[Int]) -> Int { 0 } fn bad(x: Box[String]) -> Int { get_int(x) }"
  signature := getIntSignature
  arguments := [positional (box .string)]
  expected := .rejected .typeMismatch
}

def mapValueMismatch : OracleCase := {
  name := "map-value-mismatch"
  issue := "#983"
  source := "fn bad(m: Map[String,Int]) -> Unit { Map::set(m, \"k\", \"bad\") }"
  signature := mapSetSignature
  arguments := [positional (map .string .int), positional .string, positional .string]
  expected := .rejected .typeMismatch
}

def mapValueAccepted : OracleCase := {
  name := "map-value-accepted"
  issue := "#983"
  source := "fn good(m: Map[String,Int]) -> Unit { Map::set(m, \"k\", 1) }"
  signature := mapSetSignature
  arguments := [positional (map .string .int), positional .string, positional .int]
  expected := .accepted .unit [.string, .int]
}

def bytesPushMismatch : OracleCase := {
  name := "bytes-push-mismatch"
  issue := "#985"
  source := "fn bad(b: Bytes) -> Unit { Bytes::push(b, \"bad\") }"
  signature := bytesPushSignature
  arguments := [positional .bytes, positional .string]
  expected := .rejected .typeMismatch
}

def int64ArraySetMismatch : OracleCase := {
  name := "int64-array-set-mismatch"
  issue := "#985"
  source := "fn bad(a: Int64Array) -> Unit { Int64Array::set(a, 0, \"bad\") }"
  signature := int64ArraySetSignature
  arguments := [positional .int64Array, positional .int, positional .string]
  expected := .rejected .typeMismatch
}

def labeledTypeMismatch : OracleCase := {
  name := "labeled-type-mismatch"
  issue := "#986"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn bad() -> Int { f(x=\"bad\", y=\"ok\") }"
  signature := labeledSignature
  arguments := [labeled "x" .string, labeled "y" .string]
  expected := .rejected .typeMismatch
}

def labeledUnknown : OracleCase := {
  name := "labeled-unknown"
  issue := "#986"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn bad() -> Int { f(z=1, y=\"ok\") }"
  signature := labeledSignature
  arguments := [labeled "z" .int, labeled "y" .string]
  expected := .rejected .unknownLabel
}

def labeledDuplicate : OracleCase := {
  name := "labeled-duplicate"
  issue := "#986"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn bad() -> Int { f(x=1, x=2) }"
  signature := labeledSignature
  arguments := [labeled "x" .int, labeled "x" .int]
  expected := .rejected .duplicateLabel
}

def labeledMissing : OracleCase := {
  name := "labeled-missing"
  issue := "#986"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn bad() -> Int { f(x=1) }"
  signature := labeledSignature
  arguments := [labeled "x" .int]
  expected := .rejected .arityMismatch
}

def cases : List OracleCase := [
  genericIdentity,
  labeledReordered,
  labeledPositional,
  builderElementMismatch,
  railwayConstructorMismatch,
  boxArgumentMismatch,
  mapValueMismatch,
  mapValueAccepted,
  bytesPushMismatch,
  int64ArraySetMismatch,
  labeledTypeMismatch,
  labeledUnknown,
  labeledDuplicate,
  labeledMissing
]

def OracleCase.actual (testCase : OracleCase) : CallOutcome :=
  checkCallOutcome testCase.signature testCase.arguments

def OracleCase.passes (testCase : OracleCase) : Bool :=
  decide (testCase.actual = testCase.expected)

def allCasesPass : Bool := cases.all OracleCase.passes

def brokenHeadOnlyAcceptsBoxMismatch : Bool :=
  brokenHeadOnlyAccepts boxArgumentMismatch.signature boxArgumentMismatch.arguments

def brokenUncheckedAcceptsBuiltinMismatch : Bool :=
  brokenUncheckedAccepts bytesPushMismatch.signature bytesPushMismatch.arguments

def brokenHeadOnlyAcceptsMapValueMismatch : Bool :=
  brokenHeadOnlyAccepts mapValueMismatch.signature mapValueMismatch.arguments

def brokenUncheckedAcceptsUnknownLabel : Bool :=
  brokenUncheckedAccepts labeledUnknown.signature labeledUnknown.arguments

private def renderErrorKind : CallErrorKind → String
  | .arityMismatch => "arity-mismatch"
  | .mixedArgumentModes => "mixed-argument-modes"
  | .unknownLabel => "unknown-label"
  | .duplicateLabel => "duplicate-label"
  | .typeMismatch => "type-mismatch"
  | .unresolvedTypeParameter => "unresolved-type-parameter"
  | .malformedSignature => "malformed-signature"
  | .internalValidation => "internal-validation"

private def renderTypes (types : List Ty) : String :=
  "[" ++ String.intercalate "," (types.map Ty.render) ++ "]"

private def renderOutcome : CallOutcome → String × String
  | .accepted returnType typeArguments =>
      ("accept", Ty.render returnType ++ ";types=" ++ renderTypes typeArguments)
  | .rejected kind => ("reject", renderErrorKind kind)

private def renderCase (testCase : OracleCase) : String :=
  let (verdict, detail) := renderOutcome testCase.actual
  String.intercalate "\t"
    [testCase.name, testCase.issue, verdict, detail, testCase.source]

def renderCorpus : String :=
  "version\t1\nname\tissue\tverdict\tdetail\tsource\n" ++
    String.intercalate "\n" (cases.map renderCase) ++ "\n"

end VibeFormal.Typing.Oracle
