# interfaces

The external surfaces of every v1 contract and the types they exchange. Contracts depend on
these files, not on each other's implementations: a sale adapter knows a token only through
`IMintTarget`, which `IStream` and `IEditions` extend. What each function does is specified by
area in the [specification](../../docs/spec/README.md); the ABIs, ERC-165 interface IDs and
EIP-712 domains integrators need are in
[ABIs and interface IDs](../../docs/integrators/abis-and-interface-ids.md).

## Files

| Path | What it holds |
| --- | --- |
| `I*.sol` | One interface per contract: `IStream`, `IWorkRecords`, `IEditions`, `IMintTarget`, `ISaleAdapter`, `IEnglishAuction` (with `IEnglishAuctionClock`, its integration view outside ERC-165), `IUniformEditionAuction` (with `IUniformEditionAuctionLens` and `IUniformEditionAuctionStorage`, the edition auction's read side and storage words), `IPackageRegistry`, `ICurationVerifier`, `IArtistRegistry`, `IArtistRoleResolver`, `IStatementLog`, `IContentStore`, `IDependencyRegistry`, `IRenderer`, `IEntropyModule`, `IEconomicsResolver`, `IFederationRegistry` (v1.1, no implementation in v1) |
| [`types/`](types/) | Shared structs and constants: `PackageTypes` (the package item), `SaleTypes`, `EconomicsTypes`, `IdentityTypes`, `ContentTypes`, `HashRef`, `StatementKinds`, `Limits` (every bound on user-supplied arrays), `Typehashes` (EIP-712 type strings and domain names), `WorksHashing` (item hashes, package leaves, media and record hashes) and `StepLadder` (the edition auction's price ladder) |
| [`external/ISignatureTransfer.sol`](external/ISignatureTransfer.sol) | The Permit2 functions the sale adapters call |
| [`../economics/interfaces/`](../economics/interfaces/) | The economics module's own interfaces (`ISplitFactory`, `ISplitWallet`, `IAssetAllowlist`, `IRevenueEscrow`, `IReleaseVerifier`, `IClaimRouter`, `IArtistPayoutResolver`) |

## Developer notes

- **Interface IDs are pinned.** [`InterfacesCompile.t.sol`](../../test/interfaces/InterfacesCompile.t.sol)
  pins every `type(I).interfaceId`, and `tools/check_docs_facts.py` checks the IDs published in
  the integrator docs against it (and, with `--artifacts out`, against the compiled selectors).
  Adding, removing or retyping a function changes the ID: update the pin and the docs in the
  same PR, and expect every ERC-165 install check that names the interface to change with it.
- **Hashes have golden vectors.** `WorksHashing` and `Typehashes` are checked against
  independently computed values in [`WorksHashing.t.sol`](../../test/interfaces/WorksHashing.t.sol)
  and [`Typehashes.t.sol`](../../test/interfaces/Typehashes.t.sol) (rule CUR-20 in
  [Curation](../../docs/spec/curation.md#rules-and-invariants)). Signers, the uploader and
  off-chain tooling compute the same values, so a change here is a breaking change for them.
- **Roles in NatSpec are hints.** Some governed functions name the role their selector is meant
  to map to; the binding mapping is [`config/genesis.example.json`](../../config/genesis.example.json),
  rendered as the [role and permission matrix](../../docs/audit/roles.md).
- **Events and errors.** Event signatures and topic0 values are owned by
  [Events and indexing](../../docs/integrators/events-and-indexing.md), which the docs checker
  verifies against the ABIs; rename an event there in the same PR.
- **Size.** Interfaces and types count toward the nSLOC budget
  ([scope](../../docs/audit/scope.md#interfaces-and-shared-types)).
- **Tests:** `forge test --match-path 'test/interfaces/**'`; the whole suite is described in
  [Testing](../../docs/testing/README.md).

## See also

[ADR 0001](../../docs/adr/0001-v1-scope.md) (scope),
[architecture overview](../../docs/architecture.md), [glossary](../../docs/glossary.md).
