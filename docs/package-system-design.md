# Vibe Package System Design

## 概要
Vibe言語のパッケージシステムは、コンテンツアドレス型の特性を活かした革新的なアプローチを採用します。

## パッケージマニフェスト (package.vibe)

```vibe
# パッケージメタデータ
package {
  name: "web-framework"
  author: "vibe-community"
  license: "MIT"
  description: "A fast web framework for Vibe"
}

# 依存関係（ハッシュベース）
dependencies {
  # 名前はローカルでのエイリアス、ハッシュが実際の識別子
  http: #a3f2b1c4d5e6f7890
  json: #b4c5d6e7f8901234a
  router: #c5d6e7f890123456b
}

# エクスポートする定義
exports {
  # 公開API
  createServer
  route
  middleware
  Response
  Request
}

# エントリーポイント
entry {
  main: "src/main.vibe"
  lib: "src/lib.vibe"
}
```

## パッケージの識別

1. **コンテンツハッシュ**: パッケージ全体のSHA256ハッシュ
2. **セマンティックバージョン**: 人間のための参考情報
3. **名前**: 検索とローカル参照用

## 依存関係解決

```vibe
# 依存関係グラフの例
Package A (#abc123)
  ├── http (#def456)
  │   └── socket (#ghi789)
  └── json (#jkl012)
      └── parser (#mno345)

# 同じコードは同じハッシュなので、重複なし
Package B (#xyz999)
  ├── http (#def456)  # Aと同じ実装を共有
  └── database (#pqr678)
```

## ローカルキャッシュ

```
~/.vibe/cache/
  ├── packages/
  │   ├── a3f2b1c4d5e6f7890/  # パッケージコンテンツ
  │   ├── b4c5d6e7f8901234a/
  │   └── c5d6e7f890123456b/
  └── metadata/
      └── registry.json  # パッケージメタデータのインデックス
```

## レジストリプロトコル

```vibe
# パッケージの公開
vpm publish

# パッケージの取得
vpm install http#a3f2b1c4d5e6f7890

# 名前での検索（最新の安定版を取得）
vpm search web-framework

# 特定バージョンの取得
vpm install web-framework@2.1.0
```

## 利点

1. **完全な再現性**: ハッシュが同じなら必ず同じコード
2. **効率的なストレージ**: 重複コードなし
3. **セキュリティ**: 改ざん不可能
4. **並列インストール**: 依存関係の競合なし
5. **AI最適化**: AIが最適な実装を選択可能

## 実装計画

1. パッケージフォーマットの定義
2. ハッシュ計算アルゴリズム
3. 依存関係解決エンジン
4. ローカルキャッシュマネージャー
5. レジストリサーバー（分散型対応）
6. CLIツール (vpm)