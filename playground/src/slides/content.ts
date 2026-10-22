// Slides for "自作プログラミング言語を自慢する会" (2026-10-22).
// Slide prose is Japanese because the talk is; every gallery sample is a real
// .vibe file that `tests/slides-smoke.mjs` compiles in the browser and checks
// against `expect` / `refuse`, so a demo cannot rot silently before the talk.

import concurrentContract from "../../../lib/@vibe/concurrent/experimental/index.vpkg?raw";
import concurrentSource from "../../../lib/@vibe/concurrent/experimental/concurrent.vibe?raw";

// @vibe/concurrent as the compiler finds it in the repo: the contract the
// resolver probes for, and the module beside it that declares TaskGroup.
const CONCURRENT_PATH = "lib/@vibe/concurrent/experimental/concurrent.vibe";
const CONCURRENT: Record<string, string> = {
  "lib/@vibe/concurrent/experimental/index.vpkg": concurrentContract,
  [CONCURRENT_PATH]: concurrentSource,
};

export type Slide = { className?: string; html: string; notes?: string };

// One sample of a gallery. `source` is a real .vibe file under ./samples; the
// smoke test runs every sample in Chromium and holds it to `expect` (stdout)
// or `refuse` (a substring of the compile error it must be refused with).
export type Sample = {
  title: string;
  source: string;
  entry?: string;
  // Files sent with the source, by the path the source imports them from.
  files?: Record<string, string>;
  expect?: string;
  refuse?: string;
  hint?: string;
};

const SAMPLE_SOURCES = import.meta.glob<string>("./samples/*/*.vibe", {
  query: "?raw",
  import: "default",
  eager: true,
});

type SampleMeta = Omit<Sample, "source"> & { file: string };

function gallery(dir: string, metas: SampleMeta[]): Sample[] {
  return metas.map(({ file, ...meta }) => {
    const source = SAMPLE_SOURCES[`./samples/${dir}/${file}`];
    if (source === undefined) throw new Error(`slides: no sample ${dir}/${file}`);
    if ((meta.expect === undefined) === (meta.refuse === undefined)) {
      throw new Error(`slides: ${dir}/${file} needs exactly one of expect / refuse`);
    }
    return { ...meta, source };
  });
}

const concurrent = (metas: SampleMeta[]) => metas.map((m) => ({ ...m, files: CONCURRENT }));

