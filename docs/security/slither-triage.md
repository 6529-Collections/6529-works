# Slither triage

Slither runs in the **Static analysis** CI job on `src/`. The gate,
[`tools/check_slither.py`](../../tools/check_slither.py), **fails on every High or Medium
impact finding that has no row in this file**. Low, Informational and Optimization
findings are counted in the job log and do not gate.

The gate ignores findings whose files are all under `lib/`, `test/` or `script/`, judged
on the repository-relative path, and fails if Slither did not analyse every
`src/**/*.sol` file. It deliberately does not use the path filter in
[`slither.config.json`](../../slither.config.json): Slither matches that filter against
absolute paths, so a checkout under a directory such as `content-attest/` hid every
finding. The config's filter only tidies a hand-run `slither .`.

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
| `reentrancy-no-eth` | `src/entropy/VrfEntropyModule.sol:VrfEntropyModule.requestSeed` | false-positive | The coordinator chooses the request ID, so it can only be stored after the call. The guard that blocks a second request, `requestedAt`, is written before the call: a reentrant `requestSeed` reverts with `RequestPending` and a reentrant delivery of the new ID finds no recorded ID. A reentrant delivery of an earlier request is valid, and `delivered` is re-checked after the call, so the new request is then not announced. `test_Request_ReentrancyFromTheCoordinatorFindsNothingToUse` and `test_Repeat_AnEarlierRequestDeliveredDuringTheRepeatIsNotOverwritten` prove it with an attacking coordinator. |
| `unused-return` | `src/entropy/VrfEntropyModule.sol:VrfEntropyModule._requestable` | false-positive | `packageOf` returns the package status, its evidence hash and the curation signer. Only the status gates a seed request, so the other two are deliberately not read. `test_Gate_RejectsAnUnknownOrRevokedPackage` covers the unknown and revoked statuses. |
| `unused-return` | `src/economics/EconomicsResolver.sol:EconomicsResolver.resolveCurrency` | false-positive | The ignored value is the default currency's revision counter, which only the allowlist's governed compare-and-set needs. Resolution uses the configured flag and the asset, then requires the asset to be active. `test/economics/EconomicsResolver.t.sol` (`test_ResolveCurrencyThroughTheAllowlist`) covers unconfigured, configured and deprecated defaults. |
| `unused-return` | `src/libraries/SignatureVerifier.sol:SignatureVerifier.isValidECDSA` | false-positive | The ignored value is the third result of `ECDSA.tryRecover`, the error argument OpenZeppelin uses only to build its custom errors. The error code itself is returned in `err` and checked, and a failed recovery returns `false`. `test/libraries/SignatureVerifier.t.sol` covers malformed, high-s and wrong-signer signatures. |
| `unused-return` | `src/curation/PackageRegistry.sol:PackageRegistry.acceptPackage` | false-positive | The ignored value is the artist's `lastActivity`, the second result of `IArtistRegistry.artist`; acceptance compares only the profile fields of the returned identity and reverts with `ProfileMismatch` when they differ. `test/curation/PackageRegistry.t.sol` (`test_acceptPackage_revertsProfileMismatch`) covers it. |
| `reentrancy-no-eth` | `src/sales/EnglishAuction.sol:EnglishAuction.startWithBid` | false-positive | The writes after the external calls are the new sale (it needs the token ID the admitted token's `mint` returns) and the first bid, which is recorded before its payment is taken. Every unrestricted state-changing entry point (`start`, `startWithBid`, `bid`, `withdrawBid`, `settle`, `claim`, `claimDelivery`) and the dispute functions (`pause(saleId, disputeRef)`, `resume`, `cancel`) hold the same transient reentrancy guard. The remaining governed setters (`pause()`, `unpause()`, `setTarget`, `setFederationRegistry`, `setConfig`, `setOpeningBid`) are `restricted`. The sale does not exist until `mint` returns, so the token cannot reach it. `test/sales/auction/EnglishAuctionHostile.t.sol` re-enters through a winner, a seller wallet, a claimer and a token callback, and the invariant campaigns in `test/sales/auction/invariant/` cover the money paths. |
| `unused-return` | `src/sales/EnglishAuction.sol:EnglishAuction._pay` | false-positive | The ignored value is the `escrowed` flag of `RevenuePayment.payETH` and `payERC20`. Either route completes the payment to that wallet (directly, or as a credit the escrow records with its own `Credited` event), and any other outcome reverts, so the settlement has nothing to branch on. `test/sales/auction/EnglishAuction.t.sol` (`test_Settle_RefusingWalletIsEscrowed`) and `EnglishAuctionHostile.t.sol` cover both routes. |
