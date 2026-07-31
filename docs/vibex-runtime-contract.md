# ADR-0075: `.vibex` executable と resource/capability 実行契約

Status: proposed

Date: 2026-07-22

Related: ADR-0010, ADR-0012, ADR-0050, ADR-0068, ADR-0069, ADR-0071,
ADR-0073, #488, #806, #817, #818

## 位置づけ

本書を `.vibex` の entry、resource requirement、provider composition、Wasm host
preflight、task/process への authority 委譲に関する source of truth とする。

- [effectset.md](effectset.md) は operation-level effect row の意味論を定める。
- [concurrency.md](concurrency.md) は task / nursery / worker の lifecycle と isolation を
  定める。
- [effect-wit-mapping.md](effect-wit-mapping.md) は現行 WIT generator の実装状態を記録する。
- 本書は、それらを executable の build / deploy / run 境界へ接続する。

現行 compiler、`runtime/vibe`、既存 `.vibex` script、export-only WIT generator は
移行前の実装であり、本書と衝突する場合は本書を目標仕様とする。

## 決定の要約

1. `.vibex` は executable root であり、ちょうど一つの `fn main` を持つ。
2. `main` は `() -> Unit`、明示された closed effect row を持ち、実際の transitive
   requirement と宣言 row は一致しなければならない。
3. effect requirement と resource claim を分離する。effect は「何をするか」、
   resource は「どの論理 instance に対して行うか」を表す。
4. logical resource identity を normalized effect argument に保持する。
   `S3[Posts]::get_object` と `S3[Uploads]::get_object` は別 authority である。
5. S3 は Http の subeffect にしない。provider/handler が S3 operation を処理し、
   Http、Clock、Credentials 等を新たに要求する。
6. compile は requirement contract を生成するだけで cloud を変更しない。
   plan、apply、instantiate/run を別 phase にする。
7. `main` は、semantic requirement、fork-safe requirement、resource binding、ABI/hash
   がすべて満たされた後にだけ開始できる。
8. task/process の authority は host authority の部分集合であり、child は parent より
   強い authority を取得できない。物理 thread / worker は独自の ambient authority を
   持たず、現在実行中の task authority を借りる。
9. provider 選択と resource binding は deploy/link 時に固定する。runtime が ambient
   provider を探索・download・自動昇格することはない。
10. WasmFX は handler / continuation の lowering 候補であり、resource lifecycle、
    IAM、binding contract の意味論にはしない。
11. path-scoped authority は正規化 glob の順序ではなく集合として扱う。同一
    scope domain で交差しうる pattern は同一 authority の場合だけ許し、
    異なる authority の重複は plan/apply 時に reject する。

## 用語と関係

| 用語 | 意味 |
| --- | --- |
| semantic requirement | source program が実行全体で行いうる operation 集合 |
| resource claim | logical resource identity と nominal kind の要求 |
| authority | 一つの execution principal が実行を許可された semantic operation 集合 |
| provider | high-level operation を handle し、別 operation へ lowering する実装 |
| resource provider | resource の create/update/delete/read lifecycle を実装する deploy-time component |
| capability adapter | resource binding を使って runtime operation を実装する handler/component |
| host profile | provider composition 後に host が提供する semantic authority と fork-safe subset |
| residual contract | provider composition 後に最終 Wasm host へ残る WIT/import requirement |
| binding lock | logical resource と physical resource、provider、policy、ABI/hash の固定結果 |
| principal | authority を持つ logical task/process。OS thread や Worker とは別概念 |

混同してはならない関係は次のとおりである。

```text
effectset inclusion:
  S3::Read[Posts] ⊆ S3[Posts]

provider lowering:
  AwsS3ViaHttp handles S3::Read[Posts]
               requires Http::request + Clock::now + Credentials::sign

resource binding:
  Posts ↦ arn:aws:s3:::prod-posts

host satisfaction:
  Entry.requires ⊆ ComposedHost.provides

authority delegation:
  Child.authority ⊆ Parent.authority ⊆ ComposedHost.provides
```

