#!/usr/bin/env bash
# Generate extractor/getter/checker functions for codegen_common.vibe
# from vibe/compiler/ast.vibe enum definitions.
#
# Usage: bash scripts/gen_codegen_extractors.sh > /tmp/extractors.vibe
# Then replace the manual section in codegen_common.vibe

set -euo pipefail

AST_FILE="vibe/compiler/ast.vibe"

# Helper: convert CamelCase to snake_case using awk (portable)
to_lower() {
  echo "$1" | awk '{
    out=""
    for(i=1;i<=length($0);i++){
      c=substr($0,i,1)
      if(c ~ /[A-Z]/){
        out = out tolower(c)
      } else {
        out = out c
      }
    }
    print out
  }'
}

# Count fields in a comma-separated type list, handling nested brackets
count_fields() {
  local s="$1"
  local depth=0 count=1
  for (( i=0; i<${#s}; i++ )); do
    local ch="${s:$i:1}"
    case "$ch" in
      '[') depth=$((depth+1)) ;;
      ']') depth=$((depth-1)) ;;
      '(') depth=$((depth+1)) ;;
      ')') depth=$((depth-1)) ;;
      ',') [[ $depth -eq 0 ]] && count=$((count+1)) ;;
    esac
  done
  echo "$count"
}

# Split fields by comma, handling nested brackets. Output one per line.
split_fields() {
  local s="$1"
  local depth=0 current=""
  for (( i=0; i<${#s}; i++ )); do
    local ch="${s:$i:1}"
    case "$ch" in
      '[') depth=$((depth+1)); current+="$ch" ;;
      ']') depth=$((depth-1)); current+="$ch" ;;
      '(') depth=$((depth+1)); current+="$ch" ;;
      ')') depth=$((depth-1)); current+="$ch" ;;
      ',')
        if [[ $depth -eq 0 ]]; then
          echo "${current## }"
          current=""
        else
          current+="$ch"
        fi
        ;;
      *) current+="$ch" ;;
    esac
  done
  echo "${current## }"
}

# Build wildcard match pattern with __v at position $2 of $1 total
make_pattern() {
  local total=$1 target=$2
  local pat=""
  for (( j=0; j<total; j++ )); do
    [[ $j -gt 0 ]] && pat+=", "
    if [[ $j -eq $target ]]; then pat+="__v"; else pat+="_"; fi
  done
  echo "$pat"
}

make_wildcards() {
  local total=$1
  local pat=""
  for (( j=0; j<total; j++ )); do
    [[ $j -gt 0 ]] && pat+=", "
    pat+="_"
  done
  echo "$pat"
}

# Map: (variant_name, field_index, field_type, total_fields) -> field_name
get_field_name() {
  local name="$1" fi="$2" ty="$3" nf="$4"
  ty="${ty## }"

  case "$ty" in
    Int) echo "value" ;;
    Bool) echo "value" ;;
    Double) echo "value" ;;
    String)
      if [[ $nf -eq 1 ]]; then
        case "$name" in
          EIdent|EForIn) echo "name" ;;
          EString) echo "value" ;;
          *) echo "name" ;;
        esac
      else
        case "$fi" in
          0) echo "name" ;;
          1) echo "op" ;;
          *) echo "field$fi" ;;
        esac
      fi
      ;;
    Expr)
      case "$name" in
        # 1-field
        EThrow) echo "expr" ;;
        # 2-field
        EWhile)
          case "$fi" in 0) echo "cond" ;; 1) echo "body" ;; esac ;;
        ESeq)
          case "$fi" in 0) echo "first" ;; 1) echo "second" ;; esac ;;
        ECall)
          case "$fi" in 0) echo "callee" ;; esac ;;
        EMatch|EHandle)
          case "$fi" in 0) echo "scrutinee" ;; esac ;;
        EUnaryOp)
          case "$fi" in 1) echo "expr" ;; esac ;;
        # 3-field with string first
        EIf)
          case "$fi" in 0) echo "cond" ;; 1) echo "then_e" ;; 2) echo "else_e" ;; esac ;;
        ELet|ELetRec|ELetMut|EAssign)
          case "$fi" in 1) echo "val" ;; 2) echo "body" ;; esac ;;
        EForIn)
          case "$fi" in 1) echo "iter" ;; 2) echo "body" ;; esac ;;
        EBinOp)
          case "$fi" in 1) echo "lhs" ;; 2) echo "rhs" ;; esac ;;
        # 4-field
        EAssignOp)
          case "$fi" in 2) echo "val" ;; 3) echo "body" ;; esac ;;
        EDot)
          case "$fi" in 0) echo "expr" ;; esac ;;
        ELabeledArg)
          case "$fi" in 2) echo "expr" ;; esac ;;
        # EFn: 6 fields
        EFn)
          case "$fi" in 5) echo "body" ;; esac ;;
        *) echo "field$fi" ;;
      esac
      ;;
    "Array[Expr]")
      case "$name" in
        ETuple|EArray) echo "elems" ;;
        ECall) echo "args" ;;
        *) echo "items" ;;
      esac
      ;;
    "Array[(Pat, Expr)]") echo "arms" ;;
    "Option[Expr]") echo "opt_expr" ;;
    "Array[String]") echo "names" ;;
    "Array[(String, Array[String])]") echo "bindings" ;;
    "Array[(String, Option[TypeExpr])]") echo "params" ;;
    "Option[TypeExpr]") echo "ret_ty" ;;
    "Option[String]") echo "effect" ;;
    "Array[Pat]")
      case "$name" in
        PTuple) echo "pats" ;;
        PCtor) echo "args" ;;
        *) echo "pats" ;;
      esac
      ;;
    Pat)
      echo "pat$fi" ;;
    *) echo "field$fi" ;;
  esac
}

