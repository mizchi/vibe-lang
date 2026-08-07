# ADR-0071: operation-level effect row と `effectset`

Status: proposed (実装 step 1-2-4 は着地済み、step 3 は関数自身の宣言 row + パラメータ row の展開が着地、step 5 (contract passthrough + signature matching + WIT 生成) は完全着地。step 6 はチェッカー側の独立実装が不要と判明し、ADR-0076 Phase 3 の実装ステップに統合する方針を確定 — 単独の残タスクは無く、次の実装単位は ADR-0076 Phase 3 そのもの、2026-07-22 — 進捗セクション参照)

Date: 2026-07-15

Related: ADR-0003, ADR-0021, ADR-0050, ADR-0063, ADR-0076, #639, #755, #817

## Context

現在の effect row は `with Env` のように effect 宣言全体を単位として
追跡する。`Env` が読み取りと書き込みの operation を両方持つ場合、読み取り
だけを行う関数も `Env` 全体を要求するため、型と package contract が実際より
広い権限を表す。

代数的エフェクトの effect signature は operation の有限集合なので、型で追跡
する最小単位も effect 名ではなく operation identity とする。再利用する集合には
新しい nominal effect や `facet` を導入せず、`effectset` という透明な名前を
与える。

## Decision

effect row の正規形を operation identity の集合へ変更する。`with` 句には
operation を直接書けるほか、閉じた operation 集合を `effectset` として定義し、
参照できる。

```vibe skip
effect Env {
  get(String) -> Option[String]
  args_len() -> Int
  args_get(Int) -> Option[String]
  set(String, String) -> Unit
}

// qualified effectset は指定した effect の部分集合でなければならない
effectset Env::Read = {
  Env::get,
  Env::args_len,
  Env::args_get,
}

// operation を直接列挙する形
fn read_one(key: String) -> Option[String] with Env::get {
  perform Env::get(key)
}

// 名前付き集合を再利用する形
fn read_config(key: String) -> Option[String] with Env::Read {
  perform Env::get(key)
}
```

effect を丸ごと書く既存形は、その effect が宣言する全 operation の shorthand
とする。

```vibe skip
with Env
// equivalent to:
with Env::get + Env::args_len + Env::args_get + Env::set
```

複数 effect にまたがる集合には unqualified な名前を使える。

```vibe skip
effectset ReadOnly = { Env::Read, Fs::read_file }

fn load() -> String with ReadOnly { ... }
```

generic effect の effectset は通常の型パラメータを持てる。effectset が閉じている
とは row variable を含まないという意味であり、宣言された型・region パラメータ
を operation へ渡すことは許可する。

```vibe skip
effect State[T] {
  get() -> T
  put(T) -> Unit
}

effectset State::Read[T] = { State[T]::get }

fn inspect() -> Int with State::Read[Int] { ... }
```

### Row item

`with ...` の各要素は次のいずれかとする。

- effect 名: 宣言された全 operation へ展開する
- `Effect::operation`: 単一の operation
- effectset 名: 宣言本体を再帰的に展開する
- effect row variable: 従来どおり open row の tail を表す

`effectset` 本体には effect 名、operation、他の effectset を書ける。
effect row variable、差集合、補集合、wildcard は許可しない。effectset は常に
閉じた集合であり、循環参照は定義エラーとする。順序と重複は意味を持たない。

`effectset Env::Read` のような qualified effectset は、完全展開後のすべての
operation が `Env` に属さなければならない。複数 effect の union は
`effectset ReadOnly` のような unqualified effectset で定義する。

operation と effectset は effect-row member namespace を共有する。
同じ effect に `Read` operation と `Env::Read` effectset を同時に宣言するなど、
参照が曖昧になる定義は reject する。

### Normalization and identity

checker、unification、contract hash、診断、codegen の前に effect 名と effectset
を再帰展開し、row を次の形へ正規化する。

