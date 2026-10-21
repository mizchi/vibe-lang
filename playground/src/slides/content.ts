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
    hint: "上の出力は、このページに埋め込んだ <b>セルフホストの vibe コンパイラ (wasm)</b> がこのタブでコンパイルし、生成された wasm を実行した結果。",
  },
  effects: {
    source: String.raw`
effect Log {
  Emit(String) -> Unit
}

fn work(x: Int) -> Int with Log {
  perform Log::Emit("start: \{x}")
  x * 2
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
    expect: "[log] start: 21\nresult = 42\n",
    hint: "<code>work</code> はログの出し先を知らない。<code>handle</code> が実装を与える。",
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
    hint: "試す: <code>main</code> の <code>allows</code> を <code>with</code> にする。診断は<b>直し方</b>から始まる。",
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
    hint: "試す: 本体を <code>Array::length([a, b])</code> にする → 確保がコンパイルエラーになる。",
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
    hint: "試す: <code>let same = (p, q) -&gt; p == q</code> を足す → 注釈を求めるエラーになる。",
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
    hint: "<code>_</code> は差し込む位置。<code>_ + _</code> は 2 引数ラムダ。",
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

export const SLIDES: Slide[] = [
  {
    className: "title",
    html: `
      <div class="logo">vibe<span>-lang</span></div>
      <div class="tagline"><strong>黙ってやらない</strong>言語。シグネチャが「できること」を語る、<br>wasm ファーストなセルフホスト関数型言語</div>
      <div class="meta">mizchi · 自作プログラミング言語を自慢する会 · 2026-10-22<br>
      <span class="small">このスライドの中で vibe コンパイラ (wasm) が動いています · github.com/mizchi/vibe-lang</span></div>`,
    notes: "0:00 (20s) 挨拶。「黙ってやらない言語です」。このスライドの中でコンパイラが動いていると最初に言う。",
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
            <span class="chip">MoonBit (wasm first)</span>
            <span class="chip">Koka (effect system)</span>
            <span class="chip">Verse</span>
            <span class="chip">Rust (Book・診断)</span>
            <span class="chip">Deno (permissions)</span>
          </div>
        </div>
        <div class="card">
          <h3>必須にした wasm の機能</h3>
          <ul>
            <li><code>v128</code> SIMD</li>
            <li><code>js-string</code> builtins</li>
            <li>WASI p3 / component model</li>
            <li>exception handling (<code>exnref</code>)</li>
          </ul>
          <p class="small muted">CLI は Rust + Wasmtime。ホスト import を外付けして Browser / Node でも動く。</p>
        </div>
      </div>`,
    notes: "0:20 (35s) row にエフェクトも権限も乗る。参考にした言語を指す。必須の wasm 機能は v128 / js-string / component model / exnref。",
  },
  {
    html: `
      <h2><span class="kicker">Live</span>このタブでコンパイルして実行</h2>
      <div class="demo" data-demo="hello"></div>`,
    notes: "0:55 (30s) r で実行 → compile+run の ms を読む。タブの中でセルフホストのコンパイラが動いている。",
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
      <p>wasm-gc の配列には <code>v128</code> が乗らない → codegen は <strong>linear memory と wasm-gc の 2 本立て</strong></p>`,
    notes: "1:25 (40s) 動機1: wasm first。SIMD、ブラウザで開発、component model。wasm-gc の配列に v128 が乗らないので 2 本立て。",
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
            <li>最悪の壊れ方は <strong>黙って間違うこと</strong> (P0)。クラッシュ (P1) より悪い。LLM の評価ループはそれに気づけない</li>
            <li>診断は <strong>直し方</strong> から始める。pass 名や ADR 番号を出さない</li>
            <li>LSP ではなく <strong>CLI</strong> で IDE 相当の問い合わせ</li>
          </ul>
        </div>
      </div>`,
    notes: "2:05 (35s) 動機2: AI first。LLM の評価ループは黙って間違うのに気づけない。だから P0 = 黙って間違う、を最悪にした。",
  },
  {
    className: "section",
    html: `<h1><small>FEATURES</small>黙ってやらない</h1><p>失敗・権限・確保・比較を、型と診断で表に出す。ここからはライブでコンパイル</p>`,
    notes: "2:40 (10s) ここから「黙ってやらせない」4 つ。ライブで。",
  },
  {
    html: `
      <h2><span class="kicker">Effects</span>黙って失敗しない: エフェクトは row に乗る</h2>
      <div class="demo" data-demo="effects"></div>`,
    notes: "2:50 (35s) r で実行。失敗も row に出る。handle が実装を与えるので、ログの出し先は呼び出し側が決める。",
  },
  {
    html: `
      <h2><span class="kicker">Capabilities</span>黙って権限を使わない: <code>with</code> は要求、<code>allows</code> は付与</h2>
      <div class="demo" data-demo="caps"></div>
      <pre class="code console diag">$ vibe check greet.vibe     <span class="out"># allows を with に書き換えた</span>
<span class="out">\`fn main\` is an entry point and grants its row, so the keyword is \`allows\`:</span>
<span class="out">write \`fn main allows Console\`</span></pre>`,
    notes: "3:25 (55s) ライブで allows を with に書き換え → 下の診断がそのまま出る。with Console を消しても直し方が出る。",
  },
  {
    html: `
      <h2><span class="kicker">Authority</span>権限はビルドの最初に一度だけ決まる</h2>
      <div class="flow">
        <div class="node hot"><b>build</b><span><code>--allow-*</code> / <code>--deny-*</code> を <code>const-fold</code> + DCE</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>apply</b><span>必要な feature level (<code>v8</code> / <code>web-baseline</code>) を宣言</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>instantiate</b><span>必須の権限が無ければ main の前に止める</span></div>
      </div>
      <div class="cols">
        <div>
          <ul class="small">
            <li>拒否された capability のコードは <strong>wasm に入らない</strong>。<code>Http</code> に届かないプログラムはネットワークのランタイムを要求しない</li>
            <li>ホスト (Rust + Wasmtime / Browser / Node) は imports を外付けする。実行時の権限はそこで止める</li>
            <li>省略可能な権限は <code>perform?</code> で <code>Attempt</code> を受ける</li>
          </ul>
        </div>
        <pre class="code" data-src="optional"></pre>
      </div>`,
    notes: "4:20 (35s) 権限はビルド時に一度。拒否した cap は const-fold + DCE で wasm から消える。ホストは imports を外付け。",
  },
  {
    html: `
      <h2><span class="kicker">#zero_alloc (OxCaml から移植)</span>黙って確保しない</h2>
      <div class="demo" data-demo="zero_alloc"></div>`,
    notes: "4:55 (30s) OxCaml の #zero_alloc。本体を Array::length([a, b]) にしてエラーを見せる。",
  },
  {
    html: `
      <h2><span class="kicker">Syntax</span>メソッド呼び出しは要らない</h2>
      <ul class="small">
        <li><code>foo.bar()</code> のメッセージパッシングは無い</li>
        <li><code>.</code> の補完は人間用。仮説: LLM には<strong>型名が書いてある方が読める</strong></li>
        <li><code>Foo::bar(foo)</code> か <code>foo |&gt; Foo::bar()</code>。<code>foo.prop</code> はフィールドアクセスだけ</li>
        <li>import はファイルスコープで明示。JS / Python と同じく、書いた名前だけがスコープに現れる</li>
      </ul>
      <div class="demo" data-demo="pipe"></div>`,
    notes: "5:25 (45s) メソッド呼び出しを捨てた。型名が書いてある方が LLM は読める、はまだ仮説。r でパイプを実行。",
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
    notes: "6:10 (35s) LSP ではなく CLI。空出力 = clean。型でフィルタする AST grep。LLM が叩けないものは CLI 側を直す。",
  },
  {
    className: "section",
    html: `<h1><small>HOW</small>どう作ったか</h1>`,
    notes: "6:45 (5s) どう作ったか。",
  },
  {
    html: `
      <h2><span class="kicker">Process</span>作り方</h2>
      <div class="cols">
        <ul class="small">
          <li><strong>MoonBit でプロトタイプ</strong>
            <div class="muted">経験的に、言語はホストした言語に似ていく</div></li>
          <li>一通り動いてから parser → codegen → CLI の順にセルフホスト化</li>
          <li>適当に論文を突っ込む</li>
          <li><strong>Lean</strong> で難しい部分を実装してテストオラクルに
            <div class="muted">effect row の健全性 / モジュールシステム / スレッド実行モデル</div></li>
          <li>「バグを潰して」</li>
          <li>Rust Book を参考に <strong>Vibe Book</strong> を書いた。例は全部 CI で実行。サブエージェントにルーブリックで使いやすさを採点させる</li>
        </ul>
        <div class="card">
          <div class="cols three" style="gap:1cqw">
            <div><div class="big-number">2,035</div><div class="label">PR (8.5ヶ月)</div></div>
            <div><div class="big-number">1,547</div><div class="label">issue</div></div>
            <div><div class="big-number">264</div><div class="label">P0 (黙って誤る)</div></div>
          </div>
          <table class="facts" style="margin-top:1.2cqw">
            <tr><td class="num">2026-02</td><td>MoonBit で書き始める</td></tr>
            <tr><td class="num">2026-06</td><td>MoonBit 実装を削除、セルフホストだけに</td></tr>
            <tr><td class="num">2026-10</td><td>0.1.0 直前</td></tr>
          </table>
        </div>
      </div>`,
    notes: "6:50 (45s) MoonBit でプロトタイプ → 部分ごとにセルフホスト。Lean をオラクルに。8.5ヶ月で PR 2,035、P0 264 件を自分で数えている。",
  },
  {
    html: `
      <h2><span class="kicker">Self-hosting</span>seed → stage1 → stage2 → stage3</h2>
      <div class="flow">
        <div class="node"><b>seed</b><span>pin された compiler.wasm (sha256 検証)</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>stage1</b><span>seed が今のソースをコンパイル</span></div>
        <div class="arrow">→</div>
        <div class="node hot"><b>stage2</b><span>stage1 が自分をコンパイル。これが本番</span></div>
        <div class="arrow">→</div>
        <div class="node"><b>stage3</b><span>stage2 と<strong>バイト一致</strong> (fixpoint)</span></div>
      </div>
      <ul class="small">
        <li>新しい構文をコンパイラ自身で使うには、先に seed がその構文を理解する状態を tag してから bump する</li>
        <li>MoonBit も LLVM も要らない。必要なのは wasm ランナーだけ</li>
        <li>罠: <code>vibe test</code> は既定で <strong>seed</strong> がコンパイルする → コンパイラの変更を「どのコンパイラが答えたか」分からないまま検証してしまう</li>
      </ul>
      <p class="quote small">44 行の変更で seed の自己ビルドが <strong>wasm32 の 4GiB 上限</strong>を突破。pass 3 で 3.89GiB、残り 119MB だった (#3439)</p>`,
    notes: "7:35 (40s) seed → stage3 の fixpoint。vibe test が seed で答える罠。4GiB の話。",
  },
  {
    className: "section",
    html: `<h1><small>PAIN</small>大変だったこと</h1>`,
    notes: "8:15 (5s) 大変だったこと。",
  },
  {
    html: `
      <h2><span class="kicker">Pain 1</span>速さとメモリ</h2>
      <div class="cols">
        <div class="card">
          <h3>ベンチが信用できない</h3>
          <ul class="small">
            <li>CI のランナー次第で、無関係な PR が <strong>最大 64% 遅く</strong>見える</li>
            <li>VM 割り当てだけでなくハードも違う (AVX512 がある時と無い時)</li>
            <li>→ wall-time をやめて <strong>wasmtime の fuel (実行命令数)</strong> で判定する</li>
          </ul>
        </div>
        <div class="card">
          <h3>セルフビルドが重い / メモリが漏れまくる</h3>
          <ul class="small">
            <li>セルフコンパイルのヒープは今も <strong>953MB</strong></li>
            <li>メモリが漏れまくる</li>
            <li><strong>Perceus</strong> (参照カウント) + <strong>FBIP</strong> (in-place 再利用)。再利用は 8,879 箇所中 1,830 で成立、でも壁時計はほぼ変わらず</li>
          </ul>
        </div>
      </div>
      <p class="small">linear と wasm-gc の 2 本立ても重い。Int のオーバーフローで 2 つのレーンが<strong>黙って別の値</strong>を返していた (#1877)</p>`,
    notes: "8:20 (45s) ベンチが揺れる → fuel に切り替えて ±2%。ヒープ 953MB。FBIP は効いたのに壁時計は変わらない。",
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
            <li>CI の検査は<strong>わざと壊した入力で落ちることを確かめてから</strong>信用する</li>
            <li>Lean のオラクルが checker との差分を 3 件発見</li>
          </ul>
        </div>
        <div class="card">
          <h3>変な実装が放置される</h3>
          <ul class="small">
            <li>String interning が無く、全シンボルを文字列比較して爆発</li>
            <li>型システムの穴を<strong>大量の実行時アサーション</strong>で塞ごうとする</li>
            <li>構文だけで判定する検査に抜け道 63 個 → <strong>1,970 行を削除</strong>して型検査器に一本化</li>
            <li>初期のエフェクトハンドラは resume のたびに本体を<strong>最初から再実行</strong>していた</li>
          </ul>
        </div>
      </div>`,
    notes: "9:05 (50s) 安いモデルだとバグの生成 > 修正。interning 無し、実行時アサーション、1,970 行削除、replay 方式のハンドラ。",
  },
  {
    html: `
      <h2><span class="kicker">Pain 3</span>それでも黙って間違っていた <code>==</code></h2>
      <p>優先度は <strong>黙って間違う (P0) &gt; 落ちる (P1) &gt; 機能追加 (P2)</strong></p>
      <ul class="small">
        <li><code>[1, 2] == [1, 2]</code> の答えが文脈で変わった。裸と tuple の中では参照比較、struct の中では構造比較 (#1526)</li>
        <li><code>[T: Eq]</code> の <code>bare(1.5, 1.5)</code> が <strong>false</strong>。<code>Double</code> の箱を比べていた (#2895)</li>
        <li>今は、型が届かない <code>==</code> では<strong>注釈を求めてビルドを止める</strong></li>
      </ul>
      <div class="demo" data-demo="eq"></div>`,
    notes: "9:55 (40s) それでも == が黙って間違っていた。r で実行して true を見せる。今は型が届かなければビルドを止める。",
  },
  {
    html: `
      <h2><span class="kicker">Spec gaps</span>wasm の仕様が足りない</h2>
      <div class="cols three">
        <div class="card"><h3>スレッド</h3><p class="small">結局どれを使えばいいのか。今は <code>TaskGroup</code> の構造化並行性 + shared-nothing。本物のスレッドを見越して表現を選んでいる</p></div>
        <div class="card"><h3>wasm-gc × SIMD</h3><p class="small">wasm-gc の ref 型の配列には <code>v128</code> が使えない。だから linear と wasm-gc の 2 本立て</p></div>
        <div class="card"><h3>WIT</h3><p class="small">ジェネリクスが無い。境界に出せる型を nominal 規則で決めている</p></div>
      </div>`,
    notes: "10:35 (30s) wasm の仕様が足りない: スレッド、wasm-gc の配列に v128 が無い、WIT にジェネリクスが無い。",
  },
  {
    html: `
      <h2><span class="kicker">Good parts</span>よかったもの・気になるもの</h2>
      <div class="cols">
        <div class="card">
          <h3>よかったもの</h3>
          <ul>
            <li><strong>wasmtime guest profiler</strong> で wasm のままプロファイル</li>
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
    notes: "11:05 (25s) よかったもの: wasmtime guest profiler、fuel。気になる言語 bend。",
  },
  {
    className: "closing",
    html: `
      <h2><span class="kicker">Takeaways</span>vibe でやったこと</h2>
      <ol class="takeaways">
        <li><strong>シグネチャが権限を語る。</strong><code>with</code> で要求し <code>allows</code> で付与する。拒否した権限のコードは wasm から消える</li>
        <li><strong>wasm の上でセルフホスト。</strong>このタブの中でもコンパイラが動いている</li>
        <li><strong>AI と作るなら、黙って間違わないことを最優先に。</strong>P0 を 264 件数えて潰した</li>
      </ol>
      <p>次は 0.1.0 のリリース。</p>
      <p class="muted">github.com/mizchi/vibe-lang · The Vibe Book: mizchi.github.io/vibe-lang</p>`,
    notes: "11:30 (30s) 3 点でまとめる。次は 0.1.0。",
  },
];