# Process an enum block and generate extractors
process_enum() {
  local enum_name="$1"  # "Expr", "Pat", or "Stmt"
  local param_name param_type
  case "$enum_name" in
    Expr) param_name="expr"; param_type="Expr" ;;
    Pat) param_name="p"; param_type="Pat" ;;
    Stmt) param_name="stmt"; param_type="Stmt" ;;
  esac

  local in_enum=0
  local tag=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^export\ enum\ ${enum_name}\ \{ ]]; then
      in_enum=1
      continue
    fi
    if [[ $in_enum -eq 1 && "$line" == "}" ]]; then
      break
    fi
    [[ $in_enum -eq 0 ]] && continue

    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%;}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^([A-Z][A-Za-z]*)\((.+)\)$ ]]; then
      local vname="${BASH_REMATCH[1]}"
      local fields_str="${BASH_REMATCH[2]}"
      local lower_name
      lower_name=$(to_lower "$vname")

      local nfields
      nfields=$(count_fields "$fields_str")

      # Read field types into array
      local -a types=()
      while IFS= read -r ft; do
        types+=("$ft")
      done < <(split_fields "$fields_str")

      # Generate getters
      for (( fi=0; fi<nfields; fi++ )); do
        local fname
        fname=$(get_field_name "$vname" "$fi" "${types[$fi]}" "$nfields")
        [[ "$fname" == "field"* && "$enum_name" == "Stmt" ]] && continue  # skip unmapped Stmt fields

        local ftype="${types[$fi]}"
        ftype="${ftype## }"
        local pat
        pat=$(make_pattern "$nfields" "$fi")

        echo "export let get_${lower_name}_${fname} = (${param_name}: ${param_type}) -> ${ftype} with { Error } {"
        echo "  match ${param_name} { ${vname}(${pat}) => __v, _ => throw(\"not ${vname}\") }"
        echo "}"
      done

      # Generate is_* check
      local wilds
      wilds=$(make_wildcards "$nfields")
      echo "export let is_${lower_name} = (${param_name}: ${param_type}) -> Bool { match ${param_name} { ${vname}(${wilds}) => true, _ => false } }"

      tag=$((tag+1))
    elif [[ "$line" =~ ^([A-Z][A-Za-z]*)$ ]]; then
      local vname="${BASH_REMATCH[1]}"
      local lower_name
      lower_name=$(to_lower "$vname")
      echo "export let is_${lower_name} = (${param_name}: ${param_type}) -> Bool { match ${param_name} { ${vname} => true, _ => false } }"
      tag=$((tag+1))
    fi
  done < "$AST_FILE"
}

echo "// === Generated Expr extractors (from ast.vibe) ==="
echo ""
process_enum "Expr"

echo ""
echo "// === Generated expr_tag ==="
echo ""

# Generate expr_tag separately
echo "export let expr_tag = (expr: Expr) -> Int {"
echo "  match expr {"
tag=0
in_expr=0
while IFS= read -r line; do
  if [[ "$line" =~ ^export\ enum\ Expr ]]; then
    in_expr=1
    continue
  fi
  if [[ $in_expr -eq 1 && "$line" == "}" ]]; then
    break
  fi
  [[ $in_expr -eq 0 ]] && continue
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%;}"
  [[ -z "$line" ]] && continue

  if [[ "$line" =~ ^([A-Z][A-Za-z]*)\( ]]; then
    local_name="${BASH_REMATCH[1]}"
    fields_str="${line#*\(}"
    fields_str="${fields_str%\)}"
    nf=$(count_fields "$fields_str")
    wilds=$(make_wildcards "$nf")
    echo "    ${local_name}(${wilds}) => ${tag},"
  elif [[ "$line" =~ ^([A-Z][A-Za-z]*)$ ]]; then
    echo "    ${BASH_REMATCH[1]} => ${tag},"
  fi
  tag=$((tag+1))
done < "$AST_FILE"
echo "    _ => -1"
echo "  }"
echo "}"

echo ""
echo "// === Generated Pat extractors ==="
echo ""
process_enum "Pat"

echo ""
echo "// === Generated Stmt extractors ==="
echo ""
process_enum "Stmt"