`S3::Read ⊆ Http` という関係は定義しない。同じ S3 operation は native binding、
AWS SDK、Http、proxy、in-memory mock のいずれでも実装できる。S3 を Http の subtype と
すると、限定された S3 read requirement から任意 URL へアクセスできる Http authority
への暗黙昇格が起きる。

## `.vibex` entry contract

### File rule

- `*.vibex` は executable root であり、import target や package member にできない。
- source 中にちょうど一つの `fn main` が必要である。
- `.vibex` の user-visible entry は常に `main`。`--entry` / `VIBE_ENTRY` は拒否する。
- compiler/selfbuild/test harness の `cli_main`、`selfbuild_entry`、`__no_entry__` は内部 ABI
  として残せるが、`.vibex` の言語仕様には含めない。
- `fn main` は通常の関数値でも export symbol でもない。target profile が `_start`、
  `wasi:cli/run`、component export 等へ lowering する。
- `*.vibe` は module/library source とする。実行可能 source の拡張子判定を compiler
  frontend で行い、launcher だけの慣習にしない。

### Main signature

canonical entry は次の形である。

```vibe skip
fn main with { S3::Read[Posts], Stdout::write } {
  ...
}
```

- 型は `() -> Unit` 固定。
- effect row は明示必須、closed で row variable を許可しない。
- body と transitive callee、spawn された closure が要求する正規化 row を `Ractual`、
  宣言 row を `Rdeclared` とすると `Ractual = Rdeclared` を要求する。
- 通常関数の `Ractual ⊆ Rdeclared` は維持する。entry だけを exact にするのは、余分な
  declaration が余分な runtime binding / IAM authority になるためである。
- `Error::Throw` と `Async::suspend` も semantic requirement として transitive に含む。
  provider/runtime boundary が処理するため WIT import に残らない場合でも source
  contract から消さない。
- 未処理 checked Error は ADR-0073 の outer handler が diagnosed failure へ変換する。
- process exit code は暗黙の `Int` return/print にしない。必要なら明示的な
  `Process::exit` operation として設計する。

value binding や `Int` return を entry とみなして stdout へ暗黙 print する挙動は
canonical `.vibex` contract に含めない。

## Logical resource identity

初期 surface は次の形とする。これは resource の作成ではなく、executable が要求する
logical binding の宣言である。

```vibe skip
resource Posts : S3::Bucket

effect S3[B: S3::Bucket] {
  get_object(String) -> Bytes
  put_object(String, Bytes) -> Unit
}

effectset S3::Read[B] = {
  S3[B]::get_object,
}

fn load[B: S3::Bucket]() -> Bytes with { S3::Read[B] } {
  perform S3[B]::get_object("posts.json")
}

fn main with { S3::Read[Posts], Stdout::write } {
  Stdout::write(load[Posts]())
}
```

決定事項:

- `resource Name : Kind` は `.vibex` root だけに置ける nominal logical identity。
- reusable module は resource 名を hard-code せず、resource kind parameter で抽象化する。
- normalized `EffectArgument` に `resourceId` kind を追加する。nursery の `regionId` と
  resource identity を同じ atom として扱わない。
- resource 名や physical ARN を通常の `String` として authority 判定しない。
- contract/hash/WIT projection/policy diff は resource-qualified operation を保持する。
- 動的に任意 resource を選ぶ API は、将来 `S3::AnyRead` 等の明示的に広い authority
  として追加できる。静的 binding から暗黙に wildcard authority へ拡張しない。

resource kind の定義、logical id、physical name、secret/credential は別物である。
特に raw cloud credential を guest へ binding value として渡さない。guest には scoped
operation interface または forge 不能な resource handle を渡し、credential は host
adapter/provider が保持する。

## Path-scoped authority

filesystem 等の resource 内を path で絞る authority は、順序付き ACL として
扱わない。Phase 1 の正規化 glob は path segment の literal、1 segment に一致する
`*`、末尾で0個以上の segment に一致する `**` だけを許す。absolute path、空 segment、
`.`、`..`、platform-dependent case folding、symlink resolution は glob 文法に含めず、
provider が正規化・confinement 境界で処理する。

同一 scope domain の grant `g1`、`g2` には次を要求する。

