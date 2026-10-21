// Slides for "自作プログラミング言語を自慢する会" (2026-10-22).
// Slide prose is Japanese because the talk is; every `DEMOS` entry is real
// vibe source that `tests/slides-smoke.mjs` compiles in the browser and checks
// against `expect`, so a demo cannot rot silently before the talk.

export type Slide = { className?: string; html: string; notes?: string };
export type Demo = {
  source: string;
  entry?: string;
  // Exact stdout the unedited source must print (checked by the smoke test).
  expect: string;
  hint?: string;
};

export const DEMOS: Record<string, Demo> = {
  hello: {
    source: String.raw`
fn main allows Console {
  let langs = ["Rust", "MoonBit", "Koka", "Verse"]
  for lang in langs {
    println("inspired by \{lang}")
  }
  println("compiled by vibe, in this browser tab")
}`,
    expect: "inspired by Rust\ninspired by MoonBit\ninspired by Koka\ninspired by Verse\ncompiled by vibe, in this browser tab\n",
    hint: "右の出力は、このページに埋め込んだ <b>セルフホストの vibe コンパイラ (wasm)</b> がこのタブでコンパイルし、生成された wasm を実行した結果。",
  },
  effects: {
    source: String.raw`
effect Log {
  Emit(String) -> Unit
}

fn work(x: Int) -> Int with Log {
  perform Log::Emit("start: \{x}")
  let y = x * 2
  perform Log::Emit("doubled: \{y}")
  y
}

fn main allows Console {
  let r = handle {
    work(21)
  } with {
    Log::Emit(msg) => {
      println("[log] \{msg}")
      resume(())
    }
  }
  println("result = \{r}")
}`,
    expect: "[log] start: 21\n[log] doubled: 42\nresult = 42\n",
    hint: "<code>work</code> はログの出し先を知らない。<code>handle</code> が実装を与える。<br>試す: ハンドラ腕の <code>println</code> を消す → テスト用の無音ハンドラになる。",
  },
  rows: {
    source: String.raw`
fn risky(x: Int) -> Int with Exception {
  if x == 0 {
    throw("division by zero")
  }
  100 / x
}

// row variable e: pure if f is pure, throws if f throws
fn twice(f~: (Int) -> Int with e, x~: Int) -> Int with e {
  f(f(x))
}

fn main allows Console {
  println("pure: \{twice(f=(n) -> n * 2, x=10)}")
  let r = handle {
    twice(f=risky, x=0)
  } with {
    Exception::Throw(msg) => {
      println("caught: \{msg}")
      -1
    }
  }
  println("r = \{r}")
}`,
    expect: "pure: 40\ncaught: division by zero\nr = -1\n",
    hint: "試す: <code>handle</code> を外して <code>twice(f=risky, x=0)</code> を直接呼ぶ → <code>main</code> の row に <code>Exception</code> が足りない、と言われる。",
  },
  caps: {
    source: String.raw`
fn greet(name: String) -> Unit with Console {
  println("hi \{name}")
}

fn main allows Console {
  greet("自作言語を自慢する会")
}`,
    expect: "hi 自作言語を自慢する会\n",
    hint: "試す: ① <code>greet</code> の <code>with Console</code> を消す ② <code>allows</code> を <code>with</code> に書き換える ③ <code>greet</code> の中で <code>Fs::read_file(\"secret\")</code> を呼ぶ。<br>診断は <b>直し方</b> から始まる。",
  },
  zero_alloc: {
    source: String.raw`
#zero_alloc
fn hot(a: Int, b: Int) -> Int {
  let s = a + b
  s * 2 - a
}

fn main allows Console {
  println("hot = \{hot(14, 14)}")
}`,
    expect: "hot = 42\n",
    hint: "試す: <code>hot</code> の本体を <code>Array::length([a, b])</code> にする → ヒープ確保がコンパイルエラーになる。推移的に呼ぶ関数も検査される。",
  },
  eq: {
    source: String.raw`
struct Pt {
  x: Int,
  y: Int
}

fn main allows Console {
  let a = [Pt::{ x: 1, y: 2 }, Pt::{ x: 3, y: 4 }]
  let b = [Pt::{ x: 1, y: 2 }, Pt::{ x: 3, y: 4 }]
  println("arrays: \{a == b}")
  println("tuples: \{(1.5, "a") == (1.5, "a")}")
}`,
    expect: "arrays: true\ntuples: true\n",
    hint: "試す: <code>let same = (p, q) -&gt; p == q</code> を足す → 型の分からない <code>==</code> は<b>注釈を求めてエラー</b>になる。",
  },
  pipe: {
    source: String.raw`
struct Talk {
  title: String,
  minutes: Int
}

fn main allows Console {
  let talks = [
    Talk::{ title: "gfx", minutes: 12 },
    Talk::{ title: "kawasima", minutes: 12 },
    Talk::{ title: "mizchi", minutes: 12 },
  ]
  let total = talks |> Array::map(_, (t) -> t.minutes) |> Array::fold(_, 0, _ + _)
  let n = "  vibe  " |> String::trim |> String::length
  println("total = \{total} min, n = \{n}")
}`,
    expect: "total = 36 min, n = 4\n",
    hint: "メソッド呼び出し <code>x.f()</code> は無い。<code>.</code> はフィールドだけ。関数は必ず <code>Type::f</code> で書き、<code>|&gt;</code> と <code>_</code> でつなぐ。",
  },
};

