;; XS Language Parser Implementation
;; トークンリストからASTを構築

(module Parser
  (export parse parseExpr Expr)
  (import Lexer)
  (import StringUtils)
  (import Pair)
  
  ;; AST (Abstract Syntax Tree) の定義
  (type Expr
    (IntLit Int)
    (FloatLit Float)
    (StringLit String)
    (Symbol String)
    (List (list Expr))
    (Let String Expr)
    (LetRec String (list String) Expr)
    (Lambda (list String) Expr)
    (If Expr Expr Expr)
    (Apply Expr (list Expr))
    (Match Expr (list MatchCase))
    (Module String (list String) (list Expr)))
  
  ;; パターンマッチのケース
  (type MatchCase
    (MatchCase Pattern Expr))
  
  ;; パターン
  (type Pattern
    (PatVar String)
    (PatLit Expr)
    (PatList (list Pattern))
    (PatWildcard))
  
  ;; パーサーの状態
  (type ParseState
    (ParseState (list Token) Int))  ; tokens, current position
  
  ;; 文字列をパースしてASTを返す
  (let parse (fn (input)
    (let tokens (Lexer.tokenize input) in
      (let state (ParseState tokens 0) in
        (match (parseExpr state)
          ((pair expr newState) expr))))))
  
  ;; 式をパース
  (rec parseExpr (state)
    (match state
      ((ParseState tokens pos)
        (if (>= pos (length tokens))
            (error "Unexpected end of input")
            (let token (nth tokens pos) in
              (match token
                ((Token (LParen) _ _)
                  (parseList state))
                ((Token (IntLit n) _ _)
                  (pair (IntLit n) (ParseState tokens (+ pos 1))))
                ((Token (FloatLit f) _ _)
                  (pair (FloatLit f) (ParseState tokens (+ pos 1))))
                ((Token (StringLit s) _ _)
                  (pair (StringLit s) (ParseState tokens (+ pos 1))))
                ((Token (Symbol sym) _ _)
                  (pair (Symbol sym) (ParseState tokens (+ pos 1))))
                ((Token (Comment _) _ _)
                  (parseExpr (ParseState tokens (+ pos 1))))
                ((Token (RParen) _ _)
                  (error "Unexpected closing parenthesis"))
                ((Token (EOF) _ _)
                  (error "Unexpected end of file"))))))))
  
  ;; リスト（S式）をパース
  (rec parseList (state)
    (match state
      ((ParseState tokens pos)
        (let state1 (ParseState tokens (+ pos 1)) in  ; Skip '('
          (let result (parseListElements state1 (list)) in
            (match result
              ((pair elements finalState)
                (parseSpecialForm elements finalState))))))))
  
  ;; リストの要素をパース
  (rec parseListElements (state acc)
    (match state
      ((ParseState tokens pos)
        (if (>= pos (length tokens))
            (error "Unclosed list")
            (let token (nth tokens pos) in
              (match token
                ((Token (RParen) _ _)
                  (pair (reverse acc) (ParseState tokens (+ pos 1))))
                (_
                  (let result (parseExpr state) in
                    (match result
                      ((pair expr newState)
                        (parseListElements newState (cons expr acc))))))))))))
  
  ;; 特殊形式をチェック
  (rec parseSpecialForm (elements state)
    (match elements
      ((list) (pair (List (list)) state))
      ((list (Symbol "let") (Symbol name) value)
        (pair (Let name value) state))
      ((list (Symbol "rec") (Symbol name) params body)
        (pair (LetRec name (extractParams params) body) state))
      ((list (Symbol "fn") params body)
        (pair (Lambda (extractParams params) body) state))
      ((list (Symbol "if") cond then else)
        (pair (If cond then else) state))
      ((list (Symbol "match") expr cases)
        (pair (Match expr (parseMatchCases cases)) state))
      ((list (Symbol "module") (Symbol name) exports body)
        (pair (Module name (extractExports exports) (extractBody body)) state))
      ((list fn args)
        (pair (Apply fn args) state))
      (elements
        (pair (List elements) state))))
  
  ;; パラメータリストを抽出
  (rec extractParams (expr)
    (match expr
      ((List params) (map extractSymbol params))
      (_ (error "Invalid parameter list"))))
  
  ;; シンボルを抽出
  (rec extractSymbol (expr)
    (match expr
      ((Symbol s) s)
      (_ (error "Expected symbol in parameter list"))))
  
  ;; エクスポートリストを抽出
  (rec extractExports (expr)
    (match expr
      ((List exports) (map extractSymbol exports))
      (_ (error "Invalid export list"))))
  
  ;; モジュール本体を抽出
  (rec extractBody (expr)
    (match expr
      ((List body) body)
      (_ (list expr))))
  
  ;; マッチケースをパース（簡易版）
  (rec parseMatchCases (cases)
    (match cases
      ((List caseList) (map parseMatchCase caseList))
      (_ (error "Invalid match cases"))))
  
  ;; 個別のマッチケースをパース
  (rec parseMatchCase (caseExpr)
    (match caseExpr
      ((List (list pattern expr))
        (MatchCase (parsePattern pattern) expr))
      (_ (error "Invalid match case"))))
  
  ;; パターンをパース
  (rec parsePattern (pattern)
    (match pattern
      ((Symbol "_") (PatWildcard))
      ((Symbol s) (PatVar s))
      ((IntLit n) (PatLit (IntLit n)))
      ((StringLit s) (PatLit (StringLit s)))
      ((List patterns) (PatList (map parsePattern patterns)))
      (_ (error "Invalid pattern"))))
  
  ;; ヘルパー関数: リストのn番目の要素
  (rec nth (lst n)
    (match lst
      ((list) (error "Index out of bounds"))
      ((list h t)
        (if (= n 0)
            h
            (nth t (- n 1))))))
  
  ;; ヘルパー関数: リストを逆順に
  (rec reverse (lst)
    (reverseAcc lst (list)))
  
  (rec reverseAcc (lst acc)
    (match lst
      ((list) acc)
      ((list h t) (reverseAcc t (cons h acc)))))
  
  ;; ヘルパー関数: map
  (rec map (f lst)
    (match lst
      ((list) (list))
      ((list h t) (cons (f h) (map f t))))))