```text
MayOverlap(g1.pattern, g2.pattern)
  implies g1.authority = g2.authority
```

同じ authority の pattern 重複は意味が同じなので許可し、plan artifact では
canonicalize できる。authority の同一性は operation list の順序ではなく
ADR-0071 の extensional row equality で判定する。異なる authority の重複は
reject する。`most-specific wins`、source order、deny-overrides の優先規則は
導入しない。例えば `read src/**` と `write src/generated/**` は
`src/generated/output.wasm` に同時に一致するため invalid であり、並び順を
変えて read/write のどちらかを選ばせない。

overlap checker は Bool だけでなく canonical な共通 path witness を返す。
reject 診断には scope domain、両 pattern、両 authority と witness path を含める。
restricted glob で overlap するなら witness は必ず存在し、`none` は semantic
intersection が空であることを意味する。

検査は二段階で行う。

1. compile/plan では logical `ResourceId` を scope domain として、同じ logical
   resource 内の pattern 交差を検査する。
2. apply では BindingLock の physical root identity を scope domain として再検査する。
   異なる logical resource が同一または alias する物理 root に bind された場合も、
   異なる authority の交差を reject する。

instantiate/run preflight は両方の検査済み digest を BindingLock hash へ含め、
scope policy が invalid または digest 不一致なら `main` を開始しない。実際の path
open は、検査と同じ正規化規則および WASI preopen/provider confinement の内側で行う。

## Contract artifacts

compile 後も source semantic contract と residual host contract を両方保持する。

```text
SemanticContract {
  entry: main
  requires: Set OperationRef
  fork_requires: Set OperationRef
  resources: Set (ResourceId, ResourceKind)
  path_scopes: Set (ResourceId, Authority, NormalizedGlob)
  source_contract_hash
}

ResolvedContract {
  semantic_contract_hash
  selected_providers
  residual_imports
  provider_abi_hashes
  resolved_contract_hash
}

BindingLock {
  resolved_contract_hash
  logical_to_physical_bindings
  resolved_path_scopes
  generated_policy_digest
  host_profile
  binding_hash
}
```

`fork_requires ⊆ requires` を必須 invariant とする。resource identity、operation
identity、provider ABI/version、target world version は contract hash に入れる。

> **拡張 (2026-07-31, ADR-0088)**: Optional capability(`allows { Fs::Read[X]? }`)
> の導入に伴い、`BindingLock` には `optional_resolution: Map[OperationRef,
> Granted | NotGranted]` が加わる(apply 時に一回だけ確定する参照テーブル。
> `perform?` は実行中これを引くだけの純粋参照)。`Entry.requires` の起動判定は
> Required エントリのみで行う。詳細は
> [capability-authorization-surface.md](capability-authorization-surface.md)。

WIT world は residual contract の ABI projection である。WIT は resource policy、
logical/physical mapping、provider 選択を十分に表せないため、WITだけを executable
contract の正本にしない。

## Provider composition

provider `P` は少なくとも次を宣言する。

```text
P.handles          : Set OperationRef
P.requires         : Set OperationRef
P.resource_claims  : Set ResourceClaim
P.fork_safe        : Set OperationRef
P.abi_hash
P.policy_mapper
```

一段の lowering は次である。

```text
Outstanding' = (Outstanding - P.handles) ∪ P.requires
```

provider を繰り返し適用し、残った operation を primitive host が提供する。循環しても
新しい operation が減らない provider chain、複数 provider が曖昧に同じ requirement
を処理する plan、ABI/hash が一致しない plan は reject する。

resource provider と capability adapter は、一つの platform Layer/plugin として配布して
よいが、意味論上は分ける。bucket の lifecycle を実装することと、実行中の
`get_object` を実装することは別 contract である。

IAM action 等への写像は provider-specific metadata とする。たとえば
`S3::get_object[Posts]` から `s3:GetObject Posts/*`、暗号化 bucket なら追加の
`kms:Decrypt` を導く責任は provider にある。core language が cloud 固有 action 名を
知る必要はない。operation requirement を狭めたとき policy が広がらない monotonicity
は provider conformance property とする。

## Build / plan / apply / run

