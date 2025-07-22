# XS言語 名前空間システム設計

## 概要

XS言語にUnison UCMライクな名前空間システムを実装します。このシステムは、関数単位でのコンテンツアドレス管理、依存関係追跡、インクリメンタルな型チェックとテスト実行を可能にします。

## 主要概念

### 1. 名前空間 (Namespace)
- 階層的な名前空間構造（例：`List.map`、`String.utils.capitalize`）
- 各名前空間は関数、型、サブ名前空間を含む
- ドット記法でアクセス

### 2. コンテンツアドレス
- すべての定義は内容のハッシュで一意に識別される
- 同じ定義は常に同じハッシュを持つ（決定論的）
- 名前は単にハッシュへのエイリアス

### 3. 依存関係グラフ
- 各定義は依存する他の定義のハッシュを記録
- 依存関係は推移的に追跡される
- 循環依存は禁止

## データ構造

```rust
// 名前空間の定義
struct Namespace {
    name: String,
    parent: Option<NamespaceId>,
    definitions: HashMap<String, DefinitionHash>,
    subnamespaces: HashMap<String, NamespaceId>,
}

// 定義のメタデータ
struct Definition {
    hash: DefinitionHash,
    content: DefinitionContent,
    dependencies: HashSet<DefinitionHash>,
    type_signature: Type,
    metadata: DefinitionMetadata,
}

enum DefinitionContent {
    Function(Expr),
    Type(TypeDefinition),
    Value(Value),
}

struct DefinitionMetadata {
    created_at: Timestamp,
    author: String,
    documentation: Option<String>,
    tests: Vec<TestHash>,
}
```

## 主要操作

### 1. add - 新しい定義を追加
```lisp
; 名前空間に新しい関数を追加
(namespace Math.utils
  (add fibonacci (fn (n)
    (if (<= n 1)
        n
        (+ (fibonacci (- n 1))
           (fibonacci (- n 2)))))))
```

### 2. update - 既存の定義を更新
```lisp
; 既存の定義を新しい実装で置き換え
(namespace Math.utils
  (update fibonacci (fn (n)
    ; 最適化されたバージョン
    (fibTail n 0 1))))
```

### 3. move - 定義を別の名前空間に移動
```lisp
(move Math.utils.fibonacci Math.algorithms.fibonacci)
```

### 4. alias - 定義に別名を付ける
```lisp
(alias Math.utils.fibonacci fib)
```

### 5. delete - 名前を削除（定義自体は残る）
```lisp
(delete Math.utils.oldFunction)
```

## ASTコマンドシステム

コード変更を表現するコマンドの集合：

```rust
enum AstCommand {
    // 定義の追加
    AddDefinition {
        namespace: NamespacePath,
        name: String,
        definition: Expr,
    },
    
    // 定義の更新
    UpdateDefinition {
        path: DefinitionPath,
        new_definition: Expr,
    },
    
    // 定義の移動
    MoveDefinition {
        from: DefinitionPath,
        to: DefinitionPath,
    },
    
    // エイリアスの作成
    CreateAlias {
        target: DefinitionPath,
        alias: DefinitionPath,
    },
    
    // 名前の削除
    DeleteName {
        path: DefinitionPath,
    },
    
    // リファクタリング
    RenameDefinition {
        from: String,
        to: String,
        scope: NamespacePath,
    },
}
```

## インクリメンタル処理

### 1. 型チェック
- 変更された定義とその依存関係のみを再チェック
- 型情報はキャッシュされ、変更がない限り再利用

### 2. テスト実行
- 変更された定義に関連するテストのみを実行
- テスト結果はハッシュに基づいてキャッシュ

### 3. 依存関係の更新
- 定義が変更されると、それに依存するすべての定義を特定
- 必要に応じて再コンパイル/再チェック

## 実装計画

### フェーズ1: 基本的な名前空間
1. 名前空間データ構造の実装
2. 基本的なadd/update/delete操作
3. ドット記法による名前解決

### フェーズ2: コンテンツアドレス
1. 定義のハッシュ計算
2. ハッシュベースの依存関係追跡
3. 定義の永続化

### フェーズ3: インクリメンタル処理
1. 差分型チェッカー
2. 差分テストランナー
3. 依存関係グラフの効率的な更新

### フェーズ4: 高度な機能
1. パッチ（複数の変更をまとめる）
2. ブランチとマージ
3. リモートコードベースとの同期

## 使用例

```lisp
; 名前空間の作成と使用
(namespace MyApp.Utils)

; 関数の追加
(add capitalize (fn (s)
  (strConcat (toUpper (stringAt s 0))
             (stringSlice s 1 (stringLength s)))))

; 別の名前空間から使用
(namespace MyApp.Main)
(import MyApp.Utils (capitalize))

(let main (fn ()
  (print (capitalize "hello"))))  ; "Hello"

; 関数の更新（依存関係は自動的に再チェック）
(namespace MyApp.Utils)
(update capitalize (fn (s)
  (if (= (stringLength s) 0)
      s
      (strConcat (toUpper (stringAt s 0))
                 (stringSlice s 1 (stringLength s))))))
```

## 利点

1. **バージョン管理不要**: コンテンツアドレスにより、すべてのバージョンが自動的に保持される
2. **安全なリファクタリング**: 依存関係が追跡されるため、変更の影響が明確
3. **効率的な開発**: インクリメンタル処理により、大規模コードベースでも高速
4. **AIフレンドリー**: 明確な依存関係とコマンドベースの変更により、AIが理解・操作しやすい

## 考慮事項

1. **メモリ使用量**: すべてのバージョンを保持するため、適切なガベージコレクションが必要
2. **パフォーマンス**: 依存関係グラフの効率的な実装が重要
3. **互換性**: 既存のモジュールシステムとの統合方法