;; XS Language Parser Implementation
;; トークンリストからASTを構築

(module Parser
  (export parse parse-expr Expr)
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
        (match (parse-expr state)
          ((pair expr new-state) expr))))))
  
  ;; 式をパース
  (rec parse-expr (state)
    (match state
      ((ParseState tokens pos)
        (if (>= pos (length tokens))
            (error "Unexpected end of input")
            (let token (nth tokens pos) in
              (match token
                ((Token (LParen) _ _)
                  (parse-list state))
                ((Token (IntLit n) _ _)
                  (pair (IntLit n) (ParseState tokens (+ pos 1))))
                ((Token (FloatLit f) _ _)
                  (pair (FloatLit f) (ParseState tokens (+ pos 1))))
                ((Token (StringLit s) _ _)
                  (pair (StringLit s) (ParseState tokens (+ pos 1))))
                ((Token (Symbol sym) _ _)
                  (pair (Symbol sym) (ParseState tokens (+ pos 1))))
                ((Token (Comment _) _ _)
                  (parse-expr (ParseState tokens (+ pos 1))))
                ((Token (RParen) _ _)
                  (error "Unexpected closing parenthesis"))
                ((Token (EOF) _ _)
                  (error "Unexpected end of file"))))))))
  
  ;; リスト（S式）をパース
  (rec parse-list (state)
    (match state
      ((ParseState tokens pos)
        (let state1 (ParseState tokens (+ pos 1)) in  ; Skip '('
          (let result (parse-list-elements state1 (list)) in
            (match result
              ((pair elements final-state)
                (parse-special-form elements final-state))))))))
  
  ;; リストの要素をパース
  (rec parse-list-elements (state acc)
    (match state
      ((ParseState tokens pos)
        (if (>= pos (length tokens))
            (error "Unclosed list")
            (let token (nth tokens pos) in
              (match token
                ((Token (RParen) _ _)
                  (pair (reverse acc) (ParseState tokens (+ pos 1))))
                (_
                  (let result (parse-expr state) in
                    (match result
                      ((pair expr new-state)
                        (parse-list-elements new-state (cons expr acc))))))))))))
  
  ;; 特殊形式をチェック
  (rec parse-special-form (elements state)
    (match elements
      ((list) (pair (List (list)) state))
      ((list (Symbol "let") (Symbol name) value)
        (pair (Let name value) state))
      ((list (Symbol "rec") (Symbol name) params body)
        (pair (LetRec name (extract-params params) body) state))
      ((list (Symbol "fn") params body)
        (pair (Lambda (extract-params params) body) state))
      ((list (Symbol "if") cond then else)
        (pair (If cond then else) state))
      ((list (Symbol "match") expr cases)
        (pair (Match expr (parse-match-cases cases)) state))
      ((list (Symbol "module") (Symbol name) exports body)
        (pair (Module name (extract-exports exports) (extract-body body)) state))
      ((list fn args)
        (pair (Apply fn args) state))
      (elements
        (pair (List elements) state))))
  
  ;; パラメータリストを抽出
  (rec extract-params (expr)
    (match expr
      ((List params) (map extract-symbol params))
      (_ (error "Invalid parameter list"))))
  
  ;; シンボルを抽出
  (rec extract-symbol (expr)
    (match expr
      ((Symbol s) s)
      (_ (error "Expected symbol in parameter list"))))
  
  ;; エクスポートリストを抽出
  (rec extract-exports (expr)
    (match expr
      ((List exports) (map extract-symbol exports))
      (_ (error "Invalid export list"))))
  
  ;; モジュール本体を抽出
  (rec extract-body (expr)
    (match expr
      ((List body) body)
      (_ (list expr))))
  
  ;; マッチケースをパース（簡易版）
  (rec parse-match-cases (cases)
    (match cases
      ((List case-list) (map parse-match-case case-list))
      (_ (error "Invalid match cases"))))
  
  ;; 個別のマッチケースをパース
  (rec parse-match-case (case-expr)
    (match case-expr
      ((List (list pattern expr))
        (MatchCase (parse-pattern pattern) expr))
      (_ (error "Invalid match case"))))
  
  ;; パターンをパース
  (rec parse-pattern (pattern)
    (match pattern
      ((Symbol "_") (PatWildcard))
      ((Symbol s) (PatVar s))
      ((IntLit n) (PatLit (IntLit n)))
      ((StringLit s) (PatLit (StringLit s)))
      ((List patterns) (PatList (map parse-pattern patterns)))
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
    (reverse-acc lst (list)))
  
  (rec reverse-acc (lst acc)
    (match lst
      ((list) acc)
      ((list h t) (reverse-acc t (cons h acc)))))
  
  ;; ヘルパー関数: map
  (rec map (f lst)
    (match lst
      ((list) (list))
      ((list h t) (cons (f h) (map f t))))))