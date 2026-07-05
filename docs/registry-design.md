# パッケージレジストリ設計 (ADR-0065 Phase 5, #755)

vibe のパッケージ配布は「**require pin (content hash) が唯一の真実**」を不変条件
にする (ADR-0063 §5)。ビルドは resolver レス・オフラインで全 edge を hash 再検証
するので、**ネットワークへの信頼は add / update の一瞬に局所化**されている。
レジストリはこの一瞬を守る装置であって、信頼の根ではない。

この文書は、実装済みの Phase 0 (レジストリなしの git 直接解決) と、レジストリ
本体 (Phase 1+) の設計を記録する。

## Phase 0 — git/GitHub 直接解決 (実装済み, #755)

レジストリが存在しなくても、hash pin があれば任意の transport は信頼不要になる。
`scripts/vibe_pkg.sh add` はそれを git に対して実装したもの:

```
vibe_pkg.sh add github:owner/repo[/sub/dir]@<ref> [#pkg:sha1:<40hex>] [--store]
vibe_pkg.sh add git:<url>@<ref>[#<sub/dir>]       [#pkg:sha1:<40hex>] [--store]
```

- **fetch**: `github:` は `https://github.com/owner/repo.git` への sugar。ref は
  git fetch で **commit に解決**され (`FETCH_HEAD`)、shallow を拒否するサーバには
  full fetch で 1 回だけ再試行する
- **hash はローカル計算**: 取得したソースに対して package hash
  (`pkg:sha1:` — package 相対 path の merkle) を手元の compiler で計算する。
  transport (GitHub / ミラー / 手渡し) は構造的に信頼対象にならない
- **expected pin**: 引数で pin を渡すと、**cache/install の副作用が起きる前に**
  照合し、不一致は拒否。pin を渡さない初回は **trust-on-first-use** — hash を
  表示し `versions.tsv` に記録する
- **version→hash 不変性**: 記録済み name@version と異なる hash を返す fetch は
  拒否 (上流の同一 version 差し替え・改竄はここで落ちる)。#754 の publish /
  install と同じ記録を共有する
- **provenance**: `$VIBE_HOME/cache/provenance.tsv` に
  `name@version → hash → source spec → commit` を追記。package hash はソース
  merkle なので、第三者は spec@commit を checkout して hash を再計算するだけで
  再現検証できる (SLSA 系 build provenance の source-only 版)
- 取得物は `$VIBE_HOME/cache/pkg/sha1/<hex>/` (受動 CAS) に置かれ、
  `$VIBE_HOME/lib/<name>/` (VIBE_LIB デフォルト root, #751) または
  `.vibe/store/<name>/` へ materialize される

検証: gate 6k (hermetic な file:// repo で TOFU / pin 照合 / 副作用なし拒否 /
同一 version 改竄拒否 / build&run の E2E)。

### Phase 0 の限界 (= レジストリが埋めるもの)

1. **名前の発見と一意性がない**: name → source spec の対応は利用者の手元にしか
   ない。同名パッケージを別 repo が名乗れる (pin があれば実害は「ビルドが
   落ちる」まで — 差し替えは成功しないが、混乱はする)
2. **TOFU の初回が無防備**: 初回 add の hash が正しいかは検証手段がない
3. **version の全体一貫性がない**: 自分の versions.tsv は自分しか守らない。
   「クライアント別に異なる hash を返す」standing attack は各自の記録でしか
   検出できない

## Phase 1+ — レジストリ本体 (設計)

レジストリの役割は **name@version → hash の全世界一貫なマッピングの公証**。
パッケージ本体の配送は CAS なので、どこから取ってもよい (レジストリは
ソースの置き場所を「指す」だけでもよい — Phase 0 の provenance がそのまま
配送レイヤになれる)。

### 必須要件 (ADR-0065 で決定済み) と設計方針

1. **Transparency log** — publish は (scope, name, version, package_hash,
   provenance) を append-only Merkle log に記録する (Go sumdb / sigstore rekor
   方式)。クライアントは (a) lookup 結果の inclusion proof、(b) log の
   consistency proof (STH の単調性) を検証する。これで「クライアント別に別の
   hash を見せる」standing attack が構造的に不可能になる。ローカルの
   `versions.tsv` は log のクライアント側キャッシュに昇格し、TOFU は
   「log を信頼の根とする検証」に置き換わる
2. **Scope 所有権 + 署名** — scope は所有権レコード (公開鍵の集合 + ローテー
   ション履歴、これも log 上) を持ち、publish は scope 鍵の署名必須。
   `@vibe` / `@vibex` は予約 scope。新規 scope/name は既存名との編集距離検査で
   typosquat を publish 時に拒否する
3. **ビルド時コード実行なし** — パッケージはソースのみ。install hook という
   概念そのものを持たない (npm postinstall 系の攻撃面の不在を仕様として明文化)。
   Phase 0 の add/install もソースのコピーと hash 検証以外を実行しない
4. **Effect surface diff** — 契約の effect row は capability 宣言でもある。
   `vibe update` は新旧契約の effect surface を diff し、**新しい capability
   (Fs / Http / Process 等) を要求し始めた update を警告/ブロック**する。
   contract_hash semver 機械検証 (#732) の capability 版で、effect system を
   持つ vibe の固有優位性。実装は contract_surface_lines の effect row 部分の
   集合差分 + severity 分類 (新規 capability = 要確認、削除 = 情報)
5. **Yank は不変** — 撤回は log 上のマーキングのみ。内容差し替えは (log が
   append-only なので) 構造的に不可能。既存 pin のビルドは警告付きで動き続ける
6. **Provenance** — publish に source repo + commit の attestation を添付
   (Phase 0 の provenance.tsv と同形式)。log に載るので第三者が
   checkout → hash 再計算で公開時点のソース同一性を監査できる

### プロトタイプ方針

- **ストレージ**: log は「1 レコード 1 行の追記ファイル + Merkle tree」から
  始める (sumdb と同じく、DB は要らない)。サービング は静的ファイル + CDN で
  成立する形 (lookup = `/@scope/name@version` → レコード + proof)
- **プロトコル**: HTTP GET のみ (publish だけ POST + 署名)。クライアント側の
  検証器 (inclusion/consistency proof) は @vibe/core の sha1 上に vibe で書く
- **移行**: Phase 0 の versions.tsv / provenance.tsv は形式そのまま log
  レコードの部分集合なので、レジストリ稼働時に初期 log へ取り込める

## 関連

- ADR-0063 (content addressing / store / pin), ADR-0065 (layout / 解決順 /
  サプライチェーン要件)
- #751 (解決順 + VIBE_LIB + freeze), #754 (version directive / cache /
  materialize / 同一 version 再公開禁止), #755 (本設計)
- `scripts/vibe_pkg.sh` (publish / install / add), gate 6h–6k
