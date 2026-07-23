# mini-vcs — rust

Standard `cargo` project (`std::env::args`, `std::fs`). No external crates
needed for this spec (no real hashing/serialization required — see
`SPEC.md`'s "hash-free" note); if a trial's implementation pulls in crates
anyway, record that as a data point (almide's own comparison notes
Rust's zero-dependency minigit CLI as a specific plus).

## Build

```bash
cd eval/lang-bench/attempts/<round>/rust
cargo build --release
```

## Run

```bash
bash eval/lang-bench/acceptance_test.sh \
  "eval/lang-bench/attempts/<round>/rust/target/release/minivcs"
```

## LOC / size

`find src -name '*.rs' | xargs wc -l` for LOC; `wc -c
target/release/minivcs` for binary size (`strip`ped, matching
`docs/BENCHMARKS.md` upstream's "stripped" convention, if comparing to
almide's own numbers).
