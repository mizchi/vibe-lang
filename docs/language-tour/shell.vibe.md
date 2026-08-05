# Shell Integration

## sh / sh_lines

```vibe
let demo: () -> Array[String] with Process = () -> {
  // Execute command; returns the captured output (String)
  let out = sh("echo hello")

  // Execute and capture output lines
  sh_lines("ls /tmp")
  // => Array[String]
}
```

Both require the `{Process}` effect:

```vibe
let run: () -> Unit with Process = () -> {
  let _ = sh("echo hello")   // sh returns String; discard it in a Unit fn
}

// In tests, effects are implicit
test "shell" {
  let lines = sh_lines("echo hello")
  assert(eq(Array::length(lines), 1))
}
```

## PosixMode (internal runtime preview)

In internal `PosixMode`, bare commands are desugared to `sh_lines()` calls:

```
$ vibe shell

> ls /tmp
note: posix-mode command-head desugar: ls -> sh_lines("ls")
file1.txt
file2.txt

> cat README.md
note: posix-mode command-head desugar: cat -> sh_lines("cat")
# vibe language
...
```

### Desugar rules

| Input | Desugars to |
|-------|-------------|
| `ls /tmp` | `sh_lines("ls /tmp")` |
| `cat file.txt` | `sh_lines("cat file.txt")` |
| `echo hello` | `sh_lines("echo hello")` |

Keywords (`let`, `if`, `while`, `for`, `match`, `test`, etc.) and function calls are not desugared.

## Expression Interpolation `{{ expr }}`

Embed vibe expressions in shell commands:

```
> let dir = "/tmp"
> ls {{ dir }}
  => sh_lines("ls \{dir}")
```

`{{ expr }}` is converted to vibe string interpolation `\{expr}`.

## Command Substitution `$()`

POSIX-style command substitution within shell commands:

```
> echo "today is $(date)"
  => captures first line of sh_lines("date") output
```

`$(cmd)` executes `sh_lines("cmd")` and substitutes the first output line.

## Pipes in Commands

Shell pipes work within `sh_lines()` strings:

```vibe
let pipes: () -> Array[String] with Process = () -> {
  let a = sh_lines("echo hello | cat")
  let b = sh_lines("printf 'a\\nb\\nc' | sort -r")
  sh_lines("seq 1 10 | head -3")
}
```

## vibe Pipe Operator with Shell

The vibe `|>` pipe operator can chain shell results with vibe functions:

```vibe
let count_txt: () -> Int with Process = () -> {
  sh_lines("ls /tmp")
  |> Array::filter((s) -> { String::contains(s, ".txt") })
  |> Array::length
}
// Works because |> inserts value as first arg, matching collection-first order
```

## where (filter)

<!-- doctest-skip: `where` は現 prelude に存在しない (doc rot — Array::filter を使う、要 doc 更新判断) -->
```vibe skip
// Filter array with predicate (prelude function, collection-first)
let evens = where([1, 2, 3, 4, 5], (x) -> { x % 2 == 0 })
// => [2, 4]
```
