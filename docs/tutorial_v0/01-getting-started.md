# XS言語 チュートリアル - 第1章: はじめに

このチュートリアルでは、XS Shellを使って対話的にXS言語を学びます。実際にコードを入力しながら、一歩ずつ進めていきましょう。

## XS Shellの起動

まず、ターミナルでXS Shellを起動します：

```bash
$ cargo run --bin xsc -- shell
```

次のようなプロンプトが表示されます：

```
XS Language Shell v0.1.0
Type 'help' for available commands, or expressions to evaluate.
xs> 
```

## 最初の一歩：簡単な計算

XS Shellに式を入力してEnterを押すと、すぐに評価されます。

```
xs:scratch> 42
42 : Int
  [a5b2c3d4]

xs:scratch> (+ 1 2)
3 : Int
  [e7f8g9h0]
```

注意: プロンプトは `xs:scratch>` と表示されます。`scratch` はデフォルトの名前空間です。

各結果の後に表示される `[a5b2c3d4]` のような文字列は、その式のハッシュ値です。XS言語では、すべての式が内容に基づいたハッシュ値を持ちます。

## 基本的な値を試してみよう

### 数値

```
xs:scratch> 100
100 : Int
  [hash...]

xs:scratch> -42
-42 : Int
  [hash...]

xs:scratch> 3.14
3.14 : Float
  [hash...]
```

### 文字列

```
xs:scratch> "Hello, XS!"
"Hello, XS!" : String
  [hash...]

xs:scratch> "日本語も使えます"
"日本語も使えます" : String
  [hash...]
```

### ブーリアン

```
xs:scratch> true
true : Bool
  [hash...]

xs:scratch> false
false : Bool
  [hash...]
```

## 基本的な演算

### 算術演算

```
xs> (+ 10 20)
30 : Int
  [hash...]

xs> (* 6 7)
42 : Int
  [hash...]

xs> (- 100 58)
42 : Int
  [hash...]

xs> (/ 84 2)
42 : Int
  [hash...]
```

### 比較演算

```
xs> (> 5 3)
true : Bool
  [hash...]

xs> (= 10 10)
true : Bool
  [hash...]

xs> (!= 5 5)
false : Bool
  [hash...]
```

## 変数の定義

`let`を使って変数を定義できます：

```
xs> (let x 10)
x : Int = 10
  [hash1234]

xs> x
10 : Int
  [hash5678]

xs> (+ x 5)
15 : Int
  [hash9012]
```

### 型注釈を付ける

型を明示的に指定することもできます：

```
xs> (let message: String "Hello from XS")
message : String = "Hello from XS"
  [hash...]

xs> (let pi: Float 3.14159)
pi : Float = 3.14159
  [hash...]
```

## 関数の定義

関数は`fn`を使って定義します：

```
xs:scratch> (let double (fn (x) (* x 2)))
double : (-> Int Int) = <closure>
  [hashABCD]
```

### 関数の呼び出し

関数を呼び出すには、2つの方法があります：

1. **S式形式**（従来の方法）：
```
xs:scratch> (double 21)
42 : Int
  [hashEFGH]
```

2. **シェル形式**（括弧なし）：
```
xs:scratch> double 21
42 : Int
  [hashEFGH]
```

括弧も引数もない場合は、関数そのものを参照します：

```
xs:scratch> double
<closure> : (-> Int Int)
  [hashABCD]
```

型注釈を付けた関数：

```
xs:scratch> (let add (fn (x: Int y: Int) (+ x y)))
add : (-> Int (-> Int Int)) = <closure>
  [hashIJKL]

xs:scratch> (add 10 32)
42 : Int
  [hashMNOP]

xs:scratch> add 10 32  
42 : Int
  [hashMNOP]
```

シェル形式では、複数の引数も自然に書けます。

## カリー化と部分適用

XS言語の関数は自動的にカリー化されます：