### Compile / build

- parse、resolve、type/effect check を行う。
- `main` の exact closed row と resource claim を抽出する。
- logical resource ごとの正規化 path scope を抽出する。
- semantic contract と未解決の component/WIT surface を生成する。
- network、cloud API、credential discovery、resource mutationを行わない。

### Plan

- target host profile と provider set を選ぶ。
- provider lowering、resource graph、policy、WIT residual imports を計算する。
- provider ambiguity、cycle、fork-safety、ABI/hash mismatch、および同一 logical
  resource 内の path-scope ambiguity を検査する。
- plan は pure data として review できるようにする。

### Apply / deploy

- resource provider が lifecycle operation を実行する。
- capability adapter、physical binding、最小権限 policy を構築する。
- physical root identity へ scope を投影し、logical resource 間の alias を含めて
  path-scope ambiguity を再検査する。
- resolved contract と一致する binding lock を生成する。

### Instantiate / run

次をすべて検査してから Wasm を instantiate し、最後に `main` を開始する。

```text
Entry.requires       ⊆ ComposedHost.provides
Entry.fork_requires  ⊆ ComposedHost.forkable
Entry.resources      satisfied-by BindingLock.bindings
Entry.path_scopes    valid for logical and resolved physical domains
contract / ABI / WIT / binding hashes match
all residual imports linked
```

不足時は `main` を一命令も実行せず、logical resource、operation、候補 provider、残余
requirement を含む構造化診断を返す。Wasm engine の generic missing-import error だけに
任せない。

> **拡張 (2026-07-31, ADR-0088)**: この preflight の直前に、TTY であれば
> **認可専用の一括 prompt** を挟める — 対象は「composed host が provide
> できるが未許可」の operation(認可待ち Required の grant-or-abort と
> 未確定 Optional)のみ。provider/binding が `ComposedHost.provides` に無い
> Required は prompt では解決できず、本節の非対話 abort のままである。
> prompt の結果は per-run ephemeral で、run 開始後の authority 不変は
> 本 ADR のまま変わらない。

ここでの satisfaction は「型の合う adapter/binding と宣言済み policy が存在する」ことを
意味する。network outage、credential expiry、cloud organization policy、対象 object の
不存在まで成功を保証しない。それらは operation の `Result` または checked `Error` と
して実行時に観測される。

## Task / process / thread authority

### Principal hierarchy

authority は physical execution resource ではなく logical principal に属する。

```text
Root.authority  = Entry.requires
Child.authority = Child.transitiveRequirements

Child.authority ⊆ Parent.authority ⊆ ComposedHost.provides
Child.authority ⊆ ComposedHost.forkable
```

entry、task、将来の supervised process が principal である。OS thread、Web Worker、
Wasm worker slot は principal ではない。task が別 worker へ migrate しても authority は
task とともに移り、worker id によって増減しない。

### Spawn typing

spawn される closure の latent row を executable contract へ含める。

```text
Req(spawn f)     = { Spawn[r]::spawn } ∪ Req(f)
ForkReq(spawn f) = Req(f) ∪ ForkReq(f)
```

したがって「親自身はS3を呼ばず、childだけが呼ぶ」場合でも、root `.vibex` contract は
S3 requirement を持つ。`Spawn::spawn` だけを追跡して child row を落とす checker は
unsound である。

spawn boundary では次を検査する。

- child row は closed。
- child requirement は parent authority の subset。
- child へ渡す全 operation evidence は選択 provider 上で fork-safe。
- child capture は `Send` / `Spawnable[r]` 規則を満たす。
- dynamic handler stack 全体を暗黙 clone しない。
- user-defined handler/evidence は既定で task-local、non-fork-safe。
- host resource handle と opaque FFI value は既定で non-`Send`。resource-qualified
  adapter が fork-safe と宣言し、host conformance を満たす場合だけ child へ渡せる。

authority は v0.4.0 では immutable とする。動的 grant、revoke、authority transfer、
arbitrary delegation token は導入しない。task cancel / nursery close / instance teardown
は lifetime を終わらせるが、実行中 principal の authority set を書き換えない。

