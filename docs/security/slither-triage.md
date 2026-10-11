# Slither triage

Slither runs in the **Static analysis** CI job on `src/` (`lib/`, `test/` and `script/`
are filtered out by [`slither.config.json`](../../slither.config.json)). The gate,
[`tools/check_slither.py`](../../tools/check_slither.py), **fails on every High or Medium
impact finding that has no row in this file**. Low, Informational and Optimization
findings are counted in the job log and do not gate.

Slither's version is pinned by the hash-locked
[`requirements-tools.lock`](../../requirements-tools.lock). A version bump can change
detector behaviour, so re-run the job and re-triage in the same PR.

## Format

One table row per dispositioned finding. A row is `detector`, `location`,
`disposition` and `reason`:

- **detector** is Slither's check name, for example `reentrancy-eth`.
- **location** is `path.sol:Contract.function`. It may be coarser (`path.sol:Contract`
  or `path.sol`), which covers every finding of that detector below it. Line numbers
  are never used, so a row survives unrelated edits. A finding is located by its first
  element, the primary one Slither lists.
- **disposition** is `false-positive` (the detector is wrong here) or `accepted` (the
  behaviour is real, intended and safe).
- **reason** says why in a sentence a reviewer can check, and points at the test or ADR
  section that covers it. It must not contain a pipe character.

A real finding is fixed in code, not dispositioned. Prefer the narrowest location: a
file-wide row for a High detector hides new findings. A row that matches no current
finding is reported as stale in the job log; remove it.

```markdown
| detector | src/path/File.sol:Contract.function | false-positive | Why, and the test that proves it. |
```

## Dispositions

| Detector | Location | Disposition | Reason |
| --- | --- | --- | --- |
| `incorrect-shift` | `src/libraries/Utf8.sol:Utf8.validate` | false-positive | The detector reads `shl(bits, 1)` as a swapped `1 << bits`. Yul orders the arguments shift first, so `shl(bits, 1)` is `1 << bits` and `shr(sub(248, bits), w)` shifts the word `w` right, as intended. `test/libraries/Utf8.t.sol` checks the validator against vectors, boundary tables and a code-point oracle, including fuzzing. |
| `incorrect-equality` | `src/economics/SplitWallet.sol:SplitWallet._release` | false-positive | The flagged `amount == 0` only rejects an empty release. Receipts can only raise `amount`, so a donation or any other balance change cannot make the check wrongly pass or fail, and rejecting zero keeps an empty release from running the recipient's code and lets `ClaimRouter` report it as a failure. `test/economics/SplitWallet.t.sol` (`test_NothingToReleaseAndUnknownPayeeRevert`) and the invariant campaign in `test/economics/invariant/` cover it. |
| `unused-return` | `src/libraries/SignatureVerifier.sol:SignatureVerifier.isValidECDSA` | false-positive | The ignored value is the third result of `ECDSA.tryRecover`, the error argument OpenZeppelin uses only to build its custom errors. The error code itself is returned in `err` and checked, and a failed recovery returns `false`. `test/libraries/SignatureVerifier.t.sol` covers malformed, high-s and wrong-signer signatures. |
| `unused-return` | `src/curation/PackageRegistry.sol:PackageRegistry.acceptPackage` | false-positive | The ignored value is the artist's `lastActivity`, the second result of `IArtistRegistry.artist`; acceptance compares only the profile fields of the returned identity and reverts with `ProfileMismatch` when they differ. `test/curation/PackageRegistry.t.sol` (`test_acceptPackage_revertsProfileMismatch`) covers it. |
