# Package registry design (ADR-0065 Phase 5, #755)

Package distribution treats the **require pin (content hash) as the only
truth** (ADR-0063 §5). A build is resolver-free and re-verifies every edge
offline, so **network trust is localised to the instant of add / update**.
The registry is the device that protects that instant; it is not the root of
trust.

This document records the shipped Phase 0 (registry-less git resolution) and
the design of the registry itself (Phase 1+).

## Phase 0 — direct git/GitHub resolution (shipped, #755)

A hash pin makes any transport untrusted even when no registry exists.
`scripts/vibe_pkg.sh add` implements that against git. Two launcher verbs sit
on top of it (#2676): `vibe add`, which materialises into the project's
`.vibe/store/` and writes a pin line into the root `index.vpkg`, and
`vibe pkg add`, which only installs into `$VIBE_HOME/lib`:

```
vibe add github:owner/repo[/sub/dir]@<ref>           # .vibe/store + require ... from <source>@<commit>
vibe add git:<url>@<ref>[#<sub/dir>]
vibe pkg add <source-spec> [#pkg:b3:<64hex>]       # $VIBE_HOME/lib, does not touch the manifest
```

- **fetch**: `github:` is sugar for `https://github.com/owner/repo.git`. The
  ref is **resolved to a commit** via git fetch (`FETCH_HEAD`). Servers that
  refuse a shallow fetch get one full-fetch retry.
- **hash is computed locally**: the fetched sources are hashed into a package
  identity (`pkg:b3:` — a merkle of package-relative paths; historical pins
  are `pkg:sha1:`) by the local compiler. The transport (GitHub / a mirror /
  a USB stick) is structurally not a trust target.
- **expected pin**: a pin argument is checked **before any cache/install side
  effect**; a mismatch is refused. The first add without a pin is
  **trust-on-first-use** — the hash is printed and recorded in `versions.tsv`.
- **version→hash immutability**: a fetch that returns a different hash for a
  recorded name@version is refused (upstream same-version substitution and
  tampering fail here). The record is shared with #754 publish / install.
- **provenance**: `$VIBE_HOME/cache/provenance.tsv` appends
  `name@version → hash → source spec → commit`. The package hash is a source
  merkle, so a third party can check out spec@commit and recompute the hash
  (a source-only form of SLSA-style build provenance).
- Fetched bytes land in `$VIBE_HOME/cache/pkg/<algo>/<hex>/` (a passive CAS;
  new writes use `b3`) and are materialised into `$VIBE_HOME/lib/<name>/`
  (the default VIBE_LIB root, #751) or `.vibe/store/<name>/`.

Pinned by gate 6k (a hermetic file:// repo covering TOFU / pin check /
rejection with no side effects / same-version tamper rejection / build&run
end to end).

### Limits of Phase 0 (= what the registry fills in)

1. **No name discovery or uniqueness**: the name → source-spec mapping lives
   only on the user's machine. Another repo can claim the same package name
   (with a pin the damage is "the build fails" — substitution still does not
   succeed, but it is confusing).
2. **The first TOFU add is undefended**: there is no way to check that the
   first add's hash is the right one.
3. **No global version consistency**: each client's `versions.tsv` only
   protects that client. A standing attack that serves different hashes to
   different clients is detectable only from each client's own record.

## Phase 1+ — the registry itself (design)

The registry's job is **worldwide-consistent notarisation of
name@version → hash**. Package bytes themselves are CAS, so they can be
fetched from anywhere (the registry may merely *point* at a source — Phase 0
provenance can be the distribution layer as-is).

### Required properties (already decided in ADR-0065) and the design

1. **Transparency log** — a publish appends (scope, name, version,
   package_hash, provenance) to an append-only Merkle log (Go sumdb /
   sigstore rekor). Clients verify (a) an inclusion proof of the lookup
   result and (b) a consistency proof of the log (monotonic STHs). A
   standing attack that shows different hashes to different clients is then
   structurally impossible. The local `versions.tsv` is promoted to a
   client-side cache of the log, and TOFU is replaced by "verify against the
   log as the root of trust".
2. **Scope ownership + signatures** — a scope holds an ownership record (a
   set of public keys plus rotation history, also on the log). Publish
   requires a signature from a scope key. `@vibe` / `@vibex` are reserved.
   A new scope/name is rejected at publish time if its edit distance to an
   existing name looks like typosquatting.
3. **No code execution at build/install** — packages are source only. There
   is no install-hook concept (the npm-postinstall attack surface is absent
   by spec). Phase 0 add/install also does nothing except copy source and
   verify the hash.
4. **Effect-surface diff** — a contract's effect row is also a capability
   declaration. `vibe update` diffs the old and new effect surfaces and
   **warns/blocks an update that newly requires a capability** (Fs / Http /
   Process, …). This is the capability analogue of contract_hash semver
   machine-checking (#732), and a native advantage of vibe's effect system.
   The implementation is a set-diff of the effect-row portion of
   `contract_surface_lines` plus a severity classification (new capability =
   confirm, removal = info).
5. **Yank is immutable** — withdrawal is a marking on the log only.
   Substituting content is structurally impossible because the log is
   append-only. Builds of existing pins keep working, with a warning.
6. **Provenance** — a publish carries a source-repo + commit attestation
   (same shape as Phase 0's provenance.tsv). It is on the log, so a third
   party can audit source identity at publish time by checkout → recompute
   hash.

### Prototype shape

- **Storage**: the log starts as "one append-only file of records + a Merkle
  tree" (same as sumdb: no database). Serving is static files + CDN
  (lookup = `/@scope/name@version` → record + proof).
- **Protocol**: HTTP GET only (publish is the one POST + signature). The
  client verifier (inclusion/consistency proofs) is written in vibe on top
  of @vibe/core sha1.
- **Migration**: Phase 0's versions.tsv / provenance.tsv are a subset of the
  log record form, so they can be ingested into the initial log when the
  registry comes up.

## Phase 1 minimum slice (shipped, #805)

A file-based implementation of requirement 1 (transparency log) and
requirement 5 (immutable yank). No database, no server code — the
"registry" is one directory that rsync / static HTTP can serve as-is.
`VIBE_REGISTRY_LOG_DIR` (default `$VIBE_HOME/log`) points at it.
`vibe pkg publish|install|add|yank|update` (launcher #805) and
`scripts/vibe_pkg.sh` (in-repo) share the implementation
(`VIBE_PKG_RUNNER`/`VIBE_PKG_CLI_WASM` swap the hash engine; an installed
toolchain ships `lib/vibe_pkg.sh`, so no checkout is required).

### Log layout

- `records.tsv` — append-only, one event per line:
  `<ordinal>\t<op>\t<name@version>\t<pkg-hash>\t<contract-hash>\t<source>\t<commit>`
  (`op` = `publish` | `yank`). **Records carry no wall-clock** — order is
  the log order itself (ordinal = 0-based line position), so the record
  sequence is a deterministic byte string that can be reproduced and
  audited.
- `head` — one line `"<size>\t<merkle-root>"`. The analogue of sumdb's STH
  (signatures are Phase 2 scope-ownership/key work; this slice does not
  ship them).

### Merkle / verification (conservative choices in this slice)

- **hash**: sha256, RFC6962-style domain separation —
  `leaf = sha256("leaf:" + record line)`, `node = sha256("node:" + L + ":" + R)`.
  Internal nodes hash **hex-string concatenation**, not raw bytes (so a bash
  verifier stays portable). The **shape** of the tree (largest-power-of-two
  split) is RFC6962 itself, so proofs migrate 1:1 onto a future verifier
  written in vibe on @vibe/core sha1/sha256.
- **Client verification at install/add**: (a) recompute that the head
  commits to the records (tamper detection); (b) **prefix consistency**
  against the last head this client saw (`$VIBE_HOME/cache/log-head.seen.<logdir-digest>`
  stores size+root; the head may only grow — a shrink is truncation, a
  changed prefix root is history rewrite, both refused); (c) an
  **inclusion proof** of the matching publish record (build the audit path
  and recompute to the root). Because static-file serving gives the client
  the whole records file, consistency is checked by recomputing the prefix
  rather than an O(log n) proof — a remote proof protocol is work for when
  the log no longer fits a full fetch.
- **publish** runs the same self/consistency checks before extending the
  log (refuse to append onto a tampered log). version→hash immutability
  (same-version republish refused) is still decided before the log append,
  so a refused publish does not grow the log.
- **yank** only appends a `yank` record (requirement 5). versions.tsv / CAS
  stay immutable, so existing pins keep building. `install` refuses a
  yanked version without `--allow-yanked`; `add` (the explicit-source lane)
  only warns. A version that only ever went through git-add (TOFU) has no
  publish record in the log, so it is not a yank target (it stays on the
  phase-0 lane).

### Implemented scope and known gaps

- `vibe pkg update <name>` switches to the newest **non-yanked** version and,
  before switching, prints the contract-hash change and a textual diff of
  the contract (`index.vpkg`). Requirement 4's canonical diff (set-diff of
  `contract_surface_lines` + capability classification of the effect row)
  is not implemented yet — the compiler still has no adapter mode the shell
  can invoke. Adding that adapter mode (something like `VIBE_SURFACE=1`) is
  the next step.
- Scope ownership / signatures (requirement 2), typosquat checks, and
  publish attestation (requirement 6 on the log) are not implemented — the
  `source`/`commit` columns of a log record are seats for them; a local
  publish writes `local\t-`.
- Pinned by gate 6l (publish → log append + inclusion verify / a refused
  republish does not grow the log / tampered-head detection / truncation
  refused / yank + --allow-yanked / a served copy verified via
  `VIBE_REGISTRY_LOG_DIR`).

## Related

- ADR-0063 (content addressing / store / pin), ADR-0065 (layout / resolution
  order / supply-chain requirements)
- #751 (resolution order + VIBE_LIB + freeze), #754 (version directive /
  cache / materialise / same-version republish forbidden), #755 (this
  design), #805 (Phase 1 minimum slice: transparency log + yank + `vibe pkg`)
- `scripts/vibe_pkg.sh` (publish / install / add / yank / update), gates 6h–6l
