import VibeFormal.Proofs.IncrementalCorrect

/-!
Executable, deterministic corpus for the bounded incremental invalidation
relation. This is deliberately a model corpus, not a serialization of compiler
cache keys or interface fingerprints.
-/

namespace VibeFormal.Compiler.IncrementalOracle

/--
Columns: case, changed source owners, changed implementation owners, and
model-required typing invalidation set. The three demo modules are `base`,
`library`, and `app`; direct dependencies
are base <- library <- app.  The rows correspond to the proved examples in
`Proofs/IncrementalCorrect.lean`.
-/
def renderCorpus : String :=
  "case\tchanged_source_owners\tchanged_implementation_owners\tmodel_typing_invalidated\n" ++
  "no_op\t-\t-\t-\n" ++
  "comment_only_edit\tlibrary\t-\t-\n" ++
  "private_body_edit\tlibrary\tlibrary\tlibrary\n" ++
  "public_interface_edit\tlibrary\tlibrary\tlibrary,app\n" ++
  "dependency_plan_edit\tapp\tapp\tapp\n"

end VibeFormal.Compiler.IncrementalOracle

def main : IO Unit :=
  IO.print VibeFormal.Compiler.IncrementalOracle.renderCorpus
