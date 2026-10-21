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
    hint: "上の出力は、このタブの中で vibe コンパイラ (wasm) が今コンパイルして実行したもの",
  },
  effects: {
    source: String.raw`
fn safe_div(a: Int, b: Int) -> Int with Exception {
  if b == 0 { throw("division by zero") }
  a / b
}

fn main allows Console {
  let r = handle {
    safe_div(84, 2) + safe_div(1, 0)
  } with {
    Exception::Throw(msg) => {
      println("caught: \{msg}")
      -1
    }
  }
  println("r = \{r}")
}`,
    expect: "caught: division by zero\nr = -1\n",
    hint: "失敗しうる関数には <code>with Exception</code> と書く。<code>handle</code> を外して直接呼ぶと、<code>main</code> の row に <code>Exception</code> が足りないと言われる",
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
    hint: "<code>main</code> の <code>allows</code> を <code>with</code> にしてみる。エラーの 1 行目が直し方になってる",
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
    hint: "本体を <code>Array::length([a, b])</code> にすると、アロケーションでコンパイルエラーになる",
  },
  eq: {
    source: String.raw`
struct Pt { x: Int; y: Int }

fn main allows Console {
  let a = [Pt::{ x: 1, y: 2 }, Pt::{ x: 3, y: 4 }]
  let b = [Pt::{ x: 1, y: 2 }, Pt::{ x: 3, y: 4 }]
  println("arrays: \{a == b}")
  println("tuples: \{(1.5, "a") == (1.5, "a")}")
}`,
    expect: "arrays: true\ntuples: true\n",
    hint: "<code>let same = (p, q) -&gt; p == q</code> を足すと、注釈を求めるエラーになる",
  },
  pipe: {
    source: String.raw`
struct Talk { title: String; minutes: Int }

fn main allows Console {
  let talks = [
    Talk::{ title: "gfx", minutes: 12 },
    Talk::{ title: "kawasima", minutes: 12 },
    Talk::{ title: "mizchi", minutes: 12 },
  ]
  let total = talks
    |> Array::map(_, (t) -> t.minutes)
    |> Array::fold(_, 0, _ + _)
  let n = "  vibe  " |> String::trim |> String::length
  println("total = \{total} min, n = \{n}")
}`,
    expect: "total = 36 min, n = 4\n",
    hint: "<code>_</code> は差し込む位置。<code>_ + _</code> は 2 引数のラムダ",
  },
};

