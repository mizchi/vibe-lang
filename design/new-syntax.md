# XS Language - 新構文設計

## 概要

XS言語をよりシェル向けに最適化し、Unisonのコンテンツアドレス指向を徹底する新しい構文設計。

## 主な変更点

### 1. ハッシュベースの評価システム

```haskell
-- 旧構文
let x = 42

-- 新構文
x = 42  -- 評価時に x#abc123 として保存される
```

- すべての評価結果は自動的にハッシュ化される
- シンボル名は現在のスコープで最新のハッシュを参照
- コードベース格納時に実際のハッシュに置換

### 2. 関数定義の新構文

```haskell
-- キーワード引数をサポートする新しい関数定義
let add x:Int y:Int -> Int = x + y

-- 型推論に任せる場合
let multiply x y = x * y
-- 推論後: let multiply x:Int y:Int -> Int = x * y

-- エフェクト付き関数
let readFile path:String -> <IO> String = 
  perform IO (readFileContents path)

-- 複数エフェクト
let processData x:Int y:String -> <IO, Exception> Result String Int {
  -- 関数本体
}
```

### 3. ブロックアノテーション

```haskell
-- エフェクトと返り値型を明示
let factorial n -> <Pure> Int {
  if n == 0 { 1 } else { n * factorial (n - 1) }
}

-- 参照キャプチャも含む（推論結果として表示）
let createCounter () -> <Pure, Ref count#abc> (Int -> <Ref count#abc> Int) {
  let count = 0
  fn () -> <Ref count#abc> Int {
    count = count + 1
    count
  }
}
```

### 4. キーワード引数の呼び出し

```haskell
-- 関数定義
let connect host:String port:Int timeout:Int -> <IO> Connection = ...

-- 様々な呼び出しパターン
connect "localhost" 8080 30                    -- 位置引数
connect host:"localhost" port:8080 timeout:30  -- キーワード引数
connect "localhost" port:8080 timeout:30       -- 混在

-- 部分適用
let localConnect = connect "localhost"     -- host固定
let connect80 = connect port:80           -- port固定
```

### 5. カリー化とキーワード引数のルール

1. **位置引数優先**: キーワードなし引数は左から順に未指定の引数に割り当て
2. **混在可能**: 位置引数とキーワード引数は自由に混在可能
3. **部分適用**: どの引数からでも部分適用可能

```haskell
let process x:Int y:Int z:Int -> Int = x + y * z

-- 部分適用の例
let f1 = process 1        -- x=1, y,z未指定
let f2 = process y:2      -- y=2, x,z未指定
let f3 = process 1 y:2    -- x=1, y=2, z未指定

-- 呼び出し
f1 2 3      -- process 1 2 3
f2 1 3      -- process 1 2 3
f3 3        -- process 1 2 3
```

## 型表記の統一

### 関数型でのエフェクト表記

```haskell
-- 型シグネチャ
connect : String -> Int -> Int -> <IO> Connection
divide : Float -> Float -> <Exception> Float
map : (a -> <e> b) -> List a -> <e> List b

-- ブロック内での表記（同じ形式）
let connect host port timeout -> <IO> Connection { ... }
```

## バージョン管理

```haskell
-- 最初のバージョン
factorial n = if n == 0 { 1 } else { n * factorial (n - 1) }
-- factorial#v1として保存

-- 更新版
factorial n = if n <= 0 { 1 } else { n * factorial (n - 1) }
-- factorial#v2として保存

-- 古いバージョンの参照
import factorial#v1 as factorialOld
```

## シェルでの使用例

```bash
xs> add x y = x + y
add : x:Int -> y:Int -> Int = <body> [#abc123]

xs> add 5 3
8 : Int [#def456]

xs> add y:3 x:5
8 : Int [#def456]

xs> inc = add x:1
inc : y:Int -> Int = <partial> [#ghi789]

xs> update
Saved to codebase:
  add#abc123 : x:Int -> y:Int -> Int
  inc#ghi789 : y:Int -> Int
```

## 実装の優先順位

1. **Phase 1**: 基本的な新構文のパーサー実装
   - `let`を保持した関数定義
   - 引数名と型の統合構文
   - エフェクト表記の統一

2. **Phase 2**: ハッシュベースシステム
   - 評価結果の自動ハッシュ化
   - シンボル解決システム
   - コードベースへの保存

3. **Phase 3**: キーワード引数
   - パーサーでのサポート
   - 型チェッカーの拡張
   - 部分適用の実装

4. **Phase 4**: 高度な機能
   - 古いバージョンの参照
   - import構文の拡張
   - デフォルト引数