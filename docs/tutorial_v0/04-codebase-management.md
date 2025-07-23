# XS言語 チュートリアル - 第4章: コンテンツアドレス型コードベース管理

この章では、XS言語の特徴的な機能であるコンテンツアドレス型コードベース管理をXS Shellを使って学びます。

```bash
$ cargo run --bin xsc -- shell
```

## コンテンツアドレス型とは

XS Shellでは、すべての式にハッシュ値が付きます。実際に確認してみましょう：

```
xs> 42
42 : Int
  [d2e88518]

xs> 42
42 : Int
  [d2e88518]
```

同じ式は常に同じハッシュ値を持ちます。関数も同様です：

```
xs> (fn (x) (* x 2))
<closure> : (-> t0 Int)
  [3f7a5c2d]

xs> (fn (x) (* x 2))
<closure> : (-> t0 Int)
  [3f7a5c2d]

xs> (fn (x) (+ x x))
<closure> : (-> Int Int)
  [8b9e1f4a]
```

最後の関数は異なる実装なので、異なるハッシュ値を持ちます。

## 履歴とハッシュ値

評価した式の履歴を見てみましょう：

```
xs> (let x 10)
x : Int = 10
  [1a2b3c4d]

xs> (+ x 5)
15 : Int
  [5e6f7g8h]

xs> (* x 3)
30 : Int
  [9i0j1k2l]

xs> history
[0] (let x 10)
[1] (+ x 5)
[2] (* x 3)
```

## 式に名前を付ける

ハッシュ値のプレフィックスを使って、過去の式に名前を付けることができます：

```
xs> (+ 20 22)
42 : Int
  [a1b2c3d4]

xs> name a1b2 answer
Named answer : Int = 42 [a1b2c3d4...]

xs> answer
42 : Int
  [a1b2c3d4]
```

関数にも名前を付けられます：

```
xs> (fn (x y) (+ (* x x) (* y y)))
<closure> : (-> Int (-> Int Int))
  [e5f6g7h8]

xs> name e5f6 sumOfSquares
Named sumOfSquares : (-> Int (-> Int Int)) = <closure> [e5f6g7h8...]

xs> (sumOfSquares 3 4)
25 : Int
  [i9j0k1l2]
```

## 定義の管理

現在の名前付き定義を確認：

```
xs> ls
x : Int = 10 [1a2b3c4d...]
answer : Int = 42 [a1b2c3d4...]
sumOfSquares : (-> Int (-> Int Int)) = <closure> [e5f6g7h8...]
```

## 関数の変更と追跡

関数を変更して、その影響を見てみましょう：

```
xs> (let double (fn (x) (* x 2)))
double : (-> Int Int) = <closure>
  [abc123...]

xs> (let quadruple (fn (x) (double (double x))))
quadruple : (-> Int Int) = <closure>
  [def456...]

xs> (quadruple 5)
20 : Int
  [ghi789...]
```

今度は`double`を変更してみます：

```
xs> (let double (fn (x) (+ x x)))
double : (-> Int Int) = <closure>
  [jkl012...]

xs> edits
Pending edits:
  ~ double : [abc123...] -> [jkl012...]
```

`edits`コマンドで、保留中の変更を確認できます。

## update - 変更のコミット

変更をコードベースに反映：

```
xs> update
Updated 1 definitions:
  ~ double

xs> (quadruple 5)
20 : Int
  [mno345...]
```

`quadruple`は自動的に新しい`double`を使うようになります。

## 実践的な例：ライブラリの構築

小さなリスト処理ライブラリを作ってみましょう：

```
xs> (rec map (f lst)
      (match lst
        ((list) (list))
        ((list h ... rest) (cons (f h) (map f rest)))))
map : (-> (-> t0 t1) (-> (List t0) (List t1))) = <rec-closure>
  [map123...]

xs> (rec filter (pred lst)
      (match lst
        ((list) (list))
        ((list h ... rest)
          (if (pred h)
              (cons h (filter pred rest))
              (filter pred rest)))))
filter : (-> (-> t0 Bool) (-> (List t0) (List t0))) = <rec-closure>
  [filter456...]

xs> (rec length (lst)
      (match lst
        ((list) 0)
        ((list _ ... rest) (+ 1 (length rest)))))
length : (-> (List t0) Int) = <rec-closure>
  [length789...]

xs> update
Updated 3 definitions:
  + map
  + filter
  + length
```

## XBinフォーマットへの保存

XS Shellを終了して、コマンドラインからXBinフォーマットに保存してみましょう：