export const CODE: Record<string, string> = {
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


type Bar = { label: string; value: number; note?: string; hot?: boolean };
function bars(rows: Bar[], max: number, unit: string): string {
  return `<div class="bars">${rows
    .map(
      (r) => `<div class="bar-row${r.hot ? " hot" : ""}" title="${r.label}: ${r.value}${unit}${r.note ? ` (${r.note})` : ""}">
        <span class="bar-label">${r.label}</span>
        <span class="bar-track"><span class="bar-fill" style="width:${(100 * r.value) / max}%"></span></span>
        <span class="bar-value">${r.value}${unit}${r.note ? `<small>${r.note}</small>` : ""}</span>
      </div>`,
    )
    .join("")}</div>`;
}

const SOURCE = `<p class="source">mizchi/vibe-lang の issue 1,549 件 (bug 841) とコミット 6,934 件、2026-10-21 時点。bug は修正コミットが触ったファイルで数えた。紐付けできたのは半分くらい。</p>`;

export const SLIDES: Slide[] = [
  {
    className: "title",
    html: `
      <div class="logo">vibe<span>-lang</span></div>
      <div class="tagline"><strong>黙って間違えない</strong>言語を作ってる<br>wasm の上でセルフホストしてる関数型言語</div>
      <div class="meta">mizchi · 自作プログラミング言語を自慢する会 · 2026-10-22<br>
      <span class="small">このスライドの中で vibe のコンパイラ (wasm) が動いてる · github.com/mizchi/vibe-lang</span></div>`,
    notes: "0:00 (15s) 挨拶。黙って間違えない言語を作ってる。このスライドの中でコンパイラが動いてる",
  },
  {
    html: `
      <h2><span class="kicker">In numbers</span>数字</h2>
      <div class="stats">
        <div class="stat"><div class="big-number">260 日</div><div class="label">開発期間 (2026-02-03 〜)</div></div>
        <div class="stat"><div class="big-number">6,934</div><div class="label">コミット</div></div>
        <div class="stat"><div class="big-number">2,035</div><div class="label">PR</div></div>
        <div class="stat"><div class="big-number">1,549</div><div class="label">issue (うち bug 841)</div></div>
        <div class="stat"><div class="big-number">34.4 万行</div><div class="label">コンパイラ + CLI (vibe)</div></div>
        <div class="stat"><div class="big-number">24.9 万行</div><div class="label">テスト (test ブロック 12,523 個)</div></div>
        <div class="stat"><div class="big-number">9.6 万行</div><div class="label">CI の検査用シェルスクリプト</div></div>
        <div class="stat"><div class="big-number">19 分</div><div class="label">PR 1 回の CI (30 ジョブ、合計 130 分)</div></div>
      </div>
      <p class="source">2026-10-21 時点の main。行数は生成物を除く。stdlib は別に 8.0 万行、Lean 1.0 万行、Rust 1.2 万行。CI はこの発表資料の PR の実測で、stage2 はキャッシュから。</p>`,
    notes: "0:15 (30s) 数字。260 日で 6,934 コミット、コンパイラ 34 万行、テスト 25 万行。CI は 1 回 19 分",
  },
  {
    html: `
      <h2><span class="kicker">What</span>vibe</h2>
      <div class="cols wide-left grow">
        <div>
          <ul>
            <li>静的型付きの関数型言語。WebAssembly にコンパイルする</li>
            <li>エフェクトは Result で包まないで、関数の型 (<strong>effect row</strong>) に書く (Koka 風)</li>
            <li><strong>権限 (capability)</strong> もエフェクトとして型に書いて、ビルド時に決める</li>
            <li>コンパイラは vibe で書いてて、wasm で動く</li>
          </ul>
          <p class="muted">参考にしたもの</p>
          <div class="chips">
            <span class="chip">MoonBit (wasm first)</span>
            <span class="chip">Koka (effect system)</span>
            <span class="chip">Verse</span>
            <span class="chip">Rust (Book・診断)</span>
            <span class="chip">Deno (permissions)</span>
          </div>
        </div>
        <div class="card">
          <h3>必須の wasm 機能</h3>
          <ul>
            <li><code>v128</code> SIMD</li>
            <li><code>js-string</code> builtins</li>
            <li>WASI p3 / component model</li>
            <li>exception handling (<code>exnref</code>)</li>
          </ul>
          <p class="small muted">CLI は Rust + Wasmtime。imports を外付けすればブラウザと Node.js でも動く</p>
        </div>
      </div>`,
    notes: "0:45 (25s) row にエフェクトも権限も乗る。参考にした言語。必須の wasm 機能",
  },
  {
    html: `
      <h2><span class="kicker">Live</span>このタブでコンパイル</h2>
      <div class="demo" data-demo="hello"></div>`,
    notes: "1:10 (20s) r で実行。compile+run の ms を読む",
  },
  {
    html: `
      <h2><span class="kicker">Why</span>wasm first な言語が欲しい</h2>
      <div class="cols">
        <div class="card">
          <h3>SIMD で速くしたい</h3>
          <ul>
            <li><code>v128</code> を使うと素直に速くなる</li>
            <li>MoonBit の標準ライブラリに SIMD 化の PR を送りまくってる</li>
            <li>本当は 256bit lane を使いたい…</li>
          </ul>
        </div>
        <div class="card">
          <h3>ブラウザで開発したい</h3>
          <ul>
            <li>ブラウザで動くものは、ブラウザで開発できるべき。なのでセルフホスト</li>
            <li>MoonBit はクロスプラットフォームで大変そう。wasm だけに絞る</li>
            <li>component model に合わせたモジュールシステム</li>
          </ul>
        </div>
      </div>
      <p class="quote">設計で迷ったときのプロンプトは<strong>「迷ったら wasm / wasi のプリミティブとして自然な方」</strong></p>
      <p>wasm-gc の配列だと <code>v128</code> が使えないので、codegen は linear と wasm-gc の両対応にしてる</p>`,
    notes: "1:30 (30s) wasm first。SIMD、ブラウザで開発、component model。wasm-gc だと v128 が使えないので両対応",
  },
  {
    html: `
      <h2><span class="kicker">Why</span>AI first な言語が欲しい</h2>
      <div class="cols">
        <div class="card">
          <h3>権限を制御したい</h3>
          <ul>
            <li>Vibe Coding で書かせたコードが何をしうるか、シグネチャで読みたい</li>
            <li>Deno のパーミッション × Koka のエフェクト</li>
            <li>呼び出す側はただの関数呼び出しのまま</li>
          </ul>
        </div>
        <div class="card">
          <h3>LLM 向けの診断と CLI</h3>
          <ul>
            <li>LLM は落ちれば直すけど、<strong>黙って間違う</strong>とそのまま先に進む。これが一番困る</li>
            <li>エラーメッセージには直し方を書く。コンパイラの内部用語は出さない</li>
            <li>IDE 相当の問い合わせは LSP じゃなくて CLI で (<code>vibe symbols</code>、<code>vibe grep</code>)</li>
          </ul>
        </div>
      </div>`,
    notes: "2:00 (25s) AI first。黙って間違うのが一番まずい。LLM の評価ループは気づけない",
  },
  {
    className: "section",
    html: `<h1><small>FEATURES</small>型に書くもの</h1><p>失敗・権限・アロケーションは型に書く。書いてないとコンパイルが通らない</p>`,
    notes: "2:25 (5s) 型に書くもの 3 つ。比較の話は後半。ここからライブでコンパイル",
  },
  {
    html: `
      <h2><span class="kicker">Effects</span>effect row</h2>
      <div class="demo" data-demo="effects"></div>`,
    notes: "2:30 (30s) r で実行。handle を外すとコンパイルが止まる",
  },
  {
    html: `
      <h2><span class="kicker">Capabilities</span><code>with</code> と <code>allows</code></h2>
      <div class="demo" data-demo="caps"></div>
      <pre class="code console diag">$ vibe check greet.vibe     <span class="out"># allows を with に書き換えた</span>
<span class="out">\`fn main\` is an entry point and grants its row, so the keyword is \`allows\`:</span>
<span class="out">write \`fn main allows Console\`</span></pre>`,
    notes: "3:00 (45s) allows を with に書き換える → 下の診断がそのまま出る",
  },
  {
    html: `
      <h2><span class="kicker">Capabilities</span>ビルド時の権限</h2>
      <div class="flow">
        <div class="node hot"><b>ビルド時</b><span><code>--allow-*</code> / <code>--deny-*</code> で権限を決めて、使わないコードは DCE で消す</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>起動前</b><span>必須の権限が無ければ main の前に止める</span></div>
      </div>
      <div class="cols">
        <div>
          <ul class="small">
            <li><code>Http</code> を使わなければ、ネットワーク周りのコードは wasm に入らない</li>
            <li>ホスト (Rust + Wasmtime / ブラウザ / Node.js) は imports を外付けする。実行時の権限はここで止める</li>
            <li>省略可能な権限は <code>perform?</code> で受けて、無いときの分岐を書く</li>
          </ul>
        </div>
        <pre class="code" data-src="optional"></pre>
      </div>`,
    notes: "3:45 (30s) 権限はビルド時に一度だけ決める。使わない権限のコードは DCE で wasm から消える。足りなければ起動前に止める",
  },
  {
    html: `
      <h2><span class="kicker">Allocation</span><code>#zero_alloc</code> (OxCaml から移植)</h2>
      <div class="demo" data-demo="zero_alloc"></div>`,
    notes: "4:15 (25s) 本体を Array::length([a, b]) にしてエラーを見せる",
  },
  {
    html: `
      <h2><span class="kicker">Syntax</span>メソッド呼び出しなし</h2>
      <ul class="small">
        <li><code>foo.bar()</code> のメッセージパッシングはいらない</li>
        <li><code>.</code> の補完は人間用。LLM には型名を省略しないほうが読みやすいはず (まだ仮説)</li>
        <li><code>Foo::bar(foo)</code> か <code>foo |&gt; Foo::bar()</code>。<code>foo.prop</code> はフィールドアクセスだけ</li>
        <li>import はファイルスコープで明示。書いたものだけがスコープに出てくる</li>
      </ul>
      <div class="demo" data-demo="pipe"></div>`,
    notes: "4:40 (35s) メソッド呼び出しを捨てた理由。型名があると LLM が読みやすいはず、はまだ仮説。r でパイプ",
  },
  {
    html: `
      <h2><span class="kicker">CLI as IDE</span>LLM 用の CLI</h2>
      <pre class="code console">${CLI}</pre>
      <ul class="small">
        <li>1 件 1 行、フィールド順は固定、空出力なら clean</li>
        <li><code>vibe grep</code> は AST パターンを型や effect row で絞れる。<code>vibe mutate</code> でテストの効き目も測る</li>
        <li>CLI で答えられないと、LLM が毎回 grep で探し回る。見つけたらその場で CLI を直す</li>
      </ul>`,
    notes: "5:15 (30s) LSP じゃなくて CLI。空出力なら clean。答えられない質問は CLI を直す",
  },
  {
    className: "section",
    html: `<h1><small>HOW</small>作り方</h1>`,
    notes: "5:45 (5s) 作り方",
  },
  {
    html: `
      <h2><span class="kicker">Process</span>MoonBit からセルフホストまで</h2>
      <div class="cols">
        <ul class="small">
          <li><strong>MoonBit でプロトタイプ</strong>
            <div class="muted">経験的に、言語はホストした言語に似ていく</div></li>
          <li>一通り動いてから、parser、codegen、CLI の順にセルフホスト化</li>
          <li>適当に論文を突っ込む</li>
          <li><strong>Lean</strong> で難しそうな部分を実装して、テストオラクルにする
            <div class="muted">型検査器の健全性 / モジュールシステム / スレッド実行モデル</div></li>
          <li>あとはひたすら「バグを潰して」と言う</li>
          <li>Rust Book を参考に <strong>Vibe Book</strong> を書いた。例は全部 CI で動かして、サブエージェントにルーブリックで使いやすさを採点させてる</li>
        </ul>
        <div class="card">
          <table class="facts">
            <tr><td class="num">2026-02</td><td>MoonBit で書き始める。最初の名前は <code>xsh</code></td></tr>
            <tr><td class="num">2026-03</td><td>vibe で書いた parser が自分のソースを読めた</td></tr>
            <tr><td class="num">2026-06</td><td>MoonBit 実装を消して、セルフホストだけに</td></tr>
            <tr><td class="num">2026-10</td><td>0.1.0 直前</td></tr>
          </table>
        </div>
      </div>`,
    notes: "5:50 (35s) MoonBit でプロトタイプ → 部分ごとにセルフホスト。Lean をオラクルに。「バグを潰して」",
  },
  {
    html: `
      <h2><span class="kicker">Self-hosting</span>セルフホスト</h2>
      <div class="flow">
        <div class="node"><b>seed</b><span>pin した compiler.wasm (sha256 で検証)</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>stage1</b><span>seed が今のソースをコンパイル</span></div>
        <div class="arrow">→</div>
        <div class="node hot"><b>stage2</b><span>stage1 が自分をコンパイル。これが本番</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>stage3</b><span>stage2 と<strong>バイト一致</strong>すれば fixpoint</span></div>
      </div>
      <ul class="small">
        <li>新しい構文をコンパイラ自身で使うには、先に seed がその構文を読める状態で tag を打って bump する</li>
        <li>MoonBit も LLVM もいらない。wasm ランナーだけで動く</li>
        <li>罠。<code>vibe test</code> は既定だと seed がコンパイルする。コンパイラを直したのに、直す前のコンパイラで検証してた</li>
      </ul>
      <p class="quote small">seed の自己ビルドは pass 3 の時点で 3.89GiB、<strong>wasm32 の 4GiB</strong> まで残り 119MB。そこに 44 行足したら超えた (#3439)</p>`,
    notes: "6:25 (35s) seed → stage3。vibe test が seed で答える罠。4GiB の話",
  },
  {
    className: "section",
    html: `<h1><small>PAIN</small>大変だったこと</h1><p>バグの優先度は <strong>黙って間違う (P0) &gt; 落ちる (P1) &gt; 機能追加 (P2)</strong></p>`,
    notes: "7:00 (10s) 大変だったこと。優先度は 黙って間違う > 落ちる > 機能追加。まず数字",
  },
  {
    html: `
      <h2><span class="kicker">In numbers</span>バグの場所</h2>
      <div class="cols wide-left grow">
        <div>
          <p class="chart-title">bug の件数 (修正が触ったサブシステム)。右は P0 率</p>
          ${bars(
            [
              { label: "checker", value: 213, note: "P0 37%", hot: true },
              { label: "codegen", value: 197, note: "P0 29%", hot: true },
              { label: "stdlib", value: 133, note: "P0 38%" },
              { label: "CLI / LSP", value: 130, note: "P0 29%" },
              { label: "normalize / desugar", value: 108, note: "P0 48%", hot: true },
              { label: "runtime", value: 93, note: "P0 28%" },
              { label: "parser", value: 89, note: "P0 33%" },
              { label: "lowering", value: 66, note: "P0 36%" },
              { label: "RC / Perceus", value: 43, note: "P0 19%" },
            ],
            213,
            "",
          )}
        </div>
        <div>
          <ul class="small">
            <li>一番黙って間違うのは desugar (48%)。型を見ないで書き換えてるので、落ちずに違う答えを出す</li>
            <li>セルフホスト後、bug の起票は月 105 → 228 → 293 件</li>
          </ul>
        </div>
      </div>
      ${SOURCE}`,
    notes: "7:05 (35s) bug 841 件を修正の場所で数えた。件数は checker と codegen、黙って間違う率は desugar",
  },
  {
    html: `
      <h2><span class="kicker">In numbers</span>バグの多かった機能</h2>
      <div class="cols">
        <div>
          <p class="chart-title">100 コミットあたりの bug 件数</p>
          ${bars(
            [
              { label: "クロージャ・捕獲", value: 44, hot: true },
              { label: "String", value: 33, hot: true },
              { label: "等価性 ==", value: 28, hot: true },
              { label: "ジェネリクス・trait", value: 27 },
              { label: "エフェクト・ハンドラ", value: 23 },
              { label: "async・並行", value: 22 },
              { label: "RC / メモリ", value: 15 },
              { label: "権限 (capability)", value: 12 },
              { label: "WIT・component", value: 5 },
            ],
            44,
            "",
          )}
        </div>
        <div>
          <p class="chart-title">そのうち P0 の割合</p>
          ${bars(
            [
              { label: "等価性 ==", value: 59, hot: true },
              { label: "String", value: 53, hot: true },
              { label: "ジェネリクス・trait", value: 45, hot: true },
              { label: "クロージャ・捕獲", value: 40 },
              { label: "エフェクト・ハンドラ", value: 32 },
              { label: "RC / メモリ", value: 29 },
              { label: "async・並行", value: 26 },
              { label: "権限 (capability)", value: 18 },
              { label: "WIT・component", value: 0 },
            ],
            100,
            "%",
          )}
        </div>
      </div>
      <ul>
        <li>だいたいクロージャ × effect row × ジェネリクスが重なるところでバグる</li>
        <li>権限まわりはほぼバグらなかった</li>
      </ul>
      ${SOURCE}`,
    notes: "7:40 (35s) バグが多いのは組み合わせ。クロージャ × effect row × ジェネリクス。== と String は P0 率も高い。権限まわりはほぼバグらなかった",
  },
  {
    html: `
      <h2><span class="kicker">Pain 1</span>ベンチとメモリ</h2>
      <div class="cols">
        <div class="card">
          <h3>ベンチが安定しない</h3>
          <ul class="small">
            <li>GitHub Actions のコンテナ次第で、同じベンチでも 20% ぐらいズレる。無関係な PR が 64% 遅く見えたこともある</li>
            <li>VM 割り当てだけじゃなくてハードも違う。AVX512 がある時と無い時がある</li>
            <li>wall-time はやめて、wasmtime の <strong>fuel (実行命令数)</strong> で比べることにした</li>
          </ul>
        </div>
        <div class="card">
          <h3>セルフビルドが重い、メモリが漏れまくる</h3>
          <ul class="small">
            <li>セルフコンパイルのヒープは今でも 953MB</li>
            <li><strong>Perceus</strong> (参照カウント) と <strong>FBIP</strong> を入れた。再利用は 8,879 箇所中 1,830 で効いたけど、実行時間はほとんど変わらなかった</li>
          </ul>
        </div>
      </div>
      <p class="small">linear と wasm-gc の両対応も重い。Int のオーバーフローの結果が linear 版と wasm-gc 版で黙って違ってた (#1877)</p>`,
    notes: "8:15 (35s) ベンチが揺れるので fuel に切り替えた。ヒープ 953MB。FBIP は効いたけど壁時計は変わらず",
  },
  {
    html: `
      <h2><span class="kicker">Pain 2</span>安いモデルで開発すると</h2>
      <div class="cols">
        <div class="card">
          <h3>バグが生まれる速度 &gt; 潰れる速度</h3>
          <ul class="small">
            <li>ある PR のレビューで落ちるバグ (P1) が 4 件出て、3 件はその PR 自身が入れたものだった (#2725)</li>
            <li>bug 841 件、うち P0 は 266 件</li>
            <li>CI の検査が 5 回 ok を返して、実は何も見てなかった (#2248)。今はわざと壊して落ちるのを見てから信用してる</li>
            <li>Lean のオラクルが型検査器との食い違いを 3 件見つけた</li>
          </ul>
        </div>
        <div class="card">
          <h3>変な実装が放置される</h3>
          <ul class="small">
            <li>String interning してなくて、全シンボルを文字列比較して爆発</li>
            <li>型システムの穴を、大量の実行時アサーションで止めようとする</li>
            <li>構文だけで判定する検査に抜け道が 63 個。1,970 行消して型検査器に寄せた</li>
            <li>最初のエフェクトハンドラは resume のたびに本体を頭から再実行してた</li>
          </ul>
        </div>
      </div>`,
    notes: "8:50 (45s) 安いモデルだとバグの生成 > 修正。interning なし、実行時アサーション、replay 方式のハンドラ",
  },
  {
    html: `
      <h2><span class="kicker">Pain 3</span><code>==</code></h2>
      <ul class="small">
        <li><code>[1, 2] == [1, 2]</code> の答えが文脈で変わってた。そのまま書くと参照比較、struct の中だと構造比較 (#1526)</li>
        <li>ジェネリクス越しの <code>1.5 == 1.5</code> が <strong>false</strong>。<code>Double</code> の箱を比べてた (#2895)</li>
        <li>今は、型が分からない <code>==</code> はビルドエラーにして、型注釈を書かせる</li>
      </ul>
      <div class="demo" data-demo="eq"></div>`,
    notes: "9:35 (40s) == が黙って間違ってた (昔は false)。r で実行、今は両方 true",
  },
  {
    html: `
      <h2><span class="kicker">Spec gaps</span>wasm に足りないもの</h2>
      <div class="cols three">
        <div class="card"><h3>スレッド</h3><p class="small">結局どれ。今は <code>TaskGroup</code> の構造化並行性と shared-nothing でやってる。wasm threads が来たら乗り換えられるようにはしてる</p></div>
        <div class="card"><h3>wasm-gc と SIMD</h3><p class="small">wasm-gc の ref 型だと、配列に <code>v128</code> が使えない。両対応を続けるのがしんどい</p></div>
        <div class="card"><h3>WIT</h3><p class="small">ジェネリクスがない。WIT に出せる型はこっちで決め打ちしてる</p></div>
      </div>
      <p>よかったのは wasmtime の guest profiler と fuel。気になってる言語は bend-lang</p>`,
    notes: "10:15 (35s) 仕様が足りない。スレッド、wasm-gc の v128、WIT のジェネリクス",
  },
  {
    className: "closing",
    html: `
      <h2><span class="kicker">Next</span>これから</h2>
      <ul>
        <li>0.1.0 をもうすぐ出すので、触ってみてください</li>
        <li>皆さんも自作言語をセルフホストしましょう</li>
      </ul>
      <p class="muted">github.com/mizchi/vibe-lang · The Vibe Book: mizchi.github.io/vibe-lang</p>`,
    notes: "10:50 (30s) 0.1.0 触ってください。皆さんもセルフホストしましょう",
  },
];
