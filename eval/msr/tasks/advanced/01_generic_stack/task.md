# advanced/01_generic_stack — 初期実装

`struct Stack[T]` を実装する (内部は `Array[T]` でよい)。以下を実装:

- `Stack::new[T]() -> Stack[T]`
- `push(s: Stack[T], x: T) -> Stack[T]` (不変更新)
- `pop(s: Stack[T]) -> (Stack[T], Option[T])` (空なら `(s, None)`)
- `peek(s: Stack[T]) -> Option[T]`
- `is_empty(s: Stack[T]) -> Bool`

`test { ... }` で `Stack[Int]` と `Stack[String]` の両方に対して push
複数回・pop・peek・is_empty の組み合わせを最低4ケース `assert` すること
(ジェネリクスが実際に別の型パラメータで動くことを示す)。