export const CODE: Record<string, string> = {
  syntax: String.raw`
import @vibe/core { Attempt }           // file-scoped, explicit
import ./talk.vibe { Talk, render }

let n = String::length(title)            // never title.length()
let m = title |> String::trim |> String::length
let w = talk.minutes                     // '.' is field access only`,
  taskgroup: String.raw`
import @vibe/concurrent { TaskGroup, TaskHandle }

fn main allows Console + Exception {
  let total = TaskGroup::run((g) -> {
    let a = TaskGroup::spawn(g, () -> 1)
    let b = TaskGroup::spawn(g, () -> 2)
    TaskHandle::join(a) + TaskHandle::join(b)
  })            // the group never outlives run()
  println("total = \{total}")
}`,
  optional: String.raw`
fn main allows Console + Fs::read_file? {
  match perform? Fs::read_file("config.json") {
    NotGranted => println("not granted"),
    Errored(_) => println("errored"),
    Granted(_) => println("granted")
  }
}`,
};

const CLI = String.raw`<span class="prompt">$</span> vibe check app.vibe            <span class="out"># empty = compiles</span>
<span class="prompt">$</span> vibe symbols app.vibe
<span class="out">add 12 3 6
main 12 46 50</span>
<span class="prompt">$</span> vibe type-at app.vibe 5 4
<span class="out">() -> () with Console</span>
<span class="prompt">$</span> vibe grep --pattern 'f($(x:exp))' --where '$x : Array[_]' lib
<span class="prompt">$</span> vibe grep --pattern '$(f:id)($(a:args))' --where-row '$f with Async' lib
<span class="prompt">$</span> vibe run --deny-fs app.vibe     <span class="out"># denied caps are DCE'd away</span>`;