将来 `Process[Msg]` を追加する場合も同じ hierarchy を使う。process が親 task より
長生きするには supervisor/host root への ownership 移管を明示し、authority を拡大しない。
process API、supervision strategy、location transparency は本 ADR では固定しない。

## Error / Async / WasmFX

`Error` と `Async` を host resource と同じ policyへ直接写像する必要はないが、source
semantic row から除外してはならない。

- `Error::Throw` は runtime outer handler が diagnosed unsuccessful outcome へ変換する。
- `Async::suspend` は cooperative scheduler、JSPI、WASI Component Model async、または
  将来の WasmFX/typed continuation lowering が handle する。
- target lowering 後に residual WIT import が無くても、source contract/hash には残る。
- current checker の transitive Async 非強制は implementation debt とし、本 ADR の
  executable/spawn boundary では採用しない。

WasmFX は continuation の suspend/resume/abort と algebraic handler lowering に利用できる。
logical resource identity、provider lifecycle、policy、binding lock、authority delegation は
WasmFX tag の意味論に押し込めない。

## Lean Oracle

実行可能な最小モデルを次へ置く。

- `formal/VibeFormal/Capability/Contract.lean`: entry、resource claim/binding、host profile、
  provider lowering、spawn delegation
- `formal/VibeFormal/Capability/Thread.lean`: physical worker が task authority だけを借りる関係
- `formal/VibeFormal/Capability/PathScope.lean`: restricted glob、scope policy、
  path-aware entry preflight
- `formal/VibeFormal/Proofs/CapabilityContractCorrect.lean`: executable predicates と relational
  contract の一致、no-start、delegation transitivity、provider lowering、worker authority
- `formal/VibeFormal/Proofs/PathScopeCorrect.lean`: overlap と semantic path
  intersection の完全一致、diagnostic witness の健全性、matching authority の一意性、
  scope-aware preflight
- `formal/VibeFormal/Proofs/CapabilityContractExamples.lean`: S3/Http、bucket identity、read/write、
  worker migration の正例・反例
- `formal/VibeFormal/Proofs/PathScopeExamples.lean`: overlapping/disjoint glob と
  order-sensitive first-match の反例

現モデルは次を証明する。

- executable preflight の Bool 判定と relational `Runnable` が一致する。
- missing semantic operation がある contract は runnable にならない。
- child authority は parent、さらに host を越えない。
- host が強い operation を持っていても、parent に無ければ child へ継承されない。
- Posts binding は Uploads claim を満たさない。
- provider lowering の残余 operation は、未処理 source operation または provider 自身の
  requirement のどちらかである。
- physical worker が行う operation は、そのworkerが所有するtask authorityを通じて
  host authority に含まれる。worker migration は authority を変更しない。
- restricted glob checker の判定と、両 pattern に一致する normalized path の存在は
  同値であり、重複の見逃しも過剰拒否もない。
- overlap witness が `some path` なら両 pattern が path に一致し、`none` なら
  semantic intersection は空である。
- valid scope policy では、同一 domain/path に一致する全 grant の authority が等しい。
- base capability preflight が成功しても scope policy が曖昧なら `main` は開始しない。

Lean がまだ証明していないもの:

- provider implementation が S3 semantics を正しく実装すること
- IAM/policy mapper の cloud-specific 正しさと monotonicity
- provider chain resolver の termination、ambiguity、最小解
- manifest/WIT/compiler/runtime の concrete serialization correspondence
- runtime evidence vector が contract どおりであること
- actual Wasm thread/Worker/allocator の isolation
- concrete path parser/normalizer、symlink/case-folding semantics、WASI/provider enforcement
- logical resource から physical root identity への BindingLock projection correspondence
- dynamic process supervision、revocation、distributed authority

これらは resolver oracle、generated JSON corpus、runtime differential trace、provider
conformance test を追加して段階的に bridge する。

## 現状仕様の負債と今決めること

