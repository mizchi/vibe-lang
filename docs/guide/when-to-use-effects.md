# When to Use Effects vs let mut

## 判断基準: 1つの質問

**「この状態変更は、関数の呼び出し元から見て透過的か？」**

- **Yes → `let mut`**: 呼び出し元は内部の状態を知る必要がない
- **No → `effect`**: 呼び出し元が実装を制御する必要がある

## let mut を使う場面

### 1. ループカウンタ

```vibe
// ✅ let mut: 内部の反復制御
let sum: (Array[Int]) -> Int = (arr) -> {
  let mut total = 0
  let mut i = 0
  while i < Array::length(arr) {
    total = total + Array::get(arr, i)
    i = i + 1
  }
  total
}
```

理由: `i` と `total` は関数の内部実装。呼び出し元は気にしない。

### 2. StringBuilder / ArrayBuilder

```vibe
// ✅ let mut: 構築中の中間状態
let join: (Array[String], String) -> String = (parts, sep) -> {
  let sb = StringBuilder::new()
  let mut first = true
  for part in parts {
    if not(first) { StringBuilder::push(sb, sep) }
    StringBuilder::push(sb, part)
    first = false
  }
  StringBuilder::build(sb)
}
```

理由: 中間バッファは外から見えない。結果は immutable String。

### 3. 局所的な条件フラグ

```vibe
// ✅ let mut: 関数内のフラグ
let has_uppercase: (String) -> Bool = (s) -> {
  let mut found = false
  let mut i = 0
  while i < String::length(s) {
    if String::char_code_at(s, i) >= 65 && String::char_code_at(s, i) <= 90 {
      found = true
    }
    i = i + 1
  }
  found
}
```

### 4. アキュムレータ（for-in との組み合わせ）

```vibe
// ✅ let mut: 集計は内部ロジック
let count_even: (Array[Int]) -> Int = (arr) -> {
  let mut count = 0
  for x in arr {
    if x - (x / 2) * 2 == 0 { count = count + 1 }
  }
  count
}
```

## effect を使う場面

### 1. 外部サービス呼び出し（DB, HTTP, ファイル）

```vibe
// ✅ effect: テスト時に mock したい
effect Db { Query(String) -> String }

let get_user: () -> String with Db = () -> {
  perform Db::Query("SELECT name FROM users WHERE id=1")
}

// テスト: mock handler
handle { get_user() } with Db { Query(_sql) => resume("Alice") }

// 本番: real handler (P3 adapter 経由)
```

理由: DB 呼び出しは外部依存。テストで差し替え可能にすべき。

### 2. 設定・環境の注入（DI）

```vibe
// ✅ effect: 実行環境ごとに値が異なる
effect Config {
  Get(String) -> String
}

let connect: () -> String with Config = () -> {
  let host = perform Config::Get("DB_HOST")
  let port = perform Config::Get("DB_PORT")
  String::concat(host, String::concat(":", port))
}

// 開発環境
handle { connect() } with Config {
  Get(key) => if String::equals(key, "DB_HOST") {
    resume("localhost")
  } else { resume("5432") }
}
```

理由: 設定値は環境で変わる。ハードコードすべきでない。

### 3. ロギング・メトリクス（観測可能性）

```vibe
// ✅ effect: ログの出力先を変えたい
effect Log { Info(String) -> Unit; Error(String) -> Unit }

let process: (String) -> Int with Log = (data) -> {
  perform Log::Info("processing started")
  let result = String::length(data)
  if result == 0 {
    perform Log::Error("empty data")
  }
  result
}

// テスト: ログを無視
handle { process("hello") } with Log {
  Info(_msg) => resume(0);
  Error(_msg) => resume(0)
}
```

理由: ログは副作用。テストでは不要、本番では必要。

### 4. 認証・認可（セキュリティ境界）

```vibe
// ✅ effect: 認証ロジックを差し替え可能に
effect Auth { Verify(String) -> Bool }

let protected_action: () -> Int with Auth = () -> {
  let ok = perform Auth::Verify("token")
  if ok { 200 } else { 401 }
}
```

理由: 認証はセキュリティ境界。テストで「常に認証成功」にできるべき。

### 5. 乱数生成

```vibe
// ✅ effect: テストで決定的にしたい
effect Random { NextInt(Int, Int) -> Int }

let roll_dice: () -> Int with Random = () -> {
  perform Random::NextInt(1, 6)
}

// テスト: 常に 4
handle { roll_dice() } with Random { NextInt(_lo, _hi) => resume(4) }
```

理由: 乱数は非決定的。テストでは決定的にすべき。

### 6. CPS 蓄積（fold/reduce）

```vibe
// ✅ effect + k: 値の蓄積を handler で制御
effect Emit { Emit(Int) -> Unit }

let total = handle {
  perform Emit::Emit(10)
  perform Emit::Emit(20)
  perform Emit::Emit(30)
  0
} { Emit::Emit(v, k) => v + k(0) }
// 10 + 20 + 30 + 0 = 60
```

理由: 蓄積ロジック（sum, product, count）を handler で切り替え可能。

## 判断フローチャート

```
この変数/操作は…
│
├─ 関数の外に影響するか？
│  ├─ Yes → effect
│  │  ├─ DB/HTTP/ファイル？ → effect Db/HttpClient/Fs
│  │  ├─ 設定値？ → effect Config
│  │  ├─ ログ？ → effect Log
│  │  ├─ 認証？ → effect Auth
│  │  └─ 乱数？ → effect Random
│  │
│  └─ No → let mut
│     ├─ ループカウンタ？ → let mut i = 0
│     ├─ 集計？ → let mut total = 0
│     ├─ 構築中？ → StringBuilder/ArrayBuilder
│     └─ フラグ？ → let mut found = false
│
└─ テスト時に差し替えたいか？
   ├─ Yes → effect (mock handler で差し替え)
   └─ No → let mut (内部実装のまま)
```

## アンチパターン

### ❌ ループカウンタを effect にしない

```vibe
// BAD: 不必要な effect 化
effect Counter { Inc() -> Unit; Get() -> Int }
let count = handle {
  perform Counter::Inc()
  perform Counter::Inc()
  perform Counter::Get()
} with Counter {
  Inc() => ...
  Get() => ...
}

// GOOD: let mut で十分
{
  let mut count = 0
  count = count + 1
  count = count + 1
  count
}
```

### ❌ 純粋関数の入出力を effect にしない

```vibe
// BAD: 文字列操作は副作用ではない
effect StringOps { Concat(String, String) -> String }

// GOOD: 直接呼ぶ
String::concat(a, b)
```

### ❌ 全ての `let mut` を排除しようとしない

```vibe
// BAD: while ループの accumulator を CPS effect で書く
effect Acc { Add(Int) -> Unit }
handle { for x in arr { perform Acc::Add(x) }; 0 } with Acc {
  Add(v) => v + resume(0)
}

// GOOD: let mut で書く（シンプル、高速）
{
  let mut total = 0
  for x in arr { total = total + x }
  total
}
```

## まとめ

| 基準 | let mut | effect |
|------|---------|--------|
| **スコープ** | 関数内 | モジュール/システム境界 |
| **テスト** | 不要 | mock handler で差し替え |
| **可視性** | 呼び出し元から隠蔽 | 型シグネチャに表出 |
| **コスト** | ゼロ | ゼロ (tail-resumptive inline) |
| **典型例** | カウンタ, Builder, フラグ | DB, HTTP, Config, Log, Auth |
