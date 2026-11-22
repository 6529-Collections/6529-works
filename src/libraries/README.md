# libraries

Shared internal libraries compiled into the contracts that use them: signature verification,
dependency install checks, EIP-7702 detection, bounded external reads, SSTORE2 chunk storage, JSON escaping,
UTF-8 validation and the recognition of protocol contracts that cannot be paid. Every function
is `internal`, so nothing here is deployed or linked, and nothing counts against the
five-linked-library budget. The rules these libraries enforce are stated where they are used,
in the [specification](../../docs/spec/README.md); the users of each library are listed in the
[audit scope](../../docs/audit/scope.md#internal-libraries).

## Files

| File | What it does | Main users |
| --- | --- | --- |
| `SignatureVerifier.sol` | The one signature check: low-s ECDSA (65 bytes, or 64 in ERC-2098 form), EIP-7702 delegated accounts (`ecrecover` first, then ERC-1271 through the delegate), ERC-1271 forwarding all gas (a shortfall reverts) with exactly one 32-byte magic word, signatures of at most 65,536 bytes. It tracks no replay. `check` and `checkDeadline` revert with the shared `InvalidSignature(signer)` and `SignatureExpired(deadline)`. | Every signed payload: curation, identity, records, statement relay, releases |
| `Dependency.sol` | The one install check for a contract another contract calls, binds, lists or pins: code, not an EIP-7702 delegated account, ERC-165 for its role where implemented, and the pinned code hash (`InvalidDependency`); and the use-time check of a pinned code hash (`DependencyCodeChanged`). | Every install, bind and listing check; every code-hash pin re-checked at use |
| `DelegatedEOA.sol` | Detects an EIP-7702 delegation designator (`0xef0100 ‖ address`). | `Dependency`, `SignatureVerifier` |
| `BoundedCall.sol` | Two families of external call. **Forward-all** (permanent contracts; no gas number): `tryReadAll`, `tryCallAll`, `tryReadWordAll` and the ERC-165 probes `supportsERC165`, `supportsInterface`, `supportsInterfaceUnchecked`; each forwards all the gas EIP-150 allows, copies a bounded return, and reverts with `BoundedCallShortfall(target)` when a failed call left at most 1/8 of the gas held before it. **Fixed-gas** (replaceable contracts): `tryRead`, `read`, `readWord`, `readString` with a gas and return-size cap that revert when the caller cannot forward the gas in full (`BoundedCallInsufficientGas`), and `hasSufficientGas`. | Forward-all: Stream, WorkRecords, Editions, content store, artist registry, split ledger, revenue escrow, statement log, the renderer (pinned by finalized works), the edition auction's lens, signature verifier, dependency and protocol-contract checks. Fixed-gas: consolidation adapter, English auction, token transfers and revenue payments |
| `SSTORE2.sol` | Stores a chunk as the code of a CREATE2 contract and reads it back verified against its keccak256. | Content store, renderer |
| `JsonEscape.sol` | JSON string escaping, a word at a time (`escape`). Script text is neutralized by `HtmlScript`, not here. | Renderer |
| `Utf8.sol` | RFC 3629 UTF-8 validation, resumable across chunks. | Renderer, Stream, statement log |
| `ProtocolContracts.sol` | Whether an address declares, by ERC-165, the interface of a protocol contract that can neither pull a payout nor accept an ETH payment; a probe that runs short reverts, never answering "not one". | Artist registry (payout validation), economics resolver (fee recipient) |

## Developer notes

- **Replay is the caller's job.** `SignatureVerifier` accepts a signature and its ERC-2098 form,
  so callers key replay protection on a nonce or a digest, never on signature bytes.
- **Fail closed on gas.** `BoundedCall` reverts rather than report a starved call as failed or
  empty. Forward-all is for permanent contracts and the renderer, fixed-gas for replaceable
  callers: the [specification's conventions](../../docs/spec/README.md#conventions) (DSP-26) and
  RND-6, RND-7 in [Rendering and tokenURI](../../docs/spec/rendering-and-tokenuri.md#rules-and-invariants).
- **Bounded return data, always.** The gas rule removes the gas cap, not the return-data bound:
  every call to code the caller does not control passes a `maxReturn` sized to the answer it
  accepts, so a callee cannot make its caller copy an unbounded answer.
- **Why 1/8, and the residuals:** `BoundedCall`'s NatSpec.
- **Stress harness.** [`test/helpers/GasRule.sol`](../../test/helpers/GasRule.sol): wrap any
  dependency in a `Burner` (each call costs a multiple of a base) and assert, with
  `GasRuleAssertions`, the same answer at 1x to 100x and a shortfall that never answers. Tests
  that use it are named `test_GasRule_*`.
- **What `ProtocolContracts` cannot see** (codeless addresses, contracts declaring none of the
  listed interfaces): LIM-ECO-4 and LIM-ID-12 in
  [known limitations](../../docs/audit/known-limitations.md).
- **Hot paths.** `Utf8`, `JsonEscape` and `SSTORE2` sit inside `tokenURI`; rerun
  `test/integration/TokenUriBudget.t.sol` after any change here.
- **Tests:** `forge test --match-path 'test/libraries/**'` (unit and fuzz tests per library;
  `BoundedCallForwardAll.t.sol` for the forward-all family, `GasRuleLibraries.t.sol` for the
  stress of its library users).
  Halmos proofs of `BoundedCall`, `Utf8` and `JsonEscape` are in
  [`test/symbolic/`](../../test/symbolic/); how to run them, and coverage and mutation
  testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001](../../docs/adr/0001-v1-scope.md) §11 ("Hardening": one shared signature library),
§8 (content storage and the renderer's bounded read) and §17 (reuse plan);
[trust assumptions](../../docs/audit/trust-assumptions.md),
[trust assumptions](../../docs/audit/trust-assumptions.md).
