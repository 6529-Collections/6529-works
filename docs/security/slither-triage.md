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
| `incorrect-equality` | `src/economics/SplitWallet.sol:SplitWallet._release` | false-positive | The flagged `amount == 0` only rejects an empty release. Receipts can only raise `amount`, so a donation or any other balance change cannot make the check wrongly pass or fail, and rejecting zero keeps an empty release from running the recipient's code and lets `ClaimRouter` report it as a failure. `test/economics/SplitWallet.t.sol` (`test_NothingToReleaseAndUnknownPayeeRevert`) and the invariant campaign in `test/economics/invariant/` cover it. |
| `reentrancy-no-eth` | `src/entropy/VrfEntropyModule.sol:VrfEntropyModule.requestSeed` | false-positive | The coordinator chooses the request ID, so it can only be stored after the call. The guard that blocks a second request, `requestedAt`, is written before the call: a reentrant `requestSeed` reverts with `RequestPending` and a reentrant delivery of the new ID finds no recorded ID. A reentrant delivery of an earlier request is valid, and `delivered` is re-checked after the call, so the new request is then not announced. `test_Request_ReentrancyFromTheCoordinatorFindsNothingToUse` and `test_Repeat_AnEarlierRequestDeliveredDuringTheRepeatIsNotOverwritten` prove it with an attacking coordinator. |
| `unused-return` | `src/entropy/VrfEntropyModule.sol:VrfEntropyModule._requestable` | false-positive | `packageOf` returns the package status, its evidence hash and the curation signer. Only the status gates a seed request, so the other two are deliberately not read. `test_Gate_RejectsAnUnknownOrRevokedPackage` covers the unknown and revoked statuses. |
| `unused-return` | `src/economics/EconomicsResolver.sol:EconomicsResolver.resolveCurrency` | false-positive | The ignored value is the default currency's revision counter, which only the allowlist's governed compare-and-set needs. Resolution uses the configured flag and the asset, then requires the asset to be active. `test/economics/EconomicsResolver.t.sol` (`test_ResolveCurrencyThroughTheAllowlist`) covers unconfigured, configured and deprecated defaults. |
| `unused-return` | `src/libraries/SignatureVerifier.sol:SignatureVerifier.isValidECDSA` | false-positive | The ignored value is the third result of `ECDSA.tryRecover`, the error argument OpenZeppelin uses only to build its custom errors. The error code itself is returned in `err` and checked, and a failed recovery returns `false`. `test/libraries/SignatureVerifier.t.sol` covers malformed, high-s and wrong-signer signatures. |
| `unused-return` | `src/curation/PackageRegistry.sol:PackageRegistry.acceptPackage` | false-positive | The ignored value is the artist's `lastActivity`, the second result of `IArtistRegistry.artist`; acceptance compares only the profile fields of the returned identity and reverts with `ProfileMismatch` when they differ. `test/curation/PackageRegistry.t.sol` (`test_acceptPackage_revertsProfileMismatch`) covers it. |
| `reentrancy-no-eth` | `src/sales/EnglishAuction.sol:EnglishAuction.startWithBid` | false-positive | The writes after the external calls are the new sale (it needs the token ID the admitted token's `mint` returns) and the first bid, which is recorded before its payment is taken. Every unrestricted state-changing entry point (`start`, `startWithBid`, `bid`, `withdrawBid`, `settle`, `claim`, `claimDelivery`) and the dispute functions (`pause(saleId, disputeRef)`, `resume`, `cancel`) hold the same transient reentrancy guard. The remaining governed setters (`pause()`, `unpause()`, `setTarget`, `setFederationRegistry`, `setConfig`, `setOpeningBid`) are `restricted`. The sale does not exist until `mint` returns, so the token cannot reach it. `test/sales/auction/EnglishAuctionHostile.t.sol` re-enters through a winner, a seller wallet, a claimer and a token callback, and the invariant campaigns in `test/sales/auction/invariant/` cover the money paths. |
| `unused-return` | `src/sales/EnglishAuction.sol:EnglishAuction._pay` | false-positive | The ignored value is the `escrowed` flag of `RevenuePayment.payETH` and `payERC20`. Either route completes the payment to that wallet (directly, or as a credit the escrow records with its own `Credited` event), and any other outcome reverts, so the settlement has nothing to branch on. `test/sales/auction/EnglishAuction.t.sol` (`test_Settle_RefusingWalletIsEscrowed`) and `EnglishAuctionHostile.t.sol` cover both routes. |
| `unused-return` | `src/sales/MintSaleBase.sol:MintSaleBase._pay` | accepted | The ignored value is the `escrowed` flag of `RevenuePayment.payETH` and `payERC20`, which only says which route a payout took. Both routes deliver the full amount to the same wallet (directly, or as an escrow credit that the escrow records with its own `Credited` event), and any other outcome reverts. The conservation invariants in `test/sales/fixed/FixedPriceInvariant.t.sol` and `test/sales/dutch/DutchInvariant.t.sol` check that every payment is paid or escrowed, and `test/sales/fixed/FixedPricePayments.t.sol` covers refusing, gas-burning and blocked wallets. |
| `unused-return` | `src/sales/MintSaleBase.sol:MintSaleBase._settle` | accepted | The ignored value is the `PrimaryTerms` that `IMintTarget.mint` returns. A sale applies the terms it locked when it opened (ADR 0001 §5: each sale locks its currency and terms when it starts), so the token cannot reprice or redirect a running sale; only the minted token ID is used, and it must equal the sale's ID. `test/sales/fixed/FixedPriceSale.t.sol` (`test_Purchase_CurrencyIsLockedAtOpen`, `test_Purchase_RevertsWhenTheTokenMintsAnotherId`) covers both. |
| `uninitialized-state` | `src/stream/WorkRecords.sol:WorkRecords` | false-positive | The two findings are `_media` (a fixed `bytes32[32]` per token) and `_locators` (a `Locator[]` per token and file). Both are mappings written through storage pointers, `list[i] = file.fileId` in `openRecord` and `list.push(locator)` in `addLocator`, which the detector does not follow; every read is bounded by the stored media count or the array length. A state-variable finding has no function, so the row is contract-wide. `test/stream/WorkRecords.t.sol` (`test_openRecord_multiFileWithRoles`, `test_addLocator_byArtistAndPlatform`, `test_addLocator_separateQuotas`) and `test/stream/PreferredLocation.t.sol` read both back. |
| `divide-before-multiply` | `src/stream/Stream.sol:Stream.royaltyInfo` | false-positive | The rounding is intentional and exact. `(p / D) * r + (p % D) * r / D` equals `floor(p * r / D)` because the remainder term restores what the first division drops, and with `r` at most 100,000 (checked when stored) it cannot overflow for any `salePrice`, which the plain product could (the overflow-free royalty form from RC1). `testFuzz_royaltyInfo_matchesMulDiv` in `test/stream/Stream.t.sol` checks it against `Math.mulDiv` over all prices and rates. |
| `reentrancy-no-eth` | `src/stream/Stream.sol:Stream.mint` | false-positive | The call is `IPackageRegistry.consume` on the immutable package registry fixed at construction, a trusted 6529 contract that marks the item consumed before it returns. Nothing `mint` reads before the call is used after it: the token-ID and serial counters are incremented in `_store`, after the call, and collections are never removed. A re-entry through an admitted adapter would still get consistent IDs and serials, which `test_mint_reentrantRegistryKeepsCountersConsistent` in `test/stream/Stream.t.sol` shows with a re-entering registry, and the invariants in `test/stream/StreamInvariant.t.sol` keep. |
| `unused-return` | `src/content/Renderer.sol:Renderer._str` | false-positive | The ignored value is the cap flag of `DataUri.escape`, which is true by construction here: the cap is `type(uint256).max`, so no input has more hits, and the strings come from reads capped at a few KiB. `test/content/renderer/TextHelpers.t.sol` (`test_Percent_TheHitCapIsInclusive`) covers the cap and `RendererReview.t.sol` (`test_E6_PercentAndHashInStreamAndSatelliteStringsAreEscaped`) the escaping of Stream, satellite and locator strings. |
| `incorrect-shift` | `src/content/HtmlScript.sol:HtmlScript.neutralize` | false-positive | The detector reads `shl(bits, 1)` as a swapped `1 << bits`, as for `Utf8.validate`. Yul orders the arguments shift first, so `shl(sub(255, shl(3, i)), 1)` is the flag bit of byte `i` of a word, cleared once that `<` is handled. `test/content/renderer/TextHelpers.t.sol` checks the neutralizer against a byte-loop oracle (fuzz, every offset in a word, a large input, bytes past the end). |
| `incorrect-shift` | `src/content/DataUri.sol:DataUri.escape` | false-positive | The same reading of `shl(sub(255, shl(3, i)), 1)`, the flag bit of byte `i` cleared once that `%` or `#` is escaped. `test/content/renderer/TextHelpers.t.sol` checks the escaper against a byte-loop oracle (fuzz, the hit cap at every offset, bytes past the end). |
| `divide-before-multiply` | `src/content/Renderer.sol:Renderer._reserved` | false-positive | `div(not(0), 255)` is exactly `0x0101...01` (2^256 - 1 is 255 times it), the byte-wise ones word of a word-at-a-time scan for a backslash; the products after it are of that constant, so nothing is rounded. `test/content/renderer/RendererReview.t.sol` (`test_L2_ABackslashIsFoundAtEveryOffset`) puts a backslash at every offset of names of up to 70 bytes, across word boundaries. |
| `unused-return` | `src/editions/Editions.sol:Editions.createEdition` | false-positive | `createEdition` needs one field of each tuple it reads: the status from `IPackageRegistry.packageOf` (an edition has no use for the package's evidence hash) and the availability flag from `IStream.seedOf` (the policy and the seed stay the master's, rendered through it). Both fields are checked: `test/editions/Editions.t.sol` refuses a revoked package (`MasterNotApproved`) and a pending VRF seed (`MasterSeedPending`). |