| 現状 | 放置した場合の負債 | 本 ADR の決定 |
| --- | --- | --- |
| `.vibex` が file convention に無く launcher 慣習 | compiler/toolごとにentry判定が分裂 | executable root、exactly-one `fn main` |
| value-bound/Int-return entry が残存 | exit/print/component ABI が固定できない | Unit main、Error/Process operationへ分離 |
| main row の明示/推論が open | dependency updateでauthorityが無音拡大 | 明示 closed exact row |
| WIT surface がexport関数だけ | non-export mainのhost requirementを表せない | `.vibex` mainをsemantic contract起点にする |
| built-in host effect がWITコメントだけ | link前に不足検査できない | stable OperationIdとresidual importを生成 |
| resourceをStringで渡すAPI | bucket単位のpolicyを静的生成できない | resource-qualified OperationRef |
| S3をHttpのsubeffectと見る | restricted S3から汎用network authorityへ昇格 | provider loweringとして分離 |
| Error WIT文書がtrap扱い | checked Error ADRと不一致 | source contractに保持、outer handlerで診断 |
| Asyncのtransitive非強制 | targetごとのruntime requirementが欠落 | executable/spawnでは完全追跡 |
| child handler stackの継承が未確定 | thread追加時にambient authorityが漏れる | closed row + explicit fork-safe evidence |
| worker/threadとtaskを混同 | migrationやpool再利用で権限が混ざる | authorityはprincipal所有、workerは借用のみ |
| resource createとruntime accessが同じ「Effect」 | buildがcloud mutationし再現性を失う | resource provider/capability adapter/phaseを分離 |

この表の右列は parser/runtime 実装より先に固定する。特に resource identity、main row、
spawn row propagation、authority subset、provider-not-subtyping、phase separation は後から
変えると package contract/hash/WIT/permission model を破壊する。

## 後回しにできる実装

次は上記 contract を変えずに延期できる。

- AWS S3、Cloudflare R2 等の実 provider と policy mapper
- SST/Alchemy互換のplan/apply engine、resource graphのcycle対応
- WIT `resource` handle の具体 encoding と component composition optimizer
- WasmFX typed continuation lowering
- JSPI/Worker、WASI、shared-everything multi-worker backend
- public `Process[Msg]` / supervisor API
- user-defined `fork-safe` handler declaration
- dynamic provider selection、dynamic grant/revoke、resource wildcard
- zero-copy/move transfer、shared immutable bulk resource
- organization policyやnetwork reachabilityまで含むonline preflight

初期縦串は cloud を使わない mock S3 provider と in-memory binding でよい。重要なのは
compiler manifest、provider lowering、host preflight、child authority の contract が先に
一致することである。

## 実装計画

### Phase 0: specification / Oracle（本 ADR）

- `.vibex`、resource identity、provider、authority 委譲を決定する。
- Leanにpositive/negative witnessを置く。
- CIは従来どおり `formal/**` 変更時だけ `formal-check` を実行する。

### Phase 1: `.vibex` entry hardening

実装状況（2026-07-22）:

- 実装済み: executable file kind、exactly-one/non-exported `fn main`、Unit/無引数、
  明示 row、`.vibex` import拒否、固定 `main` entry、`.vibe` run拒否、CLI/script移行。
- 未実装: checker が求める `Ractual = Rdeclared` の exact/closed row 検査。
  現段階は構文上 row が書かれていることだけを検査し、semantic contract emission と
  同時に Phase 2 で接地する。この差は target contract の緩和ではない。
- `.vibex --wit` は Phase 2 まで拒否する。export-only の旧 WIT generator で
  non-exported main の requirement を欠落させた artifact は生成しない。

Red:

- `.vibex` without main、multiple main、value-bound main、custom `--entry` をreject。
- `.vibe` を `vibe run` した場合と `.vibex` importをreject。
- open/inferred/overdeclared main rowをreject。

Green:

- frontendにfile kindを渡し、`fn main` contractをcheckerで検査する。
- canonical Unit mainからtarget entryを合成する。
- 既存script/fixtureを移行し、seed bump前はcompat harnessを隔離する。

### Phase 2: semantic contract emission

Red:

- operation順序/alias表記が違ってもhashが同じ。
- `S3[Posts]` と `S3[Uploads]` のhash/requirementが異なる。
- direct operationとeffectsetが同じmanifestを生成する。
- child-only effectがroot contractから欠落しない。

