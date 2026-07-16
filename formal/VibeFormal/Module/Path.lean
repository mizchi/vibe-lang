import Std

set_option autoImplicit false

namespace VibeFormal.Module

/-- A normalized logical directory. `.` and `..` never occur as segments. -/
structure Directory where
  segments : List String
  deriving DecidableEq, Repr

namespace Directory

def isPrefixOf (ancestor descendant : Directory) : Bool :=
  ancestor.segments.isPrefixOf descendant.segments

def isStrictAncestorOf (ancestor descendant : Directory) : Bool :=
  ancestor.isPrefixOf descendant &&
    ancestor.segments.length < descendant.segments.length

def depth (directory : Directory) : Nat :=
  directory.segments.length

end Directory

end VibeFormal.Module
