-- ASTコマンドシステムのデモ
-- 
-- このファイルは、XS言語のASTコマンドシステムがどのように
-- コード変換を行うかを示すデモです。

-- 元のコード
calculateTotal items = 
  let sum = 0 in
  let i = 0 in
  let n = length items in
  if i < n {
    sum + (nth items i)
  } else {
    sum
  }

-- AST Command 1: Extract - 繰り返し処理を別関数に抽出
-- コマンド: Extract { target: [calculateTotal, body, if-expr], name: "sumLoop" }
-- 
-- 結果:
sumLoop items sum i n = 
  if i < n {
    sumLoop items (sum + (nth items i)) (i + 1) n
  } else {
    sum
  }

calculateTotal items =
  let sum = 0 in
  let i = 0 in
  let n = length items in
  sumLoop items sum i n

-- AST Command 2: Rename - 変数名の変更
-- コマンド: Rename { target: [sumLoop, param, "i"], newName: "index" }
-- 
-- 結果:
sumLoop items sum index n = 
  if index < n {
    sumLoop items (sum + (nth items index)) (index + 1) n
  } else {
    sum
  }

-- AST Command 3: Replace - より効率的な実装に置き換え
-- コマンド: Replace { target: [calculateTotal], newCode: "foldLeft (+) 0" }
-- 
-- 結果:
calculateTotal = foldLeft (+) 0

-- AST Command 4: Wrap - エラーハンドリングの追加
-- コマンド: Wrap { target: [calculateTotal], wrapper: "tryCatch", errorHandler: "fn _ -> 0" }
-- 
-- 結果:
calculateTotal items =
  tryCatch 
    (fn _ = foldLeft (+) 0 items)
    (fn _ = 0)

-- これらのコマンドは、XS言語の開発ツールが
-- コードの自動リファクタリングや最適化を
-- どのように支援できるかを示しています。