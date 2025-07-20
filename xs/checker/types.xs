;; Type definitions for the XS type checker

(module Types
  (export Type TypeScheme TypeEnv type-var mono poly instantiate)
  
  ;; 型の定義
  (type Type
    (TInt)
    (TFloat)
    (TBool)
    (TString)
    (TList Type)
    (TFunction Type Type)
    (TVar String)
    (TUserDefined String (list Type)))
  
  ;; 型スキーム（多相型）
  (type TypeScheme
    (Mono Type)
    (Poly (list String) Type))
  
  ;; 型環境
  (type TypeEnv
    (TypeEnv (list (pair String TypeScheme))))
  
  ;; 新しい型変数を生成
  (let type-var-counter (ref 0))
  
  (let type-var (fn ()
    (let n (deref type-var-counter) in
      (do
        (set! type-var-counter (+ n 1))
        (TVar (string-concat "t" (int-to-string n)))))))
  
  ;; 単相型スキームを作成
  (let mono (fn (t) (Mono t)))
  
  ;; 多相型スキームを作成
  (let poly (fn (vars t) (Poly vars t)))
  
  ;; 型スキームをインスタンス化
  (rec instantiate (scheme)
    (match scheme
      ((Mono t) t)
      ((Poly vars t)
        (let subst (make-subst vars) in
          (apply-subst subst t)))))
  
  ;; 型変数の置換を作成
  (rec make-subst (vars)
    (match vars
      ((list) (list))
      ((list v vs)
        (cons (pair v (type-var))
              (make-subst vs)))))
  
  ;; 置換を型に適用
  (rec apply-subst (subst t)
    (match t
      ((TInt) (TInt))
      ((TFloat) (TFloat))
      ((TBool) (TBool))
      ((TString) (TString))
      ((TList elem-type)
        (TList (apply-subst subst elem-type)))
      ((TFunction from to)
        (TFunction (apply-subst subst from)
                   (apply-subst subst to)))
      ((TVar v)
        (match (lookup v subst)
          ((Some new-type) new-type)
          ((None) (TVar v))))
      ((TUserDefined name args)
        (TUserDefined name (map (fn (t) (apply-subst subst t)) args)))))
  
  ;; 環境から型を検索
  (rec lookup (key alist)
    (match alist
      ((list) (None))
      ((list (pair k v) rest)
        (if (string-eq k key)
            (Some v)
            (lookup key rest)))))
  
  ;; Option型の定義（標準ライブラリにあるはずだが、ここで定義）
  (type Option a
    (Some a)
    (None))
  
  ;; 参照型の簡易実装（実際にはビルトインが必要）
  (let ref (fn (x) (list x)))
  (let deref (fn (r) (car r)))
  (let set! (fn (r v) (set-car! r v))))