import VibeFormal.Effect.Id

set_option autoImplicit false

namespace VibeFormal.Typing

/-- Primitive runtime representations distinguished by the call-typing model. -/
inductive Primitive where
  | int
  | string
  | bool
  | unit
  | bytes
  deriving DecidableEq, Repr

mutual

/--
The minimum type language needed to cover the recent call-typing bugs. Nominal
type arguments remain visible; erasing them is the deliberately broken witness.
Resolved function signatures are modeled separately below this layer. Function
types, variance, and row polymorphism belong to the higher-order extension
tracked by #939.
-/
inductive Ty where
  | prim (primitive : Primitive)
  | var (index : Nat)
  | nominal (name : String) (arguments : TyArgs)

/-- A direct mutual encoding avoids erasing arbitrarily nested generic args. -/
inductive TyArgs where
  | nil
  | cons (head : Ty) (tail : TyArgs)

end

deriving instance DecidableEq for Ty, TyArgs
deriving instance Repr for Ty, TyArgs

namespace TyArgs

def ofList : List Ty → TyArgs
  | [] => .nil
  | head :: tail => .cons head (ofList tail)

def toList : TyArgs → List Ty
  | .nil => []
  | .cons head tail => head :: toList tail

def length : TyArgs → Nat
  | .nil => 0
  | .cons _ tail => tail.length + 1

end TyArgs

namespace Ty

def int : Ty := .prim .int
def string : Ty := .prim .string
def bool : Ty := .prim .bool
def unit : Ty := .prim .unit
def bytes : Ty := .prim .bytes
/-- `Int64Array` is a source alias normalized to `Array[Int]`. -/
def int64Array : Ty := .nominal "Array" (TyArgs.ofList [.int])

def listAt? {α : Type} : List α → Nat → Option α
  | [], _ => none
  | value :: _, 0 => some value
  | _ :: rest, index + 1 => listAt? rest index

mutual
  def instantiate (substitution : List Ty) : Ty → Option Ty
    | .prim primitive => some (.prim primitive)
    | .var index => listAt? substitution index
    | .nominal name arguments => do
        let instantiated ← instantiateArgs substitution arguments
        pure (.nominal name instantiated)

  def instantiateArgs (substitution : List Ty) : TyArgs → Option TyArgs
    | .nil => some .nil
    | .cons head tail => do
        let instantiatedHead ← instantiate substitution head
        let instantiatedTail ← instantiateArgs substitution tail
        pure (.cons instantiatedHead instantiatedTail)
end

def renderPrimitive : Primitive → String
  | .int => "Int"
  | .string => "String"
  | .bool => "Bool"
  | .unit => "Unit"
  | .bytes => "Bytes"

mutual
  def render : Ty → String
    | .prim primitive => renderPrimitive primitive
    | .var index => "$" ++ toString index
    | .nominal name .nil => name
    | .nominal name arguments =>
        name ++ "[" ++ String.intercalate "," (renderArgs arguments) ++ "]"

  def renderArgs : TyArgs → List String
    | .nil => []
    | .cons head tail => render head :: renderArgs tail
end

/-- The bug-compatible comparison that forgets nominal type arguments. -/
def sameHead : Ty → Ty → Bool
  | .var _, _ => true
  | _, .var _ => true
  | .prim left, .prim right => decide (left = right)
  | .nominal left _, .nominal right _ => decide (left = right)
  | _, _ => false

end Ty

end VibeFormal.Typing