export const DEMOS: Record<string, Sample[]> = {
  effects: gallery("effects", [
    { file: "1_resume.vibe", title: "resume", expect: "v = 42\n",
      hint: "<code>answer_of</code> は値の出どころを知らない。handler が <code>resume</code> した値で続きが走る" },
    { file: "2_handlers.vibe", title: "handler を差し替える", expect: "1\n2\nFizz\n4\nlines = 9\n",
      hint: "<code>fizz</code> は出力先を知らない。表示する handler と数える handler で同じ関数を動かす" },
    { file: "3_row_variable.vibe", title: "row 変数", expect: "apply_twice = 40\n",
      hint: "<code>f</code> の row が <code>e</code>。純粋な <code>f</code> なら純粋、throw する <code>f</code> なら <code>Exception</code> を運ぶ" },
    { file: "4_typed_exception.vibe", title: "Exception[E]", expect: "7\nempty\nnot a digit: x\n",
      hint: "型付きの例外。arm は payload を名前で受けて <code>match</code> する" },
    { file: "5_optional_capability.vibe", title: "perform?", expect: "not granted\n",
      hint: "省略できる権限。許可されてなければ <code>NotGranted</code> に落ちる。このタブには <code>Fs</code> が無い" },
    { file: "6_effectset.vibe", title: "effectset", expect: "bundled\n",
      hint: "権限の束に名前を付ける" },
    { file: "7_missing_row.vibe", title: "row が足りない", refuse: "missing { Exception }",
      hint: "throw しうる関数を <code>handle</code> なしで呼ぶと、<code>main</code> の row に足りないと言われる。hint が直し方" },
    { file: "8_no_resume.vibe", title: "resume が無い", refuse: "must pass its value back with resume(...)",
      hint: "arm の最後は <code>resume</code> か <code>return</code> / <code>throw</code>。値だけ返すと、続けるのか止めるのか分からないので拒否" },
    { file: "9_with_on_main.vibe", title: "main に with", refuse: "so the keyword is `allows`",
      hint: "entry は row を与える側なので <code>allows</code>。エラーの 1 行目が直し方" },
    { file: "a_payload_pattern.vibe", title: "payload で分岐", refuse: "bind the payload to a name",
      hint: "arm は operation でしか選ばれない。payload のパターンを書くと全部その arm に落ちるので、黙って間違う前に拒否" },
  ]),
  memory: gallery("memory", [
    { file: "1_zero_alloc.vibe", title: "#zero_alloc", expect: "hot = 42\n",
      hint: "ヒープに確保しない関数。呼んだ先まで見る" },
    { file: "2_zero_alloc_refused.vibe", title: "配列リテラル", refuse: "may allocate: array literal",
      hint: "配列を作った時点で拒否" },
    { file: "3_transitive.vibe", title: "呼んだ先で確保", refuse: "call to 'pair' which may allocate",
      hint: "呼んだ関数の中の確保も見つけて、どこで確保したかまで言う" },
    { file: "4_region.vibe", title: "region", expect: "sum = 45\n",
      hint: "region の中の確保はまとめて捨てる。ヒープの確保には数えない" },
    { file: "5_region_strict.vibe", title: "strict", refuse: "region/arena allocation",
      hint: "<code>#zero_alloc(strict)</code> は region の確保も拒否" },
    { file: "6_region_escape.vibe", title: "region の外へ", refuse: "region escapes its scope",
      hint: "region の値を外に返すと拒否" },
  ]),
  concurrency: gallery("concurrency", concurrent([
    { file: "1_spawn_join.vibe", title: "spawn / join", expect: "after spawn\ntask a\ntask b\ntotal = 3\n",
      hint: "<code>spawn</code> しただけでは動かない。<code>join</code> で待ったときにキューの順で動く。毎回同じ順番" },
    { file: "2_channel.vibe", title: "Channel", expect: "sum = 6\n",
      hint: "容量 1 のチャネル。<code>recv</code> は閉じて空になると <code>None</code>" },
    { file: "3_parallel_map.vibe", title: "Parallel::map", expect: "[30, 10, 20]\n",
      hint: "結果は入力の順。終わった順は観測できない" },
    { file: "4_failure.vibe", title: "失敗", expect: "caught Failed(boom)\nr = 0\n",
      hint: "タスクが throw すると group ごと失敗して、<code>join</code> が <code>TaskError</code> を投げ直す" },
    { file: "5_suspend.vibe", title: "止まるタスク", expect: "a1\nb1\na2\nb2 saw a = 1\n",
      hint: "<code>spawn_suspend</code> のタスクは <code>sleep_wait</code> で止まって、ほかのタスクに譲る" },
    { file: "6_future.vibe", title: "Future", expect: "resolved later\ntotal = 80\n",
      hint: "<code>await</code> で待つのは <code>Async</code> effect。<code>main</code> が <code>allows Async</code> する" },
    { file: "7_send_refused.vibe", title: "Send じゃない", refuse: "is neither Send nor a same-nursery endpoint",
      hint: "<code>Array</code> は <code>Send</code> じゃないのでタスクに捕まえられない" },
    { file: "8_escape_refused.vibe", title: "handle の持ち出し", refuse: "inside this TaskGroup::run body",
      hint: "<code>TaskHandle</code> を <code>run</code> の外に返すと拒否。その group はもう終わってる" },
  ])),
  syntax: gallery("syntax", [
    { file: "1_pipe.vibe", title: "パイプ", expect: "total = 36 min, n = 4\n",
      hint: "<code>_</code> は差し込む位置。<code>_ + _</code> は 2 引数のラムダ" },
    { file: "2_enum_match.vibe", title: "enum と match", expect: "area(Circle(2)) = 12\narea(Rect(6, 7)) = 42\n" },
    { file: "3_guards.vibe", title: "ガード", expect: "classify(0) = zero\nclassify(2) = small\nclassify(-5) = negative\nclassify(99) = big\n",
      hint: "or パターンと <code>if</code> ガード" },
    { file: "4_optional_arg.vibe", title: "省略できる引数", expect: "hi x1\nhi x3\n",
      hint: "<code>times?</code> は <code>Option</code> で受ける" },
    { file: "5_let_star.vibe", title: "let*", expect: "halves_or_zero(4, 6) = 5\nhalves_or_zero(4, 3) = 0\n",
      hint: "<code>Option</code> の早期脱出" },
    { file: "6_trait_bound.vibe", title: "trait", expect: "size_of = 3\n",
      hint: "<code>T::measure</code> は witness 経由で呼ぶ。メソッド呼び出しは無い" },
    { file: "7_byte_string.vibe", title: "バイト文字列", expect: "bytes = 11\nhead  = vibe\ntail  = 言語\n",
      hint: "<code>String</code> はバイト列。長さもスライスもバイト単位で、wasm のメモリそのまま" },
    { file: "8_int_wrap.vibe", title: "63bit Int", expect: "max     = 4611686018427387903\nmax + 1 = -4611686018427387904\n~0      = -1, ~5 = -6\n",
      hint: "<code>Int</code> は 63bit。どのバックエンドでも同じように wrap する" },
  ]),
  equality: gallery("equality", [
    { file: "1_structural.vibe", title: "中身で比べる", expect: "arrays: true\ntuples: true\n",
      hint: "<code>==</code> はどこに書いても中身を比べる" },
    { file: "2_bound.vibe", title: "[T: Eq]", expect: "Double: true\nString: true, false\n",
      hint: "ジェネリクス越しの <code>1.5 == 1.5</code> は昔 <code>false</code> だった" },
    { file: "3_generalized_refused.vibe", title: "注釈を求める", refuse: "annotate `p`, `q` with concrete types",
      hint: "型の分からない <code>==</code> は、参照で比べて答えるのをやめてビルドエラーにした" },
  ]),
};