```text
OperationId  = (EffectDefId, OperationIndex)
OperationRef = (OperationId, NormalizedEffectArguments)
EffectRow    = ({OperationRef...}, optional RowVariable)
```

`EffectDefId` は package/module identity を含む定義 ID であり、表示名の文字列では
ない。`NormalizedEffectArguments` は `State[Int]` の型引数、`Write[router]` の
region 引数、`S3[Posts]` の logical resource 引数を別 kind として保持する。
resource identity は nursery/borrow region と混同しない。別 package がそれぞれ宣言した
同名の `effect State`、または同じ generic effect の異なる instantiation は、異なる
参照として扱う。

ADR-0075 の executable contract では resource-qualified operation を authority の最小
単位とする。したがって `S3[Posts]::get_object` と
`S3[Uploads]::get_object` は別 `OperationRef` であり、一方の host binding/evidence で
他方を満たせない。logical resource name、physical ARN、通常の `String` 値は別の
identity space とする。

effectset は compile-time alias であり、runtime identity、独自 handler、独自
continuation を持たない。`perform Env::Read` や
`handle ... with Env::Read` は許可しない。`perform` は operation、handler target
は effect 宣言を参照する。

### Type and handler rules

関数本体が要求する正規化 row を `Rreq`、その関数に宣言された row を `Rdecl`
とすると、次を要求する。

```text
Rreq ⊆ Rdecl
```

ADR-0073 の `Error::Throw` も通常の semantic operation として `Rreq` に含める。
明示 `with Exception` は高階関数型・subtyping・package contract/hash で意味を持ち、
caller は requirement を宣言するか `handle Error` で放電する。

したがって、少ない operation しか要求しない関数は、より広い row を許可する
context で利用できる。`with Env::Read` 内から `Env::set` を perform または
推移的に要求する関数を呼ぶことは型エラーになる。

`handle body with Env { ... }` は body の正規化 row から、実際に存在する `Env`
operation を除く。handler arm 自身が要求する effect は handler 式の結果 row に
加える。effectset は handler の網羅性や dispatch 規則を変更せず、ADR-0050 の
「effect 宣言の operation を exhaustive に扱う」規則を維持する。

### Package contract, WIT, and security surface

effectset は `index.vpkg` の contract symbol として import/export できる。
公開 effectset 宣言の contract には名前と展開後の `OperationRef` 集合を記録する。
関数の effect row、content hash、互換性判定は alias 名ではなく展開後の集合を
使う。同じ関数 row を直接列挙した場合と effectset で書いた場合は、同じ contract
surface とする。

公開関数の effect surface diff は operation 単位で行う。operation または
effectset の追加によって既存関数の展開後 row が広がる変更は、権限拡大として
breaking/security-sensitive change にする。特に `with Env` は全 operation
shorthand なので、`Env` への operation 追加で公開 surface も広がる。

WIT world 生成では公開 entry の row を展開し、元の effect ごとに operation の
union を取る。生成する WIT interface には、その world が実際に要求する
operation だけを含める。直接列挙と effectset 参照は同じ WIT を生成し、
effectset を effect 全体へ広げてはならない。

### Diagnostics

不足診断は alias 名だけでなく、展開後の operation 差分を表示する。

```text
effect requirements not satisfied: missing { Env::set }
declared effectset Env::Read expands to
  { Env::get, Env::args_len, Env::args_get }
```

fix-it は、局所的な一回利用なら不足 operation の `with` 句への追加を、既存の
effectset と一致する場合はその effectset の参照を優先する。effectset 定義そのもの
を自動で拡張する fix-it は、複数 consumer の権限を広げるため出さない。

## Rejected alternatives

- **`facet` を新しい宣言種別として導入する**: effectset と別の型・handler
  semantics を持つように見え、operation 集合の alias という実態より概念が重い。
- **`EnvRead` / `EnvWrite` を別々の effect として宣言する**: handler、mock、WIT
  interface が分裂し、同じ algebraic signature の部分集合であることを失う。
