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
private def array (element : Ty) : Ty := named "Array" [element]
private def map (key value : Ty) : Ty := named "Map" [key, value]
private def builder (element : Ty) : Ty := named "ArrayBuilder" [element]
private def result (ok error : Ty) : Ty := named "Result" [ok, error]
private def option (element : Ty) : Ty := named "Option" [element]

private def identitySignature : Signature :=
  ⟨"identity", 1, [parameter (.var 0)], .var 0⟩

private def sameTypeVariableSignature : Signature :=
  ⟨"same", 1, [parameter (.var 0), parameter (.var 0)], .var 0⟩

private def correlatedArraysSignature : Signature :=
  ⟨"first", 1,
    [parameter (array (.var 0)), parameter (array (.var 0))],
    array (.var 0)⟩

private def addSignature : Signature :=
  ⟨"add", 0, [parameter .int, parameter .int], .int⟩

private def getIntSignature : Signature :=
  ⟨"get_int", 0, [parameter (box .int)], .int⟩

private def mapSetSignature : Signature :=
  ⟨"Map::set", 2,
    [parameter (map (.var 0) (.var 1)), parameter (.var 0),
      parameter (.var 1)],
    map (.var 0) (.var 1)⟩

private def builderPushSignature : Signature :=
  ⟨"ArrayBuilder::push", 1,
    [parameter (builder (.var 0)), parameter (.var 0)],
    .unit⟩

private def resultOptionCallSignature : Signature :=
  ⟨"use_result", 0, [parameter (result .int .string)], .int⟩

private def useNestedIntsSignature : Signature :=
  ⟨"use_nested_ints", 0, [parameter (box (array .int))], .int⟩

private def useOptionsSignature : Signature :=
  ⟨"use_options", 0, [parameter (array (option .int))], .int⟩

private def useIntArraySignature : Signature :=
  ⟨"use_array", 0, [parameter (array .int)], .int⟩

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

def sameTypeVariableAccepted : OracleCase := {
  name := "same-type-variable-accepted"
  issue := "#990"
  source := "fn same[T](x: T, y: T) -> T { x } fn good() -> Int { same(1, 2) }"
  signature := sameTypeVariableSignature
  arguments := [positional .int, positional .int]
  expected := .accepted .int [.int]
}

def sameTypeVariableMismatch : OracleCase := {
  name := "same-type-variable-mismatch"
  issue := "#990"
  source := "fn same[T](x: T, y: T) -> T { x } fn bad() -> Int { same(1, \"bad\") }"
  signature := sameTypeVariableSignature
  arguments := [positional .int, positional .string]
  expected := .rejected .typeMismatch
}

def nestedTypeVariableCorrelation : OracleCase := {
  name := "nested-type-variable-correlation"
  issue := "#990"
  source := "fn first[T](a: Array[T], b: Array[T]) -> Array[T] { a } fn bad(a: Array[Int], b: Array[String]) -> Array[Int] { first(a, b) }"
  signature := correlatedArraysSignature
  arguments := [positional (array .int), positional (array .string)]
  expected := .rejected .typeMismatch
}

def tooFewArguments : OracleCase := {
  name := "too-few-arguments"
  issue := "#990"
  source := "fn add(x: Int, y: Int) -> Int { x + y } fn bad() -> Int { add(1) }"
  signature := addSignature
  arguments := [positional .int]
  expected := .rejected .arityMismatch
}

