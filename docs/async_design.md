# xsh async/await 設計

## 概要

xsh の Effect システムを拡張し、WASM stack switching と WASI Preview 3 を活用した async/await を実装する。

## 背景技術

### WebAssembly Stack Switching (Phase 3)
- **cont.new**: 関数から suspended continuation を作成
- **suspend**: 実行を中断し control tag を呼び出す
- **resume**: handler の下で continuation を実行

```wasm
;; Control tag 定義
(tag $yield (param i32) (result i32))

;; Continuation 作成と実行
(cont.new $ct (ref.func $my_func))
(resume $ct (tag $yield $handler_label))
```

### WASI Preview 3
- `async func`: 非同期関数定義
- `future<T>`: 遅延計算
- `stream<T>`: 非同期ストリーム
- Task/Subtask によるライフサイクル管理

## 現在の Effect システム

```xsh
// 現在の構文
let parse = (s: String) -> Json with {Error} {
  if s == "" { raise "empty" }
  // ...
}

// try-catch
let result = try { parse(input) } catch { JNull }
```

### AST 構造
```moonbit
enum EffectAtom {
  Const(String)  // {Error}
  Var(String)    // {E} (型変数)
}

enum Expr {
  Fn(params~, ret~, effects~: Array[EffectAtom], body~, span~)
  Raise(value~: Expr, span~)
  Try(try_body~, catch_body~, span~)
}
```

## 設計案

### 1. Effect の拡張

現在の `{Error}` に加えて `{Async}` を追加:

```xsh
// 非同期関数
let fetch_data = (url: String) -> String with {Async, Error} {
  let response = await http_get(url)
  response.body
}

// 非同期ストリーム
let process_stream = (input: Stream[Byte]) -> Stream[Json] with {Async} {
  for chunk in input {
    yield parse_json(chunk)
  }
}
```

### 2. 構文拡張

#### 2.1 async/await
```xsh
// async 関数（暗黙的に {Async} effect）
async let fetch = (url: String) -> Response {
  // ...
}

// await 式
let data = await fetch("https://example.com")
```

#### 2.2 yield（ストリーム生成）
```xsh
// ストリーム生成
let numbers = () -> Stream[Int] with {Async} {
  for i in 0..10 {
    yield i
  }
}
```

#### 2.3 for-await（ストリーム消費）
```xsh
for await item in stream {
  process(item)
}
```

### 3. 型システム

```
// 新しい型
Stream[T]     // 非同期ストリーム
Future[T]     // 非同期計算結果

// Effect の合成
{Async}           // 非同期のみ
{Error}           // エラーのみ
{Async, Error}    // 両方
```

### 4. WASM コンパイル戦略

#### Phase 1: Exception-based (現状)
```wasm
;; Error effect → WASM exceptions
(try
  (call $may_throw)
  (catch $error_tag
    (local.get 0)  ;; error message
  )
)
```

#### Phase 2: Stack Switching (将来)
```wasm
;; Async effect → Continuations
(tag $async (param i32) (result i32))

(func $async_op (param $cont (ref $cont_type))
  ;; suspend して runtime に制御を渡す
  (suspend $async)
  ;; runtime が resume すると継続
)
```

### 5. Runtime 統合

#### 5.1 Interpreter モード
```moonbit
enum AsyncValue {
  Pending(continuation: () -> AsyncValue)
  Ready(value: Value)
  Error(message: String)
}

fn run_async(task: AsyncValue) -> Value {
  match task {
    Pending(cont) => run_async(cont())
    Ready(v) => v
    Error(msg) => raise msg
  }
}
```

#### 5.2 WASM モード（将来）
- stack switching proposal を使用
- WASI Preview 3 の async ABI に準拠
- Component Model との統合

## 実装ロードマップ

### Step 1: Interpreter での async/await
1. `EffectAtom::Const("Async")` の追加
2. `Expr::Await(expr)` の追加
3. `Expr::Yield(expr)` の追加
4. `eval.mbt` で CPS 変換または coroutine 実装

### Step 2: 型チェック
1. `{Async}` effect の伝播チェック
2. `await` は `{Async}` コンテキストでのみ許可
3. `Stream[T]` と `Future[T]` の型推論

### Step 3: WASM 例外ベース実装
1. `{Async}` を WASM exceptions で表現
2. scheduler を WASM memory に実装
3. 単一スレッドでの協調的マルチタスク

### Step 4: Stack Switching 統合（将来）
1. stack switching proposal の安定化を待つ
2. `cont.new`/`suspend`/`resume` への変換
3. WASI Preview 3 対応

## 構文詳細

### async 関数宣言
```xsh
// 明示的
let fetch = (url: String) -> Response with {Async} {
  // ...
}

// async キーワード（糖衣構文）
async let fetch = (url: String) -> Response {
  // ...同上
}
```

### await 式
```xsh
// 単純な await
let response = await fetch(url)

// エラーハンドリングと組み合わせ
let data = try {
  await fetch(url)
} catch {
  default_data
}
```

### Stream 操作
```xsh
// ストリーム生成
let gen = () -> Stream[Int] with {Async} {
  yield 1
  yield 2
  yield 3
}

// ストリーム消費
for await n in gen() {
  print(n)
}

// ストリーム変換
let doubled = gen() |> map((n) { n * 2 })
```

## Effect ハンドラ（将来拡張）

代数的エフェクトの完全なサポート:

```xsh
// Effect 定義
effect Log {
  log: (msg: String) -> Unit
}

// ハンドラ
let with_logger = (f: () -> T with {Log}) -> T {
  handle f() {
    log(msg) => {
      print("[LOG] " + msg)
      resume()
    }
  }
}

// 使用
with_logger(() {
  do Log.log("hello")
  42
})
```

## 未決事項

1. **async 構文**: `async let` vs `let async` vs `with {Async}` のみ
2. **Stream 型**: 組み込み vs ライブラリ
3. **並行性モデル**: 協調的 vs 並列（WASM threads）
4. **キャンセル**: タスクキャンセルのサポート
5. **バックプレッシャー**: Stream のフロー制御

## 参考

- [WebAssembly Stack Switching Proposal](https://github.com/WebAssembly/stack-switching)
- [WASI Preview 3](https://github.com/WebAssembly/WASI)
- [Component Model Async](https://github.com/WebAssembly/component-model/blob/main/design/mvp/Async.md)
- [WasmFX](https://wasmfx.dev/)
