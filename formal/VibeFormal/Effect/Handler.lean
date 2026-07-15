import VibeFormal.Effect.Row

set_option autoImplicit false

namespace VibeFormal.EffectRow

/-- Remove exactly the body operations belonging to the handled effect. -/
def discharge (effectDef : EffectDefId) (body : Normalized) : Normalized :=
  body.filter fun operation => decide (operation.id.effectDef ≠ effectDef)

/--
The result row of a handler. Effects required by handler arms are added after
the handled operations have been discharged from the body.
-/
def handleResult
    (effectDef : EffectDefId)
    (body armRequirements : Normalized) : Normalized :=
  normalizeList (discharge effectDef body ++ armRequirements)

end VibeFormal.EffectRow