Green:

- ADR-0071 normalizationに`resourceId`を配線する。
- `resource` declaration/resolution、exact main row、`fork_requires` projectionを実装する。
- deterministic JSON/custom sectionを生成しgoldenを固定する。

### Phase 3: local provider resolver / preflight

Red:

- missing operation、wrong resource kind/id、non-fork-safe provider、ABI mismatchでmain未実行。
- read-only parentからwrite childをreject。
- S3 mock providerでS3が消え、provider requirementだけがresidualに残る。
- `read src/**` と `write src/generated/**` を reject し、同一 authority の重複と
  `read src/**` / `write cache/**` は accept。
- overlap 診断が両 pattern に一致する canonical path witness を含む。
- 異なる logical resource が同じ physical root へ bind された場合にも重複を再検出。

Green:

- deterministic provider selectionとbinding lock readerを実装する。
- mock/in-memory providerでcompile→plan→runの縦串を通す。
- normalized glob intersection と logical/physical scope policy gate を実装する。
- LeanのcaseをJSON corpus化し、selfhost resolver/runtime preflightとdifferential testする。

### Phase 4: WIT / Component boundary

- export-only scanから`.vibex` semantic contract起点へ移行する。
- provider composition前後のsemantic/residual contractを両方保持する。
- operation-level WIT import、resource binding slot、ABI/hash検査を実装する。
- Error/Async outer providerをWIT projection前に明示的にlowerする。

### Phase 5: task authority

- higher-order `spawn` typingでchild rowをroot requirementへ伝播する。
- evidence vectorをoperation/resource単位でsubset抽出する。
- fork-safe provider check、`Send`/`Spawnable`、task-local handler拒否を実装する。
- cooperative one-worker backendで権限traceを取得しLean modelと比較する。

### Phase 6: resource provisioning

- resource provider lifecycle、plan/apply、policy mapperを別層で実装する。
- 最初のcloud providerはS3 Read-onlyに限定し、credentialをguestへ渡さない。
- policy diffとcontract surface diffをsecurity-sensitive changeとして表示する。

### Phase 7: multi-worker / process / WasmFX

- capability contractを変えずにworker backendを追加する。
- task migration、worker reuse、cancel後のevidence破棄をdifferential traceで検証する。
- public process、WasmFX、shared-everythingは個別ADRとopt-in gateで追加する。

## Conformance locks

Static:

- `.vibex` entry uniqueness、Unit main、closed exact row
- resource identity/kindのnominal一致
- direct/effectset/whole-effect shorthandのcontract equivalence
- spawn child requirementのroot contract伝播
- child authority、fork-safe evidence、resource handle capture

Build/deploy:

- compileはcloud/networkへ触れない
- provider loweringとresidual importのdeterminism
- contract/provider/WIT/binding hash mismatchのreject
- operation/resource単位のpolicy diff

Runtime:

-不足時にmainが開始されない
- wrong bucket binding、read/write escalation、ambient host inheritanceのreject
- worker migration/reuseでtask authorityが変わらない
- provider/runtime Errorはchecked failureになり、authority不足と区別される

Formal/refinement:

- `pkf run formal-check`
- generated contract corpusとselfhost checker/preflightのdifferential test
- cooperative authority traceを基準にmulti-worker traceを射影
- providerごとのoperation→policy conformance test

## 参考にする外部設計

- [SST Resource Linking](https://sst.dev/docs/linking): runtime value injection、
  generated type、permission付与をlinkとして扱う。
- [Alchemy Infrastructure as Effects](https://alchemy.run/infrastructure-as-effects/)、
  [Resources](https://alchemy.run/infrastructure-as-code/resource/)、
  [Providers](https://alchemy.run/infrastructure-as-code/provider/): resource declaration、
  provider Layer、plan/apply、runtime bindingをphase分離する。
- [WasmFX](https://wasmfx.dev/): algebraic effect handler / typed continuationのlowering。

これらの語彙は参考にするが、Vibeのsource of truthはnormalized operation identity、
resource-qualified authority、Lean Oracle、本ADRのphase/委譲規則である。
