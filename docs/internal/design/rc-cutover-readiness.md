# The linear RC default (ADR-0055, #493)

```text
linear-default: RC
```

[`check_rc_default.sh`](../../../scripts/check_rc_default.sh) reads that line
and compares one program compiled with `VIBE_RC` unset, `1` and `0`.
The unset and RC artifacts must agree; the bump artifact must differ.
This contract concerns the **generated program**, not the allocator of the
compiler executing the command.

## Two independent selections

| Artifact | Default | Source of the selection |
| --- | --- | --- |
| User program compiled by the ordinary CLI | Linear RC | `fs_lane_request` / `ss_lane_request` in the compiler adapter |
| Compiler built by `scripts/generations.sh` | Linear bump | `VIBE_RC` defaults to `0` in that script; an explicit override is accepted |

See the [memory contract](memory-contract.md) for representations, GC selection,
and region storage. The compiler self-build default is a performance choice.
Current artifact identities, direct RC self-reproduction evidence and timing
comparisons live in the [experiment record](compiler-memory-experiments.md);
historical ratios are not a performance contract for the current compiler.

## What bootstrap checks establish

An RC self-hosting check must start from an artifact known to be RC-built,
have it recompile the same flat source with explicit RC output, and compare
the resulting artifact byte-for-byte. A cross-check can have it regenerate
the known bump artifact with `VIBE_RC=0`.

`scripts/test_rc_bootstrap.sh` currently checks the generation manifest's
fixpoint flag or stage hashes. It neither forces an RC build nor checks RC
mode when reusing a manifest. Its default generation is therefore bump, and
success alone does not establish RC self-hosting. The direct checks recorded
in the experiment record provide that evidence for the identified artifacts;
the missing mode assertion in this gate remains separate work.

## Reclamation and residual limitations

Perceus emits retain/release operations and reuse opportunities on the
linear RC backend. Reclamation depends on the object's ownership path and
runtime representation, so a successful bounded-heap fixture does not prove
every compiler workload has bounded live storage.

- Plain RC does not collect reference cycles.
- Conservative ownership handling can retain values longer than necessary.
  Perceus correctness tests and the mixed-feature reclamation probe describe
  the exercised cases; a performance claim needs a measured workload.
- Dedicated `region` arena allocation is disabled on the RC backend. Current
  region syntax uses ordinary collection allocation there, without bulk
  release. See [RC arena requirements](region-mutable-state.md#requirements-for-an-rc-arena-experiment).

[`rc_cutover_readiness.sh`](../../../scripts/rc_cutover_readiness.sh) compares
allocation-heavy programs under bump and RC, checks result parity and tests
heap-pointer boundedness at two iteration counts. Its `READY` wording means
that probe passed; it does not choose the production default or prove the
self-build performance target.
