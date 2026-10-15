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
| `SignatureVerifier.sol` | The one signature check: low-s ECDSA (65 bytes, or 64 in ERC-2098 form), EIP-7702 delegated accounts (`ecrecover` first, then ERC-1271 through the delegate), ERC-1271 with a fixed gas cap and exactly one 32-byte magic word, signatures of at most 4,096 bytes. It tracks no replay. `check` and `checkDeadline` revert with the shared `InvalidSignature(signer)` and `SignatureExpired(deadline)`. | Every signed payload: curation, identity, records, statement relay, phase consents, releases |
| `Dependency.sol` | The one install check for a contract another contract calls, binds, lists or pins: code, not an EIP-7702 delegated account, ERC-165 for its role where implemented, and the pinned code hash (`InvalidDependency`); and the use-time check of a pinned code hash (`DependencyCodeChanged`). | Every install, bind and listing check; every code-hash pin re-checked at use |
| `DelegatedEOA.sol` | Detects an EIP-7702 delegation designator (`0xef0100 ‖ address`). | `Dependency`, `SignatureVerifier` |
| `BoundedCall.sol` | A `staticcall` with a fixed gas and return-size cap that reverts when the caller cannot forward the gas in full (`BoundedCallInsufficientGas`), and `hasSufficientGas`, the same check for callers that make their own fixed-gas calls. | Renderer, consolidation adapter, statement log, auction, claim router, token transfers |
| `SSTORE2.sol` | Stores a chunk as the code of a CREATE2 contract and reads it back verified against its keccak256. | Content store, renderer |
| `JsonEscape.sol` | JSON string escaping, a word at a time (`escape`). Script text is neutralized by `HtmlScript`, not here. | Renderer |
| `Utf8.sol` | RFC 3629 UTF-8 validation, resumable across chunks. | Renderer, Stream, statement log |
| `ProtocolContracts.sol` | Whether an address declares, by ERC-165, the interface of a protocol contract that can neither pull a payout nor accept an ETH payment. | Artist registry (payout validation), economics resolver (fee recipient) |

## Developer notes

- **Replay is the caller's job.** `SignatureVerifier` accepts a signature and its ERC-2098 form,
  so callers key replay protection on a nonce or a digest, never on signature bytes.
- **Fail closed on gas.** `BoundedCall` reverts rather than report a starved read as a failed or
  empty one (RND-7 in [Rendering and tokenURI](../../docs/spec/rendering-and-tokenuri.md#rules-and-invariants));
  callers size their own caps and reserves. Changing a cap changes the gas a caller must supply,
  which the integrator guides quote.
- **What `ProtocolContracts` cannot see.** An address without code (including a split wallet's
  predicted address before deployment) and contracts that declare none of the listed interfaces
  (content store, statement log, AccessManager, renderer, curation verifier, entropy module)
  are not recognised; see LIM-ECO-4 and LIM-ID-12 in
  [known limitations](../../docs/audit/known-limitations.md).
- **Hot paths.** `Utf8`, `JsonEscape` and `SSTORE2` sit inside `tokenURI`, whose 8M Prague gas
  budget is proven by `test/integration/TokenUriBudget.t.sol`; rerun it after any change here.
- **Tests:** `forge test --match-path 'test/libraries/**'` (unit and fuzz tests per library).
  Halmos proofs of `BoundedCall`, `Utf8` and `JsonEscape` are in
  [`test/symbolic/`](../../test/symbolic/); how to run them, and coverage and mutation
  testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001](../../docs/adr/0001-v1-scope.md) §11 ("Hardening": one shared signature library),
§8 (content storage and the renderer's bounded read) and §17 (reuse plan);
[trust assumptions](../../docs/audit/trust-assumptions.md),
[threat model](../../docs/audit/threat-model.md).