- **effectset を nominal capability にする**: full `Env` handler が `Env::Read` を
  満たすための subtyping/evidence 規則が別途必要になる。透明展開なら通常の集合
  包含だけで済む。
- **`with Env` の atom を維持したまま alias だけ追加する**: alias が operation
  単位の最小権限を表せず、本件の目的を満たさない。

## Implementation and regression locks

実装は compiler を source of truth とし、次の順で TDD する。

1. parser/printer: direct operation row、qualified/unqualified effectset、round-trip
2. resolver: `OperationId`、import identity、member collision、cycle rejection
3. checker: 展開・包含・推移呼び出し・row variable との合成
4. handler: operation-level discharge と handler-arm effect の再加算
5. contract/WIT/diagnostics: normalized surface と operation-level diff
6. codegen/evidence: 正規化 row を ADR-0076 (#817) の evidence vector 入力に
   接続。ADR-0076 の row-polymorphic (row variable 越し) evidence 解決は
   本 ADR の row variable 構造化が前提であり、ADR-0076 Phase 3
   (yield bubbling による replay 全廃) 着手までに本 ADR の resolver/checker
   (項目 2–3) が着地している必要がある — 静的解決のみの ADR-0076 Phase 1–2
   はこの依存を受けない

   **(2026-07-22 追記、docs/effect-evidence-passing.md 側で詳細調査済み)**:
   調査の結果、本項目は「Phase 3 着手前の独立した準備ステップ」として
   単独では実装しないことにした。理由: (a) `decl_authorizes_effect`
   の row-polymorphism hack はチェッカーの健全性としては現状のままで
   正しい (row 変数は「どんな row を渡されても動く」という
   parametricity の主張そのもの) — チェッカー側に直すべきバグは無い。
   (b) evidence 構築に足りないのは Phase 3 の codegen 側の情報のみで、
   かつ trait dict-passing (desugar_trait_dict.vibe) の固定レイアウト
   struct パターンをそのまま転用できない — trait dict は「trait の
   メソッド一覧」という T に依存しない固定 field 集合を持つが、
   effect row 変数は呼び出し箇所ごとに異なる (時には複数 effect の)
   集合へ実体化されうるため、固定レイアウト struct という型自体が
   存在しない。(c) 暫定方針として、evidence の runtime 表現を
   `(OperationId, closure)` ペアの可変長ベクタ (固定 struct ではない)
   にすることで、trait dict の「呼び出し元の dict をそのまま/フィルタ
   して転送する」スレッディングの形だけを流用しつつ monomorphize を
   避ける。`OperationId` はこのベクタのキーとしてのみ必要で、ADR-0071
   の正規化 row をチェッカー全域に波及させる必要はない。よって本項目
   6 は独立した先行実装をせず、**Phase 3 の段階導入計画ステップ 4/5
   (evidence 直接呼び出し・yield bubbling の実装) に統合して行う**
   — 消費者のいない状態でキー割り当てだけ先行実装すると、Phase 2 の
   当初計画 (`EPerform`/`EResume` IR ノード) と同じく未使用の
   scaffolding になるリスクがあるため。詳細は
   docs/effect-evidence-passing.md の「追記 (2026-07-22, ADR-0071 step 6
   着手時の調査で判明)」セクション参照。

**進捗 (2026-07-22)**: 項目 1 (parser/printer) は着地済み。`with Env::get` の
ような直接 operation row item と `effectset Name = { ... }` /
`effectset Effect::Name = { ... }` 宣言の両方が parse・round-trip する
(collect_effect_names の拡張、SEffectSet Stmt variant)。項目 2 (resolver)
のうち、ADR の Decision セクションが名指しする 2 つの不正定義チェック
— member 参照の循環 (`effectset A = { B }` / `effectset B = { A }` →
"effectset cycle: A -> B -> A") と、qualified name の operation 名との
衝突 (`effect Env { Read -> Int }` の下で `effectset Env::Read` を宣言
すると reject) — は checker_stmt.vibe のローカル関数
(es_detect_cycle / es_qualified_collision、全 stmt の事前収集パスで
宣言順に依存しない) として着地済み。

項目 3 (checker: 展開・包含) のうち、**関数自身の宣言 row の展開**と
**関数パラメータ自身の型に付く row (#885 callback overlay) の展開**は
着地済み: 循環・衝突のない `effectset` は (項目 2 時点の「常に reject」
から変わり) 受理され、`with EffectsetName` を持つ row を実際に
展開してから (checker_stmt.vibe の es_expand_stmts_effect_rows /
es_expand_top_value、純粋な AST 変換パス)、既存の文字列ラベルベースの
effect row 包含チェック機構に渡す。展開は check_program の最初
(check_stmts より前) で一度だけ行う — 当初この展開を
collect_async_effect_errors の直前だけに絞っていたところ、
checker.vibe の effect_row_dropped (引数の型互換性チェック、
check_stmts の一部として実行される、独立した別経路) が展開前の生の
row 文字列を比較してしまい、`with AskAll` を持つコールバック
引数を渡すと「未展開の "AskAll" と "Ask::Get" が一致しない」という
誤検出で reject される実例が見つかった。展開のタイミングを
check_stmts より前に前倒しすることで、この経路と perform-effect
leak-through チェック (checker_effects.vibe の #885 overlay) の両方が
展開後の row を見るようになり、修正された。`with AskAll` だけを
宣言した関数・コールバック引数のどちらも、`Ask::Get` を要求する呼び出しを
正しく authorize できることを実証済み
(fixtures/effect_effectset_expansion.vibe /
effect_effectset_param_expansion.vibe)。

**#1361 (2026-08-02)**: この #885 overlay に **ローカル closure** も載る
ようになった。`let f = () -> T with E { .. }` を関数本体の中に書いた
場合、それは top-level 関数やコールバック引数と同じ call-graph の葉だが、
どちらの表にも載っていなかった (call-graph map は top-level SLet/SLetMut
のみ、overlay は関数型パラメータのみ) ため、`f()` は何もリークせず、
closure 本体は自分の宣言 row の下で自己充足していた — つまり
`with Stdout` しか宣言していない関数から `Env` に到達できた。同じ walk
を使う doctest / `vibe test` の cache 判定 (`file_entry_cacheable` /
`file_tests_cacheable`) もこれを決定的とみなしていた。ELet/ELetRec/ELetMut
で binding を overlay に登録することで両方閉じている。実測: この変更で
cache 判定が変わったファイルは test 499/499・doctest ```vibe run 27/27 で
**ゼロ** (`fixtures/err_local_closure_effect_leak.vibe`, compiler_gate 82)。
なお注釈つきの `let f: () -> T with E = ..` は ascription call
(`ascribe_wrap`) に desugar されてからこの walk に来るので row が見えず、
従来どおりの寛容な扱いのまま。**未着手のまま残っている範囲**:
handler レベルの operation 単位 discharge (項目 4 — 現状 `handle ...
with Env` は Env 全体を一括で discharge しており、特定 operation だけを
discharge する形にはなっていない)、contract/WIT の operation 単位
surface (項目 5)。`with Env::get` (単一 operation の直接列挙、
effectset を介さない) 自体は既存の文字列ラベルベースの effect row
チェック機構にそのまま乗るため、単一 operation を指す row item は
最小権限として機能する (caller 側の transitive call-graph チェックで
実証済み) が、これは正式な OperationRef 正規化ではなく既存機構の
副産物である点に注意 (この点は変わっていない)。
fixtures/effect_row_operation_item.vibe (項目1) /
effect_effectset_expansion.vibe・effect_effectset_param_expansion.vibe・
err_effectset_cycle.vibe・err_effectset_operation_collision.vibe
(項目2/3) + compiler_gate.sh 40m/40n/40o/40p で回帰を固定。

項目 4 (handler: operation 単位の discharge) も着地済み:
`handle body with Effect {...}` は Effect の全 operation を exhaustive
に扱う (ADR-0050、部分的な handling は表現不能) ため、bare な effect
名を discharge することは、その全 qualified operation 名を discharge
することと意味的に等価だが、collect_handle_effects
(checker_effects.vibe) は従来 bare な effect 名しか記録しておらず、
下流の包含チェックは厳密な文字列一致で行われるため、handled body が
transitively 呼び出す関数が operation 単位の row
(`with Ask::Get`、bare な effect ではなく) を宣言していると、
handle が明らかにそれをカバーしているにも関わらず「still missing」と
誤って reject されるケースがあった (修正前に実際に再現・確認)。
collect_handle_effects が各 arm の bare effect 名に加えて fully
qualified operation 名も discharge set に加えるよう修正し、ADR 本文の
回帰ロック項目「`handle ... with Env` 後は body が要求した `Env`
operation だけが消える」を実質的に満たす形になった。
fixtures/effect_handle_operation_level_discharge.vibe +
compiler_gate.sh 40q で回帰を固定。

項目 5 (contract/WIT/diagnostics) のうち、**contract passthrough**の
一部は着地済み: `effectset` は `effect` と同じ透明な compile-time-only
alias として classify_contract_stmts (contract.vibe) を通過し、
`index.vpkg` (ADR-0070 の boundary file) / legacy `index.vibei` の
どちらの契約ファイル経由でも package facade を生き延びることを
fixtures/contract_effectset_vpkg/ (実際の package import 境界を跨いだ
end-to-end テスト) で実証済み。fixtures/contract_effectset_vpkg_main.vibe
+ compiler_gate.sh 40r で回帰を固定。

さらに、contract-vs-implementation の**signature matching**も
effectset 対応が着地済み: check_contract (contract.vibe) は従来
effect row を厳密な文字列比較で照合しており、contract 側で
`fn f() -> T with AskAll` と書き実装側で展開後の operation を
直接 `with Ask::Get` と書くと、意味的に等価でも mismatch エラーに
なるバグがあった (修正前に実際に再現・確認)。check_contract に
`contract_type_defs: Array[Stmt]` 引数を追加し、contract 自身の
effectset 宣言から構築した ES table で両側の signature を比較前に
展開するよう修正 (ctr_expand_sig_row、contract.vibe 内のローカル
関数、クロスファイル参照なし)。この変更は package import 全体が通る
check_contract の中核比較ロジックに触れるため、既存の contract テスト
6 ファイル 43 test + effectset/handle fixture 一式で広範な回帰確認を
実施 (fixtures/contract_conformance_test.vibe が check_contract を
直接 18 箇所で呼んでいたため、既存の no_type_defs() ヘルパーで
シグネチャ変更に追従させる修正も同時に必要だった)。
fixtures/contract_effectset_signature_alias/ +
compiler_gate.sh 40s で回帰を固定。

さらに、**WIT 生成**(wit_gen.vibe) も effectset 対応が着地し、項目 5 が
完全に着地した: 従来 wit_gen.vibe は `used_effects` を集める際に生の
row label をそのまま effect 定義名として突き合わせていたため、
`effectset` alias (`with AskAll`) や、対応する bare な effect 名の
row item を伴わない qualified operation item 単独 (`with Ask::Get`)
は effect 定義に一致せず、実際には WIT マッピングを持つ effect でも
"host capability effect ... no WIT mapping yet" のコメントマーカーに
フォールバックしてしまうバグがあった (修正前に実際に再現・確認)。
checker_stmt.vibe / contract.vibe と同型のローカル関数群
(wit_es_collect_into / wit_es_expand_into / wit_effect_name_of /
wit_resolve_effect_names_into、wit_gen.vibe 内のみ、クロスファイル
参照なし) を追加し、`used_effects` の収集ループで各 raw label を
effectset 展開 + qualified→effect 名解決してから照合するよう修正。
既存の effect->WIT golden (fixtures/wit_gen_http.vibe、通常の
`with Effect` 形式) はバイト同一で無回帰であることを確認した上で、
effectset alias と bare qualified item の両方をカバーする新規 golden
fixtures/wit_gen_effectset.vibe + compiler_gate.sh 40t で回帰を固定。

**進捗 (2026-08-02, #1340)**: generic effect の instantiation 検査が着地
した。(a) `SEffectDef` は型パラメータ付きでも registry に登録される
(`TDEffect` に tparams slot を末尾追加 — TDStruct の #829 と同じ規約。
型パラメータは op signature 内で rigid `CtNamed(param, [])` として resolve
される)。(b) perform site (括弧付き/括弧なしの両形) は使用箇所ごとに
fresh inference vars で instantiate した signature に対して arity と引数型
を検査する — `perform State::Get(1, 2, 3)` が 0-arity 宣言に通る #1218 の
横断発見の穴はここで閉じた。(c) handle site は **handle 式ごとに 1 回**
instantiate して全 arm で共有する (`Get => resume(0)` が束縛した S=Int を
`Put(v)` の payload binder も見る)。(d) `with State[Int]` row item が
parse する (parser_base.vibe collect_row_item_targs)。row 文字列表現の
"," 区切りと衝突するため **型引数は1個のみ** (multi-arg instantiation は
parse error)。containment/unification/dropped-row 比較は base 名
(`[` 以前) で行う instantiation-insensitive な v1 — `State[Int]` と
`State[String]` を row 包含で区別する完全な OperationRef 正規化は残タスク。
row item の bracket は geff_validate_row_targs (checker_stmt.vibe) が宣言
と照合する (非 generic effect への bracket、effectset への bracket、空
bracket は reject)。#1302 の暫定宣言サイト warning
(`detect_generic_effect_decls`) は削除した。回帰ロック:
fixtures/effect_generic_row_instantiation.vibe /
err_generic_effect_perform_arity.vibe / err_generic_effect_row_targ.vibe +
compiler_gate.sh 79、unit tests
lib/@vibe/compiler/tests/checker_generic_effect_test.vibe。

**進捗 (2026-08-02, #1343)**: 項目 3 の **builtin slice** が着地した。
それまで operation-level row が効くのは `perform Eff::Op` の経路だけで、
**host capability には effect 全体以外の粒度が存在しなかった** —
builtin 呼び出しの経路 (`checker_effects.vibe` の `builtin_call_effect`) は
裸の effect ラベルを返し `decl_authorizes_effect(declared, "Fs")` で照合して
いたため、`with Fs::read_file` は `missing { Fs }` で reject されていた
(実測)。これが `with Http` のような粗い row を強制していた原因で、
1つのラベルに「ポートを bind して serve する権限」と「任意 URL への
outbound request」が同居していた。

builtin 経路を operation ラベルでも認可するよう修正した
(`builtin_call_op_label`: 修飾 builtin は canonical 名がそのまま operation id、
非修飾の `sh` 等は従来どおり effect のみ)。**裸の effect を先に試すので純粋な
緩和**であり、既存の `with Fs` / `with Http` は一切変わらない。
診断も ADR-0071 の契約どおり不足 operation を名指しする
(`missing { Fs::write_file }`) — effect 全体への widening を勧めない。

ここで確認された設計上の軸の分離を記録しておく: **effect 名は provider 軸**
(どの WASI/host provider が実装するか — host import 束・WIT interface・
binding の単位) であり、**row は consumer 軸** (呼ぶ側の最小権限)。
consumer 側の細粒度が欲しいからといって provider ラベルを分割
(`Http` → `HttpServer`/`HttpClient`/`HttpIncoming`) すると実装契約が断片化
するので、細粒度は operation-level row と effectset で表す。
回帰ロック: fixtures/effect_builtin_operation_row.vibe + compiler_gate.sh 80。

**進捗 (2026-08-02, #1344)**: ADR-0085 の typed `Exception[E]` が row に入った。
#1340 が残した「instantiation まで見た row identity」を **exception effect に
限って先取り**したもので、他の generic effect (`State[Int]` 等) は base 名比較の
v1 のままである。具体的には `row_base_membership` (checker_effects.vibe) と
`effect_label_base_name` (core/types.vibe) の両方が exception label を base 名
同一視から除外し、代わりに kind (`Exception[K]` の `K`) で比較する
(`exception_kinds_compatible`, core/exception_effect.vibe)。除外しないと
`State[Int] ~ State[String]` と同じ規則で `Exception[IoError] ~
Exception[ParseError]` になり、typed exception の唯一の保証が消える。

`Error` / `Exception` (bracket なし) は **kind 消去された最弱の label** として
扱い、宣言側・要求側どちらに現れても全 kind と compatible とした。これが
既存の ~970 の un-annotated throw site を無変更に保つ根拠であり、同時に
「この変更は既存コードに対し証明可能に additive」の根拠でもある — 新たに
失敗しうるのは kinded label を書いた row だけで、その綴りはコードベースに
存在しない。回帰ロック: fixtures/exception_typed_row.vibe /
err_exception_kind_mismatch.vibe + compiler_gate.sh 81、unit tests
lib/@vibe/compiler/tests/checker_exception_kind_test.vibe。

**未着手のまま残っている範囲**: ADR-0076 evidence vector への正規化 row
の接続 (項目 6)、および row 包含での instantiation 区別 (上記 v1 の
base-name 比較を OperationRef 単位へ精密化する作業)。

**Bootstrap gotcha**: `lib/@vibe/parser/` 配下で「新しい関数を定義し、
別ファイルからその関数を import で参照する」変更を同一コミットに含めると、
`scripts/generate_bundle.sh` の merge/rename-plan ステップ
(`_cli_adapter_module_source.vibe` を土台にビルドされる flatten tool)
が新規のクロスファイル参照を解決できず `unknown name: <fn>` で失敗する
ことがある (旧世代の flatten tool が新しい名前を知らないため)。
回避策: 新しい関数を呼び出し元と同一ファイルに定義する
(クロスファイル edge を増やさない)。既存のクロスファイル名を新しい
import 元に追加するだけなら問題ない。

最低限、次を回帰として固定する。

- `with Env::Read` から `Env::set` は reject
- direct row と同じ集合の effectset row は型・contract hash・WIT が一致
- effectset の順序違いと重複は同一、循環は reject
- `State::Read[Int]` と `State::Read[String]` は異なる operation 集合
- `handle ... with Env` 後は body が要求した `Env` operation だけが消える
- 別 package の同名 effect/operation は衝突しない
- effectset の operation 追加を effect surface diff が権限拡大として報告する

新構文を compiler source 自身で使うのは、seed compiler が構文と正規化を理解する
tag を作り、bootstrap bump を完了してからとする。

## References

- D. Hillerström, S. Lindley, [Liberating Effects with Rows and
  Handlers](https://homepages.inf.ed.ac.uk/slindley/papers/links-effect.pdf)
  — operation specification を要素とする Links の effect row
- D. Leijen, [The Koka Programming Language: Effect
  Typing](https://koka-lang.github.io/koka/doc/book.html#sec-effect-types)
  — extensible/scoped effect row と row polymorphism
- N. Xie, D. Leijen, [Generalized Evidence Passing for Effect
  Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/)
  — ADR-0076 (#817) が定める正規化 row から evidence vector への lowering。
  設計詳細は [effect-evidence-passing.md](effect-evidence-passing.md)
