# Mutation testing baseline

The first full mutation campaign over `src/`, with every surviving mutant triaged. How the
campaign works, and how to run it, is in the [testing guide](README.md#mutation-testing). The
weekly workflow (`.github/workflows/mutation.yml`) produces the same report from the same
mutants; this file is the reviewed reference, and
[`tools/mutation-floors.json`](../../tools/mutation-floors.json) holds the floors it sets.

## How it was measured

- **Code.** `main` at 054442d (after #63). Shards for files whose code changed while the
  campaign ran (the governance files in #52; Stream, FixedPriceSale, DutchSale, Editions,
  ArtistRegistry and MintSaleBase in #63) were run again on the merged code, so every mutant is
  a mutant of 054442d. Line numbers and error names below are that commit's. #66 changed
  `src/` after the campaign without changing behaviour beyond its errors: one install check
  (`Dependency`), `InvalidMintRequest` split into an error per Stream rule, errors declared in
  the interfaces, and `JsonEscape.scriptText` removed. The tests written for the baseline were
  checked against 054442d's mutants and carried onto the current code; the weekly run measures the
  current code against the floors.
- **Tools.** `slither-mutate` from slither-analyzer 0.11.6 through `tools/mutation.py` (its
  fixed ROR and LIR, and the CONST rule), Foundry 1.7.1 and solc 0.8.37. Tests ran under the
  `lite` profile.
- **Procedure.** 72 shards: one per `src/` file with code, and the seven largest files in
  four groups each (statements, operators, relations, conditions), plus six reruns of the
  relational and literal rules for the files where stock slither-mutate had aborted them
  (fixed since; see the guide). Each mutant ran its module's tests with `--fail-fast`; each
  survivor then ran the whole suite of the shard's checkout. The campaign took about 19
  hours on a 48-core machine running up to 40 shards at once; on a GitHub runner one small
  shard takes 10 to 15 minutes.
- **The final suite.** The campaign ran while tests were still being added, so every survivor
  was then run again in the final tree (054442d's code with the tests written for the baseline),
  against each test file added or changed since its shard ran, and each test written for a
  survivor was also run against that mutant directly. That kills a survivor a later test
  catches. Survivors triaged as equivalent were not run again: no test can kill them.
- **Timeouts.** A mutant whose tests ran past 20 minutes counts as killed, as slither-mutate
  counts it (a mutation that makes a loop endless). There were none.

## Kill rate per contract

"Killed" is the campaign's count; "killed by the final suite" adds the survivors a later test
kills, most of them the tests written for the baseline. The last column leaves out the
survivors triaged as equivalent, which no test can kill.

| Contract | Mutants | Killed | Kill rate | Killed by the final suite | Kill rate, final | Equivalent | Rate without them |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `src/content/Base64Validator.sol` | 17 | 13 | 76.5% | 13 | 76.5% | 4 | 100.0% |
| `src/content/ContentStore.sol` | 505 | 451 | 89.3% | 453 | 89.7% | 48 | 99.1% |
| `src/content/DataUri.sol` | 43 | 41 | 95.3% | 41 | 95.3% | 1 | 97.6% |
| `src/content/DependencyRegistry.sol` | 90 | 79 | 87.8% | 79 | 87.8% | 11 | 100.0% |
| `src/content/HtmlScript.sol` | 48 | 42 | 87.5% | 42 | 87.5% | 5 | 97.7% |
| `src/content/JsonScan.sol` | 425 | 336 | 79.1% | 346 | 81.4% | 57 | 94.0% |
| `src/content/Renderer.sol` | 846 | 719 | 85.0% | 724 | 85.6% | 101 | 97.2% |
| `src/curation/Eip712CurationVerifier.sol` | 95 | 92 | 96.8% | 92 | 96.8% | 3 | 100.0% |
| `src/curation/PackageRegistry.sol` | 444 | 382 | 86.0% | 399 | 89.9% | 42 | 99.3% |
| `src/economics/AssetAllowlist.sol` | 187 | 173 | 92.5% | 175 | 93.6% | 12 | 100.0% |
| `src/economics/ClaimRouter.sol` | 171 | 148 | 86.5% | 149 | 87.1% | 17 | 96.8% |
| `src/economics/EconomicsResolver.sol` | 196 | 175 | 89.3% | 181 | 92.3% | 15 | 100.0% |
| `src/economics/ReleaseVerifier.sol` | 82 | 79 | 96.3% | 79 | 96.3% | 3 | 100.0% |
| `src/economics/RevenueEscrow.sol` | 171 | 165 | 96.5% | 165 | 96.5% | 5 | 99.4% |
| `src/economics/RevenuePayment.sol` | 68 | 59 | 86.8% | 59 | 86.8% | 5 | 93.7% |
| `src/economics/SplitFactory.sol` | 125 | 111 | 88.8% | 113 | 90.4% | 12 | 100.0% |
| `src/economics/SplitWallet.sol` | 213 | 204 | 95.8% | 206 | 96.7% | 7 | 100.0% |
| `src/economics/Splits.sol` | 122 | 110 | 90.2% | 111 | 91.0% | 11 | 100.0% |
| `src/economics/TokenTransfer.sol` | 140 | 127 | 90.7% | 133 | 95.0% | 7 | 100.0% |
| `src/editions/EditionRules.sol` | 53 | 48 | 90.6% | 50 | 94.3% | 3 | 100.0% |
| `src/editions/Editions.sol` | 536 | 501 | 93.5% | 508 | 94.8% | 25 | 99.4% |
| `src/entropy/VrfEntropyModule.sol` | 332 | 291 | 87.7% | 305 | 91.9% | 26 | 99.7% |
| `src/governance/BoundedParameter.sol` | 59 | 57 | 96.6% | 57 | 96.6% | 2 | 100.0% |
| `src/governance/GovernanceConfig.sol` | 660 | 513 | 77.7% | 523 | 79.2% | 133 | 99.2% |
| `src/governance/GovernanceConfigurator.sol` | 22 | 22 | 100.0% | 22 | 100.0% | 0 | 100.0% |
| `src/governance/Roles.sol` | 300 | 278 | 92.7% | 278 | 92.7% | 22 | 100.0% |
| `src/governance/WorksAccessManager.sol` | 79 | 74 | 93.7% | 76 | 96.2% | 1 | 97.4% |
| `src/identity/ArtistRegistry.sol` | 709 | 631 | 89.0% | 640 | 90.3% | 47 | 96.7% |
| `src/identity/ConsolidationAdapter.sol` | 225 | 187 | 83.1% | 193 | 85.8% | 30 | 99.0% |
| `src/interfaces/types/HashRef.sol` | 6 | 4 | 66.7% | 6 | 100.0% | 0 | 100.0% |
| `src/interfaces/types/Limits.sol` | 44 | 31 | 70.5% | 33 | 75.0% | 11 | 100.0% |
| `src/interfaces/types/StatementKinds.sol` | 10 | 10 | 100.0% | 10 | 100.0% | 0 | 100.0% |
| `src/interfaces/types/Typehashes.sol` | 34 | 34 | 100.0% | 34 | 100.0% | 0 | 100.0% |
| `src/interfaces/types/WorksHashing.sol` | 37 | 33 | 89.2% | 33 | 89.2% | 4 | 100.0% |
| `src/libraries/BoundedCall.sol` | 184 | 169 | 91.8% | 172 | 93.5% | 9 | 98.3% |
| `src/libraries/DelegatedEOA.sol` | 47 | 41 | 87.2% | 41 | 87.2% | 3 | 93.2% |
| `src/libraries/JsonEscape.sol` | 138 | 111 | 80.4% | 113 | 81.9% | 23 | 98.3% |
| `src/libraries/ProtocolContracts.sol` | 13 | 13 | 100.0% | 13 | 100.0% | 0 | 100.0% |
| `src/libraries/SSTORE2.sol` | 91 | 85 | 93.4% | 85 | 93.4% | 6 | 100.0% |
| `src/libraries/SignatureVerifier.sol` | 61 | 52 | 85.2% | 53 | 86.9% | 4 | 93.0% |
| `src/libraries/Utf8.sol` | 105 | 86 | 81.9% | 91 | 86.7% | 14 | 100.0% |
| `src/records/StatementLog.sol` | 431 | 389 | 90.3% | 396 | 91.9% | 26 | 97.8% |
| `src/sales/DutchPricing.sol` | 87 | 82 | 94.3% | 82 | 94.3% | 5 | 100.0% |
| `src/sales/DutchSale.sol` | 151 | 145 | 96.0% | 146 | 96.7% | 5 | 100.0% |
| `src/sales/EnglishAuction.sol` | 983 | 880 | 89.5% | 902 | 91.8% | 56 | 97.3% |
| `src/sales/FixedPriceSale.sol` | 394 | 343 | 87.1% | 349 | 88.6% | 45 | 100.0% |
| `src/sales/MintSaleBase.sol` | 539 | 490 | 90.9% | 493 | 91.5% | 32 | 97.2% |
| `src/stream/SpdxId.sol` | 41 | 38 | 92.7% | 38 | 92.7% | 3 | 100.0% |
| `src/stream/Stream.sol` | 588 | 529 | 90.0% | 546 | 92.9% | 32 | 98.2% |
| `src/stream/WorkRecords.sol` | 788 | 677 | 85.9% | 713 | 90.5% | 57 | 97.5% |
| **Total** | **11735** | **10350** | **88.2%** | **10561** | **90.0%** | **990** | **98.3%** |

## What survives, and why

After the final suite, 1,174 of the 11,735 mutants survive: 990 equivalent, 32 gas margins, 73
defensive, 1 caught only by a Halmos proof, and 78 open gaps. The campaign and the tests
written for it moved the kill rate from 88.2% to 90.0%; leaving out the equivalent mutants,
which no test can kill, it is 98.3%.

- **Equivalent** mutants are mostly mechanical: an unsigned `== 0` against `<= 0` (and `!= 0`
  against `> 0`), an enum compared at its first or last value, a loop counter's `<` against
  `!=` or `++i` against `i++`, a constant made `immutable` or narrowed to a type that still
  holds it, a read-only storage reference read as a copy, and, inside assembly, a scan that
  skips ahead less far (gas only). The others are argued one by one in their notes: a value a
  check above already bounds, or a branch whose effect another statement repeats.
- **Gas margins** move a gas allowance or reserve by one unit (the bounded reads' budgets, the
  auction's delivery reserve and payout gas, the ERC-1271 and token-transfer allowances), sit
  on an exact-gas boundary in the claim router, or skip releasing a memory buffer. Only an
  exact-gas harness would see them.
- **Defensive** checks guard against answers the contracts v1 deploys never give (the content
  store's chunk layout, the package registry's `consume` answer, the economics resolver's fee
  bounds as Stream reads them, a records satellite passing a reversed range) or against states
  out of reach (a 65,536th fee recipient, 2**23 overflow terms, an artist ID of 2**160 - 1).

The gaps followed a few patterns. The baseline added 72 tests and extended 44 more (#69 and its
follow-up); with them, and the tests other changes added while the campaign ran, the final
suite kills 211 of the campaign's survivors:

- **One-sided comparisons.** A check written `!=` was tested from one side only, so `<` or `>`
  survived it: pinned code hashes (renderers, resolvers, curation verifiers, the split
  factory's dependencies), interface IDs below the supported ones in every `supportsInterface`,
  sale kinds, revisions and expected values, and license keys on either side of CC0's.
- **Exact bounds.** A bound tested only through the constant it bounds, or never at its edge:
  deadline seconds (permits, override acceptances, curation approvals), the auction's pause
  limit, length caps (collection names, signatures, previews), the federated list and the
  512-chunk sync budget.
- **Unchecked effects.** Constructor events, a price preview that skipped Stream's rules, a
  split factory never required to have code, a reentry guard.
- **Amounts and indexes.** Mints and burns of zero, chunk and preference indexes more than one
  past the end, more signatures than parties, a file ID of zero.

The 78 open gaps are listed below and grouped in the next lane's [work
list](README.md#gaps-the-next-testing-lane). Most follow the same patterns where a test costs
more to build: an EIP-7702 delegated dependency whose delegate answers ERC-165, a 49-chunk
base64 file whose padding straddles two chunks, a work with every trait slot filled, and
answers an arbitrary contract may give (a dispute subject whose `ownerOf` returns zero or a
short word, a revert reason longer than its decoder reads).

## Survivors, triaged

Each survivor is one of:

- **Equivalent:** the change does not alter what the code does: an unsigned `== 0` against
  `<= 0`, a loop counter's increment form, a narrower type that still holds every value, a
  read-only storage pointer read as a copy, a statement whose effect a later one repeats, or a
  scan that skips ahead less far (gas only).
- **Gas margin:** a gas constant or a comparison against one, moved by one gas. Only an
  exact-gas harness could see it.
- **Defensive:** a guard that cannot fail with the contracts as deployed (a trusted contract's
  answer, a document another function already validated, code that EIP-3541 forbids). Killing
  it needs a lying mock or input v1 never produces.
- **Proved:** a Halmos proof in `test/symbolic` kills it, checked by running the proof against
  the mutant; the Foundry suite does not.
- **Gap:** a missing test. When the note names a test, the baseline added it and the
  mutant is killed in the final suite; such mutants are not listed below, only counted in the
  table. The open ones are in the [work list](README.md#gaps-the-next-testing-lane).

### `src/content/Base64Validator.sol`

4 survivors: 4 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 36 | MIA | `if rem {` to `if true {` | Equivalent | with no partial word the fill still runs: it checks one more word of `A` past the end and restores it |
| 50 | CR | `end := add(last, 32)` to `//end := add(last, 32)` | Equivalent | the loop bound inside the partial word still covers that word |
| 101 | MIA | `if last { mstore(last, saved) }` to `if true { mstore(last, saved) }` | Equivalent | with no partial word it writes zero to scratch memory at 0x00 |
| 103 | ROR | `return bad == 0;` to `return bad <= 0;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |

</details>

### `src/content/ContentStore.sol`

52 survivors: 3 open gaps, 1 gas margin, 48 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 28 | SBR | `uint256 public constant CHUNK_SIZE = SSTORE2.MAX_CHUNK_LENGTH` to `uint256 public immutable CHUNK_SIZE = SSTORE2.MAX_CHUNK_LENGTH` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 33 | SBR | `uint256 public constant MAX_CHUNKS = 512;` to `uint256 public immutable MAX_CHUNKS = 512;` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 35 | SBR | `uint256 public constant MAX_MIME_LENGTH = 64;` to `uint256 public immutable MAX_MIME_LENGTH = 64;` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 35 | SBR | `uint256 public constant MAX_MIME_LENGTH` to `uint128 public constant MAX_MIME_LENGTH` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 37 | SBR | `uint256 public constant ATTEST_CHUNKS_PER_CALL = 48;` to `uint256 public immutable ATTEST_CHUNKS_PER_CALL = 48;` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 78 | ROR | `if (f.length != 0) return fileId;` to `if (f.length > 0) return fileId;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 81 | ROR | `if (count == 0 \|\| count > MAX_CHUNKS) revert` to `if (count <= 0 \|\| count > MAX_CHUNKS \|\| count > MAX_CHUNKS) revert` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 85 | ROR | `if (sha256Hash == bytes32(0)) revert ContentDigestMissing(` to `if (sha256Hash <= bytes32(0)) revert ContentDigestMissing(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 91 | SBR | `f.length = uint64(length);` to `f.length = uint32(length);` | Equivalent | the length is bounded by 512 chunks of 24,575 bytes, far below 2**32 |
| 112 | ROR | `for (uint256 i; i < f.chunks.length; ++i) {` to `for (uint256 i; i != f.chunks.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 112 | SBR | `for (uint256 i; i < f.chunks.length; ++i)` to `for (uint128 i; i < f.chunks.length; ++i)` | Equivalent | the counter never reaches 2**128 |
| 112 | SBR | `for (uint256 i; i < f.chunks.length; ++i)` to `for (uint128 i; i < f.chunks.length; ++i)` | Equivalent | the counter never reaches 2**128 |
| 112 | UOR | `uint256 i; i < f.chunks.length; ++i) {` to `uint256 i; i < f.chunks.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 122 | SBR | `uint256 found;` to `uint128 found;` | Equivalent | the counter never reaches 2**128 |
| 123 | ROR | `for (uint256 i; i < missing.length; ++i) {` to `for (uint256 i; i != missing.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 123 | SBR | `for (uint256 i; i < missing.length; ++i) {` to `for (uint128 i; i < missing.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 123 | SBR | `for (uint256 i; i < missing.length; ++i) {` to `for (uint128 i; i < missing.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 123 | UOR | `uint256 i; i < missing.length; ++i) {` to `uint256 i; i < missing.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 142 | ROR | `if (sha == 0) revert ContentFileUnknown(fileId` to `if (sha <= 0) revert ContentFileUnknown(fileId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 147 | SBR | `File storage f = _file(fileId);` to `File memory f = _file(fileId);` | Equivalent | a memory copy of the file record reads the same chunk hash, at a higher cost |
| 160 | SBR | `Attestation memory a = _attestation[fileId];` to `Attestation storage a = _attestation[fileId];` | Equivalent | the attestation is read before it is overwritten, so a storage reference sees the same values |
| 165 | ROR | `if (f.length % 4 != 0) revert ContentBase64LengthInvalid(fileId,` to `if (f.length % 4 > 0) revert ContentBase64LengthInvalid(fileId,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 169 | ROR | `if (stop > count) stop = count;` to `if (stop >= count) stop = count;` | Equivalent | `>=` also assigns an equal value |
| 172 | ROR | `done = stop == count;` to `done = done = stop >= count;` | Equivalent | `stop` is at most `count`, so `>=` is `==` |
| 175 | SBR | `_attestation[fileId] = Attestation(uint64(stop), done);` to `_attestation[fileId] = Attestation(uint32(stop), done);` | Equivalent | `stop` is at most 512 |
| 192 | SBR | `uint256 total = f.length;` to `uint128 total = f.length;` | Equivalent | the value never reaches 2**128 |
| 197 | SBR | `uint256 dest;` to `uint128 dest;` | Equivalent | a memory address never reaches 2**128 |
| 202 | ROR | `while (done < length) {` to `while (done != length) {` | Equivalent | each copy is clamped to the bytes left, so `done` meets `length` exactly |
| 203 | AOR | `fileId, f, offset + done, length - done, dest + done);` to `fileId, f, offset + done, length + done, dest + done);` | Equivalent | the last copy then takes the rest of its chunk, past the end of `out` into released memory; the bytes returned are the same |
| 219 | SBR | `uint256 mark;` to `uint128 mark;` | Equivalent | a memory address never reaches 2**128 |
| 226 | MIA | `if (take > remaining) take = remaining;` to `if (false) take = remaining;` | Equivalent | without the clamp the last copy takes the rest of its chunk, past the end of `out` into released memory; the bytes returned are the same |
| 226 | ROR | `if (take > remaining) take = remaining;` to `if (take >= remaining) take = remaining;` | Equivalent | `>=` also assigns an equal value, and `==` never clamps, which (as for the clamp removed) only runs the last copy past the end of `out`; the bytes returned are the same |
| 226 | ROR | `if (take > remaining) take = remaining;` to `if (take == remaining) take = remaining;` | Equivalent | `>=` also assigns an equal value, and `==` never clamps, which (as for the clamp removed) only runs the last copy past the end of `out`; the bytes returned are the same |
| 243 | AOR | `if (to + 1 >= f.chunks.length) strictEnd` to `if (to / 1 >= f.chunks.length) strictEnd` | Gap | a file whose `==` padding straddles its last two chunks, attested in a call that stops at the second-to-last chunk (49 chunks, 48 per call): no test builds one |
| 243 | AOR | `if (to + 1 >= f.chunks.length) strictEnd` to `if (to * 1 >= f.chunks.length) strictEnd` | Gap | a file whose `==` padding straddles its last two chunks, attested in a call that stops at the second-to-last chunk (49 chunks, 48 per call): no test builds one |
| 243 | ROR | `if (to + 1 >= f.chunks.length) strictEnd -=` to `if (to + 1 > f.chunks.length) strictEnd -=` | Gap | a file whose `==` padding straddles its last two chunks, attested in a call that stops at the second-to-last chunk (49 chunks, 48 per call): no test builds one |
| 244 | ROR | `for (uint256 i = from; i < to; ++i) {` to `for (uint256 i = from; i != to; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 244 | UOR | `for (uint256 i = from; i < to; ++i) {` to `for (uint256 i = from; i < to; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 245 | SBR | `uint256 mark;` to `uint128 mark;` | Equivalent | a memory address never reaches 2**128 |
| 252 | ROR | `if (strict > chunk.length) strict = chunk.length` to `if (strict >= chunk.length) strict = chunk.length` | Equivalent | `>=` also assigns an equal value |
| 264 | SBR | `storage f) private view returns (uint256 pad) {` to `storage f) private view returns (uint128 pad) {` | Equivalent | the padding is 0, 1 or 2 |
| 265 | SBR | `uint256 mark;` to `uint128 mark;` | Equivalent | a memory address never reaches 2**128 |
| 278 | CR | `mstore(0x40, mark)` to `//mstore(0x40, mark)` | Gas margin | only releases the chunk buffer: the answer is the same, at a higher memory cost |
| 311 | ROR | `if (f.length == 0) revert ContentFileUnknown(fileId` to `if (f.length <= 0) revert ContentFileUnknown(fileId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 320 | LIR | `` to `` | Equivalent | a local is zero without its initializer |
| 320 | MVIV | `uint256 slashes = 0;` to `uint256 slashes ;` | Equivalent | a local is zero without its initializer |
| 320 | SBR | `uint256 slashes = 0;` to `uint128 slashes = 0;` | Equivalent | the counter never reaches 2**128 |
| 321 | ROR | `for (uint256 i; i < m.length; ++i) {` to `for (uint256 i; i != m.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 321 | SBR | `for (uint256 i; i < m.length; ++i) {` to `for (uint128 i; i < m.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 321 | SBR | `for (uint256 i; i < m.length; ++i) {` to `for (uint128 i; i < m.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 321 | UOR | `for (uint256 i; i < m.length; ++i) {` to `for (uint256 i; i < m.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 325 | UOR | `++slashes;` to `slashes++;` | Equivalent | pre- or post-increment of a loop counter |

</details>

### `src/content/DataUri.sol`

2 survivors: 1 defensive, 1 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 63 | MIA | `if lt(sub(end, p), 32) { z := and(z, not(shr(shl(3, sub(end,` to `if true { z := and(z, not(shr(shl(3, sub(end,` | Equivalent | for a whole word the mask shifts by 256 bits or more and keeps every flag |
| 83 | CR | `mstore(add(out, words), 0) // zero` to `//mstore(add(out, words), 0) // zero` | Defensive | zeroes the output's last-word padding; no reader depends on it (ABI encoding re-pads) |

</details>

### `src/content/DependencyRegistry.sol`

11 survivors: 11 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 32 | ROR | `if (address(store_).code.length == 0) revert DependencyStoreInvalid...` to `if (address(store_).code.length <= 0) revert DependencyStoreInvalid...` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 40 | ROR | `_entries[name][version].fileId != bytes32(0)) {` to `_entries[name][version].fileId > bytes32(0)) {` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 62 | SBR | `Entry storage entry = _entry(name, version)` to `Entry memory entry = _entry(name, version)` | Equivalent | a read-only struct copied instead of read in place |
| 70 | ROR | `if (entry.fileId == bytes32(0)) revert DependencyUnknown(name,` to `if (entry.fileId <= bytes32(0)) revert DependencyUnknown(name,` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 76 | MVIV | `bool ended = false;` to `bool ended ;` | Equivalent | `false` is the default value |
| 77 | ROR | `for (uint256 i; i < 32; ++i) {` to `for (uint256 i; i != 32; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 77 | SBR | `for (uint256 i; i < 32; ++i) {` to `for (uint128 i; i < 32; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 77 | SBR | `for (uint256 i; i < 32; ++i) {` to `for (uint128 i; i < 32; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 77 | UOR | `for (uint256 i; i < 32; ++i) {` to `for (uint256 i; i < 32; i++) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 79 | ROR | `if (c == 0) {` to `if (c <= 0) {` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 92 | ROR | `if (label[0] == 0) revert DependencyLabelInvalid(label` to `if (label[0] <= 0) revert DependencyLabelInvalid(label` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |

</details>

### `src/content/HtmlScript.sol`

6 survivors: 1 defensive, 5 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 80 | MIA | `if lt(sub(end, p), 32) { z := and(z, not(shr(shl(3, sub(end,` to `if true { z := and(z, not(shr(shl(3, sub(end,` | Equivalent | for a whole word the mask shifts by 256 bits or more and keeps every flag |
| 90 | CR | `p := end` to `//p := end` | Equivalent | past the cap the scan counts on to the end instead of stopping; the result is refused either way (gas only) |
| 91 | CR | `break` to `//break` | Equivalent | past the cap the scan counts on to the end instead of stopping; the result is refused either way (gas only) |
| 98 | MIA | `if eq(second, 0x21) {` to `if true {` | Equivalent | the `<!--` comparison is false unless the second byte is `!` |
| 118 | MIA | `if ok {` to `if true {` | Equivalent | a refused script's output is written but never used: `ok` is false |
| 122 | CR | `mstore(dst, 0) // zero the final` to `//mstore(dst, 0) // zero the final` | Defensive | zeroes the output's last-word padding; no reader depends on it (ABI encoding re-pads) |

</details>

### `src/content/JsonScan.sol`

79 survivors: 1 open gap, 21 defensive, 57 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 55 | ROR | `_run(0, json, 0, keys, spans) != 0;` to `_run(0, json, 0, keys, spans) > 0;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 66 | ROR | `_run(1, json, start, keys, spans) != 0;` to `_run(1, json, start, keys, spans) > 0;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 78 | ROR | `ok = found != 0;` to `ok = found > 0;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 99 | ROR | `ok = found != 0;` to `ok = found > 0;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 140 | MIA | `if iszero(shr(128, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 141 | CR | `idx := 16` to `//idx := 16` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 144 | MIA | `if iszero(shr(192, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 145 | CR | `idx := add(idx, 8)` to `//idx := add(idx, 8)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 148 | MIA | `if iszero(shr(224, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 149 | CR | `idx := add(idx, 4)` to `//idx := add(idx, 4)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 152 | MIA | `if iszero(shr(240, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 153 | CR | `idx := add(idx, 2)` to `//idx := add(idx, 2)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 156 | CR | `if iszero(shr(248, m)) { idx :=` to `//if iszero(shr(248, m)) { idx :=` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 156 | MIA | `if iszero(shr(248, m)) { idx := add(idx, 1) }` to `if false { idx := add(idx, 1) }` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 188 | CR | `leave` to `//leave` | Equivalent | the next check (not `u`) leaves with the same `q` |
| 191 | CR | `if lt(sub(e, p), 4) { leave }` to `//if lt(sub(e, p), 4) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 191 | MIA | `if lt(sub(e, p), 4) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 202 | CR | `if lt(sub(e, p), 6) { leave }` to `//if lt(sub(e, p), 6) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 202 | MIA | `if lt(sub(e, p), 6) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 220 | CR | `if eq(kind, 2) { off := not(0)` to `//if eq(kind, 2) { off := not(0)` | Equivalent | mode 2 then flags control bytes, which its bytewise loop lets through anyway (gas only) |
| 220 | MIA | `if eq(kind, 2) { off := not(0) }` to `if false { off := not(0) }` | Equivalent | mode 2 then flags control bytes, which its bytewise loop lets through anyway (gas only) |
| 225 | CR | `if lt(p, near) { wordEnd := near` to `//if lt(p, near) { wordEnd := near` | Equivalent | the scan only skips less far ahead or goes bytewise sooner (gas only) |
| 225 | MIA | `if lt(p, near) { wordEnd := near }` to `if false { wordEnd := near }` | Equivalent | the scan only skips less far ahead or goes bytewise sooner (gas only) |
| 226 | MIA | `if and(iszero(lt(p, near)), iszero(lt(sub(e, p), 32))) {` to `if true {` | Equivalent | the word test then also runs near the start and the end: the first flagged byte is still the first special byte of the text, so only the work changes |
| 252 | CR | `p := add(p, firstFlag(flags))` to `//p := add(p, firstFlag(flags))` | Equivalent | the scan only skips less far ahead or goes bytewise sooner (gas only) |
| 254 | CR | `if gt(wordEnd, e) { wordEnd :=` to `//if gt(wordEnd, e) { wordEnd :=` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 254 | MIA | `if gt(wordEnd, e) { wordEnd := e }` to `if false { wordEnd := e }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 259 | CR | `if and(gt(c, 0x22), iszero(eq(c,` to `//if and(gt(c, 0x22), iszero(eq(c,` | Equivalent | the usual byte then goes through the other checks, none of which matches it (gas only) |
| 259 | MIA | `if and(gt(c, 0x22), iszero(eq(c, 0x5c))) { continue }` to `if false { continue }` | Equivalent | the usual byte then goes through the other checks, none of which matches it (gas only) |
| 271 | CR | `if iszero(p) { leave }` to `//if iszero(p) { leave }` | Defensive | an invalid escape then restarts the scan at memory address zero, which would have to read as valid JSON up to the end of the text to change the result |
| 271 | MIA | `if iszero(p) { leave }` to `if false { leave }` | Defensive | an invalid escape then restarts the scan at memory address zero, which would have to read as valid JSON up to the end of the text to change the result |
| 272 | CR | `continue` to `//continue` | Equivalent | the backslash then goes through the remaining checks, none of which matches it |
| 293 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 293 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 307 | MIA | `if lt(p, e) {` to `if true {` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 321 | CR | `if gt(add(p, len), e) { leave }` to `//if gt(add(p, len), e) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 321 | MIA | `if gt(add(p, len), e) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 337 | CR | `leave` to `//leave` | Equivalent | the document is already rejected (`ok` is zero); callers pass distinct keys, so no later key resets it |
| 364 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 364 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 367 | CR | `leave` to `//leave` | Gap | an empty array then costs one more unit of the 1,024-unit budget; observable only in a document at the exact budget |
| 371 | CR | `if iszero(p) { leave }` to `//if iszero(p) { leave }` | Defensive | after a failed value the pointer is zero and the next read is of scratch memory, which would have to hold `]` or `,` to change the result |
| 371 | MIA | `if iszero(p) { leave }` to `if false { leave }` | Defensive | after a failed value the pointer is zero and the next read is of scratch memory, which would have to hold `]` or `,` to change the result |
| 373 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check (the walk must end exactly at the end) still rejects the document |
| 373 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 378 | CR | `leave` to `//leave` | Equivalent | the `q` already set survives: the next check leaves the same way |
| 389 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check (the walk must end exactly at the end) still rejects the document |
| 389 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 392 | CR | `leave` to `//leave` | Equivalent | the loop's key read fails on `}` without counting a unit, leaving the same `q` |
| 401 | CR | `if gt(mload(ctx), 1024) { leave` to `//if gt(mload(ctx), 1024) { leave` | Equivalent | `value` checks the same budget right after every key |
| 401 | MIA | `if gt(mload(ctx), 1024) { leave }` to `if false { leave }` | Equivalent | `value` checks the same budget right after every key |
| 403 | MIA | `if eq(depth, 8) { h := keccak256(add(at, 1), sub(sub(p,` to `if true { h := keccak256(add(at, 1), sub(sub(p,` | Equivalent | nested keys are then hashed too, but only top-level ones are captured (gas only) |
| 409 | MIA | `if eq(depth, 8) {` to `if true {` | Equivalent | nested keys are not hashed (their hash stays zero), and no requested key hashes to zero, so capturing them changes nothing |
| 413 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check (the walk must end exactly at the end) still rejects the document |
| 413 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Equivalent | a pointer at or past the end only reads the byte after the text, and the caller's end check still rejects the document |
| 418 | CR | `leave` to `//leave` | Equivalent | the `q` already set survives: the next check leaves the same way |
| 428 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 428 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 453 | CR | `leave` to `//leave` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 471 | CR | `if iszero(and(lt(p, e), eq(byte(0,` to `//if iszero(and(lt(p, e), eq(byte(0,` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 471 | MIA | `if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x7b))) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 473 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 473 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 476 | CR | `leave` to `//leave` | Equivalent | the `q` already set survives: the next check leaves the same way |
| 487 | CR | `if iszero(p) { leave }` to `//if iszero(p) { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 487 | MIA | `if iszero(p) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 496 | CR | `leave` to `//leave` | Equivalent | the `q` already set survives: the next check leaves the same way |
| 498 | CR | `if iszero(eq(c, 0x2c)) { leave` to `//if iszero(eq(c, 0x2c)) { leave` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 498 | MIA | `if iszero(eq(c, 0x2c)) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 507 | CR | `if iszero(and(lt(p, e), eq(byte(0,` to `//if iszero(and(lt(p, e), eq(byte(0,` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 507 | MIA | `if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x5b))) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 509 | CR | `if iszero(lt(p, e)) { leave }` to `//if iszero(lt(p, e)) { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 509 | MIA | `if iszero(lt(p, e)) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 517 | MIA | `if objects { stride := add(1, mload(mload(add(ctx,` to `if true { stride := add(1, mload(mload(add(ctx,` | Equivalent | `elements` passes no keys, so the stride is 1 either way |
| 527 | CR | `if iszero(p) { leave }` to `//if iszero(p) { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 527 | MIA | `if iszero(p) { leave }` to `if false { leave }` | Defensive | the navigators run only on documents `object` accepted, where this guard never fires (it backs the promise that they give false on other text) |
| 539 | CR | `leave` to `//leave` | Equivalent | the `q` already set survives: the next check leaves the same way |
| 548 | CR | `mstore(0x40, add(ctx, 0x80))` to `//mstore(0x40, add(ctx, 0x80))` | Equivalent | the context is used only inside this assembly block, which allocates nothing else |
| 560 | MIA | `if q { r := eq(ws(q, e), e) }` to `if true { r := eq(ws(q, e), e) }` | Equivalent | after a failed walk the end check starts at address zero and stops at the first byte that is not white space, never at the end of the text |

</details>

### `src/content/Renderer.sol`

122 survivors: 7 open gaps, 6 defensive, 8 gas margin, 101 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 94 | CONST | `internal constant PREVIEW_LIMIT = 65_536;` to `internal constant PREVIEW_LIMIT = 65537;` | Defensive | WorkRecords caps a preview at 16,384 stored bytes (an `Identity` one four times), a weight of at most 32,768, far inside 65,536 |
| 125 | CONST | `private constant MEDIA_GAS = 1_000_000;` to `private constant MEDIA_GAS = 1000001;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 125 | CONST | `uint256 private constant MEDIA_GAS = 1_000_000;` to `uint256 private constant MEDIA_GAS = 999999;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 126 | CONST | `private constant CHUNK_GAS = 300_000;` to `private constant CHUNK_GAS = 300001;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 126 | CONST | `uint256 private constant CHUNK_GAS = 300_000;` to `uint256 private constant CHUNK_GAS = 299999;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 127 | CONST | `private constant COMPLETE_GAS = 700_000;` to `private constant COMPLETE_GAS = 700001;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 127 | CONST | `private constant COMPLETE_GAS = 700_000;` to `private constant COMPLETE_GAS = 699999;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 129 | CONST | `private constant AFTER_GAS = 50_000;` to `private constant AFTER_GAS = 50001;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 129 | CONST | `uint256 private constant AFTER_GAS = 50_000;` to `uint256 private constant AFTER_GAS = 49999;` | Gas margin | one gas more or less of a read's gas budget is not observable without an exact-gas harness |
| 131 | CONST | `private constant TEXT_RETURN = 4_096;` to `private constant TEXT_RETURN = 4097;` | Equivalent | the collection record read with it holds a name of at most 256 bytes, far inside 4,096 |
| 131 | CONST | `private constant TEXT_RETURN = 4_096;` to `private constant TEXT_RETURN = 4095;` | Equivalent | the collection record read with it holds a name of at most 256 bytes, far inside 4,096 |
| 132 | AOR | `LOCATOR_RETURN = Limits.MAX_URI_BYTES + 256;` to `LOCATOR_RETURN = Limits.MAX_URI_BYTES - 256;` | Equivalent | locator URIs are 48 or 66 bytes (WorkRecords checks their shape), far inside either return cap |
| 136 | CONST | `private constant SPDX_CHARS = 0x07fffffe07fffffe03ff680000000000;` to `private constant SPDX_CHARS = 0x7fffffe07fffffe03ff680000000001;` | Defensive | only adds the NUL byte to the characters that make an SPDX link; license IDs are checked (`SpdxId`) before they reach the renderer |
| 214 | ROR | `if (threshold == 0 \|\| threshold > MAX_INLINE_BYTES` to `if (threshold <= 0 \|\| threshold > MAX_INLINE_BYTES` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 257 | AOR | `memory t = new bytes[](MAX_ARTISTS + 8);` to `memory t = new bytes[](MAX_ARTISTS * 8);` | Equivalent | a larger array of traits; only the first `n` are used (gas only) |
| 261 | ROR | `if (state == RecordState.Ready) {` to `if (state >= RecordState.Ready) {` | Equivalent | `Ready` is the last record state, so `>= Ready` is `== Ready` |
| 266 | ROR | `if (state != RecordState.Ready) {` to `if (state < RecordState.Ready) {` | Equivalent | `Ready` is the last record state, so `< Ready` is `!= Ready` |
| 285 | ROR | `if (ok && ret.length == 32 && abi.decode(ret, (uint256` to `if (ok && ret.length <= 32 && abi.decode(ret, (uint256` | Defensive | only 6529 Stream and 6529 Editions call the renderer with themselves as the token, and both answer `supportsInterface` with one word of 0 or 1 (the read copies at most 32 bytes, so `>= 32` is also `== 32`) |
| 285 | ROR | `if (ok && ret.length == 32 && abi.decode(ret, (uint256` to `if (ok && ret.length >= 32 && abi.decode(ret, (uint256` | Equivalent | the read copies at most 32 bytes, so `>= 32` is `== 32` |
| 285 | ROR | `&& abi.decode(ret, (uint256)) == 1) {` to `&& abi.decode(ret, (uint256)) >= 1) {` | Defensive | only 6529 Stream and 6529 Editions call the renderer with themselves as the token, and both answer `supportsInterface` with one word of 0 or 1 (the read copies at most 32 bytes, so `>= 32` is also `== 32`) |
| 301 | MIA | `if (c.core.collectionId != 0) {` to `if (true) {` | Equivalent | the collection is read but used only when the work has one |
| 301 | ROR | `if (c.core.collectionId != 0) {` to `if (c.core.collectionId > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 334 | ROR | `c.media.length == 0 \|\| c.media[0].role != FileRole.PRIMARY` to `c.media.length <= 0 \|\| c.media[0].role != FileRole.PRIMARY` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 334 | ROR | `c.media.length == 0 \|\| c.media[0].role != FileRole.PRIMARY` to `c.media.length == 0 \|\| c.media[0].role > FileRole.PRIMARY` | Equivalent | `PRIMARY` is the first file role, so `> PRIMARY` is `!= PRIMARY` |
| 334 | ROR | `c.edition && c.media[0].sha256Hash != c.hash)` to `c.edition && c.media[0].sha256Hash > c.hash)` | Gap | an edition whose primary file hash sorts below its content hash renders instead of being refused (only the other direction is tested) |
| 357 | ROR | `if (fi.encoding != IContentStore.Encoding.Identity` to `if (fi.encoding > IContentStore.Encoding.Identity` | Equivalent | `Identity` is the first encoding, so `> Identity` is `!= Identity` |
| 394 | ROR | `name.length < 3 \|\| description.length == 0) return _bad();` to `name.length < 3 \|\| description.length <= 0) return _bad();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 395 | ROR | `if (medium.length == 0 \|\| dimensions.length == 0)` to `if (medium.length <= 0 \|\| dimensions.length == 0)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 395 | ROR | `medium.length == 0 \|\| dimensions.length == 0) return _bad();` to `medium.length == 0 \|\| dimensions.length <= 0) return _bad();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 397 | ROR | `if (s[2] != 0) {` to `if (s[2] > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 400 | ROR | `for (uint256 i; ok && i < a.length; ++i) {` to `for (uint256 i; ok && i != a.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 400 | UOR | `uint256 i; ok && i < a.length; ++i) {` to `uint256 i; ok && i < a.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 407 | ROR | `if (s[3] != 0) {` to `if (s[3] > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 412 | ROR | `if (medium.length > 2) t[n++] = _trait("Medium", medium` to `if (medium.length != 2) t[n++] = _trait("Medium", medium` | Equivalent | the text is a quoted string (empty text was refused just above), so its length is at least 2 and `!= 2` is `> 2` |
| 413 | ROR | `if (dimensions.length > 2) t[n++] = _trait("Dimensions",` to `if (dimensions.length != 2) t[n++] = _trait("Dimensions",` | Equivalent | the text is a quoted string (empty text was refused just above), so its length is at least 2 and `!= 2` is `> 2` |
| 414 | ROR | `if (s[6] != 0) {` to `if (s[6] > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 419 | ROR | `c.deps = s[7] != 0 && JsonScan.slice(j, s[7]).length` to `c.deps = s[7] > 0 && JsonScan.slice(j, s[7]).length` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 419 | ROR | `JsonScan.slice(j, s[7]).length > 2;` to `JsonScan.slice(j, s[7]).length != 2;` | Gap | a one-character `dependencies` value (such as `0`) counts as no dependencies; nothing tests it |
| 420 | CR | `ok = true;` to `//ok = true;` | Equivalent | every path that reaches it already has `ok` true (it would have returned `_bad()` otherwise) |
| 424 | CR | `return (false, "", 0, "");` to `//return (false, "", 0, "");` | Equivalent | the function returns the same defaults when its only statement is gone |
| 446 | ROR | `for (uint256 i; ok && i < a.length; i += 5) {` to `for (uint256 i; ok && i != a.length; i += 5) {` | Equivalent | the records array holds five words per element, so a counter stepping by five meets its length exactly |
| 448 | ROR | `a[i + 1] == 0 \|\| a[i + 2] == 0 \|\| _reserved(JsonScan.slice(j,` to `a[i + 1] <= 0 \|\| a[i + 2] == 0 \|\| _reserved(JsonScan.slice(j,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 448 | ROR | `a[i + 1] == 0 \|\| a[i + 2] == 0 \|\| _reserved(JsonScan.slice(j,` to `a[i + 1] == 0 \|\| a[i + 2] <= 0 \|\| _reserved(JsonScan.slice(j,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 455 | ROR | `return (ok, a.length == 0 ? bytes("") : JsonScan.slice(j,` to `return (ok, a.length <= 0 ? bytes("") : JsonScan.slice(j,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 498 | CR | `if lt(sub(e, q), 32) { z := and(z,` to `//if lt(sub(e, q), 32) { z := and(z,` | Gap | the mask for the bytes after a trait name in its last word: reaching it needs the memory after the name to hold a byte of 0x80 or more, a backslash or DEL, which no test arranges |
| 498 | MIA | `if lt(sub(e, q), 32) { z := and(z, not(shr(shl(3, sub(e,` to `if true { z := and(z, not(shr(shl(3, sub(e,` | Equivalent | `true`: when the name reaches the word's end the shift is 256 or more, which masks nothing |
| 498 | MIA | `if lt(sub(e, q), 32) { z := and(z, not(shr(shl(3, sub(e,` to `if false { z := and(z, not(shr(shl(3, sub(e,` | Gap | `true` is equivalent (a shift of 256 or more masks nothing); `false` drops the mask for the bytes after a trait name, which needs memory after the name to hold a byte of 0x80 or more, a backslash or DEL |
| 511 | MIA | `if lt(k, 17) {` to `if true {` | Equivalent | longer names are hashed too, but no reserved name is longer than 16 letters, short of a 32-bit hash collision |
| 537 | ROR | `return first == '"' \|\| first == "-" \|\| (first` to `return first <= '"' \|\| first == "-" \|\| (first` | Equivalent | no JSON value starts with a byte below `"` |
| 537 | ROR | `return first == '"' \|\| first == "-" \|\| (first >= "0" && first` to `return first == '"' \|\| first <= "-" \|\| (first >= "0" && first` | Equivalent | between `"` and `-` no byte starts a JSON value |
| 542 | ROR | `uint256 i = y[0] == "-" ? 1 : 0; // a span is never` to `uint256 i = y[0] <= "-" ? 1 : 0; // a span is never` | Equivalent | only a string starts below `-`, and its closing quote fails the digit check either way |
| 543 | ROR | `ok = y.length > i && y.length - i <= 6;` to `ok = y.length >= i && y.length - i <= 6;` | Equivalent | `i` is at most 1 and a span is never empty or the sign alone, so the length is always above `i` |
| 543 | ROR | `ok = y.length > i && y.length - i <= 6;` to `ok = y.length != i && y.length - i <= 6;` | Equivalent | `i` is at most 1 and a span is never empty or the sign alone, so the length is always above `i` |
| 544 | ROR | `for (; ok && i < y.length; ++i) {` to `for (; ok && i != y.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 544 | UOR | `for (; ok && i < y.length; ++i) {` to `for (; ok && i < y.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 556 | MIA | `if (span == 0) return required ? bytes("") : bytes('""');` to `if (span == 0) return false ? bytes("") : bytes('""');` | Equivalent | a required field that is missing reads as `""`, two bytes, which the caller's minimum of three rejects as it does an empty one |
| 556 | ROR | `if (span == 0) return required ? bytes(""` to `if (span <= 0) return required ? bytes(""` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 558 | ROR | `if (text[0] != '"') return "";` to `if (text[0] > '"') return "";` | Equivalent | no JSON value starts with a byte below `"` |
| 572 | ROR | `if (p.mode == Mode.Locator) m[2] = p;` to `if (p.mode <= Mode.Locator) m[2] = p;` | Equivalent | a primary in `None` mode written to the empty `media_url` slot is skipped like the empty slot |
| 574 | ROR | `m[0] = p.mode >= Mode.Data \|\| v.mode == Mode.None` to `m[0] = p.mode > Mode.Data \|\| v.mode == Mode.None` | Equivalent | an image primary is never in `Data` mode (only a wrapped script is), and `None` is the first mode |
| 574 | ROR | `p.mode >= Mode.Data \|\| v.mode == Mode.None ? p : v;` to `p.mode >= Mode.Data \|\| v.mode <= Mode.None ? p : v;` | Equivalent | an image primary is never in `Data` mode (only a wrapped script is), and `None` is the first mode |
| 584 | ROR | `if (m.mode != Mode.None) return m;` to `if (m.mode > Mode.None) return m;` | Equivalent | `None` is the first mode, so `> None` is `!= None` |
| 592 | ROR | `for (uint256 i = 1; i < c.media.length; ++i) {` to `for (uint256 i = 1; i != c.media.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 592 | UOR | `uint256 i = 1; i < c.media.length; ++i) {` to `uint256 i = 1; i < c.media.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 593 | ROR | `if (c.media[i].role != FileRole.PREVIEW) continue;` to `if (c.media[i].role > FileRole.PREVIEW) continue;` | Equivalent | the loop starts after the primary, the only PRIMARY file (`openRecord` enforces it) |
| 599 | ROR | `if (m.mode != Mode.None) return m;` to `if (m.mode > Mode.None) return m;` | Equivalent | `None` is the first mode, so `> None` is `!= None` |
| 614 | ROR | `return enc == IContentStore.Encoding.Identity` to `return enc <= IContentStore.Encoding.Identity` | Equivalent | `Identity` is the first encoding, so `<= Identity` is `== Identity` |
| 623 | ROR | `} else if (enc == IContentStore.Encoding.Identity` to `} else if (enc <= IContentStore.Encoding.Identity` | Equivalent | `Identity` is the first encoding, so `<= Identity` is `== Identity` |
| 626 | CR | `return m;` to `//return m;` | Equivalent | the mode stays `None`, which every caller treats as not inlineable, so the locator is served as before |
| 646 | ROR | `seed == 0 ? bytes("null") : _quote(Strings.toHexString(uint256(seed` to `seed <= 0 ? bytes("null") : _quote(Strings.toHexString(uint256(seed` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 675 | ROR | `if (l.kind != LocatorKind.NONE && l.kind !=` to `if (l.kind > LocatorKind.NONE && l.kind !=` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 675 | ROR | `!= LocatorKind.NONE && l.kind != LocatorKind.ONCHAIN && bytes(l.uri` to `!= LocatorKind.NONE && l.kind < LocatorKind.ONCHAIN && bytes(l.uri` | Equivalent | `ONCHAIN` is the last locator kind, so `< ONCHAIN` is `!= ONCHAIN` |
| 675 | ROR | `LocatorKind.ONCHAIN && bytes(l.uri).length != 0)` to `LocatorKind.ONCHAIN && bytes(l.uri).length > 0)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 691 | ROR | `for (uint256 i; i < 3; ++i) {` to `for (uint256 i; i != 3; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 691 | UOR | `for (uint256 i; i < 3; ++i) {` to `for (uint256 i; i < 3; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 692 | ROR | `if (m[i].mode != Mode.None) total += keys[i].length` to `if (m[i].mode > Mode.None) total += keys[i].length` | Equivalent | `None` is the first mode, so `> None` is `!= None` |
| 696 | ROR | `for (uint256 i; i < 3; ++i) {` to `for (uint256 i; i != 3; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 697 | ROR | `if (m[i].mode == Mode.None) continue;` to `if (m[i].mode <= Mode.None) continue;` | Equivalent | `None` is the first mode, so `<= None` is `== None` |
| 700 | ROR | `if (m[i].mode == Mode.Copy) {` to `if (m[i].mode <= Mode.Copy) {` | Equivalent | locator and data entries have a length of zero, so the copy branch copies nothing for them |
| 703 | MIA | `} else if (m[i].mode == Mode.Encode) {` to `} else if (true) {` | Equivalent | the other modes carry no file length, so encoding writes nothing |
| 703 | ROR | `} else if (m[i].mode == Mode.Encode) {` to `} else if (m[i].mode <= Mode.Encode) {` | Equivalent | locator and data entries have a length of zero, so the encode branch writes nothing for them; `Encode` is the last mode |
| 703 | ROR | `} else if (m[i].mode == Mode.Encode) {` to `} else if (m[i].mode >= Mode.Encode) {` | Equivalent | locator and data entries have a length of zero, so the encode branch writes nothing for them; `Encode` is the last mode |
| 713 | ROR | `if (m.mode == Mode.Copy) return m.text.length` to `if (m.mode <= Mode.Copy) return m.text.length` | Equivalent | locator and data entries have a length of zero, so the sizes agree |
| 714 | MIA | `if (m.mode == Mode.Encode) return m.text.length + (((m.length` to `if (true) return m.text.length + (((m.length` | Equivalent | the other modes carry no file length, so the size is the text's either way |
| 714 | ROR | `if (m.mode == Mode.Encode) return m.text.length` to `if (m.mode <= Mode.Encode) return m.text.length` | Equivalent | locator and data entries have a length of zero, so the sizes agree; `Encode` is the last mode |
| 714 | ROR | `if (m.mode == Mode.Encode) return m.text.length` to `if (m.mode >= Mode.Encode) return m.text.length` | Equivalent | locator and data entries have a length of zero, so the sizes agree; `Encode` is the last mode |
| 730 | CR | `mstore(0x40, mark)` to `//mstore(0x40, mark)` | Equivalent | not restoring the free-memory pointer only leaves the encoded copy allocated (gas only) |
| 739 | ROR | `for (uint256 i; done < length; ++i) {` to `for (uint256 i; done != length; ++i) {` | Equivalent | each chunk is checked to be the remainder or a full chunk, so `done` meets `length` exactly |
| 739 | UOR | `for (uint256 i; done < length; ++i) {` to `for (uint256 i; done < length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 756 | ROR | `if (n != (left < SSTORE2.MAX_CHUNK_LENGTH` to `if (n < (left < SSTORE2.MAX_CHUNK_LENGTH` | Defensive | the trusted store's chunks follow its layout rule, so a chunk longer than the remainder cannot arrive (`<=` on the limit is equivalent: at exactly the limit both give the limit) |
| 756 | ROR | `if (n != (left < SSTORE2.MAX_CHUNK_LENGTH` to `if (n < (left < SSTORE2.MAX_CHUNK_LENGTH` | Defensive | the trusted store's chunks follow its layout rule, so a chunk longer than the remainder cannot arrive (`<=` on the limit is equivalent: at exactly the limit both give the limit) |
| 756 | ROR | `if (n != (left < SSTORE2.MAX_CHUNK_LENGTH ? left` to `if (n != (left <= SSTORE2.MAX_CHUNK_LENGTH ? left` | Equivalent | at exactly the chunk limit both forms give the limit |
| 779 | ROR | `if (c.core.collectionId != 0) {` to `if (c.core.collectionId > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 783 | ROR | `state == RecordState.NotOpen` to `state <= RecordState.NotOpen` | Equivalent | `NotOpen` is the first state, and past it the state is `Incomplete` or `Invalid`, so the order tests are the equality tests |
| 783 | ROR | `: state == RecordState.Incomplete ? bytes("incomplete"` to `: state <= RecordState.Incomplete ? bytes("incomplete"` | Equivalent | `NotOpen` is the first state, and past it the state is `Incomplete` or `Invalid`, so the order tests are the equality tests |
| 806 | ROR | `if (c.core.collectionId != 0) {` to `if (c.core.collectionId > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 812 | ROR | `if (seed != 0) t[n++] = _trait("Seed", _quote(Strings.toHexString(u...` to `if (seed > 0) t[n++] = _trait("Seed", _quote(Strings.toHexString(ui...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 823 | ROR | `if (entry != 0) {` to `if (entry > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 857 | ROR | `if (url.length != 0) out = bytes.concat(out, ',"license_url":"',` to `if (url.length > 0) out = bytes.concat(out, ',"license_url":"',` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 858 | ROR | `if (lic.textFileId != 0) {` to `if (lic.textFileId > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 867 | ROR | `ours.length != 0 && attributes.length != 0 ?` to `ours.length > 0 && attributes.length != 0 ?` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 867 | ROR | `ours.length != 0 && attributes.length != 0 ? bytes(",") : bytes(""),` to `ours.length != 0 && attributes.length > 0 ? bytes(",") : bytes(""),` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 884 | ROR | `bool spdx = id.length != 0;` to `bool spdx = id.length > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 885 | ROR | `for (uint256 i; spdx && i < id.length; ++i) {` to `for (uint256 i; spdx && i != id.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 885 | UOR | `uint256 i; spdx && i < id.length; ++i) {` to `uint256 i; spdx && i < id.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 887 | ROR | `spdx = b < 128 && (SPDX_CHARS >> b) & 1 ==` to `spdx = b <= 128 && (SPDX_CHARS >> b) & 1 ==` | Equivalent | the character set has no bit at or above 128, so `<= 128` and `!= 128` admit nothing more; `& 1 >= 1` is `== 1` |
| 887 | ROR | `spdx = b < 128 && (SPDX_CHARS >> b) & 1 ==` to `spdx = b != 128 && (SPDX_CHARS >> b) & 1 ==` | Equivalent | the character set has no bit at or above 128, so `<= 128` and `!= 128` admit nothing more; `& 1 >= 1` is `== 1` |
| 887 | ROR | `< 128 && (SPDX_CHARS >> b) & 1 == 1;` to `< 128 && (SPDX_CHARS >> b) & 1 >= 1;` | Equivalent | the character set has no bit at or above 128, so `<= 128` and `!= 128` admit nothing more; `& 1 >= 1` is `== 1` |
| 902 | ROR | `for (uint256 i; lic.textFileId != 0 && i < c.media.length; ++i)` to `for (uint256 i; lic.textFileId > 0 && i < c.media.length; ++i)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 902 | ROR | `uint256 i; lic.textFileId != 0 && i < c.media.length; ++i) {` to `uint256 i; lic.textFileId != 0 && i != c.media.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 903 | ROR | `if (c.media[i].fileId == lic.textFileId) return _locator(c,` to `if (c.media[i].fileId >= lic.textFileId) return _locator(c,` | Gap | a license text that is not among the media while a media file's ID sorts above it: the mutant serves the text's locator anyway |
| 905 | CR | `return "";` to `//return "";` | Equivalent | the function returns the empty string by default when the last statement is gone |
| 912 | ROR | `if (c.core.seedPolicy == SeedPolicy.NONE) return 0;` to `if (c.core.seedPolicy <= SeedPolicy.NONE) return 0;` | Equivalent | `NONE` is the first seed policy, so `<= NONE` is `== NONE` |
| 918 | ROR | `} else if (c.core.seedPolicy == SeedPolicy.VRF) {` to `} else if (c.core.seedPolicy >= SeedPolicy.VRF) {` | Equivalent | `VRF` is the last seed policy, so `>= VRF` is `== VRF` |
| 938 | ROR | `uint256 total = n == 0 ? 0 : n - 1;` to `uint256 total = n <= 0 ? 0 : n - 1;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 939 | ROR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i <= n; ++i) {` | Gap | no test fills every trait slot (the most artists, year, medium, dimensions, collection, serial, edition, seed and a dispute statement), so reading one past the count goes unnoticed |
| 939 | ROR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i != n; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 939 | UOR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i < n; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 944 | ROR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i <= n; ++i) {` | Gap | no test fills every trait slot (the most artists, year, medium, dimensions, collection, serial, edition, seed and a dispute statement), so reading one past the count goes unnoticed |
| 944 | ROR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i != n; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 945 | ROR | `if (i != 0) p = _put(p, ",");` to `if (i > 0) p = _put(p, ",");` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1026 | ROR | `return fi.encoding == IContentStore.Encoding.Identity` to `return fi.encoding <= IContentStore.Encoding.Identity` | Equivalent | `Identity` is the first encoding, so `<= Identity` is `== Identity` |

</details>

### `src/curation/Eip712CurationVerifier.sol`

3 survivors: 3 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 122 | SBR | `SignerState storage s = _signers[signer];` to `SignerState memory s = _signers[signer];` | Equivalent | a read-only struct copied instead of read in place |
| 133 | SBR | `abi.encode(Typehashes.PACKAGE_APPROVAL, packageRoot,` to `abi.encodePacked(Typehashes.PACKAGE_APPROVAL, packageRoot,` | Equivalent | `abi.encodePacked` of four 32-byte values is the same bytes as `abi.encode` |
| 160 | ROR | `if (a.length < 96) return (false, address(0),` to `if (a.length <= 96) return (false, address(0),` | Equivalent | a 96-byte attestation carries an empty signature, which never verifies: refused either way |

</details>

### `src/curation/PackageRegistry.sol`

45 survivors: 3 defensive, 42 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 73 | CONST | `private constant NONCES_PER_WORD = 255;` to `private constant NONCES_PER_WORD = 254;` | Equivalent | 254 nonces a word still keeps every nonce distinct and off the sentinel bit |
| 157 | ROR | `if (p.status != PackageStatus.NONE) revert PackageExists(packageRoot` to `if (p.status > PackageStatus.NONE) revert PackageExists(packageRoot` | Equivalent | the enum's first value is zero, so `>` is `!=` |
| 161 | ROR | `if (!approved \|\| evidenceHash == 0) revert NotApproved(packageRoot` to `if (!approved \|\| evidenceHash <= 0) revert NotApproved(packageRoot` | Equivalent | `bytes32` compares as unsigned: `== 0` and `<= 0` are the same test |
| 175 | ROR | `if (p.status == PackageStatus.REVOKED) revert` to `if (p.status >= PackageStatus.REVOKED) revert` | Equivalent | the enum's last (or first) value, so the order test is the equality test |
| 200 | ROR | `address signer = artistId == 0 ? account : _artists.activeAuthority...` to `address signer = artistId <= 0 ? account : _artists.activeAuthority...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 207 | ROR | `if (accepted[account] != 0) return accepted[account];` to `if (accepted[account] > 0) return accepted[account];` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 208 | ROR | `if (artistId != 0) {` to `if (artistId > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 222 | ROR | `!= artistId` to `< artistId` | Defensive | the artist registry returns the ID it just assigned (coverage lists the revert as unreachable) |
| 222 | ROR | `!= artistId` to `> artistId` | Defensive | the artist registry returns the ID it just assigned (coverage lists the revert as unreachable) |
| 252 | ROR | `if (prior != 0) {` to `if (prior > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 253 | ROR | `if (prior != RELEASED) revert ContentUsed(PRODUCT_STREAM,` to `if (prior > RELEASED) revert ContentUsed(PRODUCT_STREAM,` | Equivalent | the only value below `RELEASED` (1) is zero, which the line before excludes |
| 260 | ROR | `if (prior == RELEASED && artistId != _releasedTo[contentHash]` to `if (prior >= RELEASED && artistId != _releasedTo[contentHash]` | Equivalent | any other used item already reverted on the line before, so `prior` is zero or `RELEASED` here |
| 277 | ROR | `if (prior != 0) revert ContentUsed(PRODUCT_EDITIONS,` to `if (prior > 0) revert ContentUsed(PRODUCT_EDITIONS,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 297 | CR | `revert IArtistRegistry.UnknownArtist(beneficiary` to `//revert IArtistRegistry.UnknownArtist(beneficiary` | Defensive | the artist registry reverts `UnknownArtist` first for an artist with no authority (coverage lists it too) |
| 361 | ROR | `if (itemHash == RELEASED) itemHash = 0;` to `if (itemHash <= RELEASED) itemHash = 0;` | Equivalent | the only value below `RELEASED` (1) is zero, which it maps to zero as well |
| 381 | ROR | `NONCES_PER_WORD] & _bit(nonce) != 0;` to `NONCES_PER_WORD] & _bit(nonce) > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 428 | ROR | `bool fixedSize = e.format == EditionFormat.FIXED;` to `bool fixedSize = e.format <= EditionFormat.FIXED;` | Equivalent | the enum's last (or first) value, so the order test is the equality test |
| 429 | ROR | `item.contentHash == 0 \|\| (item.seedPolicy == SeedPolicy.ARTIST` to `item.contentHash <= 0 \|\| (item.seedPolicy == SeedPolicy.ARTIST` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 429 | ROR | `SeedPolicy.ARTIST) == (item.seed == 0);` to `SeedPolicy.ARTIST) == (item.seed <= 0);` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 431 | ROR | `if (item.kind == ItemKind.ORIGINAL) {` to `if (item.kind <= ItemKind.ORIGINAL) {` | Equivalent | the enum's last (or first) value, so the order test is the equality test |
| 432 | ROR | `= bad \|\| !fixedSize \|\| e.size != 0 \|\| e.window != 0 \|\| e.price` to `= bad \|\| !fixedSize \|\| e.size > 0 \|\| e.window != 0 \|\| e.price` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 432 | ROR | `!fixedSize \|\| e.size != 0 \|\| e.window != 0 \|\| e.price != 0` to `!fixedSize \|\| e.size != 0 \|\| e.window > 0 \|\| e.price != 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 432 | ROR | `0 \|\| e.window != 0 \|\| e.price != 0` to `0 \|\| e.window != 0 \|\| e.price > 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 432 | ROR | `e.currency != address(0) \|\| e.saleKind != 0 \|\| e.params.length != 0;` to `e.currency != address(0) \|\| e.saleKind > 0 \|\| e.params.length != 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 432 | ROR | `e.saleKind != 0 \|\| e.params.length != 0;` to `e.saleKind != 0 \|\| e.params.length > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 455 | ROR | `n == 0 \|\| n > Limits.MAX_PARTIES \|\|` to `n <= 0 \|\| n > Limits.MAX_PARTIES \|\|` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 455 | ROR | `Limits.MAX_PARTIES \|\| parties[0].role != PartyRole.ARTIST` to `Limits.MAX_PARTIES \|\| parties[0].role > PartyRole.ARTIST` | Equivalent | `ARTIST` is the first party role, so `> ARTIST` is `!= ARTIST` |
| 455 | ROR | `\|\| payees.length == 0 \|\| payees.length > n` to `\|\| payees.length <= 0 \|\| payees.length > n` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 460 | ROR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i != n; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 460 | UOR | `for (uint256 i; i < n; ++i) {` to `for (uint256 i; i < n; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 462 | ROR | `if (id == 0) revert PartyNotAccepted(packageRoot,` to `if (id <= 0) revert PartyNotAccepted(packageRoot,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 463 | ROR | `for (uint256 j; j < i; ++j) {` to `for (uint256 j; j <= i; ++j) {` | Equivalent | `ids[i]` is still zero when compared and an accepted ID is never zero, so the extra comparison never matches |
| 463 | ROR | `for (uint256 j; j < i; ++j) {` to `for (uint256 j; j != i; ++j) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 463 | UOR | `for (uint256 j; j < i; ++j) {` to `for (uint256 j; j < i; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 469 | ROR | `for (uint256 i; i < payees.length; ++i) {` to `for (uint256 i; i != payees.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 471 | ROR | `bool ordered = i == 0 \|\| p.artistId > payees[i -` to `bool ordered = i <= 0 \|\| p.artistId > payees[i -` | Equivalent | `i <= 0` is `i == 0` for an unsigned index; a tie-break of `>=` adds only `>`, which the clause before already accepts |
| 471 | ROR | `\|\| (p.artistId == payees[i - 1].artistId && p.account` to `\|\| (p.artistId >= payees[i - 1].artistId && p.account` | Equivalent | `i <= 0` is `i == 0` for an unsigned index; a tie-break of `>=` adds only `>`, which the clause before already accepts |
| 474 | ROR | `!ordered \|\| (p.artistId == 0) == (p.account == address(0` to `!ordered \|\| (p.artistId <= 0) == (p.account == address(0` | Equivalent | `<= 0` and `<= address(0)` are the zero tests they replace |
| 474 | ROR | `p.account == address(0)) \|\| p.share == 0` to `p.account == address(0)) \|\| p.share <= 0` | Equivalent | `<= 0` and `<= address(0)` are the zero tests they replace |
| 488 | ROR | `for (uint256 j; j < ids.length; ++j) {` to `for (uint256 j; j != ids.length; ++j) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 488 | UOR | `for (uint256 j; j < ids.length; ++j) {` to `for (uint256 j; j < ids.length; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 489 | ROR | `if (p.artistId == 0 ? parties[j].account == p.account` to `if (p.artistId <= 0 ? parties[j].account == p.account` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 493 | CR | `return false;` to `//return false;` | Equivalent | the function returns false by default when the last statement is gone |
| 520 | ROR | `if (bits & bit != 0) revert MoveNonceUsed(artistId,` to `if (bits & bit > 0) revert MoveNonceUsed(artistId,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 548 | ROR | `return target.code.length != 0 && !DelegatedEOA.isDelegated(target` to `return target.code.length > 0 && !DelegatedEOA.isDelegated(target` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/economics/AssetAllowlist.sol`

12 survivors: 12 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 27 | SBR | `address public constant ETH = address(0);` to `address public immutable ETH = address(0);` | Equivalent | `constant` to `immutable` with the same value |
| 61 | SBR | `AssetConfig storage config = _assets[asset];` to `AssetConfig memory config = _assets[asset];` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 66 | ROR | `if (config.status == Status.Deprecated) {` to `if (config.status >= Status.Deprecated) {` | Equivalent | `Deprecated` is the last status, so `>=` is `==` |
| 67 | SBR | `uint256 allowedAt = uint256(config.since) + Roles.FUNDS;` to `uint128 allowedAt = uint128(config.since) + Roles.FUNDS;` | Equivalent | the timestamp sum fits the narrower type |
| 72 | ROR | `if (asset.code.length == 0 \|\| DelegatedEOA.isDelegated(asset)) {` to `if (asset.code.length <= 0 \|\| DelegatedEOA.isDelegated(asset) \|\| De...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 100 | ROR | `if (floor == 0) revert InvalidIncrementFloor(` to `if (floor <= 0) revert InvalidIncrementFloor(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 111 | ROR | `if (product == bytes32(0)) revert InvalidProduct(` to `if (product <= bytes32(0)) revert InvalidProduct(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 138 | SBR | `AssetConfig storage config = _assets[asset];` to `AssetConfig memory config = _assets[asset];` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 150 | SBR | `Currency storage currency = _defaults[product]` to `Currency memory currency = _defaults[product]` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 158 | SBR | `Currency storage currency = _defaults[product]` to `Currency memory currency = _defaults[product]` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 167 | ROR | `if (floor == 0) revert InvalidIncrementFloor(` to `if (floor <= 0) revert InvalidIncrementFloor(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 169 | ROR | `if (previous == Status.Deprecated) {` to `if (previous >= Status.Deprecated) {` | Equivalent | `Deprecated` is the last status, so `>=` is `==` |

</details>

### `src/economics/ClaimRouter.sol`

22 survivors: 2 open gaps, 3 gas margin, 17 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 40 | SBR | `uint256 public constant MAX_CLAIMS = 50;` to `uint256 public immutable MAX_CLAIMS = 50;` | Equivalent | `constant` to `immutable` with the same value |
| 42 | SBR | `uint256 public constant MIN_ITEM_GAS = 200_000;` to `uint256 public immutable MIN_ITEM_GAS = 200_000;` | Equivalent | `constant` to `immutable` with the same value |
| 48 | SBR | `uint256 public constant MAX_SIGNED_CLAIMS = 20;` to `uint256 public immutable MAX_SIGNED_CLAIMS = 20;` | Equivalent | `constant` to `immutable` with the same value |
| 50 | SBR | `uint256 public constant MIN_SIGNED_ITEM_GAS = 450_000` to `uint256 public immutable MIN_SIGNED_ITEM_GAS = 450_000` | Equivalent | `constant` to `immutable` with the same value |
| 54 | SBR | `uint256 public constant SHORTFALL_REVERT_CEILING = 1_500_000` to `uint256 public immutable SHORTFALL_REVERT_CEILING = 1_500_000` | Equivalent | `constant` to `immutable` with the same value |
| 56 | SBR | `uint256 private constant _MAX_REASON_BYTES = 256;` to `uint256 private immutable _MAX_REASON_BYTES = 256;` | Equivalent | the same value as `immutable` or a narrower type |
| 56 | SBR | `uint256 private constant _MAX_REASON_BYTES` to `uint128 private constant _MAX_REASON_BYTES` | Equivalent | the same value as `immutable` or a narrower type |
| 76 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i != count; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 76 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the value never reaches 2**128 |
| 76 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the value never reaches 2**128 |
| 76 | UOR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i < count; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 93 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i != count; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 93 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the value never reaches 2**128 |
| 93 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the value never reaches 2**128 |
| 93 | UOR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i < count; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 111 | SBR | `memory input) private returns (uint256 amount) {` to `memory input) private returns (uint128 amount) {` | Gap | a release of 2**128 or more through the router (an allowlisted token would need that supply) |
| 113 | SBR | `uint256 size;` to `uint128 size;` | Equivalent | return data never reaches 2**128 bytes |
| 115 | ROR | `if (wallet.code.length == 0) {` to `if (wallet.code.length <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 121 | MIA | `uint256 callGas = item.keepGoing ? available / (item.remaining` to `uint256 callGas = true ? available / (item.remaining` | Gap | stop mode forwards all the gas left; no test gives a stop-mode item more gas than its continue-mode share would be |
| 122 | ROR | `if (item.keepGoing && callGas < item.minGas) {` to `if (item.keepGoing && item.keepGoing && callGas <= item.minGas) {` | Gas margin | `callGas` exactly equal to the item's minimum is not observable without an exact-gas harness |
| 147 | ROR | `item.keepGoing && callGas < SHORTFALL_REVERT_CEILING` to `item.keepGoing && item.keepGoing && callGas <= SHORTFALL_REVERT_CEI...` | Gas margin | `<=` at the ceiling and `>=` on the spent gas are exact-gas boundaries (the third mutant here, an error selector above the shortfall's, is killed by `test_ContinueModeSkipsAnItemFailingWithAHighSelector`) |
| 147 | ROR | `&& (spent > callGas - callGas / 64` to `&& (item.keepGoing && callGas < SHORTFALL_REVERT_CEILING && (spent ...` | Gas margin | `<=` at the ceiling and `>=` on the spent gas are exact-gas boundaries (the third mutant here, an error selector above the shortfall's, is killed by `test_ContinueModeSkipsAnItemFailingWithAHighSelector`) |

</details>

### `src/economics/EconomicsResolver.sol`

15 survivors: 15 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 47 | SBR | `uint32 public constant DEFAULT_FEE_SHARE = 25_000;` to `uint32 public immutable DEFAULT_FEE_SHARE = 25_000;` | Equivalent | a `constant` as `immutable`, or a `uint16` that still holds the value: same behaviour and getter word |
| 47 | SBR | `uint32 public constant DEFAULT_FEE_SHARE` to `uint16 public constant DEFAULT_FEE_SHARE` | Equivalent | a `constant` as `immutable`, or a `uint16` that still holds the value: same behaviour and getter word |
| 49 | SBR | `uint32 public constant FEDERATED_FEE_SHARE = 10_000;` to `uint32 public immutable FEDERATED_FEE_SHARE = 10_000;` | Equivalent | a `constant` as `immutable`, or a `uint16` that still holds the value: same behaviour and getter word |
| 49 | SBR | `uint32 public constant FEDERATED_FEE_SHARE` to `uint16 public constant FEDERATED_FEE_SHARE` | Equivalent | a `constant` as `immutable`, or a `uint16` that still holds the value: same behaviour and getter word |
| 51 | SBR | `uint32 public constant DEFAULT_ROYALTY_RATE = 6_529;` to `uint32 public immutable DEFAULT_ROYALTY_RATE = 6_529;` | Equivalent | a `constant` as `immutable`, or a `uint16` that still holds the value: same behaviour and getter word |
| 51 | SBR | `uint32 public constant DEFAULT_ROYALTY_RATE` to `uint16 public constant DEFAULT_ROYALTY_RATE` | Equivalent | a `constant` as `immutable`, or a `uint16` that still holds the value: same behaviour and getter word |
| 151 | SBR | `ProductEconomics memory e = _known(product).economics` to `ProductEconomics storage e = _known(product).economics` | Equivalent | a read-only struct read from storage instead of copied |
| 194 | SBR | `Product storage p = _known(product);` to `Product memory p = _known(product);` | Equivalent | a read-only struct copied instead of read in place |
| 228 | ROR | `if (p.feeRevision == 0) revert UnknownProduct(product` to `if (p.feeRevision <= 0) revert UnknownProduct(product` | Equivalent | `== 0` and `<= 0` agree on an unsigned value |
| 237 | ROR | `\|\| (e.feeShare != 0 && e.feeRecipient == address(0))` to `\|\| (e.feeShare >= Splits.DENOMINATOR \|\| e.royaltyRate > Splits.DENO...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 252 | ROR | `for (uint256 i; i < id.length; ++i) {` to `for (uint256 i; i != id.length; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 252 | SBR | `for (uint256 i; i < id.length; ++i) {` to `for (uint128 i; i < id.length; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 252 | SBR | `for (uint256 i; i < id.length; ++i) {` to `for (uint128 i; i < id.length; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 252 | UOR | `for (uint256 i; i < id.length; ++i) {` to `for (uint256 i; i < id.length; i++) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 260 | ROR | `if (dependency.code.length == 0 \|\| DelegatedEOA.isDelegated(depende...` to `if (dependency.code.length <= 0 \|\| DelegatedEOA.isDelegated(depende...` | Equivalent | `== 0` and `<= 0` agree on an unsigned value |

</details>

### `src/economics/ReleaseVerifier.sol`

3 survivors: 3 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 21 | SBR | `bytes32 public constant RELEASE_TYPEHASH = keccak256(` to `bytes32 public immutable RELEASE_TYPEHASH = keccak256(` | Equivalent | `constant` to `immutable` with the same value |
| 71 | ROR | `if (bits & bit != 0) revert NonceAlreadyUsed(account,` to `if (bits & bit > 0) revert NonceAlreadyUsed(account,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 72 | BOR | `_nonceBitmap[account][nonce >> 8] = bits \| bit;` to `_nonceBitmap[account][nonce >> 8] = bits ^ bit;` | Equivalent | line 71 reverts when the bit is already set, so `|` and `^` set the same bit |

</details>

### `src/economics/RevenueEscrow.sol`

6 survivors: 1 defensive, 5 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 43 | ROR | `address(factory_).code.length == 0 \|\| DelegatedEOA.isDelegated(addr...` to `address(factory_).code.length <= 0 \|\| DelegatedEOA.isDelegated(addr...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 66 | ROR | `if (amount == 0) revert NothingOwed(wallet,` to `if (amount <= 0) revert NothingOwed(wallet,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 92 | CR | `nonReentrant` to `//nonReentrant` | Defensive | `recover` is restricted to governance, so no token or wallet callback can re-enter it |
| 95 | ROR | `if (config != bytes32(0)) {` to `if (config > bytes32(0)) {` | Equivalent | `bytes32` compares as unsigned: `!= 0` and `> 0` are the same test |
| 107 | ROR | `if (amount == 0) revert NothingOwed(wallet,` to `if (amount <= 0) revert NothingOwed(wallet,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 130 | ROR | `if (amount == 0) revert ZeroAmount();` to `if (amount <= 0) revert ZeroAmount();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/economics/RevenuePayment.sol`

9 survivors: 4 gas margin, 5 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 23 | CONST | `constant ETH_CALL_RESERVE = 40_000;` to `constant ETH_CALL_RESERVE = 40001;` | Gas margin | one gas more or less of reserve is not observable without an exact-gas harness |
| 23 | CONST | `internal constant ETH_CALL_RESERVE = 40_000;` to `internal constant ETH_CALL_RESERVE = 39999;` | Gas margin | one gas more or less of reserve is not observable without an exact-gas harness |
| 23 | SBR | `uint256 internal constant ETH_CALL_RESERVE` to `uint128 internal constant ETH_CALL_RESERVE` | Equivalent | the value fits the narrower type |
| 27 | CONST | `constant ERC20_TRANSFER_GAS = 300_000;` to `constant ERC20_TRANSFER_GAS = 300001;` | Gas margin | one gas more or less for the token's `transfer` is not observable without a token tuned to the exact boundary |
| 27 | CONST | `constant ERC20_TRANSFER_GAS = 300_000;` to `constant ERC20_TRANSFER_GAS = 299999;` | Gas margin | one gas more or less for the token's `transfer` is not observable without a token tuned to the exact boundary |
| 27 | SBR | `uint256 internal constant ERC20_TRANSFER_GAS` to `uint128 internal constant ERC20_TRANSFER_GAS` | Equivalent | the value fits the narrower type |
| 46 | ROR | `if (amount == 0) return false;` to `if (amount <= 0) return false;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 65 | ROR | `if (amount == 0) return false;` to `if (amount <= 0) return false;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 73 | ROR | `address(this), address(escrow)) != 0) {` to `address(this), address(escrow)) > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/economics/SplitFactory.sol`

12 survivors: 12 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 69 | ROR | `if (wallet.code.length != 0) return wallet;` to `if (wallet.code.length > 0) return wallet;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 88 | SBR | `uint256 count;` to `uint128 count;` | Equivalent | the count never reaches 2**128 |
| 93 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i != count; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 93 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 93 | UOR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i < count; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 130 | SBR | `return keccak256(abi.encode(configHash, salt));` to `return keccak256(abi.encodePacked(configHash, salt));` | Equivalent | two 32-byte words encode the same packed or padded |
| 139 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i != count; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 139 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 139 | UOR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i < count; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 142 | BOR | `= uint256(uint160(p.account)) \| (uint256(p.share) << 160);` to `= uint256(uint160(p.account)) ^ (uint256(p.share) << 160);` | Equivalent | the account and the shifted share do not overlap, so `|` and `^` agree |
| 142 | SBR | `uint256 packed = uint256(uint160(p.account)) \| (uint256(p.share) <<...` to `uint128 packed = uint128(uint160(p.account)) \| (uint128(p.share) <<...` | Equivalent | as compiled: solc leaves the narrowed value uncleaned on the stack and the inline `tstore` writes the whole word (tests pass with it); fragile, not meaningful |
| 152 | ROR | `if (dependency.code.length == 0 \|\| DelegatedEOA.isDelegated(depende...` to `if (dependency.code.length <= 0 \|\| DelegatedEOA.isDelegated(depende...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/economics/SplitWallet.sol`

7 survivors: 7 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 67 | ROR | `for (uint256 i; i < payees_.length; ++i) {` to `for (uint256 i; i != payees_.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 67 | SBR | `for (uint256 i; i < payees_.length; ++i) {` to `for (uint128 i; i < payees_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 67 | SBR | `for (uint256 i; i < payees_.length; ++i) {` to `for (uint128 i; i < payees_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 67 | UOR | `uint256 i; i < payees_.length; ++i) {` to `uint256 i; i < payees_.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 166 | ROR | `if (amount == 0) revert NothingToRelease(asset,` to `if (amount <= 0) revert NothingToRelease(asset,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 207 | SBR | `Payee storage p = _payee(index);` to `Payee memory p = _payee(index);` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 208 | ROR | `if (p.artistId == 0) return (p.account, false)` to `if (p.artistId <= 0) return (p.account, false)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/economics/Splits.sol`

11 survivors: 11 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 15 | SBR | `uint256 internal constant MAX_PAYEES =` to `uint128 internal constant MAX_PAYEES =` | Equivalent | the value fits the narrower type |
| 23 | ROR | `if (count == 0 \|\| count > MAX_PAYEES) revert` to `if (count <= 0 \|\| count > MAX_PAYEES \|\| count > MAX_PAYEES) revert` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 24 | LIR | `` to `` | Equivalent | the literal is replaced by the same value |
| 24 | MVIV | `uint256 total = 0;` to `uint256 total ;` | Equivalent | an uninitialised local is zero |
| 24 | SBR | `uint256 total = 0;` to `uint128 total = 0;` | Equivalent | at most 64 shares of 32 bits sum far below 2**128 |
| 25 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i != count; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 25 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 25 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 25 | UOR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i < count; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 27 | ROR | `if ((p.artistId == 0) == (p.account == address(0))` to `if (((p.artistId <= 0) ) == (p.account == address(0))` | Equivalent | unsigned: `== 0` and `<= 0` are the same test |
| 30 | ROR | `if (i != 0 && !_sortsBefore(payees[i - 1],` to `if (i > 0 && !_sortsBefore(payees[i - 1], p) && !_sortsBefore(payee...` | Equivalent | unsigned: `!= 0` and `> 0` are the same test |

</details>

### `src/economics/TokenTransfer.sol`

7 survivors: 7 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 26 | SBR | `uint256 private constant _ALL_GAS = type(uint256).max;` to `uint128 private constant _ALL_GAS = type(uint128).max;` | Equivalent | a gas limit of 2**128 - 1 still forwards all the gas there is |
| 65 | CR | `revert TokenCallFailed(asset, IERC20.transfer.selector` to `//revert TokenCallFailed(asset, IERC20.transfer.selector` | Equivalent | dead code: the strict path reverts inside `_moveExact` and never returns false (see the coverage work list) |
| 139 | ROR | `if (outcome == Outcome.Reverted && tolerateFailure) return false;` to `if (outcome <= Outcome.Reverted && tolerateFailure && tolerateFailu...` | Equivalent | `Reverted` is the enum's first value: `<=` and `==` agree |
| 145 | ROR | `if (outcome == Outcome.False) {` to `if (outcome >= Outcome.False) {` | Equivalent | `Malformed`, the only value above `False`, has already reverted |
| 157 | ROR | `if (gasLimit != _ALL_GAS && !BoundedCall.hasSufficientGas(gasleft()...` to `if (gasLimit < _ALL_GAS && !BoundedCall.hasSufficientGas(gasleft(),...` | Equivalent | nothing is above `_ALL_GAS` (the maximum): `<` and `!=` agree |
| 161 | SBR | `uint256 size;` to `uint128 size;` | Equivalent | the return size of a call that returned at most 32 bytes into scratch space fits 128 bits |
| 175 | SBR | `uint256 size;` to `uint128 size;` | Equivalent | the return size of a balance read that returned at most 32 bytes into scratch space fits 128 bits |

</details>

### `src/editions/EditionRules.sol`

3 survivors: 3 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 19 | SBR | `uint256 private constant DUTCH_PARAMS_LENGTH` to `uint128 private constant DUTCH_PARAMS_LENGTH` | Equivalent | the value fits the narrower type |
| 29 | ROR | `if (t.currency == CURRENCY_DEFAULT && t.price != 0) return false;` to `if (t.currency == CURRENCY_DEFAULT && t.currency == CURRENCY_DEFAUL...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 30 | ROR | `if (t.format == EditionFormat.FIXED ? t.size == 0 \|\| t.window != 0 ...` to `if (t.format == EditionFormat.FIXED ? t.size == 0 \|\| t.format == Ed...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/editions/Editions.sol`

28 survivors: 2 open gaps, 1 defensive, 25 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 81 | SBR | `bytes32 private constant WORK_RECORDS = "WORK_RECORDS"` to `bytes32 private immutable WORK_RECORDS = "WORK_RECORDS"` | Equivalent | the same value as `immutable` |
| 83 | SBR | `uint8 private constant MINTER_NONE = 0;` to `uint8 private immutable MINTER_NONE = 0;` | Equivalent | the same value as `immutable` |
| 84 | SBR | `uint8 private constant MINTER_ADMITTED = 1;` to `uint8 private immutable MINTER_ADMITTED = 1;` | Equivalent | the same value as `immutable` |
| 85 | CONST | `private constant MINTER_REMOVED = 2;` to `private constant MINTER_REMOVED = 3;` | Equivalent | any value other than 0 and 1 marks a removed minter |
| 85 | SBR | `uint8 private constant MINTER_REMOVED = 2;` to `uint8 private immutable MINTER_REMOVED = 2;` | Equivalent | the same value as `immutable` |
| 223 | ROR | `if (terms.saleKind == SaleKind.DUTCH) {` to `if (terms.saleKind <= SaleKind.DUTCH) {` | Equivalent | terms reach this line only as FIXED_PRICE or DUTCH (`EditionRules.isValid`), and FIXED_PRICE's label sorts above DUTCH's |
| 238 | ROR | `linked != address(this) \|\| linkedId != workId) revert LinkFailed(wo...` to `linked != address(this) \|\| linkedId > workId) revert LinkFailed(workId` | Defensive | 6529 Stream, the bound core, links an edition only under its master's token ID |
| 335 | ROR | `_records[editionId].contentHash != 0;` to `_records[editionId].contentHash > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 352 | ROR | `if (amount == 0 \|\| data.length != 0) revert` to `if (amount <= 0 \|\| data.length != 0) revert` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 352 | ROR | `if (amount == 0 \|\| data.length != 0) revert InvalidMintRequest(` to `if (amount == 0 \|\| data.length > 0) revert InvalidMintRequest(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 357 | ROR | `uint256 cap = r.size == 0 ? type(uint64).max : r.size` to `uint256 cap = r.size <= 0 ? type(uint64).max : r.size` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 357 | SBR | `uint256 cap = r.size == 0 ? type(uint64` to `uint128 cap = r.size == 0 ? type(uint64` | Equivalent | the cap is at most 2**64 - 1, which fits |
| 359 | ROR | `if (r.format == EditionFormat.OPEN) {` to `if (r.format >= EditionFormat.OPEN) {` | Equivalent | `OPEN` is the last edition format, so `>= OPEN` is `== OPEN` |
| 361 | ROR | `if (start == 0) {` to `if (start <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 362 | SBR | `start = uint64(block.timestamp);` to `start = uint32(block.timestamp);` | Gap | an open edition first minted after 2**32 seconds (the year 2106): the window's start would wrap |
| 373 | SBR | `if (block.timestamp >= uint256(start) + r.window) revert EditionUna...` to `if (block.timestamp >= uint128(start) + r.window) revert EditionUna...` | Equivalent | a timestamp plus a window fits 128 bits |
| 395 | ROR | `if (_minterStatus[msg.sender] == MINTER_NONE) revert NotAdmittedMin...` to `if (_minterStatus[msg.sender] <= MINTER_NONE) revert NotAdmittedMin...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 396 | ROR | `if (amount == 0) revert InvalidMintRequest(` to `if (amount <= 0) revert InvalidMintRequest(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 406 | ROR | `if (_minterStatus[msg.sender] == MINTER_NONE) revert NotAdmittedMin...` to `if (_minterStatus[msg.sender] <= MINTER_NONE) revert NotAdmittedMin...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 419 | SBR | `Record storage r = _edition(tokenId);` to `Record memory r = _edition(tokenId);` | Equivalent | the record is only read, so a memory copy reads the same values |
| 497 | ROR | `stream).primarySaleSettled(workId) \|\| item.kind != ItemKind.EDITION...` to `stream).primarySaleSettled(workId) \|\| item.kind < ItemKind.EDITION_...` | Equivalent | `EDITION_MASTER` is the last item kind, so `< EDITION_MASTER` is `!= EDITION_MASTER` |
| 497 | ROR | `\|\| itemHash != master.itemHash \|\| item.contentHash` to `\|\| itemHash > master.itemHash \|\| item.contentHash` | Gap | `< EDITION_MASTER` is equivalent (the last item kind) and `<= 0` the unsigned test; `itemHash > master.itemHash` accepted an item whose hash sorts below the master's (only the other direction is tested) |
| 497 | ROR | `master.itemHash \|\| item.contentHash == 0` to `master.itemHash \|\| item.contentHash <= 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 503 | ROR | `if (evidenceHash == 0) revert NotEditionMaster(workId` to `if (evidenceHash <= 0) revert NotEditionMaster(workId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 508 | ROR | `return target.code.length != 0 && !DelegatedEOA.isDelegated(target` to `return target.code.length > 0 && !DelegatedEOA.isDelegated(target` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 508 | ROR | `return target.code.length != 0 && !DelegatedEOA.isDelegated(target` to `return target.code.length >= 0 && !DelegatedEOA.isDelegated(target` | Equivalent | `length >= 0` always holds, and an account without code fails the ERC-165 check that follows |
| 514 | ROR | `if (r.contentHash == 0) revert UnknownEdition(editionId` to `if (r.contentHash <= 0) revert UnknownEdition(editionId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 520 | ROR | `== CURRENCY_DEFAULT && t.price != 0) revert PricedDefaultCurrency(w...` to `== CURRENCY_DEFAULT && t.price > 0) revert PricedDefaultCurrency(wo...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/entropy/VrfEntropyModule.sol`

27 survivors: 1 open gap, 26 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 95 | SBR | `uint32 public constant MIN_CALLBACK_GAS = 100_000;` to `uint32 public immutable MIN_CALLBACK_GAS = 100_000;` | Equivalent | the same value as `immutable` or a narrower type |
| 97 | SBR | `uint32 public constant MAX_CALLBACK_GAS = 2_500_000;` to `uint32 public immutable MAX_CALLBACK_GAS = 2_500_000;` | Equivalent | the same value as `immutable` or a narrower type |
| 99 | SBR | `uint16 public constant MIN_CONFIRMATIONS = 3;` to `uint16 public immutable MIN_CONFIRMATIONS = 3;` | Equivalent | the same value as `immutable` or a narrower type |
| 99 | SBR | `uint16 public constant MIN_CONFIRMATIONS` to `uint8 public constant MIN_CONFIRMATIONS` | Equivalent | the same value as `immutable` or a narrower type |
| 101 | SBR | `uint16 public constant MAX_CONFIRMATIONS = 200;` to `uint16 public immutable MAX_CONFIRMATIONS = 200;` | Equivalent | the same value as `immutable` or a narrower type |
| 101 | SBR | `uint16 public constant MAX_CONFIRMATIONS` to `uint8 public constant MAX_CONFIRMATIONS` | Equivalent | the same value as `immutable` or a narrower type |
| 104 | SBR | `uint64 public constant MIN_RETRY_DELAY = 3 days;` to `uint64 public immutable MIN_RETRY_DELAY = 3 days;` | Equivalent | the same value as `immutable` or a narrower type |
| 104 | SBR | `uint64 public constant MIN_RETRY_DELAY` to `uint32 public constant MIN_RETRY_DELAY` | Equivalent | the same value as `immutable` or a narrower type |
| 106 | SBR | `uint64 public constant MAX_RETRY_DELAY = 30 days;` to `uint64 public immutable MAX_RETRY_DELAY = 30 days;` | Equivalent | the same value as `immutable` |
| 106 | SBR | `uint64 public constant MAX_RETRY_DELAY` to `uint32 public constant MAX_RETRY_DELAY` | Equivalent | a narrower type that still holds 30 days |
| 108 | SBR | `uint256 public constant MAX_PROOF_LENGTH = 32;` to `uint256 public immutable MAX_PROOF_LENGTH = 32;` | Equivalent | the same value as `immutable` or a narrower type |
| 108 | SBR | `uint256 public constant MAX_PROOF_LENGTH` to `uint128 public constant MAX_PROOF_LENGTH` | Equivalent | the same value as `immutable` or a narrower type |
| 111 | SBR | `bytes4 private constant EXTRA_ARGS_V1_TAG = 0x92fd1338` to `bytes4 private immutable EXTRA_ARGS_V1_TAG = 0x92fd1338` | Equivalent | `constant` to `immutable` with the same value |
| 185 | ROR | `registry.code.length == 0 \|\| DelegatedEOA.isDelegated(registry)` to `registry.code.length < 0 \|\| DelegatedEOA.isDelegated(registry) \|\| !...` | Equivalent | `length < 0` never holds, and an account without code fails the ERC-165 check that follows |
| 185 | ROR | `registry.code.length == 0 \|\| DelegatedEOA.isDelegated(registry)` to `registry.code.length <= 0 \|\| DelegatedEOA.isDelegated(registry) \|\| ...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 190 | CR | `c.callbackGasLimit =` to `//c.callbackGasLimit =` | Equivalent | only the assignment's first line is commented: the bound check still runs as a statement, and it returns the value unchanged |
| 237 | ROR | `if (seed.requestedAt != 0) {` to `if (seed.requestedAt > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 248 | SBR | `VrfConfig memory c = _config;` to `VrfConfig storage c = _config;` | Equivalent | a read-only copy read through a storage pointer instead (gas only) |
| 262 | ROR | `if (requestId == 0 \|\| _requests[coord][requestId]` to `if (requestId <= 0 \|\| _requests[coord][requestId] != 0 \|\| _requests...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 262 | ROR | `if (requestId == 0 \|\| _requests[coord][requestId] != 0) {` to `if (requestId == 0 \|\| requestId == 0 \|\| _requests[coord][requestId]...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 287 | ROR | `if (contentHash == 0) revert UnknownRequest(requestId` to `if (contentHash <= 0) revert UnknownRequest(requestId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 372 | SBR | `Seed storage seed = _seeds[_contentOf[itemHash]]` to `Seed memory seed = _seeds[_contentOf[itemHash]]` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 385 | SBR | `Seed storage seed = _seeds[_contentOf[itemHash]]` to `Seed memory seed = _seeds[_contentOf[itemHash]]` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 411 | ROR | `item.seedPolicy != SeedPolicy.VRF \|\| item.contentHash == 0` to `item.seedPolicy < SeedPolicy.VRF \|\| item.contentHash == 0 \|\| proof....` | Equivalent | `VRF` is the last seed policy, so `< VRF` is `!= VRF` |
| 411 | ROR | `item.seedPolicy != SeedPolicy.VRF \|\| item.contentHash == 0` to `item.seedPolicy != SeedPolicy.VRF \|\| item.seedPolicy != SeedPolicy....` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 411 | ROR | `\|\| proof.length > MAX_PROOF_LENGTH` to `\|\| item.seedPolicy != SeedPolicy.VRF \|\| item.contentHash == 0 \|\| pr...` | Gap | a proof of exactly `MAX_PROOF_LENGTH` nodes |
| 421 | ROR | `if (account.code.length == 0 \|\| DelegatedEOA.isDelegated(account)) {` to `if (account.code.length <= 0 \|\| DelegatedEOA.isDelegated(account) \|...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/governance/BoundedParameter.sol`

2 survivors: 2 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 22 | ROR | `if (value == 0 \|\| ceiling == 0) revert ParameterZero(` to `if (value <= 0 \|\| ceiling == 0) revert ParameterZero(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 22 | ROR | `if (value == 0 \|\| ceiling == 0) revert ParameterZero();` to `if (value == 0 \|\| ceiling <= 0) revert ParameterZero();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/governance/GovernanceConfig.sol`

137 survivors: 4 open gaps, 133 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 65 | SBR | `uint256 internal constant MIN_GUARDIANS` to `uint128 internal constant MIN_GUARDIANS` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 72 | SBR | `uint256 internal constant MAX_WIRING_CALLS` to `uint128 internal constant MAX_WIRING_CALLS` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 116 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 116 | MVIV | `for (uint256 i = 0; i < targets.length; ++i) {` to `for (uint256 i ; i < targets.length; ++i) {` | Equivalent | a local is zero without its initializer |
| 116 | ROR | `for (uint256 i = 0; i < targets.length; ++i) {` to `for (uint256 i = 0; i != targets.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 116 | SBR | `for (uint256 i = 0; i < targets.length; ++i) { address target = tar...` to `for (uint128 i = 0; i < targets.length; ++i) { address target = tar...` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 116 | SBR | `for (uint256 i = 0; i < targets.length; ++i` to `for (uint128 i = 0; i < targets.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 116 | UOR | `uint256 i = 0; i < targets.length; ++i) {` to `uint256 i = 0; i < targets.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 121 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 121 | MVIV | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j ; j < i; ++j) {` | Equivalent | a local is zero without its initializer |
| 121 | ROR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j = 0; j != i; ++j) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 121 | SBR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint128 j = 0; j < i; ++j) {` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 121 | SBR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint128 j = 0; j < i; ++j) {` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 121 | UOR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j = 0; j < i; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 155 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 155 | MVIV | `for (uint256 i = 0; i < wiring.length; ++i) {` to `for (uint256 i ; i < wiring.length; ++i) {` | Equivalent | a local is zero without its initializer |
| 155 | ROR | `for (uint256 i = 0; i < wiring.length; ++i) {` to `for (uint256 i = 0; i != wiring.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 155 | SBR | `for (uint256 i = 0; i < wiring.length; ++i` to `for (uint128 i = 0; i < wiring.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 155 | SBR | `for (uint256 i = 0; i < wiring.length; ++i` to `for (uint128 i = 0; i < wiring.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 155 | UOR | `uint256 i = 0; i < wiring.length; ++i) {` to `uint256 i = 0; i < wiring.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 161 | ROR | `if (data.length < 4 \|\| !_isTarget(cfg, target)) {` to `if (data.length <= 4 \|\| !_isTarget(cfg, target) \|\| !_isTarget(cfg, ...` | Equivalent | every genesis selector takes arguments, so a four-byte wiring call fails either way, at validation or when it runs |
| 175 | ROR | `for (uint64 role = 1; role < Roles.COUNT; ++role) {` to `for (uint64 role = 1; role != Roles.COUNT; ++role) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 175 | SBR | `for (uint64 role = 1; role < Roles.COUNT;` to `for (uint32 role = 1; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 175 | SBR | `for (uint64 role = 1; role < Roles.COUNT;` to `for (uint32 role = 1; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 175 | UOR | `role = 1; role < Roles.COUNT; ++role) {` to `role = 1; role < Roles.COUNT; role++) {` | Equivalent | pre- or post-increment of a loop counter |
| 183 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 183 | MVIV | `for (uint256 i = 0; i < cfg.targets.length; ++i)` to `for (uint256 i ; i < cfg.targets.length; ++i)` | Equivalent | a local is zero without its initializer |
| 183 | ROR | `for (uint256 i = 0; i < cfg.targets.length; ++i) {` to `for (uint256 i = 0; i != cfg.targets.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 183 | SBR | `for (uint256 i = 0; i < cfg.targets.length` to `for (uint128 i = 0; i < cfg.targets.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 183 | SBR | `for (uint256 i = 0; i < cfg.targets.length` to `for (uint128 i = 0; i < cfg.targets.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 183 | UOR | `i = 0; i < cfg.targets.length; ++i) {` to `i = 0; i < cfg.targets.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 188 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 188 | MVIV | `for (uint256 i = 0; i < wiring.length; ++i) {` to `for (uint256 i ; i < wiring.length; ++i) {` | Equivalent | a local is zero without its initializer |
| 188 | ROR | `for (uint256 i = 0; i < wiring.length; ++i) {` to `for (uint256 i = 0; i != wiring.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 188 | SBR | `for (uint256 i = 0; i < wiring.length; ++i` to `for (uint128 i = 0; i < wiring.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 188 | SBR | `for (uint256 i = 0; i < wiring.length; ++i` to `for (uint128 i = 0; i < wiring.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 191 | ROR | `if (reason.length == 0) revert WiringCallFailed(i` to `if (reason.length <= 0) revert WiringCallFailed(i` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 198 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 198 | MVIV | `for (uint256 i = 0; i < cfg.targets.length; ++i)` to `for (uint256 i ; i < cfg.targets.length; ++i)` | Equivalent | a local is zero without its initializer |
| 198 | ROR | `for (uint256 i = 0; i < cfg.targets.length; ++i) {` to `for (uint256 i = 0; i != cfg.targets.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 198 | SBR | `for (uint256 i = 0; i < cfg.targets.length; ++i) { Target memory ta...` to `for (uint128 i = 0; i < cfg.targets.length; ++i) { Target memory ta...` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 198 | SBR | `for (uint256 i = 0; i < cfg.targets.length` to `for (uint128 i = 0; i < cfg.targets.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 201 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 201 | MVIV | `for (uint256 j = 0; j < target.functions.length;` to `for (uint256 j ; j < target.functions.length;` | Equivalent | a local is zero without its initializer |
| 201 | ROR | `for (uint256 j = 0; j < target.functions.length; ++j)` to `for (uint256 j = 0; j != target.functions.length; ++j)` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 201 | SBR | `for (uint256 j = 0; j < target.functions.length` to `for (uint128 j = 0; j < target.functions.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 201 | SBR | `for (uint256 j = 0; j < target.functions.length` to `for (uint128 j = 0; j < target.functions.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 201 | UOR | `0; j < target.functions.length; ++j) {` to `0; j < target.functions.length; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 207 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 207 | MVIV | `for (uint256 i = 0; i < cfg.grants.length; ++i)` to `for (uint256 i ; i < cfg.grants.length; ++i)` | Equivalent | a local is zero without its initializer |
| 207 | ROR | `for (uint256 i = 0; i < cfg.grants.length; ++i) {` to `for (uint256 i = 0; i != cfg.grants.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 207 | SBR | `for (uint256 i = 0; i < cfg.grants.length;` to `for (uint128 i = 0; i < cfg.grants.length;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 207 | SBR | `for (uint256 i = 0; i < cfg.grants.length;` to `for (uint128 i = 0; i < cfg.grants.length;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 219 | CR | `validate(manager, cfg);` to `//validate(manager, cfg);` | Gap | `verify` without its own `validate`: a manager configured outside `install` with an invalid configuration (too few guardians, say) that reads back the same; no test builds one |
| 220 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 220 | MVIV | `for (uint64 role = 0; role < Roles.COUNT; ++role)` to `for (uint64 role ; role < Roles.COUNT; ++role)` | Equivalent | a local is zero without its initializer |
| 220 | ROR | `for (uint64 role = 0; role < Roles.COUNT; ++role) {` to `for (uint64 role = 0; role != Roles.COUNT; ++role) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 220 | SBR | `for (uint64 role = 0; role < Roles.COUNT;` to `for (uint32 role = 0; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 220 | SBR | `for (uint64 role = 0; role < Roles.COUNT;` to `for (uint32 role = 0; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 220 | UOR | `role = 0; role < Roles.COUNT; ++role) {` to `role = 0; role < Roles.COUNT; role++) {` | Equivalent | pre- or post-increment of a loop counter |
| 228 | CR | `_verifyTarget(manager, address(manager` to `//_verifyTarget(manager, address(manager` | Gap | the manager's own target check in `verify`: no test closes the manager or changes its own admin delay before a readback |
| 229 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 229 | MVIV | `for (uint256 i = 0; i < cfg.targets.length; ++i)` to `for (uint256 i ; i < cfg.targets.length; ++i)` | Equivalent | a local is zero without its initializer |
| 229 | ROR | `for (uint256 i = 0; i < cfg.targets.length; ++i) {` to `for (uint256 i = 0; i != cfg.targets.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 229 | SBR | `for (uint256 i = 0; i < cfg.targets.length; ++i) { Target memory ta...` to `for (uint128 i = 0; i < cfg.targets.length; ++i) { Target memory ta...` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 229 | SBR | `for (uint256 i = 0; i < cfg.targets.length` to `for (uint128 i = 0; i < cfg.targets.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 229 | UOR | `i = 0; i < cfg.targets.length; ++i) {` to `i = 0; i < cfg.targets.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 232 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 232 | MVIV | `for (uint256 j = 0; j < target.functions.length;` to `for (uint256 j ; j < target.functions.length;` | Equivalent | a local is zero without its initializer |
| 232 | ROR | `for (uint256 j = 0; j < target.functions.length; ++j)` to `for (uint256 j = 0; j != target.functions.length; ++j)` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 232 | SBR | `for (uint256 j = 0; j < target.functions.length` to `for (uint128 j = 0; j < target.functions.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 232 | SBR | `for (uint256 j = 0; j < target.functions.length` to `for (uint128 j = 0; j < target.functions.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 232 | UOR | `0; j < target.functions.length; ++j) {` to `0; j < target.functions.length; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 240 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 240 | MVIV | `for (uint256 i = 0; i < cfg.grants.length; ++i)` to `for (uint256 i ; i < cfg.grants.length; ++i)` | Equivalent | a local is zero without its initializer |
| 240 | ROR | `for (uint256 i = 0; i < cfg.grants.length; ++i) {` to `for (uint256 i = 0; i != cfg.grants.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 240 | SBR | `for (uint64 role = 0; role < Roles.COUNT;` to `for (uint32 role = 0; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 240 | SBR | `for (uint256 i = 0; i < cfg.grants.length;` to `for (uint128 i = 0; i < cfg.grants.length;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 240 | SBR | `for (uint256 i = 0; i < cfg.grants.length;` to `for (uint128 i = 0; i < cfg.grants.length;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 244 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 244 | MVIV | `for (uint64 role = 0; role < Roles.COUNT; ++role)` to `for (uint64 role ; role < Roles.COUNT; ++role)` | Equivalent | a local is zero without its initializer |
| 244 | ROR | `for (uint64 role = 0; role < Roles.COUNT; ++role) {` to `for (uint64 role = 0; role <= Roles.COUNT; ++role) {` | Equivalent | `!=` stops where `<` does, and `<=` adds role 13, which no account can hold a record for |
| 244 | ROR | `for (uint64 role = 0; role < Roles.COUNT; ++role) {` to `for (uint64 role = 0; role != Roles.COUNT; ++role) {` | Equivalent | `!=` stops where `<` does, and `<=` adds role 13, which no account can hold a record for |
| 244 | SBR | `for (uint64 role = 0; role < Roles.COUNT;` to `for (uint32 role = 0; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 244 | SBR | `for (uint64 role = 0; role < Roles.COUNT;` to `for (uint32 role = 0; role < Roles.COUNT;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 270 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 270 | MVIV | `for (uint256 i = 0; i < cfg.targets.length; ++i)` to `for (uint256 i ; i < cfg.targets.length; ++i)` | Equivalent | a local is zero without its initializer |
| 270 | ROR | `for (uint256 i = 0; i < cfg.targets.length; ++i) {` to `for (uint256 i = 0; i != cfg.targets.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 270 | SBR | `for (uint256 i = 0; i < cfg.targets.length` to `for (uint128 i = 0; i < cfg.targets.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 270 | SBR | `for (uint256 i = 0; i < cfg.targets.length` to `for (uint128 i = 0; i < cfg.targets.length` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 270 | UOR | `i = 0; i < cfg.targets.length; ++i) {` to `i = 0; i < cfg.targets.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 273 | CR | `return false;` to `//return false;` | Equivalent | the function's default return value is already false |
| 277 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 277 | MVIV | `uint256 guardians = 0;` to `uint256 guardians ;` | Equivalent | a local is zero without its initializer |
| 277 | SBR | `uint256 guardians = 0;` to `uint128 guardians = 0;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 278 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 278 | MVIV | `uint256 seen = 0; // one bit per role with at least` to `uint256 seen ; // one bit per role with at least` | Equivalent | a local is zero without its initializer |
| 279 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 279 | MVIV | `for (uint256 i = 0; i < grants.length; ++i) {` to `for (uint256 i ; i < grants.length; ++i) {` | Equivalent | a local is zero without its initializer |
| 279 | ROR | `for (uint256 i = 0; i < grants.length; ++i) {` to `for (uint256 i = 0; i != grants.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 279 | SBR | `for (uint256 i = 0; i < grants.length; ++i) { Grant memory grant = ...` to `for (uint128 i = 0; i < grants.length; ++i) { Grant memory grant = ...` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 279 | SBR | `for (uint256 i = 0; i < grants.length; ++i` to `for (uint128 i = 0; i < grants.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 279 | UOR | `uint256 i = 0; i < grants.length; ++i) {` to `uint256 i = 0; i < grants.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 281 | CR | `Roles.requireKnown(grant.role)` to `//Roles.requireKnown(grant.role)` | Equivalent | `install` and `verify` both reach `Roles.executionDelay` for every grant, which refuses an unknown role with the same `UnknownRole` |
| 283 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 283 | MVIV | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j ; j < i; ++j) {` | Equivalent | a local is zero without its initializer |
| 283 | ROR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j = 0; j != i; ++j) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 283 | SBR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint128 j = 0; j < i; ++j) {` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 283 | SBR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint128 j = 0; j < i; ++j) {` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 283 | UOR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j = 0; j < i; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 288 | UOR | `grant.role == Roles.GUARDIAN) ++guardians;` to `grant.role == Roles.GUARDIAN) guardians++;` | Equivalent | pre- or post-increment of a loop counter |
| 289 | SBR | `seen \|= uint256(1) << grant.role;` to `seen \|= uint128(1) << grant.role;` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 292 | BOR | `if (seen & (uint256(1) << Roles.ADMIN) == 0) revert MissingHolder(R...` to `if (seen & (uint256(1) \| Roles.ADMIN) == 0) revert MissingHolder(Ro...` | Equivalent | `ADMIN` is 0, so `1 | 0`, `1 >> 0` and `1 ^ 0` are all `1 << 0` |
| 292 | BOR | `if (seen & (uint256(1) << Roles.ADMIN) == 0) revert MissingHolder(R...` to `if (seen & (uint256(1) >> Roles.ADMIN) == 0) revert MissingHolder(R...` | Equivalent | `ADMIN` is 0, so `1 | 0`, `1 >> 0` and `1 ^ 0` are all `1 << 0` |
| 292 | BOR | `if (seen & (uint256(1) << Roles.ADMIN) == 0) revert MissingHolder(R...` to `if (seen & (uint256(1) ^ Roles.ADMIN) == 0) revert MissingHolder(Ro...` | Equivalent | `ADMIN` is 0, so `1 | 0`, `1 >> 0` and `1 ^ 0` are all `1 << 0` |
| 292 | ROR | `& (uint256(1) << Roles.ADMIN) == 0) revert MissingHolder(Roles.ADMIN` to `& (uint256(1) << Roles.ADMIN) <= 0) revert MissingHolder(Roles.ADMIN` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 292 | SBR | `if (seen & (uint256(1) << Roles.ADMIN) == 0) revert` to `if (seen & (uint128(1) << Roles.ADMIN) == 0) revert` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 293 | ROR | `& (uint256(1) << Roles.PAUSER) == 0) revert MissingHolder(Roles.PAUSER` to `& (uint256(1) << Roles.PAUSER) <= 0) revert MissingHolder(Roles.PAUSER` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 293 | SBR | `if (seen & (uint256(1) << Roles.PAUSER) == 0) revert` to `if (seen & (uint128(1) << Roles.PAUSER) == 0) revert` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 294 | ROR | `uint256(1) << Roles.UNPAUSER) == 0) revert MissingHolder(Roles.UNPA...` to `uint256(1) << Roles.UNPAUSER) <= 0) revert MissingHolder(Roles.UNPA...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 294 | SBR | `if (seen & (uint256(1) << Roles.UNPAUSER) == 0) revert` to `if (seen & (uint128(1) << Roles.UNPAUSER) == 0) revert` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 309 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 309 | MVIV | `for (uint256 i = 0; i < functions.length; ++i) {` to `for (uint256 i ; i < functions.length; ++i) {` | Equivalent | a local is zero without its initializer |
| 309 | ROR | `for (uint256 i = 0; i < functions.length; ++i) {` to `for (uint256 i = 0; i != functions.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 309 | SBR | `for (uint256 i = 0; i < functions.length; ++i) { FunctionRole memor...` to `for (uint128 i = 0; i < functions.length; ++i) { FunctionRole memor...` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 309 | SBR | `for (uint256 i = 0; i < functions.length; ++i` to `for (uint128 i = 0; i < functions.length; ++i` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 309 | UOR | `uint256 i = 0; i < functions.length; ++i) {` to `uint256 i = 0; i < functions.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 315 | LIR | `` to `` | Equivalent | the literal replaced by itself (the mutant is the source unchanged) |
| 315 | MVIV | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j ; j < i; ++j) {` | Equivalent | a local is zero without its initializer |
| 315 | ROR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j = 0; j != i; ++j) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 315 | SBR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint128 j = 0; j < i; ++j) {` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 315 | SBR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint128 j = 0; j < i; ++j) {` | Equivalent | a narrower type that still holds every value: at most a few dozen targets, grants and selectors, and role IDs below 13 |
| 315 | UOR | `for (uint256 j = 0; j < i; ++j) {` to `for (uint256 j = 0; j < i; j++) {` | Equivalent | pre- or post-increment of a loop counter |
| 325 | ROR | `\|\| manager.getTargetAdminDelay(target) != TARGET_ADMIN_DELAY` to `\|\| manager.isTargetClosed(target) \|\| manager.getTargetAdminDelay(ta...` | Gap | a target whose admin delay moved either way since installation: no readback test changes one |
| 325 | ROR | `\|\| manager.getTargetAdminDelay(target) != TARGET_ADMIN_DELAY` to `\|\| manager.isTargetClosed(target) \|\| manager.getTargetAdminDelay(ta...` | Gap | a target whose admin delay moved either way since installation: no readback test changes one |
| 336 | ROR | `!active \|\| since == 0 \|\| delay != expected \|\| current` to `!active \|\| !active \|\| since < 0 \|\| delay != expected \|\| current != ...` | Equivalent | a holder with no record is not active, so `!active` already refuses it; `<= 0` is the unsigned zero test |
| 336 | ROR | `!active \|\| since == 0 \|\| delay != expected \|\| current != expected \|...` to `!active \|\| !active \|\| since <= 0 \|\| delay != expected \|\| current !=...` | Equivalent | a holder with no record is not active, so `!active` already refuses it; `<= 0` is the unsigned zero test |

</details>

### `src/governance/Roles.sol`

22 survivors: 22 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 15 | SBR | `uint32 internal constant IMMEDIATE =` to `uint16 internal constant IMMEDIATE =` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 27 | SBR | `uint64 internal constant ADMIN = 0;` to `uint32 internal constant ADMIN = 0;` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 32 | SBR | `uint64 internal constant GUARDIAN = 1` to `uint32 internal constant GUARDIAN = 1` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 34 | SBR | `uint64 internal constant PAUSER = 2;` to `uint32 internal constant PAUSER = 2;` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 36 | SBR | `uint64 internal constant UNPAUSER = 3` to `uint32 internal constant UNPAUSER = 3` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 39 | SBR | `uint64 internal constant CURATION_SIGNER` to `uint32 internal constant CURATION_SIGNER` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 41 | SBR | `uint64 internal constant STORAGE_OPERATOR` to `uint32 internal constant STORAGE_OPERATOR` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 43 | SBR | `uint64 internal constant MINTER = 6;` to `uint32 internal constant MINTER = 6;` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 45 | SBR | `uint64 internal constant KEEPER = 7;` to `uint32 internal constant KEEPER = 7;` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 48 | SBR | `uint64 internal constant PLATFORM = 8` to `uint32 internal constant PLATFORM = 8` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 50 | SBR | `uint64 internal constant PARAMETER_SETTER` to `uint32 internal constant PARAMETER_SETTER` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 52 | SBR | `uint64 internal constant FUNDS_SETTER` to `uint32 internal constant FUNDS_SETTER` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 54 | SBR | `uint64 internal constant SUCCESSOR_SETTER` to `uint32 internal constant SUCCESSOR_SETTER` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 57 | SBR | `uint64 internal constant CURATOR = 12` to `uint32 internal constant CURATOR = 12` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 59 | SBR | `uint64 internal constant COUNT = 13;` to `uint32 internal constant COUNT = 13;` | Equivalent | the same constant in a narrower type that still holds it (constants are inlined) |
| 74 | ROR | `if (role == ADMIN \|\| role == SUCCESSOR_SETTER` to `if (role <= ADMIN \|\| role == SUCCESSOR_SETTER` | Equivalent | `ADMIN` is zero, so `<= ADMIN` is `== ADMIN` |
| 77 | CR | `return IMMEDIATE;` to `//return IMMEDIATE;` | Equivalent | `IMMEDIATE` is zero, the function's default return value |
| 85 | ROR | `role == ADMIN \|\| role == GUARDIAN \|\|` to `role <= ADMIN \|\| role == GUARDIAN \|\|` | Equivalent | the role is below `COUNT` (13), so each order test admits only roles the same condition already lists: `<= ADMIN` is 0, `<= GUARDIAN` adds 0, `>= SUCCESSOR_SETTER` adds `CURATOR` (12), `>= CURATOR` is 12 |
| 85 | ROR | `role == ADMIN \|\| role == GUARDIAN \|\| role == CURATION_SIGNER` to `role == ADMIN \|\| role <= GUARDIAN \|\| role == CURATION_SIGNER` | Equivalent | the role is below `COUNT` (13), so each order test admits only roles the same condition already lists: `<= ADMIN` is 0, `<= GUARDIAN` adds 0, `>= SUCCESSOR_SETTER` adds `CURATOR` (12), `>= CURATOR` is 12 |
| 85 | ROR | `\|\| role == SUCCESSOR_SETTER \|\| role == CURATOR` to `\|\| role >= SUCCESSOR_SETTER \|\| role == CURATOR` | Equivalent | the role is below `COUNT` (13), so each order test admits only roles the same condition already lists: `<= ADMIN` is 0, `<= GUARDIAN` adds 0, `>= SUCCESSOR_SETTER` adds `CURATOR` (12), `>= CURATOR` is 12 |
| 85 | ROR | `role == SUCCESSOR_SETTER \|\| role == CURATOR` to `role == SUCCESSOR_SETTER \|\| role >= CURATOR` | Equivalent | the role is below `COUNT` (13), so each order test admits only roles the same condition already lists: `<= ADMIN` is 0, `<= GUARDIAN` adds 0, `>= SUCCESSOR_SETTER` adds `CURATOR` (12), `>= CURATOR` is 12 |
| 88 | ROR | `if (role == FUNDS_SETTER) return FUNDS;` to `if (role >= FUNDS_SETTER) return FUNDS;` | Equivalent | `SUCCESSOR_SETTER` and `CURATOR`, the only roles above `FUNDS_SETTER`, returned on the line before |

</details>

### `src/governance/WorksAccessManager.sol`

3 survivors: 2 defensive, 1 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 56 | ROR | `if (since == 0 \|\| _suspended[roleId][account]` to `if (since <= 0 \|\| _suspended[roleId][account]` | Equivalent | unsigned: `== 0` and `<= 0` are the same test |
| 104 | ROR | `address(this) && data.length >= 4` to `address(this) && data.length > 4` | Defensive | a `revokeRole` call of exactly four bytes cannot be scheduled (the manager decodes its role first), so no one cancels one |
| 104 | ROR | `== address(this) && data.length >= 4` to `== address(this) && data.length != 4` | Defensive | a `revokeRole` call of exactly four bytes cannot be scheduled (the manager decodes its role first), so no one cancels one |

</details>

### `src/identity/ArtistRegistry.sol`

69 survivors: 16 open gaps, 4 defensive, 2 gas margin, 47 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 117 | CONST | `private constant BIND_READ_GAS = 50_000;` to `private constant BIND_READ_GAS = 50001;` | Gas margin | the bounded read needs far less than 50,000 gas, so one unit either way changes nothing |
| 117 | CONST | `private constant BIND_READ_GAS = 50_000;` to `private constant BIND_READ_GAS = 49999;` | Gas margin | the bounded read needs far less than 50,000 gas, so one unit either way changes nothing |
| 201 | CR | `_checkBinding(target, bytes4(0` to `//_checkBinding(target, bytes4(0` | Gap | a delegated (EIP-7702) statement-log account whose delegate names this registry: only the binding check refuses it, and no test builds one |
| 205 | ROR | `if (!ok \|\| resolver.length != 32 \|\| abi.decode(resolver, (address` to `if (!ok \|\| resolver.length < 32 \|\| abi.decode(resolver, (address` | Equivalent | the read is capped at 32 bytes, so `< 32` is `!= 32` |
| 205 | ROR | `if (!ok \|\| resolver.length != 32 \|\| abi.decode(resolver, (address` to `if (!ok \|\| resolver.length > 32 \|\| abi.decode(resolver, (address` | Gap | `< 32` is equivalent (the read is capped at 32 bytes); `> 32` lets a shorter answer through to a decode that reverts with another error |
| 235 | ROR | `if (artistIdOf[account] != 0 \|\| reservedFor[account] != 0` to `if (artistIdOf[account] > 0 \|\| reservedFor[account] != 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 235 | ROR | `artistIdOf[account] != 0 \|\| reservedFor[account] != 0) revert Accou...` to `artistIdOf[account] != 0 \|\| reservedFor[account] > 0) revert Accoun...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 258 | ROR | `if (_pending[artistId].kind != ChangeKind.NONE) revert ChangePendin...` to `if (_pending[artistId].kind > ChangeKind.NONE) revert ChangePending...` | Equivalent | `NONE` is the enum's first value, so the order test is the equality test |
| 287 | ROR | `ChangeKind.CONTESTED \|\| evidenceHash == bytes32(0)) revert InvalidI...` to `ChangeKind.CONTESTED \|\| evidenceHash <= bytes32(0)) revert InvalidI...` | Equivalent | `bytes32` compares as unsigned: `== 0` and `<= 0` are the same test |
| 291 | ROR | `if (kind != ChangeKind.CONTESTED && block.timestamp` to `if (kind > ChangeKind.CONTESTED && block.timestamp` | Equivalent | only CONTESTED, ESTATE and LOST_KEY reach this line (line 287 refuses the rest), so `>` is `!=` |
| 307 | ROR | `if (pending != ChangeKind.NONE) _clear(artistId,` to `if (pending > ChangeKind.NONE) _clear(artistId,` | Equivalent | `NONE` is the enum's first value, so the order test is the equality test |
| 317 | ROR | `bool allowed = p.kind == ChangeKind.STANDARD && msg.sender` to `bool allowed = p.kind <= ChangeKind.STANDARD && msg.sender` | Equivalent | a pending change is never `NONE` here, so `<= STANDARD` is `== STANDARD` |
| 319 | ROR | `for (uint256 i; !allowed && i < cancellers.length; ++i) {` to `for (uint256 i; !allowed && i != cancellers.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 319 | UOR | `!allowed && i < cancellers.length; ++i) {` to `!allowed && i < cancellers.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 323 | ROR | `if (p.contestedAt != 0) return;` to `if (p.contestedAt > 0) return;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 324 | ROR | `if (p.kind == ChangeKind.STANDARD) {` to `if (p.kind <= ChangeKind.STANDARD) {` | Equivalent | a pending change is never `NONE` here, so `<= STANDARD` is `== STANDARD` |
| 346 | ROR | `if (p.contestedAt == 0 \|\| _lapsed(p)) revert NotContested(artistId` to `if (p.contestedAt <= 0 \|\| _lapsed(p)) revert NotContested(artistId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 347 | ROR | `if (outcomeRef == bytes32(0) \|\| outcomeRef != _latestOutcome(artistId` to `if (outcomeRef <= bytes32(0) \|\| outcomeRef != _latestOutcome(artistId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 347 | ROR | `outcomeRef == bytes32(0) \|\| outcomeRef != _latestOutcome(artistId)) {` to `outcomeRef == bytes32(0) \|\| outcomeRef > _latestOutcome(artistId)) {` | Gap | `<= 0` is equivalent; `>` accepts an outcome reference that sorts below the latest one |
| 350 | ROR | `if (outcomeRef == p.priorOutcome) revert OutcomePredatesContest(art...` to `if (outcomeRef <= p.priorOutcome) revert OutcomePredatesContest(art...` | Gap | an outcome reference that sorts below the one recorded before the contest is refused as if it were that one |
| 363 | ROR | `if (p.contestedAt == 0) revert NotContested(artistId` to `if (p.contestedAt <= 0) revert NotContested(artistId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 384 | ROR | `if (p.contestedAt != 0) revert OverrideContested(artistId` to `if (p.contestedAt > 0) revert OverrideContested(artistId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 441 | ROR | `if (_federated[artistId].length >= MAX_FEDERATED) revert FederatedL...` to `if (_federated[artistId].length == MAX_FEDERATED) revert FederatedL...` | Equivalent | the list never grows past its maximum, so `==` is `>=` |
| 461 | CR | `\|\| contentHash == bytes32(0)) return false;` to `\|\| contentHash == bytes32(0)) //return false;` | Gap | an Editions answer naming another master contract or a zero content hash: the mutant goes on to the work with the edition's ID instead of answering false |
| 461 | LOR | `if (master != s \|\| contentHash == bytes32(0)) return` to `if (master != s && contentHash == bytes32(0)) return` | Defensive | the Stream's own Editions contract answers every master with this Stream and a nonzero content hash; only a lying Editions mock reaches it |
| 461 | MIA | `if (master != s \|\| contentHash == bytes32(0)) return false;` to `if (false) return false;` | Defensive | the Stream's own Editions contract answers every master with this Stream and a nonzero content hash; only a lying Editions mock reaches it |
| 461 | ROR | `if (master != s \|\| contentHash == bytes32(0)) return false;` to `if (master != s \|\| contentHash <= bytes32(0)) return false;` | Equivalent | `bytes32` compares as unsigned: `== 0` and `<= 0` are the same test |
| 462 | CR | `id = workId;` to `//id = workId;` | Equivalent | an edition's ID is its master's token ID (Stream links them only so), so `id` already is `workId` |
| 464 | CR | `return false;` to `//return false;` | Gap | an edition Editions does not know whose number is a minted Stream work: the mutant answers for that work instead of false |
| 470 | CR | `return false;` to `//return false;` | Equivalent | the function returns false by default when the catch block falls through |
| 479 | ROR | `bool moves = p.kind != ChangeKind.NONE && p.next.payout` to `bool moves = p.kind > ChangeKind.NONE && p.next.payout` | Equivalent | `NONE` is the enum's first value, so the order test is the equality test |
| 589 | ROR | `if (p.kind == ChangeKind.NONE) revert NoPendingChange(artistId` to `if (p.kind <= ChangeKind.NONE) revert NoPendingChange(artistId` | Equivalent | `NONE` is the enum's first value, so the order test is the equality test |
| 613 | ROR | `return artistIdOf[account] != 0 \|\| (reserved != 0 && reserved` to `return artistIdOf[account] > 0 \|\| (reserved != 0 && reserved` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 613 | ROR | `artistIdOf[account] != 0 \|\| (reserved != 0 && reserved != artistId);` to `artistIdOf[account] != 0 \|\| (reserved > 0 && reserved != artistId);` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 613 | ROR | `\|\| (reserved != 0 && reserved != artistId);` to `\|\| (reserved != 0 && reserved > artistId);` | Gap | the `> 0` mutants are equivalent; `reserved > artistId` lets an account reserved for a lower artist ID count as free |
| 632 | ROR | `if (address(source).codehash != consolidationSourceCodeHash)` to `if (address(source).codehash < consolidationSourceCodeHash)` | Gap | a dependency whose code hash moved in the other direction (the consolidation source) |
| 640 | ROR | `target.codehash != codeHash \|\| DelegatedEOA.isDelegated(target` to `target.codehash > codeHash \|\| DelegatedEOA.isDelegated(target` | Gap | a dependency whose code hash moved in the other direction (an installed dependency) |
| 648 | ROR | `target.code.length == 0 \|\| DelegatedEOA.isDelegated(target` to `target.code.length <= 0 \|\| DelegatedEOA.isDelegated(target` | Equivalent | `!= 0` and `> 0` (and `== 0` and `<= 0`) are the same unsigned tests |
| 648 | ROR | `\|\| (interfaceId != 0 && !ERC165Checker.supportsInterface(target,` to `\|\| (interfaceId > 0 && !ERC165Checker.supportsInterface(target,` | Equivalent | `!= 0` and `> 0` (and `== 0` and `<= 0`) are the same unsigned tests |
| 675 | ROR | `for (uint256 i; i < snapshot.length; ++i) {` to `for (uint256 i; i != snapshot.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 675 | UOR | `uint256 i; i < snapshot.length; ++i) {` to `uint256 i; i < snapshot.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 691 | ROR | `a.restrained = kind > ChangeKind.STANDARD && next.authority` to `a.restrained = kind != ChangeKind.STANDARD && next.authority` | Equivalent | a staged change is never `NONE`, so `!= STANDARD` is `> STANDARD` |
| 731 | ROR | `Limits.MAX_CANCELLERS \|\| times.length != live.length) {` to `Limits.MAX_CANCELLERS \|\| times.length < live.length) {` | Defensive | the consolidation adapter always answers two arrays of the same length |
| 731 | ROR | `Limits.MAX_CANCELLERS \|\| times.length != live.length) {` to `Limits.MAX_CANCELLERS \|\| times.length > live.length) {` | Defensive | the consolidation adapter always answers two arrays of the same length |
| 735 | ROR | `for (uint256 i = s.length; i > 0; --i) {` to `for (uint256 i = s.length; i != 0; --i) {` | Equivalent | a counter that steps down by one from the length: `> 0` and `!= 0` stop at the same point |
| 735 | UOR | `(uint256 i = s.length; i > 0; --i) {` to `(uint256 i = s.length; i > 0; i--) {` | Equivalent | pre- or post-increment of a loop counter |
| 739 | ROR | `if (since == 0) {` to `if (since <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 746 | ROR | `if (since != 0) {` to `if (since > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 750 | ROR | `if (since < e.effectiveAt \|\| e.effectiveAt` to `if (since <= e.effectiveAt \|\| e.effectiveAt` | Gap | the boundaries of a standing refresh: a wallet effective exactly now, or established at exactly its recorded time |
| 750 | ROR | `e.effectiveAt \|\| e.effectiveAt > block.timestamp) {` to `e.effectiveAt \|\| e.effectiveAt >= block.timestamp) {` | Gap | the boundaries of a standing refresh: a wallet effective exactly now, or established at exactly its recorded time |
| 754 | ROR | `if (e.missingSince != 0) {` to `if (e.missingSince > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 759 | ROR | `} else if (e.missingSince == 0 && e.effectiveAt <= block.timestamp` to `} else if (e.missingSince <= 0 && e.effectiveAt <= block.timestamp` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 773 | ROR | `for (uint256 pass; pass < 2; ++pass) {` to `for (uint256 pass; pass != 2; ++pass) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 773 | UOR | `for (uint256 pass; pass < 2; ++pass) {` to `for (uint256 pass; pass < 2; pass++) {` | Equivalent | pre- or post-increment of a loop counter |
| 774 | ROR | `for (uint256 i; i < live.length && s.length < Limits.MAX_CANCELLERS` to `for (uint256 i; i != live.length && s.length < Limits.MAX_CANCELLERS` | Equivalent | `!=` stops at the same point as `<`: the counter steps by one and the list never passes its maximum |
| 774 | ROR | `i; i < live.length && s.length < Limits.MAX_CANCELLERS; ++i) {` to `i; i < live.length && s.length != Limits.MAX_CANCELLERS; ++i) {` | Equivalent | `!=` stops at the same point as `<`: the counter steps by one and the list never passes its maximum |
| 777 | ROR | `if ((times[i] <= block.timestamp) != (pass ==` to `if ((times[i] == block.timestamp) != (pass ==` | Gap | `pass <= 0` is equivalent; `times[i] == now` treats a wallet established earlier as not yet established |
| 777 | ROR | `times[i] <= block.timestamp) != (pass == 0) \|\| _recorded(s, live[i]))` to `times[i] <= block.timestamp) != (pass <= 0) \|\| _recorded(s, live[i]))` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 791 | ROR | `!bestEffort \|\| reason.length != 36` to `!bestEffort \|\| reason.length < 36` | Gap | a revert reason longer than 36 bytes read as the 36-byte form |
| 791 | ROR | `!bestEffort \|\| reason.length != 36` to `!bestEffort \|\| reason.length > 36` | Gap | a revert reason longer than 36 bytes read as the 36-byte form |
| 791 | ROR | `\|\| bytes4(reason) != IConsolidationSource.DelegationReadFailed.sele...` to `\|\| bytes4(reason) < IConsolidationSource.DelegationReadFailed.selector` | Gap | a revert reason longer than 36 bytes read as the 36-byte form |
| 791 | ROR | `\|\| bytes4(reason) != IConsolidationSource.DelegationReadFailed.sele...` to `\|\| bytes4(reason) > IConsolidationSource.DelegationReadFailed.selector` | Gap | a revert reason longer than 36 bytes read as the 36-byte form |
| 807 | ROR | `for (uint256 i; i < list.length; ++i) {` to `for (uint256 i; i != list.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 807 | UOR | `for (uint256 i; i < list.length; ++i) {` to `for (uint256 i; i < list.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 810 | CR | `return 0;` to `//return 0;` | Equivalent | the function's default return value is already zero |
| 814 | ROR | `for (uint256 i; i < s.length; ++i) {` to `for (uint256 i; i != s.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 814 | UOR | `for (uint256 i; i < s.length; ++i) {` to `for (uint256 i; i < s.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 817 | CR | `return false;` to `//return false;` | Equivalent | the function's default return value is already false |
| 841 | ROR | `return contestedAt != 0 && block.timestamp >= uint256(contestedAt` to `return contestedAt > 0 && block.timestamp >= uint256(contestedAt` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/identity/ConsolidationAdapter.sol`

32 survivors: 2 defensive, 30 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 64 | SBR | `address public constant ALL_COLLECTIONS = 0x88888888888888888888888...` to `address public immutable ALL_COLLECTIONS = 0x8888888888888888888888...` | Equivalent | `constant` to `immutable` with the same value |
| 66 | SBR | `uint256 public constant USE_CASE_CONSOLIDATION = 999;` to `uint256 public immutable USE_CASE_CONSOLIDATION = 999;` | Equivalent | `constant` to `immutable` with the same value |
| 68 | SBR | `uint256 public constant MIN_AGE = 30 days;` to `uint256 public immutable MIN_AGE = 30 days;` | Equivalent | the same value as `immutable` or a narrower type |
| 68 | SBR | `uint256 public constant MIN_AGE = 30 days` to `uint128 public constant MIN_AGE = 30 days` | Equivalent | the same value as `immutable` or a narrower type |
| 70 | SBR | `uint256 public constant MAX_DELEGATES_SCANNED = 2 * Limits.MAX_CANC...` to `uint256 public immutable MAX_DELEGATES_SCANNED = 2 * Limits.MAX_CAN...` | Equivalent | `constant` to `immutable` with the same value |
| 72 | SBR | `uint256 public constant MAX_REGISTRATIONS_READ = 4;` to `uint256 public immutable MAX_REGISTRATIONS_READ = 4;` | Equivalent | the same value as `immutable` or a narrower type |
| 72 | SBR | `uint256 public constant MAX_REGISTRATIONS_READ` to `uint128 public constant MAX_REGISTRATIONS_READ` | Equivalent | the same value as `immutable` or a narrower type |
| 74 | SBR | `uint256 public constant READ_GAS = 200_000` to `uint128 public constant READ_GAS = 200_000` | Equivalent | the value fits the narrower type |
| 84 | ROR | `address(delegation_).code.length == 0) revert NoDelegationCode(addr...` to `address(delegation_).code.length <= 0) revert NoDelegationCode(addr...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 125 | ROR | `if (forward == 0) return 0;` to `if (forward <= 0) return 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 127 | ROR | `if (reverse == 0) return 0;` to `if (reverse <= 0) return 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 143 | SBR | `uint256 found;` to `uint128 found;` | Equivalent | the count never reaches 2**128 |
| 145 | SBR | `for (uint256 i; i < MAX_DELEGATES_SCANNED &&` to `for (uint128 i; i < MAX_DELEGATES_SCANNED &&` | Equivalent | the counter never reaches 2**128 |
| 145 | SBR | `for (uint256 i; i < MAX_DELEGATES_SCANNED &&` to `for (uint128 i; i < MAX_DELEGATES_SCANNED &&` | Equivalent | the counter never reaches 2**128 |
| 145 | UOR | `MAX_DELEGATES_SCANNED && found < limit; ++i) {` to `MAX_DELEGATES_SCANNED && found < limit; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 153 | ROR | `if (due == 0 \|\| (establishedOnly && due > block.timestamp` to `if (due <= 0 \|\| (establishedOnly && due > block.timestamp) \|\| (esta...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 166 | ROR | `for (uint256 i; i < MAX_REGISTRATIONS_READ; ++i)` to `for (uint256 i; i != MAX_REGISTRATIONS_READ; ++i)` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 166 | SBR | `for (uint256 i; i < MAX_REGISTRATIONS_READ; ++i) { (bool ok, bytes ...` to `for (uint128 i; i < MAX_REGISTRATIONS_READ; ++i) { (bool ok, bytes ...` | Equivalent | the counter never reaches 2**128 |
| 166 | SBR | `for (uint256 i; i < MAX_REGISTRATIONS_READ` to `for (uint128 i; i < MAX_REGISTRATIONS_READ` | Equivalent | the counter never reaches 2**128 |
| 166 | UOR | `i; i < MAX_REGISTRATIONS_READ; ++i) {` to `i; i < MAX_REGISTRATIONS_READ; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 174 | ROR | `if (expiry > block.timestamp && registered != 0 && registered <= bl...` to `if (expiry > block.timestamp && expiry > block.timestamp && registe...` | Defensive | `> 0` is equivalent; `>= 0` returns a zero registration date at once instead of reading on, and the delegation contract never stores a zero date (it records `block.timestamp`) |
| 174 | ROR | `if (expiry > block.timestamp && registered != 0 && registered <= bl...` to `if (expiry > block.timestamp && expiry > block.timestamp && registe...` | Defensive | `> 0` is equivalent; `>= 0` returns a zero registration date at once instead of reading on, and the delegation contract never stores a zero date (it records `block.timestamp`) |
| 178 | CR | `return 0;` to `//return 0;` | Equivalent | the function returns zero by default when the last statement is gone |
| 192 | ROR | `if (target.code.length == 0) revert DelegationReadFailed(target` to `if (target.code.length <= 0) revert DelegationReadFailed(target` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 197 | SBR | `uint256 size;` to `uint128 size;` | Equivalent | return data never reaches 2**128 bytes |
| 205 | MIA | `if (!found) return (false, result);` to `if (false) return (false, result);` | Equivalent | an index past the end returns no data, so going on returns the same empty result |
| 217 | ROR | `for (uint256 i; i < length; ++i) {` to `for (uint256 i; i <= length; ++i) {` | Equivalent | `!=` stops at the same point; `<=` also reads index `length`, which is in bounds and still the zero address, which never consolidates |
| 217 | ROR | `for (uint256 i; i < length; ++i) {` to `for (uint256 i; i != length; ++i) {` | Equivalent | `!=` stops at the same point; `<=` also reads index `length`, which is in bounds and still the zero address, which never consolidates |
| 217 | SBR | `for (uint256 i; i < length; ++i) {` to `for (uint128 i; i < length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 217 | SBR | `for (uint256 i; i < length; ++i) {` to `for (uint128 i; i < length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 217 | UOR | `for (uint256 i; i < length; ++i) {` to `for (uint256 i; i < length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 220 | CR | `return false;` to `//return false;` | Equivalent | the function returns false by default when the last statement is gone |

</details>

### `src/interfaces/types/Limits.sol`

11 survivors: 11 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 20 | SBR | `uint256 internal constant MAX_PARTIES` to `uint128 internal constant MAX_PARTIES` | Equivalent | the value fits the narrower type |
| 22 | SBR | `uint256 internal constant MAX_MEDIA_FILES` to `uint128 internal constant MAX_MEDIA_FILES` | Equivalent | the value fits the narrower type |
| 24 | SBR | `uint256 internal constant MAX_LICENSE_ID_BYTES` to `uint128 internal constant MAX_LICENSE_ID_BYTES` | Equivalent | the value fits the narrower type |
| 26 | SBR | `uint256 internal constant MAX_LOCATORS_PER_FILE` to `uint128 internal constant MAX_LOCATORS_PER_FILE` | Equivalent | the value fits the narrower type |
| 29 | SBR | `uint256 internal constant MAX_URI_BYTES` to `uint128 internal constant MAX_URI_BYTES` | Equivalent | the value fits the narrower type |
| 31 | SBR | `uint256 internal constant MAX_PHASES =` to `uint128 internal constant MAX_PHASES =` | Equivalent | the value fits the narrower type |
| 33 | SBR | `uint256 internal constant MAX_CANCELLERS` to `uint128 internal constant MAX_CANCELLERS` | Equivalent | the value fits the narrower type |
| 36 | SBR | `uint256 internal constant MAX_RECORD_BYTES` to `uint128 internal constant MAX_RECORD_BYTES` | Equivalent | the value fits the narrower type |
| 38 | SBR | `uint256 internal constant MAX_ARTISTS` to `uint128 internal constant MAX_ARTISTS` | Equivalent | the value fits the narrower type |
| 46 | SBR | `uint256 internal constant MAX_PREVIEW_BYTES` to `uint128 internal constant MAX_PREVIEW_BYTES` | Equivalent | the value fits the narrower type |
| 48 | SBR | `uint256 internal constant MAX_PROOF_DEPTH` to `uint128 internal constant MAX_PROOF_DEPTH` | Equivalent | the value fits the narrower type |

</details>

### `src/interfaces/types/WorksHashing.sol`

4 survivors: 4 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 66 | ROR | `for (uint256 i; i < id.length; ++i) {` to `for (uint256 i; i != id.length; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 66 | SBR | `for (uint256 i; i < id.length; ++i) {` to `for (uint128 i; i < id.length; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 66 | SBR | `for (uint256 i; i < id.length; ++i) {` to `for (uint128 i; i < id.length; ++i) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |
| 66 | UOR | `for (uint256 i; i < id.length; ++i) {` to `for (uint256 i; i < id.length; i++) {` | Equivalent | loop-index form (`!=` for `<`, `i++`, a narrower index) with the same iterations |

</details>

### `src/libraries/BoundedCall.sol`

12 survivors: 2 gas margin, 1 proved, 9 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 13 | CONST | `internal constant CALL_RESERVE = 1_000;` to `internal constant CALL_RESERVE = 1001;` | Gas margin | one gas more or less of call reserve is not observable without an exact-gas harness |
| 13 | CONST | `internal constant CALL_RESERVE = 1_000;` to `internal constant CALL_RESERVE = 999;` | Gas margin | one gas more or less of call reserve is not observable without an exact-gas harness |
| 13 | SBR | `uint256 internal constant CALL_RESERVE` to `uint128 internal constant CALL_RESERVE` | Equivalent | the value fits the narrower type |
| 30 | ROR | `if (available < gasLimit) return false;` to `if (available <= gasLimit) return false;` | Equivalent | differs only for a zero gas limit with zero gas available; every caller passes a nonzero constant limit |
| 33 | MIA | `if (afterLimit < retention) return false;` to `if (false) return false;` | Proved | without it the subtraction underflows and reverts: `check_hasSufficientGas_neverReverts` fails on it (checked with Halmos) |
| 33 | ROR | `if (afterLimit < retention) return false;` to `if (afterLimit <= retention) return false;` | Equivalent | differs only for a zero completion buffer; every caller passes at least `CALL_RESERVE` (1,000) |
| 48 | ROR | `if (target.code.length == 0) return (false, result);` to `if (target.code.length <= 0) return (false, result);` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 53 | SBR | `uint256 size;` to `uint128 size;` | Equivalent | return data never reaches 2**128 bytes |
| 86 | ROR | `if (result.length != 32) revert BoundedCallMalformedReturn(target` to `if (result.length < 32) revert BoundedCallMalformedReturn(target` | Equivalent | `read` with a 32-byte cap never returns more than 32 bytes (proved: `check_tryRead_copiesOnlyWhatFits`) |
| 129 | ROR | `if (padded != length) {` to `if (padded > length) {` | Equivalent | the padded length is never below the length, so `!=` and `>` agree |
| 134 | ROR | `lastWord << ((length % 32) * 8) != 0) return (false, value);` to `lastWord << ((length % 32) * 8) > 0) return (false, value);` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 140 | SBR | `return (length + 31) & ~uint256(31);` to `return (length + 31) & ~uint128(31);` | Equivalent | lengths here are below the data length, far below 2**128 |

</details>

### `src/libraries/DelegatedEOA.sol`

6 survivors: 3 defensive, 3 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 15 | SBR | `uint256 internal constant DESIGNATOR_LENGTH` to `uint128 internal constant DESIGNATOR_LENGTH` | Equivalent | the value fits the narrower type |
| 32 | MIA | `if (account.code.length != DESIGNATOR_LENGTH) return 0;` to `if (false) return 0;` | Defensive | EIP-3541 forbids deployed code starting with 0xEF, so only a 23-byte delegation designator starts with 0xef0100 |
| 32 | ROR | `if (account.code.length != DESIGNATOR_LENGTH) return 0;` to `if (account.code.length < DESIGNATOR_LENGTH) return 0;` | Defensive | EIP-3541 forbids deployed code starting with 0xEF, so only a 23-byte delegation designator starts with 0xef0100 |
| 32 | ROR | `if (account.code.length != DESIGNATOR_LENGTH) return 0;` to `if (account.code.length > DESIGNATOR_LENGTH) return 0;` | Defensive | EIP-3541 forbids deployed code starting with 0xEF, so only a 23-byte delegation designator starts with 0xef0100 |
| 33 | SBR | `// Scratch use of free memory; nothing is allocated and the` to `// Scratch use of free storage; nothing is allocated and the` | Equivalent | the mutant changes a word in a comment |
| 36 | CR | `mstore(scratch, 0)` to `//mstore(scratch, 0)` | Equivalent | both readers shift out the low nine bytes the copy leaves unzeroed |

</details>

### `src/libraries/JsonEscape.sol`

25 survivors: 2 defensive, 23 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 35 | MIA | `if iszero(shr(128, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 36 | CR | `i := 16` to `//i := 16` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 39 | MIA | `if iszero(shr(192, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 40 | CR | `i := add(i, 8)` to `//i := add(i, 8)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 43 | MIA | `if iszero(shr(224, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 44 | CR | `i := add(i, 4)` to `//i := add(i, 4)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 47 | MIA | `if iszero(shr(240, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 48 | CR | `i := add(i, 2)` to `//i := add(i, 2)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 51 | CR | `if iszero(shr(248, m)) { i := add(i,` to `//if iszero(shr(248, m)) { i := add(i,` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 59 | MIA | `if iszero(lt(sub(end, p), 32)) {` to `if false {` | Equivalent | every byte goes through the byte-by-byte path (gas only) |
| 75 | MIA | `if iszero(m) {` to `if false {` | Equivalent | a clean word falls through to the first-flag jump, which also lands past it (gas only) |
| 79 | CR | `p := add(p, firstFlag(m))` to `//p := add(p, firstFlag(m))` | Equivalent | the bytes of a word are checked one by one instead of jumping (gas only) |
| 154 | CR | `mstore(add(out, words), 0) // zero` to `//mstore(add(out, words), 0) // zero` | Defensive | zeroes the output's last-word padding; no reader depends on it (ABI encoding re-pads) |
| 169 | MIA | `if iszero(shr(128, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 170 | CR | `i := 16` to `//i := 16` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 173 | MIA | `if iszero(shr(192, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 174 | CR | `i := add(i, 8)` to `//i := add(i, 8)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 177 | MIA | `if iszero(shr(224, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 178 | CR | `i := add(i, 4)` to `//i := add(i, 4)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 181 | MIA | `if iszero(shr(240, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 182 | CR | `i := add(i, 2)` to `//i := add(i, 2)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 185 | CR | `if iszero(shr(248, m)) { i := add(i,` to `//if iszero(shr(248, m)) { i := add(i,` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads bytes it would have skipped (gas only) |
| 193 | MIA | `if iszero(lt(sub(end, p), 32)) {` to `if true {` | Equivalent | the word test past the end finds the first `<`, which is past the end only when none is left in range |
| 201 | CR | `p := add(p, firstFlag(m))` to `//p := add(p, firstFlag(m))` | Equivalent | the bytes of a word are checked one by one instead of jumping (gas only) |
| 236 | CR | `mstore(add(out, words), 0) // zero` to `//mstore(add(out, words), 0) // zero` | Defensive | zeroes the output's last-word padding; no reader depends on it (ABI encoding re-pads) |

</details>

### `src/libraries/SSTORE2.sol`

6 survivors: 6 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 14 | SBR | `uint256 internal constant MAX_CHUNK_LENGTH` to `uint128 internal constant MAX_CHUNK_LENGTH` | Equivalent | the constant fits 128 bits |
| 35 | ROR | `if (pointer.code.length != 0) return pointer;` to `if (pointer.code.length > 0) return pointer;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 51 | LIR | `uint256 first = 1;` to `uint256 first = 115792089237316195423570985008687907853269984665640...` | Equivalent | any non-zero start value: an empty account still reverts, and the code byte overwrites it otherwise |
| 51 | SBR | `uint256 first = 1;` to `uint128 first = 1;` | Equivalent | any non-zero start value: an empty account still reverts, and the code byte overwrites it otherwise |
| 52 | ROR | `if (codeLength != 0) {` to `if (codeLength > 0) {` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 61 | ROR | `if (first != 0) revert SSTORE2InvalidPointer(pointer` to `if (first > 0) revert SSTORE2InvalidPointer(pointer` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |

</details>

### `src/libraries/SignatureVerifier.sol`

8 survivors: 2 defensive, 2 gas margin, 4 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 25 | SBR | `uint256 internal constant MAX_SIGNATURE_LENGTH` to `uint128 internal constant MAX_SIGNATURE_LENGTH` | Equivalent | the value fits the narrower type |
| 28 | CONST | `constant ERC1271_GAS_LIMIT = 200_000;` to `constant ERC1271_GAS_LIMIT = 200001;` | Gas margin | one gas more or less for ERC-1271 is not observable without an exact-gas harness |
| 28 | CONST | `internal constant ERC1271_GAS_LIMIT = 200_000;` to `internal constant ERC1271_GAS_LIMIT = 199999;` | Gas margin | one gas more or less for ERC-1271 is not observable without an exact-gas harness |
| 28 | SBR | `uint256 internal constant ERC1271_GAS_LIMIT` to `uint128 internal constant ERC1271_GAS_LIMIT` | Equivalent | the value fits the narrower type |
| 39 | ROR | `if (signer.code.length == 0) return isValidECDSA(signer,` to `if (signer.code.length <= 0) return isValidECDSA(signer,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 53 | MIA | `if (signature.length != 64 && signature.length != 65) return false;` to `if (false) return false;` | Defensive | other lengths parse to `v = 0` in OpenZeppelin's `ECDSA.parse`, which line 55 rejects |
| 55 | MIA | `if (v != 27 && v != 28) return false;` to `if (false) return false;` | Defensive | OpenZeppelin's `tryRecover` rejects any other `v` (ecrecover returns zero) |
| 73 | ROR | `if (!ok \|\| result.length != 32) return false;` to `if (!ok \|\| !ok \|\| result.length < 32) return false;` | Equivalent | `tryRead` with a 32-byte cap never returns more than 32 bytes with `ok` (proved: `check_tryRead_copiesOnlyWhatFits`) |

</details>

### `src/libraries/Utf8.sol`

14 survivors: 14 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 30 | ROR | `return ok && state == 0;` to `return ok && state <= 0;` | Equivalent | `== 0` and `<= 0` (or `!= 0` and `> 0`) agree on an unsigned value |
| 40 | SBR | `returns (bool ok, uint256 next)` to `returns (bool ok, uint128 next)` | Equivalent | `pure` to `view`: no behaviour change |
| 45 | MIA | `if iszero(shr(128, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 46 | CR | `i := 16` to `//i := 16` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 49 | MIA | `if iszero(shr(192, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 50 | CR | `i := add(i, 8)` to `//i := add(i, 8)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 53 | MIA | `if iszero(shr(224, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 54 | CR | `i := add(i, 4)` to `//i := add(i, 4)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 57 | MIA | `if iszero(shr(240, m)) {` to `if false {` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 58 | CR | `i := add(i, 2)` to `//i := add(i, 2)` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 61 | CR | `if iszero(shr(248, m)) { i := add(i,` to `//if iszero(shr(248, m)) { i := add(i,` | Equivalent | the first-flag index can only come out smaller, so the scan re-reads ASCII bytes it would have skipped (gas only) |
| 104 | CR | `if gt(byte(1, w), 0x7f) { continue` to `//if gt(byte(1, w), 0x7f) { continue` | Equivalent | the short ASCII run is taken instead of going straight to the next lead byte (gas only) |
| 111 | CR | `if lt(p, short) { continue }` to `//if lt(p, short) { continue }` | Equivalent | the word loop starts at a non-ASCII byte or the end and leaves at once (gas only) |
| 116 | CR | `p := add(p, firstFlag(m))` to `//p := add(p, firstFlag(m))` | Equivalent | the word skip stops at the word's start and the bytes are checked one by one (gas only) |

</details>

### `src/records/StatementLog.sol`

35 survivors: 7 open gaps, 2 gas margin, 26 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 58 | SBR | `uint256 public constant MAX_URI_BYTES = 2_048;` to `uint256 public immutable MAX_URI_BYTES = 2_048;` | Equivalent | the same value as `immutable` or a narrower type |
| 58 | SBR | `uint256 public constant MAX_URI_BYTES` to `uint128 public constant MAX_URI_BYTES` | Equivalent | the same value as `immutable` or a narrower type |
| 61 | CONST | `public constant OWNER_READ_GAS = 50_000;` to `public constant OWNER_READ_GAS = 50001;` | Gas margin | one gas more or less for the owner read is not observable without an exact-gas harness |
| 61 | CONST | `public constant OWNER_READ_GAS = 50_000;` to `public constant OWNER_READ_GAS = 49999;` | Gas margin | one gas more or less for the owner read is not observable without an exact-gas harness |
| 61 | SBR | `uint256 public constant OWNER_READ_GAS = 50_000;` to `uint256 public immutable OWNER_READ_GAS = 50_000;` | Equivalent | the same value as `immutable` or a narrower type |
| 61 | SBR | `uint256 public constant OWNER_READ_GAS` to `uint128 public constant OWNER_READ_GAS` | Equivalent | the same value as `immutable` or a narrower type |
| 71 | SBR | `bytes32 private constant ENTRY_DOMAIN = keccak256("6529.works.State...` to `bytes32 private immutable ENTRY_DOMAIN = keccak256("6529.works.Stat...` | Equivalent | `constant` to `immutable` with the same value |
| 72 | SBR | `bytes32 private constant HEAD_DOMAIN = keccak256("6529.works.Statem...` to `bytes32 private immutable HEAD_DOMAIN = keccak256("6529.works.State...` | Equivalent | `constant` to `immutable` with the same value |
| 201 | SBR | `Chain storage chain = _chains[subjectKey(token,` to `Chain memory chain = _chains[subjectKey(token,` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 224 | ROR | `if (entryHash != 0 \|\| token == address(0)) return` to `if (entryHash > 0 \|\| token == address(0) \|\| token == address(0)) re...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 228 | LOR | `if (ok && core.length == 192) {` to `if (ok \|\| core.length == 192) {` | Gap | a subject whose `coreOf` answers with another length than 192 bytes (an arbitrary contract may) |
| 228 | ROR | `if (ok && core.length == 192) {` to `if (ok && ok && core.length <= 192) {` | Equivalent | the read caps the answer at 192 bytes, so `>= 192` is `== 192` |
| 228 | ROR | `if (ok && core.length == 192) {` to `if (ok && ok && core.length >= 192) {` | Equivalent | the read caps the answer at 192 bytes, so `>= 192` is `== 192` |
| 282 | ROR | `if (statement.kind == StatementKinds.DISPUTE_OUTCOME` to `if (statement.kind >= StatementKinds.DISPUTE_OUTCOME` | Gap | a kind whose label sorts above the dispute outcome's, about a token that answers ERC-165 and has no owner: the test mocks answer no ERC-165, so the dispute check passes them |
| 294 | SBR | `e.head = keccak256(abi.encode(HEAD_DOMAIN, chain.head, e.entryHash` to `e.head = keccak256(abi.encodePacked(HEAD_DOMAIN, chain.head, e.entr...` | Equivalent | three 32-byte words encode the same packed or padded |
| 318 | ROR | `if (s.kind == 0) revert InvalidKind();` to `if (s.kind <= 0) revert InvalidKind();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 323 | ROR | `if (s.schema == 0) revert InvalidSchema();` to `if (s.schema <= 0) revert InvalidSchema();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 324 | ROR | `if (s.content.digest == 0 \|\| !isKnownHashAlgorithm(s.content.algori...` to `if (s.content.digest <= 0 \|\| !isKnownHashAlgorithm(s.content.algori...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 329 | ROR | `if (hasUri && s.fileId != 0) revert ConflictingLocators(` to `if (hasUri && hasUri && s.fileId > 0) revert ConflictingLocators(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 330 | ROR | `if (!hasUri && s.fileId == 0) revert MissingLocator();` to `if (!hasUri && !hasUri && s.fileId <= 0) revert MissingLocator();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 339 | MIA | `if (token == address(0)) return;` to `if (false) return;` | Equivalent | address zero answers no ERC-165 query, so the next check returns as well |
| 345 | MIA | `if (!supported[1]) {` to `if (true) {` | Gap | a token that answers both ERC-721 and ERC-1155 (a dispute may not name an edition) |
| 349 | LOR | `if (ok && owner.length == 32 && abi.decode(owner, (uint256)) != 0) ...` to `if (ok \|\| owner.length == 32 ) return;` | Gap | a dispute about an ERC-721 token with no owner, from a token that answers ERC-165 (the test mocks do not) |
| 349 | ROR | `if (ok && owner.length == 32 && abi.decode(owner, (uint256` to `if (ok && ok && owner.length <= 32 && abi.decode(owner, (uint256)) ...` | Gap | an `ownerOf` answer shorter than a word is still refused, but by a failed decode instead of `UnknownDisputeSubject`; nothing tests it |
| 349 | ROR | `if (ok && owner.length == 32 && abi.decode(owner, (uint256` to `if (ok && ok && owner.length >= 32 && abi.decode(owner, (uint256)) ...` | Equivalent | the bounded read copies at most 32 bytes, so `>= 32` is `== 32` |
| 349 | ROR | `if (ok && owner.length == 32 && abi.decode(owner, (uint256)) != 0) ...` to `if (ok && owner.length == 32 && ok && owner.length == 32 && abi.dec...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 349 | ROR | `if (ok && owner.length == 32 && abi.decode(owner, (uint256)) != 0) ...` to `if (ok && owner.length == 32 && ok && owner.length == 32 && abi.dec...` | Gap | an ERC-721 that answers `ownerOf` with the zero address instead of reverting |
| 380 | LOR | `if (token == address(0) \|\| who == address(0)) return false` to `if (token == address(0) && who == address(0)) return false` | Equivalent | a zero token has no code, so every read fails and nothing is owned; a zero signer never reaches this |
| 380 | MIA | `if (token == address(0) \|\| who == address(0)) return false;` to `if (false) return false;` | Equivalent | a zero token has no code, so every read fails and nothing is owned; a zero signer never reaches this |
| 386 | ROR | `if (ok && result.length == 32) {` to `if (ok && ok && result.length >= 32) {` | Equivalent | the read caps the answer at 32 bytes, so `>= 32` is `== 32` |
| 392 | SBR | `32 && abi.decode(result, (uint256)) != 0;` to `32 && abi.decode(result, (uint128)) != 0;` | Gap | an ERC-1155 balance of 2**128 or more in the owner check reverts instead of counting as owned |
| 398 | ROR | `if (bits & bit != 0) revert NonceAlreadyUsed(signer,` to `if (bits & bit > 0) revert NonceAlreadyUsed(signer,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 399 | BOR | `_nonceBitmap[signer][nonce >> 8] = bits \| bit;` to `_nonceBitmap[signer][nonce >> 8] = bits ^ bit;` | Equivalent | the line before reverts when the bit is already set, so `|` and `^` set the same bit |
| 409 | ROR | `next.code.length == 0 \|\| DelegatedEOA.isDelegated(next)` to `next.code.length < 0 \|\| DelegatedEOA.isDelegated(next) \|\| !ERC165Ch...` | Equivalent | `length < 0` never holds, and an account without code fails the ERC-165 check that follows |
| 409 | ROR | `next.code.length == 0 \|\| DelegatedEOA.isDelegated(next)` to `next.code.length <= 0 \|\| DelegatedEOA.isDelegated(next) \|\| !ERC165C...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/sales/DutchPricing.sol`

5 survivors: 5 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 23 | ROR | `if (restingPrice != startPrice && duration == 0) return false` to `if (restingPrice < startPrice && duration == 0 && duration == 0) re...` | Equivalent | line 22 already returned for a resting price above the start, so `!=` and `<` agree; `== 0` and `<= 0` are the same unsigned test |
| 23 | ROR | `if (restingPrice != startPrice && duration == 0) return false;` to `if (restingPrice != startPrice && restingPrice != startPrice && dur...` | Equivalent | line 22 already returned for a resting price above the start, so `!=` and `<` agree; `== 0` and `<= 0` are the same unsigned test |
| 37 | ROR | `if (timestamp <= startTime) return startPrice;` to `if (timestamp < startTime) return startPrice;` | Equivalent | at the start time both return the start price (nothing has elapsed) |
| 39 | ROR | `if (elapsed >= duration) return restingPrice` to `if (elapsed > duration) return restingPrice` | Equivalent | at exactly the duration both give the resting price, since the steps divide the duration (and a zero duration never gets here: nothing has elapsed at line 37) |
| 40 | ROR | `if (stepSeconds != 0) elapsed -= elapsed % stepSeconds` to `if (stepSeconds > 0) elapsed -= elapsed % stepSeconds` | Equivalent | unsigned: `!= 0` and `> 0` are the same test |

</details>

### `src/sales/DutchSale.sol`

5 survivors: 5 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 68 | ROR | `if (_openSales[token][id] != 0) revert SaleAlreadyOpen(token,` to `if (_openSales[token][id] > 0) revert SaleAlreadyOpen(token,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 107 | ROR | `if (quantity == 0) revert InvalidQuantity();` to `if (quantity <= 0) revert InvalidQuantity();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 128 | ROR | `if (excess != 0) {` to `if (excess > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 144 | SBR | `Listing storage l = _listing(saleId);` to `Listing memory l = _listing(saleId);` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |
| 185 | SBR | `Schedule storage s = _schedules[saleId];` to `Schedule memory s = _schedules[saleId];` | Equivalent | a read-only storage pointer read as a memory copy (gas only) |

</details>

### `src/sales/EnglishAuction.sol`

81 survivors: 14 open gaps, 3 defensive, 8 gas margin, 56 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 90 | CONST | `public constant PAYOUT_GAS = 100_000;` to `public constant PAYOUT_GAS = 100001;` | Gas margin | one gas more or less is not observable without an exact-gas harness |
| 90 | CONST | `uint256 public constant PAYOUT_GAS = 100_000;` to `uint256 public constant PAYOUT_GAS = 99999;` | Gas margin | one gas more or less is not observable without an exact-gas harness |
| 93 | CONST | `internal constant DELIVERY_GAS = 300_000;` to `internal constant DELIVERY_GAS = 300001;` | Gas margin | one gas more or less is not observable without an exact-gas harness |
| 93 | CONST | `internal constant DELIVERY_GAS = 300_000;` to `internal constant DELIVERY_GAS = 299999;` | Gas margin | one gas more or less is not observable without an exact-gas harness |
| 95 | CONST | `constant DELIVERY_RESERVE = 50_000;` to `constant DELIVERY_RESERVE = 50001;` | Gas margin | the delivery reserve keeps tens of thousands of gas back for the transfer; one unit either way changes nothing |
| 95 | CONST | `internal constant DELIVERY_RESERVE = 50_000;` to `internal constant DELIVERY_RESERVE = 49999;` | Gas margin | the delivery reserve keeps tens of thousands of gas back for the transfer; one unit either way changes nothing |
| 99 | CONST | `constant _ERC20_PAYOUT_GAS = 1_000_000;` to `constant _ERC20_PAYOUT_GAS = 1000001;` | Gas margin | a token payout needs far less than 1,000,000 gas; one unit either way changes nothing |
| 99 | CONST | `private constant _ERC20_PAYOUT_GAS = 1_000_000;` to `private constant _ERC20_PAYOUT_GAS = 999999;` | Gas margin | a token payout needs far less than 1,000,000 gas; one unit either way changes nothing |
| 216 | CR | `_requireContract(address(economicsResolver_` to `//_requireContract(address(economicsResolver_` | Gap | an economics resolver that is an EIP-7702 delegated account whose delegate answers ERC-165 (the interface check alone refuses any other non-contract) |
| 230 | ROR | `for (uint256 i; i < targets.length; ++i) {` to `for (uint256 i; i != targets.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 230 | UOR | `uint256 i; i < targets.length; ++i) {` to `uint256 i; i < targets.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 258 | MIA | `bytes32 witness = payment.method != PaymentMethod.PERMIT2` to `bytes32 witness = false` | Equivalent | the witness is read only on the Permit2 path, so computing it for other payments changes nothing |
| 258 | ROR | `bytes32 witness = payment.method != PaymentMethod.PERMIT2` to `bytes32 witness = payment.method < PaymentMethod.PERMIT2` | Equivalent | `PERMIT2` is the last method, so `<` is `!=`; `>` never holds, and the witness is read only on the Permit2 path |
| 258 | ROR | `bytes32 witness = payment.method != PaymentMethod.PERMIT2` to `bytes32 witness = payment.method > PaymentMethod.PERMIT2` | Equivalent | `PERMIT2` is the last method, so `<` is `!=`; `>` never holds, and the witness is read only on the Permit2 path |
| 284 | MIA | `bytes32 witness = payment.method != PaymentMethod.PERMIT2` to `bytes32 witness = false` | Equivalent | the witness is read only on the Permit2 path, so computing it for other payments changes nothing |
| 284 | ROR | `bytes32 witness = payment.method != PaymentMethod.PERMIT2` to `bytes32 witness = payment.method < PaymentMethod.PERMIT2` | Equivalent | `PERMIT2` is the last method, so `<` is `!=`; `>` never holds, and the witness is read only on the Permit2 path |
| 284 | ROR | `bytes32 witness = payment.method != PaymentMethod.PERMIT2` to `bytes32 witness = payment.method > PaymentMethod.PERMIT2` | Equivalent | `PERMIT2` is the last method, so `<` is `!=`; `>` never holds, and the witness is read only on the Permit2 path |
| 301 | ROR | `if (s.status != AuctionState.ACTIVE \|\| active` to `if (s.status > AuctionState.ACTIVE \|\| active` | Gap | a withdrawal from an unknown sale reverts with another error (the state is `NONE`, the only state below `ACTIVE`) |
| 362 | ROR | `if (s.flags & _DELIVERY_PENDING == 0) revert NoPendingDelivery(saleId` to `if (s.flags & _DELIVERY_PENDING <= 0) revert NoPendingDelivery(saleId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 377 | ROR | `return s.flags & _DELIVERY_PENDING != 0 ? _recipientOf(s) : address(0` to `return s.flags & _DELIVERY_PENDING > 0 ? _recipientOf(s) : address(0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 385 | ROR | `if (s.flags & _PAUSE_USED != 0) revert PauseExhausted(saleId` to `if (s.flags & _PAUSE_USED > 0) revert PauseExhausted(saleId` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 393 | ROR | `if (entry != 0) s.outcomeFrom = uint40(index` to `if (entry > 0) s.outcomeFrom = uint40(index` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 420 | ROR | `if (outcomeRef == bytes32(0) \|\| outcomeRef != entry` to `if (outcomeRef <= bytes32(0) \|\| outcomeRef != entry` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 467 | ROR | `if (_settings.pausedAt != 0) revert SalePaused();` to `if (_settings.pausedAt > 0) revert SalePaused();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 476 | ROR | `if (pausedAt == 0) revert NotPaused();` to `if (pausedAt <= 0) revert NotPaused();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 484 | ROR | `return _settings.pausedAt != 0;` to `return _settings.pausedAt > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 498 | CR | `_requireContract(next);` to `//_requireContract(next);` | Gap | a federation registry that is an EIP-7702 delegated account whose delegate answers ERC-165 |
| 504 | MIA | `federationRegistryCodeHash = next == address(0) ? bytes32(0) : next...` to `federationRegistryCodeHash = false ? bytes32(0) : next.codehash;` | Equivalent | the stored hash is checked only while a registry is set |
| 548 | ROR | `if (a.state == AuctionState.NONE) revert UnknownSale(saleId` to `if (a.state <= AuctionState.NONE) revert UnknownSale(saleId` | Equivalent | `NONE` is the enum's first value, so `<=` is `==` |
| 562 | ROR | `if (a.pausedAt != 0 && block.timestamp > a.pausedAt` to `if (a.pausedAt > 0 && block.timestamp > a.pausedAt` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 595 | ROR | `address(0) && registry.codehash == federationRegistryCodeHash` to `address(0) && registry.codehash <= federationRegistryCodeHash` | Gap | a federation registry whose code hash sorts below the pin |
| 628 | ROR | `if (c.pausedAt != 0) revert SalePaused();` to `if (c.pausedAt > 0) revert SalePaused();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 633 | ROR | `if (terms.saleKind != SaleKind.ENGLISH_AUCTION) {` to `if (terms.saleKind > SaleKind.ENGLISH_AUCTION) {` | Gap | a mint target reporting a sale kind whose label sorts below the English auction's |
| 641 | ROR | `tokenId >> 32 != 0 \|\| terms.seller == address(0` to `tokenId >> 32 > 0 \|\| terms.seller == address(0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 641 | ROR | `== address(0) && terms.feeShare != 0)))` to `== address(0) && terms.feeShare > 0)))` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 641 | ROR | `\|\| terms.price != 0 \|\| terms.params.length != 0` to `\|\| terms.price > 0 \|\| terms.params.length != 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 641 | ROR | `terms.price != 0 \|\| terms.params.length != 0` to `terms.price != 0 \|\| terms.params.length > 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 651 | MIA | `if (s.status != AuctionState.NONE) revert InvalidAuctionState(saleId,` to `if (false) revert InvalidAuctionState(saleId,` | Gap | `start` on a sale that already exists (a settled token sent back to the auction): reachable, untested (coverage lists it too) |
| 651 | ROR | `if (s.status != AuctionState.NONE) revert InvalidAuctionState(saleId,` to `if (s.status < AuctionState.NONE) revert InvalidAuctionState(saleId,` | Gap | `<` never holds: `start` on a sale that already exists (coverage lists it too); `>` is `!=` (`NONE` is zero) |
| 651 | ROR | `if (s.status != AuctionState.NONE) revert InvalidAuctionState(saleId,` to `if (s.status > AuctionState.NONE) revert InvalidAuctionState(saleId,` | Gap | `<` never holds: `start` on a sale that already exists (coverage lists it too); `>` is `!=` (`NONE` is zero) |
| 704 | ROR | `e.codeHash != token.codehash \|\| e.feeShare >` to `e.codeHash > token.codehash \|\| e.feeShare >` | Gap | a federated token whose code moved so that its hash sorts above the registry entry's (only the other direction is tested) |
| 704 | ROR | `token.codehash \|\| e.feeShare > Splits.DENOMINATOR` to `token.codehash \|\| e.feeShare >= Splits.DENOMINATOR` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 704 | ROR | `recipient == address(0) && e.feeShare != 0)` to `recipient == address(0) && e.feeShare > 0)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 716 | ROR | `if (id == 0) {` to `if (id <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 742 | MIA | `if (lt.feeShare > Splits.DENOMINATOR) revert InvalidTerms(s.token,` to `if (false) revert InvalidTerms(s.token,` | Defensive | a locked fee share above the denominator: the resolver bounds fee shares before they are locked (coverage lists it too) |
| 742 | ROR | `if (lt.feeShare > Splits.DENOMINATOR) revert InvalidTerms(s.token,` to `if (lt.feeShare >= Splits.DENOMINATOR) revert InvalidTerms(s.token,` | Defensive | a locked fee share of exactly the denominator: the resolver bounds fee shares below it before they are locked |
| 760 | ROR | `if (t.incrementFloor == 0) {` to `if (t.incrementFloor <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 782 | MIA | `if (s.flags & _RECIPIENT_SET == 0) {` to `if (true) {` | Equivalent | it rewrites the same flag and recipient |
| 782 | ROR | `if (s.flags & _RECIPIENT_SET == 0) {` to `if (s.flags & _RECIPIENT_SET <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 782 | ROR | `if (s.flags & _RECIPIENT_SET == 0) {` to `if (s.flags & _RECIPIENT_SET >= 0) {` | Equivalent | both branches leave the flag set and the new recipient stored |
| 785 | MIA | `} else if (s.recipient != recipient) {` to `} else if (true) {` | Equivalent | it rewrites the same recipient |
| 788 | ROR | `else if (s.flags & _RECIPIENT_SET != 0) {` to `else if (s.flags & _RECIPIENT_SET > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 790 | CR | `s.recipient = address(0);` to `//s.recipient = address(0);` | Equivalent | the recipient is read only while its flag is set, and the flag is cleared |
| 797 | ROR | `if (end - block.timestamp < window) {` to `if (end - block.timestamp <= window) {` | Equivalent | at exactly `window` seconds before the end, the extension sets the end the sale already has |
| 814 | ROR | `if (p.method != PaymentMethod.DIRECT \|\| p.payer` to `if (p.method > PaymentMethod.DIRECT \|\| p.payer` | Equivalent | `DIRECT` is the first payment method, so `> DIRECT` is `!= DIRECT` |
| 820 | ROR | `if (msg.value != 0) revert InvalidPayment();` to `if (msg.value > 0) revert InvalidPayment();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 824 | ROR | `if (p.method != PaymentMethod.DIRECT && block.timestamp` to `if (p.method > PaymentMethod.DIRECT && block.timestamp` | Equivalent | `DIRECT` is the first payment method, so `> DIRECT` is `!= DIRECT` |
| 827 | ROR | `if (p.method == PaymentMethod.PERMIT2) {` to `if (p.method >= PaymentMethod.PERMIT2) {` | Equivalent | `PERMIT2` is the last method, so `>=` is `==` |
| 843 | ROR | `TokenTransfer.balanceOf(currency, address(this)) != held + p.amount` to `TokenTransfer.balanceOf(currency, address(this)) < held + p.amount` | Gap | a Permit2 pull whose balances move other than by exactly the amount, either way |
| 843 | ROR | `TokenTransfer.balanceOf(currency, p.payer) != payerHeld - p.amount` to `TokenTransfer.balanceOf(currency, p.payer) < payerHeld - p.amount` | Gap | a Permit2 pull whose balances move other than by exactly the amount, either way |
| 843 | ROR | `TokenTransfer.balanceOf(currency, p.payer) != payerHeld - p.amount` to `TokenTransfer.balanceOf(currency, p.payer) > payerHeld - p.amount` | Gap | a Permit2 pull whose balances move other than by exactly the amount, either way |
| 850 | ROR | `if (p.method == PaymentMethod.PERMIT) {` to `if (p.method >= PaymentMethod.PERMIT) {` | Equivalent | Permit2 payments return above, so only `PERMIT` reaches this test |
| 851 | ROR | `if (p.signature.length != 65) revert InvalidPayment();` to `if (p.signature.length > 65) revert InvalidPayment();` | Gap | a permit signature shorter than 65 bytes fails with a panic instead of `InvalidPayment` |
| 887 | ROR | `if (amount == 0) return;` to `if (amount <= 0) return;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 909 | ROR | `if (amount == 0) revert NothingToClaim(account,` to `if (amount <= 0) revert NothingToClaim(account,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 969 | MIA | `if (s.flags & _RECIPIENT_SET != 0) {` to `if (true) {` | Equivalent | it clears a flag and recipient that are already clear |
| 969 | ROR | `if (s.flags & _RECIPIENT_SET != 0) {` to `if (s.flags & _RECIPIENT_SET > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 970 | CR | `s.flags &= ~_RECIPIENT_SET;` to `//s.flags &= ~_RECIPIENT_SET;` | Equivalent | with no bidder left, the flag is cleared or overwritten by the next bid before anything reads it |
| 971 | CR | `s.recipient = address(0);` to `//s.recipient = address(0);` | Equivalent | the recipient is read only while its flag is set, and the flag is cleared |
| 999 | ROR | `_terms[s.termsId].extensionWindow <= s.endTime) return false;` to `_terms[s.termsId].extensionWindow < s.endTime) return false;` | Gap | a currency coming back exactly at the end of the reopening window (boundary) |
| 1016 | ROR | `active = status == IAssetAllowlist.Status.Active` to `active = status <= IAssetAllowlist.Status.Active` | Defensive | an auction's currency was admitted when it was locked, so its status is never `None` |
| 1033 | ROR | `if (s.status == AuctionState.NONE) revert UnknownSale(saleId` to `if (s.status <= AuctionState.NONE) revert UnknownSale(saleId` | Equivalent | `NONE` is the enum's first value, so `<=` is `==` |
| 1050 | ROR | `if (s.flags & _PAUSE_USED != 0) {` to `if (s.flags & _PAUSE_USED > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1054 | ROR | `if (pausedAt != 0 && block.timestamp > pausedAt` to `if (pausedAt > 0 && block.timestamp > pausedAt` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1059 | ROR | `if (state == AuctionState.NONE) revert UnknownSale(saleId` to `if (state <= AuctionState.NONE) revert UnknownSale(saleId` | Equivalent | `NONE` is the enum's first value, so `<=` is `==` |
| 1079 | ROR | `pausedAt = s.flags & _PAUSE_USED == 0 ? 0 : s.pausedAt;` to `pausedAt = s.flags & _PAUSE_USED <= 0 ? 0 : s.pausedAt;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1080 | ROR | `if (pausedAt != 0) {` to `if (pausedAt > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1093 | AOR | `+ length + Math.max(s.endTime - pausedAt, _reopening(s));` to `+ length + Math.max(s.endTime % pausedAt, _reopening(s));` | Equivalent | an end time is less than twice the pause time for any real timestamp, so `%` and `-` agree |
| 1113 | ROR | `return s.flags & _RECIPIENT_SET != 0 ? s.recipient : s.bidder;` to `return s.flags & _RECIPIENT_SET > 0 ? s.recipient : s.bidder;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1118 | ROR | `&& (token.code.length == 0` to `&& (token.code.length <= 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 1147 | ROR | `if (dependency.code.length == 0 \|\| DelegatedEOA.isDelegated(dependency` to `if (dependency.code.length <= 0 \|\| DelegatedEOA.isDelegated(dependency` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/sales/FixedPriceSale.sol`

45 survivors: 45 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 65 | SBR | `bytes32 public constant ALLOWLIST_LEAF_DOMAIN = keccak256("6529WORK...` to `bytes32 public immutable ALLOWLIST_LEAF_DOMAIN = keccak256("6529WOR...` | Equivalent | the same value as `immutable` |
| 107 | ROR | `if (_openSales[token][id] != 0) revert SaleAlreadyOpen(token,` to `if (_openSales[token][id] > 0) revert SaleAlreadyOpen(token,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 109 | ROR | `if (consent.signature.length != 0) {` to `if (consent.signature.length > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 122 | ROR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint256 i; i != phases_.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 122 | SBR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint128 i; i < phases_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 122 | SBR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint128 i; i < phases_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 122 | UOR | `uint256 i; i < phases_.length; ++i) {` to `uint256 i; i < phases_.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 124 | ROR | `bool allowlisted = phase.root != 0;` to `bool allowlisted = phase.root > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 133 | MIA | `if (allowlisted) _roots[saleId][i] = phase.root` to `if (true) _roots[saleId][i] = phase.root` | Equivalent | a phase without an allowlist has root zero, so storing it writes zero over zero |
| 162 | ROR | `if (payment.amount != total) revert InvalidPayment(` to `if (payment.amount > total) revert InvalidPayment(` | Equivalent | `MintSaleBase._collect` refuses an amount below the charge with the same `InvalidPayment`, so only an overpayment needed this check |
| 218 | ROR | `for (uint256 i; i < list.length; ++i) {` to `for (uint256 i; i != list.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 218 | SBR | `StoredPhase memory s = _phases[saleId][i];` to `StoredPhase storage s = _phases[saleId][i];` | Equivalent | a read-only storage reference reads the same values as a copy, and the counter never reaches 2**128 |
| 218 | SBR | `for (uint256 i; i < list.length; ++i) {` to `for (uint128 i; i < list.length; ++i) {` | Equivalent | a read-only storage reference reads the same values as a copy, and the counter never reaches 2**128 |
| 218 | SBR | `for (uint256 i; i < list.length; ++i) {` to `for (uint128 i; i < list.length; ++i) {` | Equivalent | a read-only storage reference reads the same values as a copy, and the counter never reaches 2**128 |
| 218 | UOR | `for (uint256 i; i < list.length; ++i) {` to `for (uint256 i; i < list.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 219 | SBR | `StoredPhase memory s = _phases[saleId][i];` to `StoredPhase storage s = _phases[saleId][i];` | Equivalent | a read-only storage reference reads the same values as a copy |
| 220 | MIA | `s.allowlisted ? _roots[saleId][i] : bytes32(0` to `true ? _roots[saleId][i] : bytes32(0` | Equivalent | a phase without an allowlist never stored a root, so its slot reads zero either way |
| 319 | ROR | `if (p.phase >= l.phaseCount \|\| l.closed) revert` to `if (p.phase > l.phaseCount \|\| l.closed) revert` | Equivalent | the slot past the last phase is empty (start and end zero), so the window check refuses it with the same `PhaseNotOpen` |
| 319 | ROR | `if (p.phase >= l.phaseCount \|\| l.closed) revert` to `if (p.phase == l.phaseCount \|\| l.closed) revert` | Equivalent | the slot past the last phase is empty (start and end zero), so the window check refuses it with the same `PhaseNotOpen` |
| 320 | SBR | `StoredPhase memory phase = _phases[p.saleId][p.phase]` to `StoredPhase storage phase = _phases[p.saleId][p.phase]` | Equivalent | a read-only storage reference reads the same values as a copy |
| 328 | ROR | `if (p.quantity == 0) revert InvalidQuantity();` to `if (p.quantity <= 0) revert InvalidQuantity();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 338 | ROR | `!phase.allowlisted && phase.walletCap == 0) return unit;` to `!phase.allowlisted && phase.walletCap <= 0) return unit;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 343 | ROR | `\|\| (phase.walletCap != 0 && bought > phase.walletCap` to `\|\| (phase.walletCap > 0 && bought > phase.walletCap` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 366 | SBR | `Listing storage l = _listings[saleId];` to `Listing memory l = _listings[saleId];` | Equivalent | the listing is only read, so a memory copy reads the same values |
| 367 | SBR | `uint256 count = l.phaseCount;` to `uint128 count = l.phaseCount;` | Equivalent | a phase count of at most 16 fits any width |
| 368 | MIA | `if (count == 0) return true;` to `if (false) return true;` | Equivalent | with no phases the loop does not run and the function returns true anyway |
| 368 | ROR | `if (count == 0) return true;` to `if (count < 0) return true;` | Equivalent | `count < 0` never holds; with no phases the loop does not run and the function returns true anyway |
| 368 | ROR | `if (count == 0) return true;` to `if (count <= 0) return true;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 370 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i <= count; ++i) {` | Equivalent | the slot past the last phase is empty (an end of zero), which never keeps the sale open |
| 370 | ROR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i != count; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 370 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 370 | SBR | `for (uint256 i; i < count; ++i) {` to `for (uint128 i; i < count; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 370 | UOR | `for (uint256 i; i < count; ++i) {` to `for (uint256 i; i < count; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 379 | ROR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint256 i; i != phases_.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 379 | SBR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint128 i; i < phases_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 379 | SBR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint128 i; i < phases_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 379 | UOR | `uint256 i; i < phases_.length; ++i) {` to `uint256 i; i < phases_.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 390 | ROR | `if (phases_.length == 0 \|\| phases_.length > Limits.MAX_PHASES` to `if (phases_.length <= 0 \|\| phases_.length > Limits.MAX_PHASES` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 392 | ROR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint256 i; i != phases_.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 392 | SBR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint128 i; i < phases_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 392 | SBR | `for (uint256 i; i < phases_.length; ++i) {` to `for (uint128 i; i < phases_.length; ++i) {` | Equivalent | the counter never reaches 2**128 |
| 392 | UOR | `uint256 i; i < phases_.length; ++i) {` to `uint256 i; i < phases_.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 395 | ROR | `\|\| (phase.root == 0 && (phase.payerKeyed \|\| phase.leafPriced` to `\|\| (phase.root <= 0 && (phase.payerKeyed \|\| phase.leafPriced` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 398 | ROR | `if (phase.start < start) start = phase.start;` to `if (phase.start <= start) start = phase.start;` | Equivalent | `<=` also assigns an equal value |
| 399 | ROR | `if (phase.end > end) end = phase.end;` to `if (phase.end >= end) end = phase.end;` | Equivalent | `>=` also assigns an equal value |

</details>

### `src/sales/MintSaleBase.sol`

46 survivors: 11 open gaps, 3 defensive, 32 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 89 | SBR | `uint256 public constant PAYOUT_GAS = 100_000;` to `uint256 public immutable PAYOUT_GAS = 100_000;` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 89 | SBR | `uint256 public constant PAYOUT_GAS = 100_000` to `uint128 public constant PAYOUT_GAS = 100_000` | Equivalent | the same value as `immutable` or a narrower type that still holds it |
| 182 | ROR | `allowlist.code.length == 0 \|\| DelegatedEOA.isDelegated(allowlist` to `allowlist.code.length <= 0 \|\| DelegatedEOA.isDelegated(allowlist` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 210 | MIA | `federationRegistryCodeHash = next == address(0) ? bytes32(0) : next...` to `federationRegistryCodeHash = false ? bytes32(0) : next.codehash;` | Gap | unsetting the federation registry records the code hash of the zero address, which is nonzero once that account holds ETH (as on mainnet); only the getter would show it |
| 228 | SBR | `uint256 allowedAt = uint256(pausedAt) + Roles.STANDARD;` to `uint128 allowedAt = uint128(pausedAt) + Roles.STANDARD;` | Equivalent | a pause time plus 48 hours fits 128 bits |
| 242 | ROR | `if (amount == 0) revert NothingToClaim(msg.sender,` to `if (amount <= 0) revert NothingToClaim(msg.sender,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 245 | MIA | `if (currency != CURRENCY_ETH) {` to `if (false) {` | Defensive | nothing credits an ERC-20 today (the only credits are Dutch refunds, in ETH), so the ERC-20 branch of `claim` is unreachable (coverage lists it too) |
| 246 | RR | `TokenTransfer.transferExact(currency, to, amount);` to `revert();` | Defensive | nothing credits an ERC-20 today (the only credits are Dutch refunds, in ETH), so the ERC-20 branch of `claim` is unreachable (coverage lists it too) |
| 263 | SBR | `Listing storage l = _listing(saleId);` to `Listing memory l = _listing(saleId);` | Equivalent | the listing is only read, so a memory copy reads the same values |
| 288 | ROR | `== CURRENCY_DEFAULT && t.price != 0) {` to `== CURRENCY_DEFAULT && t.price > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 300 | ROR | `if (e.codeHash != token.codehash) revert InvalidSaleTerms(token,` to `if (e.codeHash > token.codehash) revert InvalidSaleTerms(token,` | Gap | a federated token whose code moved so that its hash sorts below the registry entry's (only one direction is tested) |
| 307 | ROR | `t.seller == address(0) \|\| (t.feeShare != 0 && t.feeRecipient == add...` to `t.seller == address(0) \|\| (t.feeShare > 0 && t.feeRecipient == addr...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 307 | ROR | `\|\| t.feeShare > Splits.DENOMINATOR \|\| t.seller` to `\|\| t.feeShare >= Splits.DENOMINATOR \|\| t.seller` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 322 | SBR | `) internal returns (uint256 saleId) {` to `) internal returns (uint128 saleId) {` | Equivalent | sale IDs never reach 2**128 |
| 325 | SBR | `// Safe: seconds of halt, far below 2^40.` to `// Safe: minutes of halt, far below 2^40.` | Equivalent | the mutation only changed a comment |
| 325 | SBR | `// Safe: seconds of halt, far below 2^40.` to `// Safe: days of halt, far below 2^40.` | Equivalent | the mutation only changed a comment |
| 325 | SBR | `// Safe: seconds of halt, far below 2^40.` to `// Safe: hours of halt, far below 2^40.` | Equivalent | the mutation only changed a comment |
| 325 | SBR | `// Safe: seconds of halt, far below 2^40.` to `// Safe: weeks of halt, far below 2^40.` | Equivalent | the mutation only changed a comment |
| 349 | ROR | `IEditions(token).formatOf(id) != EditionFormat.FIXED) {` to `IEditions(token).formatOf(id) > EditionFormat.FIXED) {` | Equivalent | `FIXED` is the first edition format, so `> FIXED` is `!= FIXED` |
| 358 | ROR | `return immediate && delay == 0;` to `return immediate && delay <= 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 358 | ROR | `return immediate && delay == 0;` to `return immediate && delay >= 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 385 | ROR | `if (status != IAssetAllowlist.Status.Active` to `if (status > IAssetAllowlist.Status.Active` | Defensive | a locked currency was active when the sale opened, and the allowlist never returns an asset to `None` |
| 419 | ROR | `pay.method != PaymentMethod.DIRECT \|\| pay.payer` to `pay.method > PaymentMethod.DIRECT \|\| pay.payer` | Equivalent | `DIRECT` is the first payment method, so `> DIRECT` is `!= DIRECT` |
| 423 | ROR | `if (value != 0) revert InvalidPayment();` to `if (value > 0) revert InvalidPayment();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 425 | ROR | `if (pay.method != PaymentMethod.DIRECT && block.timestamp` to `if (pay.method > PaymentMethod.DIRECT && block.timestamp` | Equivalent | `DIRECT` is the first payment method, so `> DIRECT` is `!= DIRECT` |
| 425 | ROR | `PaymentMethod.DIRECT && block.timestamp > pay.deadline) {` to `PaymentMethod.DIRECT && block.timestamp >= pay.deadline) {` | Gap | a permit used at its deadline second in the fixed-price and Dutch adapters (`> DIRECT` is equivalent) |
| 428 | ROR | `if (pay.method == PaymentMethod.PERMIT2) {` to `if (pay.method >= PaymentMethod.PERMIT2) {` | Equivalent | `PERMIT2` is the last payment method, so `>= PERMIT2` is `== PERMIT2` |
| 433 | ROR | `if (pay.method == PaymentMethod.PERMIT) {` to `if (pay.method >= PaymentMethod.PERMIT) {` | Equivalent | `PERMIT2` returned on the line before, so past it `>= PERMIT` is `== PERMIT` |
| 435 | ROR | `if (pay.signature.length != 65) revert InvalidPayment();` to `if (pay.signature.length < 65) revert InvalidPayment();` | Gap | a permit signature longer than 65 bytes |
| 450 | MIA | `if (charge != 0) TokenTransfer.pullExact(currency,` to `if (true) TokenTransfer.pullExact(currency,` | Gap | a zero-charge ERC-20 purchase through a token that refuses zero-value transfers |
| 450 | ROR | `if (charge != 0) TokenTransfer.pullExact(currency,` to `if (charge > 0) TokenTransfer.pullExact(currency,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 450 | ROR | `if (charge != 0) TokenTransfer.pullExact(currency,` to `if (charge >= 0) TokenTransfer.pullExact(currency,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 463 | ROR | `if (minted != l.id) revert InvalidSaleTerms(l.token,` to `if (minted > l.id) revert InvalidSaleTerms(l.token,` | Gap | a token that mints an ID below the sale's (only one minting a higher ID is tested) |
| 501 | MIA | `return index == 0 ? address(0) : _feeRecipients[index]` to `return false ? address(0) : _feeRecipients[index]` | Equivalent | index zero is never written, so `_feeRecipients[0]` is the zero address anyway |
| 501 | ROR | `return index == 0 ? address(0) : _feeRecipients[index]` to `return index < 0 ? address(0) : _feeRecipients[index]` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 501 | ROR | `return index == 0 ? address(0) : _feeRecipients[index]` to `return index <= 0 ? address(0) : _feeRecipients[index]` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 511 | MIA | `if (recipient == address(0)) return 0;` to `if (false) return 0;` | Gap | terms without a fee recipient would register the zero address as one (a wasted index); nothing checks the count |
| 513 | ROR | `if (index == 0) {` to `if (index <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 514 | ROR | `if (_feeRecipientCount == type(uint16).max) revert InvalidSaleTerms...` to `if (_feeRecipientCount >= type(uint16).max) revert InvalidSaleTerms...` | Equivalent | the counter stops at its maximum, so `>=` is `==` |
| 525 | ROR | `address(0) && registry.codehash == federationRegistryCodeHash` to `address(0) && registry.codehash <= federationRegistryCodeHash` | Gap | a federation registry whose code moved so that its hash sorts below the pin |
| 537 | MVIE | `uint256 ours = TokenTransfer.balanceOf(currency, address(this));` to `uint256 ours ;` | Gap | a Permit2 purchase while the adapter already holds some of the token |
| 550 | ROR | `TokenTransfer.balanceOf(currency, address(this)) != ours + charge \|...` to `TokenTransfer.balanceOf(currency, address(this)) < ours + charge \|\|...` | Gap | a Permit2 pull whose balances move by more than the charge (only less is tested) |
| 550 | ROR | `TokenTransfer.balanceOf(currency, pay.payer) != theirs - charge` to `TokenTransfer.balanceOf(currency, pay.payer) < theirs - charge` | Gap | a Permit2 pull whose balances move by more than the charge (only less is tested) |
| 557 | ROR | `return dependency.code.length != 0 && !DelegatedEOA.isDelegated(dep...` to `return dependency.code.length > 0 && !DelegatedEOA.isDelegated(depe...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 557 | ROR | `return dependency.code.length != 0 && !DelegatedEOA.isDelegated(dep...` to `return dependency.code.length >= 0 && !DelegatedEOA.isDelegated(dep...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 564 | ROR | `if (amount != 0) {` to `if (amount > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/stream/SpdxId.sol`

3 survivors: 3 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 14 | SBR | `uint256 private constant ALLOWED = 0x07fffffe07fffffe03ff680000000000` to `uint128 private constant ALLOWED = 0x07fffffe07fffffe03ff680000000000` | Equivalent | the 128-bit mask fits the narrower type |
| 19 | ROR | `if (n == 0 \|\| n > Limits.MAX_LICENSE_ID_BYTES` to `if (n <= 0 \|\| n > Limits.MAX_LICENSE_ID_BYTES \|\| n > Limits.MAX_LIC...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 33 | ROR | `if (n == 0 \|\| n > Limits.MAX_LICENSE_ID_BYTES` to `if (n <= 0 \|\| n > Limits.MAX_LICENSE_ID_BYTES \|\| n > Limits.MAX_LIC...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/stream/Stream.sol`

42 survivors: 10 defensive, 32 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 219 | ROR | `if (to != msg.sender \|\| id != 0 \|\| amount != 1) revert InvalidMintR...` to `if (to != msg.sender \|\| id > 0 \|\| amount != 1) revert InvalidMintRe...` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 228 | ROR | `if (artistId == 0 \|\| artistId > type(uint160` to `if (artistId <= 0 \|\| artistId > type(uint160` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 228 | ROR | `if (artistId == 0 \|\| artistId > type(uint160).max) revert InvalidMi...` to `if (artistId == 0 \|\| artistId >= type(uint160).max) revert InvalidM...` | Defensive | artist IDs are the artist registry's counter: an ID of 2**160 - 1 cannot occur |
| 230 | ROR | `item.seedPolicy == SeedPolicy.VRF` to `item.seedPolicy >= SeedPolicy.VRF` | Equivalent | `VRF` is the last seed policy, so `>= VRF` is `== VRF` |
| 259 | ROR | `if (id != 0) {` to `if (id > 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 271 | ROR | `if (artistId == 0) revert InvalidMintRequest(` to `if (artistId <= 0) revert InvalidMintRequest(` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 290 | ROR | `if (t.flags & SETTLED != 0) revert SaleAlreadySettled(id` to `if (t.flags & SETTLED > 0) revert SaleAlreadySettled(id` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 305 | ROR | `if (tokenId == 0 \|\| tokenId > _counts.minted` to `if (tokenId <= 0 \|\| tokenId > _counts.minted` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 325 | ROR | `if (minter.id == 0) minter.id = ++_counts.minters` to `if (minter.id <= 0) minter.id = ++_counts.minters` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 339 | ROR | `if (flags & SETTLED != 0) return;` to `if (flags & SETTLED > 0) return;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 356 | ROR | `if (raw.length == 0 \|\| raw.length > MAX_NAME_BYTES` to `if (raw.length <= 0 \|\| raw.length > MAX_NAME_BYTES` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 359 | ROR | `for (uint256 i; i < raw.length; ++i) {` to `for (uint256 i; i != raw.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 359 | UOR | `for (uint256 i; i < raw.length; ++i) {` to `for (uint256 i; i < raw.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 445 | ROR | `_tokens[tokenId].flags & SETTLED != 0;` to `_tokens[tokenId].flags & SETTLED > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 481 | ROR | `if (minted != 0) emit BatchMetadataUpdate(1,` to `if (minted > 0) emit BatchMetadataUpdate(1,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 547 | ROR | `if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId` to `if (fromTokenId >= toTokenId) emit MetadataUpdate(fromTokenId` | Defensive | the records satellite, the only caller, never passes a range whose start is above its end |
| 559 | ROR | `flags & KIND_MASTER == 0 \|\| flags & SETTLED == 0 \|\|` to `flags & KIND_MASTER <= 0 \|\| flags & SETTLED == 0 \|\|` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 559 | ROR | `KIND_MASTER == 0 \|\| flags & SETTLED == 0 \|\| flags & LINKED != 0` to `KIND_MASTER == 0 \|\| flags & SETTLED <= 0 \|\| flags & LINKED != 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 559 | ROR | `SETTLED == 0 \|\| flags & LINKED != 0` to `SETTLED == 0 \|\| flags & LINKED > 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 573 | ROR | `_tokens[tokenId].flags & LINKED != 0) return (editions, tokenId)` to `_tokens[tokenId].flags & LINKED > 0) return (editions, tokenId)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 619 | ROR | `if (data.length < 160 \|\| uint256(bytes32(data[:32]` to `if (data.length <= 160 \|\| uint256(bytes32(data[:32]` | Equivalent | a request of exactly 160 bytes has no room for its item, so it is refused either way (by the member read instead of the length check) |
| 637 | MIA | `if (result.length != 64) revert InvalidMintRequest();` to `if (false) revert InvalidMintRequest();` | Defensive | the bound package registry always answers `consume` with 64 bytes (coverage lists it too) |
| 637 | ROR | `if (result.length != 64) revert InvalidMintRequest(` to `if (result.length < 64) revert InvalidMintRequest(` | Defensive | the package registry's `consume` returns exactly two words |
| 637 | ROR | `if (result.length != 64) revert InvalidMintRequest(` to `if (result.length > 64) revert InvalidMintRequest(` | Defensive | the package registry's `consume` returns exactly two words |
| 651 | ROR | `SaleKind.ENGLISH_AUCTION \|\| item.sale.params.length != 0` to `SaleKind.ENGLISH_AUCTION \|\| item.sale.params.length > 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 651 | ROR | `\|\| item.parties.length == 0 \|\| !_collections[item.collectionId].exists` to `\|\| item.parties.length <= 0 \|\| !_collections[item.collectionId].exists` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 651 | ROR | `SeedPolicy.ARTIST) != (item.seed != 0)` to `SeedPolicy.ARTIST) != (item.seed > 0)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 651 | ROR | `\|\| (policy == SeedPolicy.VRF && entropyModule` to `\|\| (policy >= SeedPolicy.VRF && entropyModule` | Equivalent | `VRF` is the last seed policy, so `>= VRF` is `== VRF` |
| 674 | ROR | `Splits.DENOMINATOR \|\| e.feeShare >= Splits.DENOMINATOR` to `Splits.DENOMINATOR \|\| e.feeShare == Splits.DENOMINATOR` | Defensive | the economics resolver refuses a fee share of 100,000 or more |
| 674 | ROR | `\|\| (e.feeShare != 0 && (e.feeRecipient == address(0` to `\|\| (e.feeShare > 0 && (e.feeRecipient == address(0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 705 | ROR | `t.flags = (item.kind == ItemKind.EDITION_MASTER ? KIND_MASTER` to `t.flags = (item.kind >= ItemKind.EDITION_MASTER ? KIND_MASTER` | Equivalent | `EDITION_MASTER` is the last item kind, so `>= EDITION_MASTER` is `== EDITION_MASTER` |
| 728 | ROR | `if (id == 0) {` to `if (id <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 731 | MIA | `if (id != _feeRecipients.length) revert InvalidMintRequest();` to `if (false) revert InvalidMintRequest();` | Defensive | the 65,536th fee recipient (coverage lists it too) |
| 731 | ROR | `if (id != _feeRecipients.length) revert` to `if (id < _feeRecipients.length) revert` | Equivalent | a truncated index is always below the length, so `<` is `!=` |
| 731 | ROR | `if (id != _feeRecipients.length) revert` to `if (id > _feeRecipients.length) revert` | Defensive | `<` is equivalent (a truncated index is always below the length); `>` drops the guard, which only a 65,536th fee recipient would reach, each one a governed economics change |
| 741 | ROR | `if (feeShare == 0) return seller;` to `if (feeShare <= 0) return seller;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 757 | ROR | `if (held.artistId == 0) {` to `if (held.artistId <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 763 | ROR | `if (id == 0) {` to `if (id <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 766 | MIA | `if (n > HASHED) revert InvalidMintRequest();` to `if (false) revert InvalidMintRequest();` | Defensive | the 2**23rd terms word in the overflow range (coverage lists it too) |
| 766 | ROR | `if (n > HASHED) revert InvalidMintRequest(` to `if (n >= HASHED) revert InvalidMintRequest(` | Defensive | the overflow range holds 2**23 - 1 terms; filling it is out of reach of a test and of use |
| 788 | ROR | `return flags & KIND_MASTER != 0 ? ItemKind.EDITION_MASTER :` to `return flags & KIND_MASTER > 0 ? ItemKind.EDITION_MASTER :` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 807 | ROR | `if (target.code.length == 0 \|\| DelegatedEOA.isDelegated(target` to `if (target.code.length <= 0 \|\| DelegatedEOA.isDelegated(target` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>

### `src/stream/WorkRecords.sol`

75 survivors: 10 open gaps, 8 defensive, 57 equivalent.

<details><summary>The survivors</summary>

| Line | Rule | Mutation | Verdict | Why |
| ---: | --- | --- | --- | --- |
| 125 | CR | `_requireContract(stream_);` to `//_requireContract(stream_);` | Gap | a stream address that is an EIP-7702 delegated account whose delegate answers ERC-165 for `IStream` (the interface check alone refuses any other non-contract) |
| 131 | ROR | `contentStore_).sha256Of(cc0.textFileId) == 0` to `contentStore_).sha256Of(cc0.textFileId) <= 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 142 | CR | `_cc0SpdxId = cc0.spdxId;` to `//_cc0SpdxId = cc0.spdxId;` | Equivalent | every CC0 license is then stored as a custom one with the same values, so every read is unchanged |
| 166 | ROR | `WorksHashing.itemHashCalldata(item) != _itemHashOf(tokenId) \|\| files` to `WorksHashing.itemHashCalldata(item) < _itemHashOf(tokenId) \|\| files` | Gap | an item whose hash sorts below the minted one (only one direction is tested) |
| 166 | ROR | `WorksHashing.itemHashCalldata(item) != _itemHashOf(tokenId) \|\| files` to `WorksHashing.itemHashCalldata(item) > _itemHashOf(tokenId) \|\| files` | Gap | an item whose hash sorts above the minted one (only one direction is tested) |
| 166 | ROR | `_itemHashOf(tokenId) \|\| files == 0` to `_itemHashOf(tokenId) \|\| files <= 0` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 166 | ROR | `WorksHashing.mediaHash(media) != item.mediaHash` to `WorksHashing.mediaHash(media) < item.mediaHash` | Gap | media whose commitment sorts below the item's media hash (only one direction is tested) |
| 166 | ROR | `WorksHashing.mediaHash(media) != item.mediaHash` to `WorksHashing.mediaHash(media) > item.mediaHash` | Gap | media whose commitment sorts above the item's media hash (only one direction is tested) |
| 166 | ROR | `\|\| media[0].sha256Hash != item.contentHash` to `\|\| media[0].sha256Hash > item.contentHash` | Gap | a primary file whose hash sorts below the item's content hash (only one direction is tested) |
| 173 | ROR | `for (uint256 i; i < files; ++i) {` to `for (uint256 i; i != files; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 173 | UOR | `for (uint256 i; i < files; ++i) {` to `for (uint256 i; i < files; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 179 | ROR | `if (declared != file.sha256Hash \|\| (file.role` to `if (declared > file.sha256Hash \|\| (file.role` | Gap | a media file whose declared hash sorts below the store's (only one direction is tested) |
| 179 | ROR | `file.sha256Hash \|\| (file.role == FileRole.PRIMARY) != (i == 0` to `file.sha256Hash \|\| (file.role <= FileRole.PRIMARY) != (i == 0` | Equivalent | `PRIMARY` is the first file role, so `<= PRIMARY` is `== PRIMARY` |
| 179 | ROR | `file.role == FileRole.PRIMARY) != (i == 0)) {` to `file.role == FileRole.PRIMARY) != (i <= 0)) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 192 | MIA | `if (!_isDefaultLicense(item.license)) {` to `if (true) {` | Equivalent | the default license stored as a custom one reads back the same: the CC0 pin is set once, in the constructor |
| 200 | MIA | `if (item.seedPolicy == SeedPolicy.ARTIST) _seeds[tokenId] = item.seed;` to `if (true) _seeds[tokenId] = item.seed;` | Defensive | an item without the ARTIST policy carries a zero seed (the package registry checks the seed), so the stored seed stays zero |
| 200 | ROR | `if (item.seedPolicy == SeedPolicy.ARTIST) _seeds[tokenId]` to `if (item.seedPolicy <= SeedPolicy.ARTIST) _seeds[tokenId]` | Equivalent | the registry and Stream refuse a seed under any policy but ARTIST, so the mutant writes zero to a zero slot |
| 200 | ROR | `if (item.seedPolicy == SeedPolicy.ARTIST) _seeds[tokenId]` to `if (item.seedPolicy >= SeedPolicy.ARTIST) _seeds[tokenId]` | Equivalent | the registry and Stream refuse a seed under any policy but ARTIST, so the mutant writes zero to a zero slot |
| 252 | ROR | `for (; next < files; ++next) {` to `for (; next != files; ++next) {` | Equivalent | the counter starts at the files already synced (at most the file count) and steps by one, so `!=` stops where `<` does |
| 252 | UOR | `for (; next < files; ++next) {` to `for (; next < files; next++) {` | Equivalent | pre- or post-increment of a loop counter |
| 264 | ROR | `if (next < files) {` to `if (next != files) {` | Equivalent | the loop leaves `next` at most the file count, so `!=` is `<` |
| 300 | ROR | `for (uint256 i; i < media.length; ++i) {` to `for (uint256 i; i != media.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 300 | UOR | `(uint256 i; i < media.length; ++i) {` to `(uint256 i; i < media.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 349 | ROR | `if (policy == SeedPolicy.ARTIST) {` to `if (policy <= SeedPolicy.ARTIST) {` | Equivalent | a seedless work has no stored seed, so reading `_seeds` gives the same zero |
| 351 | ROR | `} else if (policy == SeedPolicy.VRF) {` to `} else if (policy >= SeedPolicy.VRF) {` | Equivalent | `VRF` is the last seed policy, so `>= VRF` is `== VRF` |
| 379 | ROR | `if (nextKey == 0) return;` to `if (nextKey <= 0) return;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 384 | CR | `r.customLicense = !_isDefaultLicense(next` to `//r.customLicense = !_isDefaultLicense(next` | Equivalent | the default license is CC0, which cannot be relicensed away, so the flag never has to turn on again; turning it off only changes storage |
| 385 | MIA | `if (r.customLicense) _licenses[tokenId] = next;` to `if (true) _licenses[tokenId] = next;` | Equivalent | the default license stored as a custom one reads back the same: the CC0 pin is set once, in the constructor |
| 386 | CR | `else delete _licenses[tokenId];` to `else //delete _licenses[tokenId];` | Equivalent | the stale license slot is never read once the flag says the license is the default |
| 436 | ROR | `renderer.code.length == 0 \|\| DelegatedEOA.isDelegated(renderer` to `renderer.code.length <= 0 \|\| DelegatedEOA.isDelegated(renderer` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 489 | ROR | `if (used >= quota \|\| seen[uriHash]) revert` to `if (used == quota \|\| seen[uriHash]) revert` | Equivalent | each side's count stops at its quota and the quotas add up to the file's maximum, so the count never passes the quota |
| 523 | ROR | `bool found = index != 0;` to `bool found = index > 0;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 530 | ROR | `if (!found && list.length != 0) (found, index) = (true, 0)` to `if (!found && list.length > 0) (found, index) = (true, 0)` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 533 | ROR | `locator = index == NONE ? Locator(LocatorKind.ONCHAIN,` to `locator = index >= NONE ? Locator(LocatorKind.ONCHAIN,` | Equivalent | `NONE` is the largest uint256, so `>= NONE` is `== NONE` |
| 549 | ROR | `if (collectionId == 0 \|\| collectionId > IStream(stream` to `if (collectionId <= 0 \|\| collectionId > IStream(stream` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 559 | CR | `_open(tokenId);` to `//_open(tokenId);` | Defensive | an unopened work has no media, so the next check refuses the call (with another error) |
| 561 | ROR | `if (index != NONE && index >= _locators[tokenId][fileId].length` to `if (index < NONE && index >= _locators[tokenId][fileId].length` | Equivalent | `NONE` is the largest uint256, so `< NONE` is `!= NONE` |
| 563 | ROR | `_filePrefs[tokenId][fileId] = index == NONE ? 0 : index + 1;` to `_filePrefs[tokenId][fileId] = index >= NONE ? 0 : index + 1;` | Equivalent | `NONE` is the largest uint256, so `>= NONE` is `== NONE` |
| 576 | ROR | `return stored == 0 ? NONE : stored - 1;` to `return stored <= 0 ? NONE : stored - 1;` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 591 | ROR | `if (pinned == 0) _rendererCodeHashes[renderer]` to `if (pinned <= 0) _rendererCodeHashes[renderer]` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 592 | ROR | `else if (pinned != codeHash) revert InvalidRenderer(renderer` to `else if (pinned < codeHash) revert InvalidRenderer(renderer` | Gap | a renderer pinned again with a code hash that sorts above its first pin (only one direction is tested) |
| 661 | ROR | `WorksHashing.itemHashCalldata(item) != _itemHashOf(tokenId)) {` to `WorksHashing.itemHashCalldata(item) > _itemHashOf(tokenId)) {` | Gap | consents over an item whose hash sorts above the minted one (only one direction is tested) |
| 671 | ROR | `for (uint256 i; i < parties; ++i) {` to `for (uint256 i; i != parties; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 671 | UOR | `for (uint256 i; i < parties; ++i) {` to `for (uint256 i; i < parties; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 674 | MIA | `if (artistId == 0) artistId = uint256(uint160(account` to `if (true) artistId = uint256(uint160(account` | Defensive | a party with no artist ID: the registry reverts `UnknownArtist` first (coverage lists this branch too) |
| 674 | MIA | `if (artistId == 0) artistId = uint256(uint160(account` to `if (false) artistId = uint256(uint160(account` | Defensive | a party with no artist ID: the registry reverts `UnknownArtist` first (coverage lists this branch too) |
| 674 | MIA | `if (artistId == 0) artistId = uint256(uint160(account` to `if (!(artistId == 0)) artistId = uint256(uint160(account` | Defensive | a party with no artist ID: the registry reverts `UnknownArtist` first (coverage lists this branch too) |
| 674 | ROR | `if (artistId == 0) artistId = uint256(uint160(account` to `if (artistId <= 0) artistId = uint256(uint160(account` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 674 | ROR | `if (artistId == 0) artistId = uint256(uint160(account` to `if (artistId >= 0) artistId = uint256(uint160(account` | Gap | consent from a registered artist whose authority is not the party account (the mutant looks every party up as unregistered) |
| 674 | RR | `if (artistId == 0) artistId = uint256(uint160(account));` to `if (artistId == 0) revert();` | Defensive | a party with no artist ID: the registry reverts `UnknownArtist` first (coverage lists this branch too) |
| 723 | ROR | `textFileId) : store.sha256Of(textFileId) == 0) {` to `textFileId) : store.sha256Of(textFileId) <= 0) {` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 749 | ROR | `if (info.length >= 4 && bytes4(info) == IContentStore.ContentFileUn...` to `if (info.length > 4 && bytes4(info) == IContentStore.ContentFileUnk...` | Equivalent | the store's `ContentFileUnknown` carries the file ID, so its revert data is 36 bytes and `> 4` is `>= 4` |
| 760 | MIA | `if (info.length < 0xc0) revert UnknownRecordFile(fileId` to `if (false) revert UnknownRecordFile(fileId` | Defensive | the trusted content store always answers a full `FileInfo` (coverage lists this branch too) |
| 760 | ROR | `if (info.length < 0xc0) revert UnknownRecordFile(fileId` to `if (info.length <= 0xc0) revert UnknownRecordFile(fileId` | Equivalent | the store's answer carries the MIME type after five words, so it is always longer than 0xc0 bytes |
| 766 | ROR | `Limits.MAX_RECORD_BYTES \|\| encoding != uint256(IContentStore.Encodi...` to `Limits.MAX_RECORD_BYTES \|\| encoding > uint256(IContentStore.Encodin...` | Equivalent | `Identity` is the first encoding, so `> Identity` is `!= Identity` |
| 778 | ROR | `if (encoding == uint256(IContentStore.Encoding.Identity` to `if (encoding <= uint256(IContentStore.Encoding.Identity` | Equivalent | `Identity` is the first encoding, so `<= Identity` is `== Identity` |
| 805 | ROR | `for (uint256 i; i < files; ++i) {` to `for (uint256 i; i != files; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 805 | UOR | `for (uint256 i; i < files; ++i) {` to `for (uint256 i; i < files; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 839 | ROR | `if (chars == 0 \|\| (lasts >> uint8(uri[uri.length` to `if (chars <= 0 \|\| (lasts >> uint8(uri[uri.length` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 839 | ROR | `uint8(uri[uri.length - 1])) & 1 == 0) revert InvalidLocator();` to `uint8(uri[uri.length - 1])) & 1 <= 0) revert InvalidLocator();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 840 | AOR | `uint256 i = start; i < uri.length - 1; ++i) {` to `uint256 i = start; i < uri.length / 1; ++i) {` | Equivalent | the loop then also checks the last character against the charset, which contains the last character's set |
| 840 | AOR | `uint256 i = start; i < uri.length - 1; ++i) {` to `uint256 i = start; i < uri.length * 1; ++i) {` | Equivalent | the loop then also checks the last character against the charset, which contains the last character's set |
| 840 | ROR | `for (uint256 i = start; i < uri.length - 1; ++i) {` to `for (uint256 i = start; i <= uri.length - 1; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 840 | ROR | `for (uint256 i = start; i < uri.length - 1; ++i) {` to `for (uint256 i = start; i != uri.length - 1; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 840 | UOR | `i = start; i < uri.length - 1; ++i) {` to `i = start; i < uri.length - 1; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 841 | ROR | `((chars >> uint8(uri[i])) & 1 == 0) revert InvalidLocator();` to `((chars >> uint8(uri[i])) & 1 <= 0) revert InvalidLocator();` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 852 | MIA | `if (kind == LocatorKind.NONE) return (false, 0);` to `if (false) return (false, 0);` | Equivalent | no locator has kind `NONE` (`addLocator` checks the kind), so NONE never matches either way |
| 852 | ROR | `if (kind == LocatorKind.NONE) return (false,` to `if (kind <= LocatorKind.NONE) return (false,` | Equivalent | `NONE` is the first locator kind, so `<= NONE` is `== NONE` |
| 853 | ROR | `if (kind == LocatorKind.ONCHAIN) return (onChain,` to `if (kind >= LocatorKind.ONCHAIN) return (onChain,` | Equivalent | `ONCHAIN` is the last locator kind, so `>= ONCHAIN` is `== ONCHAIN` |
| 854 | ROR | `for (uint256 i; i < list.length; ++i) {` to `for (uint256 i; i != list.length; ++i) {` | Equivalent | a loop counter that steps by one: `<` and `!=` stop at the same point |
| 854 | UOR | `for (uint256 i; i < list.length; ++i) {` to `for (uint256 i; i < list.length; i++) {` | Equivalent | pre- or post-increment of a loop counter |
| 857 | CR | `return (false, 0);` to `//return (false, 0);` | Equivalent | the function returns `(false, 0)` by default when the last statement is gone |
| 873 | ROR | `if (minted != 0) core.emitMetadataUpdate(1,` to `if (minted > 0) core.emitMetadataUpdate(1,` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |
| 875 | MIA | `if (editions != address(0)) IEditions(editions).notifyAllUpdated(` to `if (true) IEditions(editions).notifyAllUpdated(` | Defensive | Stream's editions are bound at genesis, before any refresh can run |
| 879 | ROR | `if (dependency.code.length == 0 \|\| DelegatedEOA.isDelegated(dependency` to `if (dependency.code.length <= 0 \|\| DelegatedEOA.isDelegated(dependency` | Equivalent | unsigned: `== 0` and `<= 0` (or `!= 0` and `> 0`) are the same test |

</details>