// Static code blocks (colourised, not editable).
export const CODE: Record<string, string> = {
  // What `vibe new` writes (runtime/vibe, `new`).
  scaffold: String.raw`
fn main allows Console {
  println("42")
}`,
};

// Measured: `vibe new hello` then `vibe run main.vibex` in the new project.
const INSTALL = String.raw`<span class="prompt">$</span> curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
<span class="prompt">$</span> . "$HOME/.vibe/env"
<span class="prompt">$</span> vibe new hello
<span class="out">created hello (run: vibe run hello/main.vibex)</span>
<span class="prompt">$</span> cd hello
<span class="prompt">$</span> vibe run main.vibex
<span class="out">42</span>
<span class="prompt">$</span> vibe check main.vibex      <span class="out"># 空出力なら clean</span>`;

// d2 figures, laid out by TALA from ./figures/*.d2 (`pnpm figures` re-renders
// them; the SVGs are committed so a build needs no d2).
const FIGURE_SVGS = import.meta.glob<string>("./figures/*.svg", { query: "?raw", import: "default", eager: true });
function figure(name: string, className = ""): string {
  const svg = FIGURE_SVGS[`./figures/${name}.svg`];
  if (svg === undefined) throw new Error(`slides: no figure ${name}`);
  // d2 pins the drawing to the top left (xMinYMin); centre it in the space it gets.
  const centred = svg.replace(/<\?xml[^>]*>/, "").replace('preserveAspectRatio="xMinYMin meet"', 'preserveAspectRatio="xMidYMid meet"');
  return `<div class="figure ${className}">${centred}</div>`;
}

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
      <h2><span class="kicker">Getting started</span>インストールして動かす</h2>
      <pre class="code console">${INSTALL}</pre>
      <div class="cols wide-left">
        <ul class="small">
          <li>今はソースからビルドするので <code>git</code>、<code>cargo</code>、Node.js が要る (数分)。リリース後は <code>| bash -s -- --version latest</code> でビルド済みを取ってくる</li>
          <li><code>vibe new</code> は <code>main.vibex</code>、<code>index.vpkg</code> (マニフェスト)、<code>.gitignore</code> を作る。<code>.vibex</code> は <code>fn main</code> を 1 つ持つ実行用のファイル</li>
        </ul>
        <pre class="code" data-src="scaffold"></pre>
      </div>`,
    notes: "0:15 (25s) インストールは 1 行。vibe new で main.vibex ができて、vibe run で動く。ドキュメントは The Vibe Book",
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
    notes: "0:40 (30s) 数字。260 日で 6,934 コミット、コンパイラ 34 万行、テスト 25 万行。CI は 1 回 19 分",
  },
  {
    html: `
      <h2><span class="kicker">What</span>vibe</h2>
      <ul>
        <li>静的型付きの関数型言語。WebAssembly にコンパイルして、コンパイラも vibe で書いてて wasm で動く</li>
        <li>effect row に<strong>権限 (capability)</strong> も乗せて、ビルド時に決める</li>
      </ul>
      ${figure("architecture", "wide")}
      <div class="chips">
        <span class="chip">MoonBit (wasm first)</span>
        <span class="chip">Koka (effect system)</span>
        <span class="chip">Verse</span>
        <span class="chip">Rust (Book・診断)</span>
        <span class="chip">Deno (permissions)</span>
        <span class="chip muted">必須: v128 / js-string / WASI p3 / exnref</span>
      </div>`,
    notes: "1:10 (25s) 図の左から。コンパイラ自身が wasm。ホストが import を外付けするので CLI、ブラウザ、Node で同じ wasm が動く",
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
      <p class="quote">設計で迷ったときのプロンプトは<strong>「迷ったら wasm / wasi のプリミティブとして自然な方」</strong></p>`,
    notes: "1:35 (30s) wasm first。SIMD、ブラウザで開発、component model",
  },
  {
    html: `
      <h2><span class="kicker">Why</span>AI first な言語が欲しい</h2>
      <div class="cols">
        <div class="card">
          <h3>権限を制御したい</h3>
          <ul>
            <li>AI に書かせたコードが何をするか、シグネチャを見ればわかるようにしたい</li>
            <li>呼び出す側はただの関数呼び出しのまま</li>
          </ul>
        </div>
        <div class="card">
          <h3>LLM 向けの診断と CLI</h3>
          <ul>
            <li>LLM は落ちれば直すけど、<strong>黙って間違う</strong>とそのまま先に進む。これが一番困る</li>
            <li>エラーメッセージには直し方を書く。コンパイラの内部用語は出さない</li>
            <li>IDE 相当の問い合わせは LSP じゃなくて CLI で</li>
          </ul>
        </div>
      </div>`,
    notes: "2:05 (25s) AI first。黙って間違うのが一番まずい。LLM の評価ループは気づけない",
  },
  {
    className: "section",
    html: `<h1><small>FEATURES</small>型に書くもの</h1><p>effect system の基本は Koka と同じ。ここからは vibe で決めたことと、その実物</p>`,
    notes: "2:30 (5s) effect system の説明はしない。vibe で決めたことだけ。サンプルは数字キーで切り替え",
  },
  {
    html: `
      <h2><span class="kicker">Effects</span>vibe の effect で決めたこと</h2>
      <div class="cols wide-right grow">
        <ul class="small">
          <li>代数的エフェクトと権限が<strong>同じ row</strong>に乗る。権限は handle しないで、entry の <code>allows</code> まで残る</li>
          <li><code>resume</code> は 1 回、arm の最後だけ</li>
          <li><code>handle</code> は中の <code>perform</code> が全部見えないといけない</li>
          <li>row の書き忘れは、直し方付きで拒否</li>
        </ul>
        ${figure("effects")}
      </div>`,
    notes: "2:35 (35s) 図。代数的エフェクトは handle で消える、権限は main の allows まで残ってホストの import になる。resume は one-shot の末尾だけ",
  },
  {
    html: `
      <h2><span class="kicker">Effects</span>サンプル</h2>
      <div class="demo" data-demo="effects"></div>`,
    notes: "3:10 (45s) 1 resume、2 handler 差し替え。7〜a は拒否される例。a は payload パターンが黙って全部マッチするのを止めてる",
  },
  {
    html: `
      <h2><span class="kicker">Capabilities</span>権限はビルド時に一度だけ決める</h2>
      ${figure("capabilities", "wide")}
      <ul class="small">
        <li>使わない権限のコードは wasm に入らない。ホストは import を外付けするだけ</li>
        <li>省略できる権限は <code>perform?</code> で受けて、無いときの分岐を書く (Effects サンプルの 5)</li>
      </ul>`,
    notes: "3:55 (30s) 権限はビルド時に一度だけ決める。--deny-http なら Http のコードは DCE で消える。足りなければ main の前で止める",
  },
  {
    html: `
      <h2><span class="kicker">Allocation</span><code>#zero_alloc</code> (OxCaml から移植) と <code>region</code></h2>
      <div class="demo" data-demo="memory"></div>`,
    notes: "4:25 (40s) 1 → 2 で配列リテラルが拒否される。3 は呼んだ先。4 region は数えない、5 strict で拒否、6 外に返すと拒否",
  },
  {
    html: `
      <h2><span class="kicker">Concurrency</span><code>TaskGroup</code></h2>
      ${figure("taskgroup", "wide")}
      <ul class="small">
        <li>スレッドはまだ無い。1 スレッドの協調スケジューラで、順番は毎回同じ</li>
        <li>でも shared-nothing の検査 (<code>Send</code> と region) は今から効かせてる。wasm threads が来たら並列に載せ替える</li>
      </ul>`,
    notes: "5:05 (25s) スレッドは無い。協調スケジューラ。Send と region の検査は先に入れてある",
  },
  {
    html: `
      <h2><span class="kicker">Concurrency</span>サンプル</h2>
      <div class="demo" data-demo="concurrency"></div>`,
    notes: "5:30 (40s) 1 spawn/join の順番、5 止まるタスク、7 と 8 は拒否",
  },
  {
    html: `
      <h2><span class="kicker">Syntax</span>メソッド呼び出しなし</h2>
      <ul class="small">
        <li><code>Foo::bar(foo)</code> か <code>foo |&gt; Foo::bar()</code>。<code>foo.prop</code> はフィールドアクセスだけ。LLM には型名が書いてあるほうが読みやすいと思ってる (まだ測ってない)</li>
        <li>import はファイルスコープで明示。書いたものだけがスコープに出てくる</li>
      </ul>
      <div class="demo" data-demo="syntax"></div>`,
    notes: "6:10 (35s) メソッド呼び出しを捨てた理由。1 パイプ、7 バイト文字列、8 63bit Int",
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
    notes: "6:45 (30s) LSP じゃなくて CLI。空出力なら clean。答えられない質問は CLI を直す",
  },
  {
    className: "section",
    html: `<h1><small>HOW</small>作り方</h1>`,
    notes: "7:15 (5s) 作り方",
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
    notes: "7:20 (35s) MoonBit でプロトタイプ → 部分ごとにセルフホスト。Lean をオラクルに。「バグを潰して」",
  },
  {
    html: `
      <h2><span class="kicker">Self-hosting</span>セルフホスト</h2>
      ${figure("selfhost", "wide")}
      <ul class="small">
        <li>MoonBit も LLVM もいらない。wasm ランナーだけで動く</li>
        <li>罠。<code>vibe test</code> は既定だと seed がコンパイルする。コンパイラを直したのに、直す前のコンパイラで検証してた</li>
      </ul>
      <p class="quote small">seed の自己ビルドは pass 3 の時点で 3.89GiB、<strong>wasm32 の 4GiB</strong> まで残り 119MB。そこに 44 行足したら超えた (#3439)</p>`,
    notes: "7:55 (35s) seed → stage3。vibe test が seed で答える罠。4GiB の話",
  },
  {
    className: "section",
    html: `<h1><small>PAIN</small>大変だったこと</h1><p>バグの優先度は <strong>黙って間違う (P0) &gt; 落ちる (P1) &gt; 機能追加 (P2)</strong></p>`,
    notes: "8:30 (10s) 大変だったこと。優先度は 黙って間違う > 落ちる > 機能追加。まず数字",
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
    notes: "8:40 (35s) bug 841 件を修正の場所で数えた。件数は checker と codegen、黙って間違う率は desugar",
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
    notes: "9:15 (35s) バグが多いのは組み合わせ。クロージャ × effect row × ジェネリクス。== と String は P0 率も高い。権限まわりはほぼバグらなかった",
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
      <p class="small">Int のオーバーフローの結果が linear と wasm-gc で違ってた (#1877)</p>`,
    notes: "9:50 (35s) ベンチが揺れるので fuel に切り替えた。ヒープ 953MB。FBIP は効いたけど壁時計は変わらず",
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
            <li>型を見ないで構文だけで穴を塞ごうとする。抜け道が 63 個出て、結局 1,970 行消して型検査器でやった</li>
            <li>最初のエフェクトハンドラは resume のたびに本体を頭から再実行してた</li>
          </ul>
        </div>
      </div>`,
    notes: "10:25 (45s) 安いモデルだとバグの生成 > 修正。interning なし、実行時アサーション、replay 方式のハンドラ",
  },
  {
    html: `
      <h2><span class="kicker">Pain 3</span><code>==</code></h2>
      <ul class="small">
        <li><code>[1, 2] == [1, 2]</code> の答えが文脈で変わってた。そのまま書くと参照比較、struct の中だと構造比較</li>
        <li>ジェネリクス越しの <code>1.5 == 1.5</code> が <strong>false</strong>。<code>Double</code> の箱を比べてた</li>
      </ul>
      ${figure("equality", "wide")}`,
    notes: "11:10 (30s) == が黙って間違ってた。型を見ない desugar を通ると lowering に型が届かない。今は届かなければビルドエラー",
  },
  {
    html: `
      <h2><span class="kicker">Pain 3</span><code>==</code> の今</h2>
      <div class="demo" data-demo="equality"></div>`,
    notes: "11:40 (20s) 1 と 2 は今は true。3 は答える代わりに注釈を求める",
  },
  {
    html: `
      <h2><span class="kicker">Spec gaps</span>wasm に足りないもの</h2>
      ${figure("backends", "wide")}
      <ul class="small">
        <li>wasm-gc の ref 型の配列には <code>v128</code> が置けない。なので codegen は linear と wasm-gc の両対応で、これを続けるのがしんどい</li>
        <li>よかったのは wasmtime の guest profiler と fuel。気になってる言語は bend-lang</li>
      </ul>`,
    notes: "12:00 (35s) wasm に足りないもの。スレッド、wasm-gc の配列に v128 が無いので両対応、WIT のジェネリクス",
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
    notes: "12:35 (30s) 0.1.0 触ってください。皆さんもセルフホストしましょう",
  },
];