```
xs> exit
Goodbye!

$ # まず、定義をファイルに保存
$ cat > mylib.xs << 'EOF'
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h ... rest) (cons (f h) (map f rest)))))

(rec filter (pred lst)
  (match lst
    ((list) (list))
    ((list h ... rest)
      (if (pred h)
          (cons h (filter pred rest))
          (filter pred rest)))))

(rec length (lst)
  (match lst
    ((list) 0)
    ((list _ ... rest) (+ 1 (length rest)))))

(let double (fn (x) (* x 2)))
(let isEven (fn (n) (= (% n 2) 0)))
EOF

$ # XBinフォーマットに変換
$ cargo run --bin xsc -- codebase store mylib.xs -o mylib.xbin
Storing codebase from mylib.xs to mylib.xbin
Processing file: mylib.xs
  Added: map
  Added: filter
  Added: length
  Added: double
  Added: isEven
Success: Stored 5 definitions
```

## XBinファイルのクエリ

保存した定義を確認：

```bash
$ cargo run --bin xsc -- codebase query mylib.xbin list
Terms:
  map [3349d127...]
  filter [82c4f652...]
  length [af3d2e89...]
  double [7892ab34...]
  isEven [1234abcd...]

Types:
```

依存関係を調べる：

```bash
$ cargo run --bin xsc -- codebase query mylib.xbin deps filter
Dependencies of filter:
  - cons (builtin)
  - if (builtin)

$ cargo run --bin xsc -- codebase query mylib.xbin dependents double
No dependents found for double
```

## 自動テスト生成

XBinファイルから自動的にテストを生成・実行：

```bash
$ cargo run --bin xsc -- codebase test mylib.xbin --verbosity 1
Generated 45 tests
PASS map_basic_0 - map
PASS map_basic_1 - map
PASS filter_basic_0 - filter
PASS filter_basic_1 - filter
PASS length_basic_0 - length
PASS length_basic_1 - length
PASS double_basic_0 - double
PASS double_basic_1 - double
PASS isEven_basic_0 - isEven
PASS isEven_basic_1 - isEven
... (more tests)

Test Summary:
  Total:       45
  Passed:      45 (100%)
  Failed:      0
  Timeout:     0
  Skipped:     0
  From cache:  0
  Total time:  52.3ms
```

## キャッシングの確認

もう一度同じテストを実行：

```bash
$ cargo run --bin xsc -- codebase test mylib.xbin --verbosity 1
Generated 45 tests
PASS map_basic_0 - map (cached)
PASS map_basic_1 - map (cached)
PASS filter_basic_0 - filter (cached)
... (all cached)

Test Summary:
  Total:       45
  Passed:      45 (100%)
  Failed:      0
  Timeout:     0
  Skipped:     0
  From cache:  45
  Total time:  3.2ms
  Cache hit rate: 100%
```

純粋関数のテスト結果はキャッシュされ、2回目の実行は非常に高速です。

## コードの更新と再テスト

関数を更新してみましょう：

```bash
$ cat > mylib-v2.xs << 'EOF'
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h ... rest) (cons (f h) (map f rest)))))

(rec filter (pred lst)
  (match lst
    ((list) (list))
    ((list h ... rest)
      (if (pred h)
          (cons h (filter pred rest))
          (filter pred rest)))))

(rec length (lst)
  (match lst
    ((list) 0)
    ((list _ ... rest) (+ 1 (length rest)))))

(let double (fn (x) (+ x x)))  ; 実装を変更
(let isEven (fn (n) (= (% n 2) 0)))
EOF

$ cargo run --bin xsc -- codebase store mylib-v2.xs -o mylib-v2.xbin
```

新しいバージョンをテスト：

```bash
$ cargo run --bin xsc -- codebase test mylib-v2.xbin --filter "double"
Generated 9 tests for double
PASS double_basic_0 - double
PASS double_basic_1 - double
... (all pass)
```

## 実践的なワークフロー

1. **XS Shellで開発**
   ```
   xs> (let myFunc (fn (x) ...))
   xs> (myFunc testData)  ; テスト
   xs> update
   ```

2. **XBinに保存**
   ```bash
   $ cargo run --bin xsc -- codebase store mycode.xs -o mycode.xbin
   ```

3. **自動テスト実行**
   ```bash
   $ cargo run --bin xsc -- codebase test mycode.xbin
   ```

4. **依存関係の確認**
   ```bash
   $ cargo run --bin xsc -- codebase query mycode.xbin deps myFunc
   ```

## 練習

以下を試してみましょう：

1. 簡単な数学関数ライブラリを作成し、XBinに保存
2. 自動テストを実行し、キャッシュの効果を確認
3. 関数の実装を変更し、テスト結果の変化を観察

## まとめ

この章では、コンテンツアドレス型コードベース管理について学びました：

- すべての式が持つハッシュ値
- XS Shellでの式の管理と名前付け
- 変更の追跡とupdate
- XBinフォーマットへの保存
- 自動テスト生成とキャッシング
- 依存関係の管理

この仕組みにより、コードの変更を正確に追跡し、安全にリファクタリングを行い、効率的にテストを実行できます。XS言語のコンテンツアドレス型システムは、特にAIがコードを理解し、変更を提案する際に大きな利点となります。

これでXS言語の基本的なチュートリアルは終了です。より詳しい情報は、リファレンスドキュメントやサンプルコードを参照してください。