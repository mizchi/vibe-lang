# XS Language TODO

## 実装済み機能

### 基本機能
- [x] S式パーサー
- [x] Hindley-Milner型推論
- [x] インタープリター
- [x] 再帰関数（`rec`構文）
- [x] CLI（parse, check, run コマンド）

### 基本型
- [x] プリミティブ型（Int, Bool, String, List）
- [x] 算術演算子（+, -, *, /）
- [x] 比較演算子（<, >, <=, >=, =）
- [x] リスト操作（list, cons）
- [x] 高階関数とクロージャ
- [x] if式
- [x] let/let-rec式
- [x] ラムダ式

### 高度な機能（基礎実装）
- [x] Salsaフレームワーク統合（インクリメンタルコンパイル）
- [x] Perceus IR層（基礎実装）
- [x] WebAssembly GCコードジェネレータ（基礎実装）
- [x] パターンマッチング
- [x] 代数的データ型（ADT）

## 実装予定機能

### 優先度：高
1. **モジュールシステム**
   ```lisp
   (module Math
     (export add sub)
     (define add ...))
   ```

### 優先度：中
4. **Perceus完全実装**
   - 参照カウント
   - drop/dup命令の自動挿入
   - reuse最適化

5. **WebAssembly GC完全実装**
   - 完全なWASMコード生成
   - GC命令の活用
   - 実行時性能検証

6. **標準ライブラリ**
   - String操作（concat, substring, etc）
   - List操作（map, filter, fold）
   - Option/Result型
   - 基本的なI/O

### 優先度：低
7. **エラーメッセージ改善**
   - より詳細なエラー位置情報
   - エラーリカバリ
   - 提案機能

8. **開発ツール**
   - REPL
   - デバッガ
   - LSP実装

9. **最適化**
   - インライン展開
   - 定数畳み込み
   - 末尾呼び出し最適化

## リファクタリング候補

### エラー処理
- [ ] `TypeScheme`と`Type`の統合
- [ ] エラーメッセージの一元管理

### インタープリター
- [ ] `Value::Closure`と`Value::RecClosure`の統合検討
- [ ] より効率的な`Environment`実装

### パーサー
- [ ] 重複コードの削減
- [ ] より一貫性のある`Span`使用

### テスト
- [ ] テストユーティリティの共通化
- [ ] プロパティベーステスト（quickcheck等）の導入
- [ ] ベンチマークスイートの追加

## 次のステップ

1. モジュールシステムの設計と実装
2. 標準ライブラリの基礎実装
3. Perceus GCの完全実装
4. WebAssembly GCの完全実装