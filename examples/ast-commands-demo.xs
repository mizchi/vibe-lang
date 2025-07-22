; ASTコマンドシステムのデモ
; 
; このファイルは、XS言語のASTコマンドシステムがどのように
; コード変換を行うかを示すデモです。

; 元のコード
(let calculateTotal (fn (items)
  (let sum 0)
  (let i 0)
  (let n (length items))
  (if (< i n)
      (+ sum (nth items i))
      sum)))

; AST Command 1: Extract - 繰り返し処理を別関数に抽出
; コマンド: Extract { target: [calculateTotal, body, if-expr], name: "sumLoop" }
; 
; 結果:
(let sumLoop (fn (items sum i n)
  (if (< i n)
      (sumLoop items (+ sum (nth items i)) (+ i 1) n)
      sum)))

(let calculateTotal (fn (items)
  (sumLoop items 0 0 (length items))))

; AST Command 2: Rename - 変数名を分かりやすく変更
; コマンド: Rename { scope: [sumLoop], old: "i", new: "index" }
;
; 結果:
(let sumLoop (fn (items sum index n)
  (if (< index n)
      (sumLoop items (+ sum (nth items index)) (+ index 1) n)
      sum)))

; AST Command 3: RefactorToLetIn - 複数のletをlet-inに変換
; コマンド: RefactorToLetIn { target: [processData, body], count: 3 }
;
; 変換前:
(let processData (fn (data)
  (let cleaned (cleanData data))
  (let normalized (normalize cleaned))
  (let result (analyze normalized))
  result))

; 変換後:
(let processData (fn (data)
  (let cleaned (cleanData data) in
    (let normalized (normalize cleaned) in
      (let result (analyze normalized) in
        result)))))

; AST Command 4: ConvertFunction - 関数スタイルの変換
; コマンド: ConvertFunction { target: [add], style: Curried }
;
; 変換前:
(let add (fn (x y) (+ x y)))

; 変換後:
(let add (fn (x) (fn (y) (+ x y))))

; AST Command 5: TransformMatch - パターンマッチの変換
; コマンド: TransformMatch { target: [handleOption], transformation: AddCase {...} }
;
; 変換前:
(let handleOption (fn (opt)
  (match opt
    ((None) 0)
    ((Some x) x))))

; 変換後（デフォルトケース追加）:
(let handleOption (fn (opt)
  (match opt
    ((None) 0)
    ((Some x) x)
    (_ (error "Invalid option")))))

; AST Command 6: Wrap - 式をラップ
; コマンド: Wrap { target: [debugValue], wrapper: Let { name: "logged", type: Int } }
;
; 変換前:
(+ x 1)

; 変換後:
(let logged (+ x 1))

; AST Command 7: Inline - 定義をインライン化
; コマンド: Inline { definition: Math.square }
;
; 変換前:
(let result (Math.square 5))

; 変換後:
(let result ((fn (x) (* x x)) 5))

; AST Command 8: Move - 式を移動
; コマンド: Move { source: [func1, let-x], destination: [func2, body], position: AtStart }
;
; これらのコマンドにより、AIやツールは構造的で安全な
; コード変換を実行できます。各コマンドは型チェックされ、
; 依存関係が追跡されるため、変更の影響を正確に把握できます。