```
xs> (let multiply (fn (x y) (* x y)))
multiply : (-> t0 (-> t1 Int)) = <closure>
  [hash...]

xs> (let double (multiply 2))
double : (-> t0 Int) = <closure>
  [hash...]

xs> (double 21)
42 : Int
  [hash...]

xs> (let triple (multiply 3))
triple : (-> t0 Int) = <closure>
  [hash...]

xs> (triple 14)
42 : Int
  [hash...]
```

## ローカル変数（letIn）

`let ... in`を使ってローカル変数を定義できます：

```
xs> (let x 5 in (+ x 10))
15 : Int
  [hash...]

xs> x
Error: Undefined variable 'x'
```

`x`はローカルスコープ内でのみ有効です。

ネストした`letIn`：

```
xs> (let x 10 in 
      (let y 20 in 
        (+ x y)))
30 : Int
  [hash...]
```

## 条件分岐

`if`式を使った条件分岐：

```
xs> (if (> 5 3) "大きい" "小さい")
"大きい" : String
  [hash...]

xs> (let age 20)
age : Int = 20
  [hash...]

xs> (if (>= age 18) "成人" "未成年")
"成人" : String
  [hash...]
```

## リスト

リストの作成：

```
xs> (list)
(list) : (List t0)
  [hash...]

xs> (list 1 2 3 4 5)
(list 1 2 3 4 5) : (List Int)
  [hash...]

xs> (list "apple" "banana" "orange")
(list "apple" "banana" "orange") : (List String)
  [hash...]
```

## XS Shellのコマンド

作業中に使える便利なコマンド：

```
xs> help
Available commands:
  help              Show this help message
  history [n]       Show last n entries (default 10)
  ls                List all named expressions
  name <hash> <id>  Name an expression by hash prefix
  clear             Clear the screen
  exit              Exit the shell

xs> history 5
[0] 42
[1] (+ 1 2)
[2] (let x 10)
[3] x
[4] (+ x 5)

xs> ls
x : Int = 10 [hash1234...]
double : (-> t0 Int) = <closure> [hashABCD...]
add : (-> Int (-> Int Int)) = <closure> [hashIJKL...]
```

## 式に名前を付ける

ハッシュ値を使って過去の式に名前を付けることができます：

```
xs> (* 7 6)
42 : Int
  [a1b2c3d4]

xs> name a1b2 answer
Named answer : Int = 42 [a1b2c3d4...]

xs> answer
42 : Int
  [a1b2c3d4]
```

## エラーメッセージ

XS言語は分かりやすいエラーメッセージを提供します：

```
xs> (+ "hello" 42)
Type error: Cannot unify String with Int
Suggestions:
  - Convert string to int using 'strToInt'
  - Convert int to string using 'intToString'

xs> (/ 10 0)
Runtime error: Division by zero

xs> undefined_variable
Error: Undefined variable 'undefined_variable'
Did you mean one of these?
  - double
  - triple
```

## 練習

以下の演習を試してみましょう：

1. 摂氏温度を華氏温度に変換する関数を定義してください
   - ヒント: F = C × 1.8 + 32

2. 数値が偶数かどうかを判定する関数を定義してください
   - ヒント: `%`演算子（剰余）を使います

3. 2つの数値の大きい方を返す関数を定義してください

解答例：

```
xs> (let celsiusToFahrenheit (fn (c) (+ (* c 1.8) 32.0)))
xs> (celsiusToFahrenheit 0.0)
32.0 : Float

xs> (let isEven (fn (n) (= (% n 2) 0)))
xs> (isEven 4)
true : Bool

xs> (let max (fn (a b) (if (> a b) a b)))
xs> (max 10 20)
20 : Int
```

## セッションの保存

作業を終了する前に、定義した関数を保存できます：

```
xs> update
Updated 5 definitions:
  + x
  + double  
  + add
  + celsiusToFahrenheit
  + isEven

xs> exit
Goodbye!
```

## まとめ

この章では、XS Shellを使って以下を学びました：

- 基本的な値と型（数値、文字列、ブーリアン、リスト）
- 変数と関数の定義
- カリー化と部分適用
- 条件分岐
- XS Shellの便利なコマンド

次章では、パターンマッチングについて学びます。XS Shellを開いたまま、続けて進めることができます。