export const SLIDES: Slide[] = [
  {
    className: "title",
    html: `
      <div class="logo">vibe<span>-lang</span></div>
      <div class="tagline">シグネチャが「できること」を語る、<br><strong>wasm ファースト</strong>な<strong>セルフホスト</strong>関数型言語</div>
      <div class="meta">mizchi · 自作プログラミング言語を自慢する会 · 2026-10-22<br>
      <span class="small">このスライドの中で vibe コンパイラ (wasm) が動いています · github.com/mizchi/vibe-lang</span></div>`,
    notes: "0:00 (20s) 挨拶。「このスライド自体の中で vibe のコンパイラが動いています」と最初に言う。",
  },
  {
    html: `
      <h2><span class="kicker">What</span>vibe とは</h2>
      <div class="cols wide-left grow">
        <div>
          <ul>
            <li>静的型付きの関数型言語 → <strong>WebAssembly</strong></li>
            <li>エフェクトは戻り値のラッパーではなく <strong>effect row</strong> に乗る</li>
            <li><strong>権限 (capability)</strong> もその row に乗り、ビルド時に確定する</li>
            <li>コンパイラは vibe 自身で書かれ、wasm として動く</li>
          </ul>
          <p class="muted">参考にしたもの</p>
          <div class="chips">
            <span class="chip">MoonBit — wasm first</span>
            <span class="chip">Koka — effect system</span>
            <span class="chip">Verse</span>
            <span class="chip">Rust — Book / 診断</span>
            <span class="chip">Deno — permissions</span>
          </div>
        </div>
        <div class="card">
          <h3>Required (wasm の新しめの機能)</h3>
          <ul>
            <li><code>v128</code> SIMD</li>
            <li><code>js-string</code> builtins</li>
            <li>WASI p3 / component model</li>
            <li>exception handling (<code>exnref</code>)</li>
          </ul>
          <p class="small muted">CLI は Rust + Wasmtime。ホスト import を外付けして Browser / Node でも動く。</p>
        </div>
      </div>`,
    notes: "0:20 (40s) 一言で: シグネチャがその関数にできることを言う言語。row にエフェクトも権限も乗る。参考にした言語を指す。",
  },
  {
    html: `
      <h2><span class="kicker">Live</span>このタブでコンパイルして実行</h2>
      <div class="demo" data-demo="hello"></div>`,
    notes: "1:00 (30s) r で実行 → compile+run の ms を読む。ブラウザのタブ内でセルフホストのコンパイラが動いている。",
  },
  {
    html: `
      <h2><span class="kicker">Why</span>wasm first な言語が欲しかった</h2>
      <div class="cols">
        <div class="card">
          <h3>速さを wasm で取りたい</h3>
          <ul>
            <li><code>v128</code> SIMD を使うと素直に速くなる</li>
            <li>MoonBit の標準ライブラリに SIMD 化 PR を送りまくっている</li>
            <li>本当は 256bit lane が欲しい…</li>
          </ul>
        </div>
        <div class="card">
          <h3>ブラウザで動くものはブラウザで開発できるべき</h3>
          <ul>
            <li>だからセルフホスト (コンパイラ自体が wasm)</li>
            <li>MoonBit はマルチターゲットで大変そう → wasm だけに絞る</li>
            <li>component model に合わせたモジュールシステム</li>
          </ul>
        </div>
      </div>
      <p class="quote">設計の迷いどころのプロンプト: <strong>「迷ったら wasm / wasi のプリミティブとして自然な方」</strong></p>
      <p class="small muted">値は tagged i64、<code>String</code> はバイト列 (byte offset で添字)。WIT 境界に出られる型は nominal に決まる。</p>`,
    notes: "1:30 (30s) 動機1: wasm first。SIMD、ブラウザで開発、component model。「迷ったら wasm/wasi として自然な方」。",
  },
  {
    html: `
      <h2><span class="kicker">Why</span>AI first な言語が欲しかった</h2>
      <div class="cols">
        <div class="card">
          <h3>権限を制御したい</h3>
          <ul>
            <li>Vibe Coding で書かれたコードが <em>何をしうるか</em> をシグネチャで読みたい</li>
            <li>Deno のパーミッション × Koka のエフェクト</li>
            <li>呼び出し側の式はただの関数呼び出しのまま ("色のない関数")</li>
          </ul>
        </div>
        <div class="card">
          <h3>型と診断を LLM の評価ループ向けに</h3>
          <ul>
            <li>最悪の壊れ方は <strong>黙って間違うこと</strong> (P0) — クラッシュ (P1) より上</li>
            <li>診断は <strong>直し方</strong> から始める。pass 名や ADR 番号を出さない</li>
            <li>LSP ではなく <strong>CLI</strong> で IDE 相当の問い合わせ</li>
          </ul>
        </div>
      </div>`,
    notes: "2:00 (30s) 動機2: AI first。権限制御と、LLM の評価ループ向けの診断。黙って間違うのが最悪。",
  },
  {
    className: "section",
    html: `<h1><small>FEATURES</small>カッコいいところ</h1><p class="muted">ここからはスライド内でライブコンパイルします</p>`,
    notes: "2:30 (5s) ここからライブ。",
  },
  {
    html: `
      <h2><span class="kicker">Effects</span>エフェクトは row に乗る</h2>
      <div class="demo" data-demo="effects"></div>`,
    notes: "2:35 (40s) r で実行。Koka 由来の代数的エフェクト。resume は one-shot / 末尾に絞った。println を消して無音ハンドラにしてみせる。",
  },
  {
    html: `
      <h2><span class="kicker">Row polymorphism</span>row は変数にできる</h2>
      <div class="demo" data-demo="rows"></div>`,
    notes: "3:15 (35s) row 変数 e。twice は f が純粋なら純粋、throw するなら Exception を運ぶ。handle を外してエラーを見せてもよい。",
  },
  {
    html: `
      <h2><span class="kicker">Capabilities</span><code>with</code> は要求、<code>allows</code> は付与</h2>
      <div class="demo" data-demo="caps"></div>`,
    notes: "3:50 (50s) ライブで with Console を消す → 直し方が出る。allows → with に変える → `write fn main allows Console`。Deno × Koka。",
  },
  {
    html: `
      <h2><span class="kicker">Authority</span>権限はビルドの最初に一度だけ決まる</h2>
      <div class="flow">
        <div class="node hot"><b>build</b><span>--allow-* / --deny-*<br>const-fold + DCE</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>apply</b><span>feature level を宣言<br>(v8 / web-baseline)</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>instantiate</b><span>付与されない必須 cap は<br>main の前に停止</span></div>
      </div>
      <div class="cols">
        <div>
          <ul class="small">
            <li>拒否された capability のコードは <strong>wasm に入らない</strong> — <code>Http</code> に届かないプログラムはネットワークのランタイムを要求しない</li>
            <li>実行中に権限は変わらない</li>
            <li>省略可能な権限は <code>perform?</code> で <code>Attempt</code> を受ける</li>
          </ul>
        </div>
        <pre class="code" data-src="optional"></pre>
      </div>
      <div class="hosts">
        <div class="host"><b>CLI</b><span>Rust + Wasmtime</span></div>
        <div class="host"><b>Browser</b><span>imports を JS で外付け</span></div>
        <div class="host"><b>Node.js</b><span>imports を JS で外付け</span></div>
      </div>`,
    notes: "4:40 (35s) 権限はビルド時に一度。拒否した cap は const-fold + DCE で wasm から消える。ホストは imports を外付け。",
  },
  {
    html: `
      <h2><span class="kicker">#zero_alloc</span>OxCaml から移植: アロケーションしない契約</h2>
      <div class="demo" data-demo="zero_alloc"></div>`,
    notes: "5:15 (30s) OxCaml の #zero_alloc。本体を Array::length([a, b]) にしてエラーを見せる。",
  },
  {
    html: `
      <h2><span class="kicker">Syntax</span>メソッド呼び出しは要らない</h2>
      <ul>
        <li><code>foo.bar()</code> のメッセージパッシングは無い</li>
        <li><code>.</code> の補完は人間用。LLM には<strong>型名を省略しない方が読める</strong></li>
        <li><code>Foo::bar(foo)</code> か <code>foo |&gt; Foo::bar()</code>。<code>foo.prop</code> はフィールドアクセスだけ</li>
        <li>import はファイルスコープで明示 — JS / Python のように、書いたものだけがスコープに現れる</li>
      </ul>
      <pre class="code" data-src="syntax"></pre>`,
    notes: "5:45 (30s) メソッド呼び出しを捨てた理由: . 補完は人間用。LLM には型名が書いてある方が読める。",
  },
  {
    html: `
      <h2><span class="kicker">Pipe</span><code>|&gt;</code> と <code>_</code> でつなぐ</h2>
      <div class="demo" data-demo="pipe"></div>`,
    notes: "6:15 (20s) r で実行。|> と _ のセクション。",
  },
  {
    html: `
      <h2><span class="kicker">Concurrency</span>スレッドではなく TaskGroup</h2>
      <div class="cols wide-left">
        <pre class="code" data-src="taskgroup"></pre>
        <div>
          <ul class="small">
            <li>構造化並行性: グループは <code>run</code> より長生きしない</li>
            <li>region タグで値の脱出を拒否、<code>Send</code> 検査</li>
            <li>今は shared-nothing。スケジューラは決定的で、意味は並列 backend でも同じ</li>
            <li>待つことは <code>Async</code> effect が表す</li>
          </ul>
        </div>
      </div>`,
    notes: "6:35 (25s) TaskGroup: 構造化並行性。グループは run より長生きしない。今は shared-nothing。",
  },
  {
    html: `
      <h2><span class="kicker">CLI as IDE</span>LLM が叩く前提の CLI</h2>
      <pre class="code console">${CLI}</pre>
      <ul class="small">
        <li>1件1行・固定フィールド順・<strong>空出力 = clean</strong>。LSP と同じ解析を CLI から直接</li>
        <li><code>vibe grep</code> は AST パターン + checker の答え (型・effect row) でフィルタ。<code>vibe mutate</code> でテストの効き目も測る</li>
        <li>CLI が答えられない質問は、そのまま LLM のコスト → <strong>その場で CLI を直す</strong></li>
      </ul>`,
    notes: "7:00 (30s) LSP ではなく CLI。空出力 = clean。LLM が叩けないものは CLI 側を直す。",
  },
  {
    className: "section",
    html: `<h1><small>HOW</small>どう作ったか</h1>`,
    notes: "7:30 (5s) どう作ったか。",
  },
  {
    html: `
      <h2><span class="kicker">Process</span>作り方</h2>
      <div class="cols">
        <ul class="small">
          <li><strong>MoonBit でプロトタイプ</strong>
            <div class="small muted">経験的に、言語はホストした言語に似ていく</div></li>
          <li>一通り動いてから parser → codegen → CLI の順にセルフホスト化</li>
          <li>適当に論文を突っ込む</li>
          <li><strong>Lean</strong> で難しい部分を実装してテストオラクルに
            <div class="small muted">effect row の健全性 / モジュールシステム / スレッド実行モデル</div></li>
          <li>「バグを潰して」</li>
          <li>Rust Book を参考に <strong>Vibe Book</strong> — 例は全部 CI で実行。サブエージェントにルーブリックで使いやすさを採点させる</li>
        </ul>
        <div class="card small">
          <h3>Timeline (2026)</h3>
          <table class="facts">
            <tr><td class="num">02-03</td><td>初コミット。名前は <code>xsh</code> (シェル言語)、MoonBit 実装</td></tr>
            <tr><td class="num">03-01</td><td>vibe で書いた parser / evaluator が自分のソースを読めた</td></tr>
            <tr><td class="num">04-14</td><td>v0.0.1 (MoonBit ホスト最後のリリース)</td></tr>
            <tr><td class="num">06-28</td><td>MoonBit 実装 <code>src/</code> (7.3MB) を削除 → selfhost-only</td></tr>
            <tr><td class="num">09-21</td><td>v0.1.0-rc.1 … 今は 0.1.0 直前</td></tr>
          </table>
          <div class="cols three" style="margin-top:1cqw;gap:1cqw">
            <div><div class="big-number">2,035</div><div class="label">PRs (8.5ヶ月)</div></div>
            <div><div class="big-number">1,547</div><div class="label">issues</div></div>
            <div><div class="big-number">264</div><div class="label">P0 = 黙って誤る</div></div>
          </div>
        </div>
      </div>`,
    notes: "7:35 (40s) MoonBit でプロトタイプ → 部分ごとにセルフホスト。Lean をオラクルに。Vibe Book をサブエージェントに採点させた。8.5ヶ月で PR 2,035。",
  },
  {
    html: `
      <h2><span class="kicker">Self-hosting</span>seed → stage1 → stage2 → stage3</h2>
      <div class="flow">
        <div class="node"><b>seed</b><span>pin された compiler.wasm<br>(sha256 検証)</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>stage1</b><span>seed が今のソースを<br>コンパイル</span></div>
        <div class="arrow">→</div>
        <div class="node hot"><b>stage2</b><span>stage1 が自分を<br>コンパイル = 本番</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>stage3</b><span>stage2 と <strong>バイト一致</strong><br>(fixpoint)</span></div>
      </div>
      <ul class="small">
        <li>新しい構文をコンパイラ自身で使うには、先に seed がその構文を理解する状態を tag してから bump する</li>
        <li>MoonBit も LLVM も要らない。必要なのは wasm ランナーだけ</li>
        <li>罠: <code>vibe test</code> は既定で <strong>seed</strong> がコンパイルする → コンパイラの変更を「どのコンパイラが答えたか」分からないまま検証してしまう</li>
      </ul>
      <p class="quote small">44 行の変更で seed の自己ビルドが <strong>wasm32 の 4GiB 上限</strong>を突破 — pass 3 で 3.89GiB、残り 119MB だった (#3439)</p>`,
    notes: "8:15 (35s) seed → stage3 の fixpoint。4GiB の話で笑いを取る。",
  },
  {
    className: "section",
    html: `<h1><small>PAIN</small>大変だったこと</h1>`,
    notes: "8:50 (5s) 大変だったこと。",
  },
  {
    html: `
      <h2><span class="kicker">Pain 1</span>速さとメモリ</h2>
      <div class="cols">
        <div class="card">
          <h3>ベンチが信用できない</h3>
          <ul class="small">
            <li>GitHub Actions のランナー次第で、無関係な PR が <strong>20〜64% 遅く</strong>見える</li>
            <li>VM 割り当てだけでなくハードも違う (AVX512 がある時と無い時)</li>
            <li>較正係数を入れても ±15〜40% 揺れる → <strong>wall-time をやめて wasmtime の fuel (実行命令数)</strong> で判定。±2%</li>
            <li>ヒープも決定的に、許容誤差ゼロで比較</li>
          </ul>
        </div>
        <div class="card">
          <h3>セルフビルドが重い / メモリが漏れまくる</h3>
          <ul class="small">
            <li>cold セルフコンパイルのヒープ 1,203MB → <strong>953MB</strong> (#3579, 10/21)</li>
            <li>release-check は 126 タスクで 55 分</li>
            <li>リークの実例: <code>let rec</code> クロージャが評価ごとに 24B、片側分岐の消費で反復ごとに 80B</li>
            <li>→ <strong>Perceus</strong> (参照カウント) + <strong>FBIP</strong> (in-place 再利用)。再利用はコンストラクタ 8,879 箇所中 1,830 で成立…でも壁時計はほぼ変わらず</li>
          </ul>
        </div>
      </div>
      <p class="small muted">linear と wasm-gc の 2 本立ても重い: Int のオーバーフローで 2 つのレーンが<strong>黙って別の値</strong>を返していた (62/63/64bit でラップ位置が違う, #1877)</p>`,
    notes: "8:55 (45s) ベンチが揺れる → fuel に切り替え。ヒープ 953MB。Perceus + FBIP。",
  },
  {
    html: `
      <h2><span class="kicker">Pain 2</span>AI と作ると起きること</h2>
      <div class="cols">
        <div class="card">
          <h3>安いモデルで回すと</h3>
          <ul class="small">
            <li><strong>バグが生まれる速度 &gt; バグが潰れる速度</strong></li>
            <li>レビューの P1 指摘 4 件中 3 件が、その PR 自身が入れたバグ</li>
            <li>bug ラベル 839 件、うち P0 (黙って誤る) 264 件</li>
          </ul>
          <h3 style="margin-top:1cqw">対策</h3>
          <ul class="small">
            <li>ゲートは <strong>失敗できることを証明してから</strong>信用する (red test 必須)</li>
            <li>Lean のオラクルが checker との差分を 3 件発見</li>
          </ul>
        </div>
        <div class="card">
          <h3>変な実装が放置される</h3>
          <ul class="small">
            <li>String interning していない → 全シンボルを文字列比較して爆発。線形走査 + 防御的コピーを 3 回別々に「修正」</li>
            <li>型システムの穴を <strong>大量の実行時アサーション</strong>で止めようとする → <code>trap: unreachable</code> をビルドエラーへ</li>
            <li>構文だけで判定する検査に、26 回のレビューで抜け道 63 個 → <strong>57 関数・1,970 行を削除</strong>して型検査器に一本化</li>
            <li>初期のエフェクトハンドラは resume のたびに本体を<strong>最初から再実行</strong>していた (replay 方式)</li>
          </ul>
        </div>
      </div>`,
    notes: "9:40 (45s) 安いモデルだとバグの生成 > 修正。interning 無し、実行時アサーション、1,970 行削除。",
  },
  {
    html: `
      <h2><span class="kicker">Pain 3</span>黙って間違う <code>==</code></h2>
      <div class="cols wide-left">
        <div>
          <ul class="small">
            <li><code>[1, 2] == [1, 2]</code> が文脈で答えを変えた: 裸だと参照比較、struct の中だと構造比較、tuple の中だとまた参照比較 (#1526)</li>
            <li><code>fn bare[T: Eq](a: T, b: T)</code> で <code>bare(1.5, 1.5)</code> が <strong>false</strong> — <code>Double</code> は箱を比べていた (#2895)</li>
            <li><code>Eq</code> はメソッドの無いマーカー trait だった → <code>equals</code> を持たせて witness 経由でディスパッチ (#2523)</li>
            <li>型が届かない <code>==</code> は「参照の同一性で答える」のではなく <strong>注釈を求めてビルドを止める</strong></li>
          </ul>
        </div>
        <div class="card">
          <h3>方針</h3>
          <p class="small">壊れ方の優先度は<br><strong>黙って間違う (P0) &gt; 落ちる (P1) &gt; 機能追加 (P2)</strong></p>
          <p class="small">「動いてるように見える」が一番高くつく。LLM の評価ループはそれを見抜けない。</p>
        </div>
      </div>
      <div class="demo" data-demo="eq"></div>`,
    notes: "10:25 (40s) == の話。r で実行して true を見せる。P0 > P1 の方針。",
  },
  {
    html: `
      <h2><span class="kicker">Spec gaps</span>wasm の仕様が足りない</h2>
      <div class="cols three">
        <div class="card"><h3>スレッド</h3><p class="small">結局どれを使えばいいのか。今は shared-nothing で設計し、本物のスレッドを見越して表現を選んでいる</p></div>
        <div class="card"><h3>wasm-gc × SIMD</h3><p class="small">wasm-gc の ref 型の配列には <code>v128</code> が使えない。だから linear と wasm-gc の 2 本立て</p></div>
        <div class="card"><h3>WIT</h3><p class="small">ジェネリクスが無い。境界に出せる型を nominal 規則で決めている</p></div>
      </div>`,
    notes: "11:05 (25s) wasm の仕様が足りない: スレッド、wasm-gc の配列に v128 が無い、WIT にジェネリクスが無い。",
  },
  {
    html: `
      <h2><span class="kicker">Good parts</span>よかったもの・気になるもの</h2>
      <div class="cols">
        <div class="card">
          <h3>よかったもの</h3>
          <ul>
            <li><strong>wasmtime guest profiler</strong> — wasm のままプロファイル</li>
            <li>Fuel で命令数を数える (ベンチのぶれ対策)</li>
            <li>OxCaml の <code>#zero_alloc</code></li>
            <li>Lean のオラクル</li>
          </ul>
        </div>
        <div class="card">
          <h3>ついでに</h3>
          <ul>
            <li>MoonBit 標準ライブラリへの SIMD PR</li>
          </ul>
          <h3 style="margin-top:1.2cqw">気になっている言語</h3>
          <ul><li>bend-lang</li><li>借用を証明する系</li></ul>
        </div>
      </div>`,
    notes: "11:30 (20s) よかったもの: wasmtime guest profiler、fuel、#zero_alloc。MoonBit への SIMD PR。気になる言語 bend。",
  },
  {
    className: "title",
    html: `
      <div class="logo">vibe<span>-lang</span></div>
      <div class="tagline">関数のシグネチャが、その関数に<strong>できること</strong>を言う。<br>それを wasm の上で、自分自身でコンパイルする。</div>
      <div class="meta">github.com/mizchi/vibe-lang · The Vibe Book: mizchi.github.io/vibe-lang</div>`,
    notes: "11:50 (10s) まとめ。リポジトリと Book の URL。",
  },
];