def tooManyArguments : OracleCase := {
  name := "too-many-arguments"
  issue := "#990"
  source := "fn add(x: Int, y: Int) -> Int { x + y } fn bad() -> Int { add(1, 2, 3) }"
  signature := addSignature
  arguments := [positional .int, positional .int, positional .int]
  expected := .rejected .arityMismatch
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

def resultOptionCallMismatch : OracleCase := {
  name := "result-option-mismatch"
  issue := "#1001"
  source := "fn use_result(x: Result[Int,String]) -> Int { 0 } fn bad(o: Option[Int]) -> Int { use_result(o) }"
  signature := resultOptionCallSignature
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

def genericEnumArgumentMismatch : OracleCase := {
  name := "generic-enum-type-argument-mismatch"
  issue := "#981"
  source := "enum Box[T] { Wrap(T) } fn get_int(x: Box[Int]) -> Int { 0 } fn bad(x: Box[String]) -> Int { get_int(x) }"
  signature := getIntSignature
  arguments := [positional (box .string)]
  expected := .rejected .typeMismatch
}

def nestedGenericArgumentMismatch : OracleCase := {
  name := "nested-generic-type-argument-mismatch"
  issue := "#981"
  source := "struct Box[T] { v: T } fn use_nested_ints(x: Box[Array[Int]]) -> Int { 0 } fn bad(x: Box[Array[String]]) -> Int { use_nested_ints(x) }"
  signature := useNestedIntsSignature
  arguments := [positional (box (array .string))]
  expected := .rejected .typeMismatch
}

def nestedNominalHeadMismatch : OracleCase := {
  name := "nested-nominal-head-mismatch"
  issue := "#1001"
  source := "fn use_options(x: Array[Option[Int]]) -> Int { 0 } fn bad(x: Array[Result[Int,String]]) -> Int { use_options(x) }"
  signature := useOptionsSignature
  arguments := [positional (array (result .int .string))]
  expected := .rejected .typeMismatch
}

def genericMethodReceiverMismatch : OracleCase := {
  name := "generic-method-receiver-mismatch"
  issue := "#981"
  source := "struct Box[T] { v: T } fn Box::get_int(self: Box[Int]) -> Int { 0 } fn bad(x: Box[String]) -> Int { x.get_int() }"
  signature := getIntSignature
  arguments := [positional (box .string)]
  expected := .rejected .typeMismatch
}

def mapValueMismatch : OracleCase := {
  name := "map-value-mismatch"
  issue := "#983"
  source := "fn bad(m: Map[String,Int]) -> Map[String,Int] { Map::set(m, \"k\", \"bad\") }"
  signature := mapSetSignature
  arguments := [positional (map .string .int), positional .string, positional .string]
  expected := .rejected .typeMismatch
}

def mapValueAccepted : OracleCase := {
  name := "map-value-accepted"
  issue := "#983"
  source := "fn good(m: Map[String,Int]) -> Map[String,Int] { Map::set(m, \"k\", 1) }"
  signature := mapSetSignature
  arguments := [positional (map .string .int), positional .string, positional .int]
  expected := .accepted (map .string .int) [.string, .int]
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

def int64ArrayAliasAccepted : OracleCase := {
  name := "int64-array-alias"
  issue := "#990"
  source := "fn use_array(a: Array[Int]) -> Int { Array::length(a) } fn good(a: Int64Array) -> Int { use_array(a) }"
  signature := useIntArraySignature
  arguments := [positional .int64Array]
  expected := .accepted .int []
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

def mixedArgumentModes : OracleCase := {
  name := "mixed-argument-modes"
  issue := "#1001"
  source := "let f: (x~: Int, y~: String) -> Int = (x~, y~) -> { x } fn bad() -> Int { f(x=1, \"ok\") }"
  signature := labeledSignature
  arguments := [labeled "x" .int, positional .string]
  expected := .rejected .mixedArgumentModes
}

def cases : List OracleCase := [
  genericIdentity,
  sameTypeVariableAccepted,
  sameTypeVariableMismatch,
  nestedTypeVariableCorrelation,
  tooFewArguments,
  tooManyArguments,
  labeledReordered,
  labeledPositional,
  builderElementMismatch,
  resultOptionCallMismatch,
  boxArgumentMismatch,
  genericEnumArgumentMismatch,
  nestedGenericArgumentMismatch,
  nestedNominalHeadMismatch,
  genericMethodReceiverMismatch,
  mapValueMismatch,
  mapValueAccepted,
  bytesPushMismatch,
  int64ArraySetMismatch,
  int64ArrayAliasAccepted,
  labeledTypeMismatch,
  labeledUnknown,
  labeledDuplicate,
  labeledMissing,
  mixedArgumentModes
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

def brokenHeadOnlyAcceptsRepeatedVariableMismatch : Bool :=
  brokenHeadOnlyAccepts sameTypeVariableMismatch.signature sameTypeVariableMismatch.arguments

def brokenUncheckedAcceptsMixedArgumentModes : Bool :=
  brokenUncheckedAccepts mixedArgumentModes.signature mixedArgumentModes.arguments

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
