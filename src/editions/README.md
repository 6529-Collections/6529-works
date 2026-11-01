# editions

6529 Stream Editions (named 6529 Editions before ADR 0005; "6529 Stream Editions",
`STREAMEDITIONS`): the one shared ERC-1155 of editions. Each edition is anchored by a settled
6529 Stream work of kind `EDITION_MASTER`, shares its ID, and renders its media and license.
Copies are minted by any sale adapter governance admits whose sale kind the edition's terms
name, rc.2's being the uniform-price edition auction in [`sales/`](../sales/README.md)
([ADR 0005](../../docs/adr/0005-stream-editions-auction.md)); a new sale method is a new adapter,
never a new Editions. The rules are in
[Editions and sales](../../docs/spec/editions-and-sales.md) (`ED-*`, and `EA-*` for the
auction).

## Files

| File | What it is |
| --- | --- |
| `Editions.sol` | The token: `createEdition`, minting and burning for admitted adapters, the creator's cap and the first-minter binding, royalties, license and `uri` from the master, ERC-4906 refreshes. Implements [`IEditions`](../interfaces/IEditions.sol) and [`IMintTarget`](../interfaces/IMintTarget.sol). |
| `EditionRules.sol` | Internal library: the one validity rule for edition terms, applied by the package registry at `consume` and by `Editions` at `createEdition`. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `createEdition(workId, item, packageRoot, proof)`: proves the master's exact item under a registered root, locks the `PRODUCT_EDITIONS` economics, claims the content hash and links both sides | ED-1 to ED-4, ED-7 |
| Admitted sale adapters | `bindMinter` when a sale opens (before the edition exists if need be), `mint`, `burn`, `settlePrimary` (a no-op); `primaryTerms` (view) when opening a sale | ED-5, ED-6, ED-8 |
| The bound `WorkRecords` | `setRoyaltyRate` (with the master's re-rate), `notifyMasterUpdated`; `notifyAllUpdated` (also from Stream) | ED-7 |
| Governance | `setAdmittedMinter`, `setContractURI`, `setOwner`; the genesis bind `bindWorkRecords` | [Role matrix: Editions](../../docs/audit/roles.md#editions) |
| Anyone (views) | `edition`, `masterOf`, `contentHashOf`, `exists`, `royaltyInfo`, `licenseOf`, `uri`, `name`, `symbol` | [Reading a work](../../docs/integrators/reading-a-work.md) |

The create flow, with every check in order, is under
[Create an edition](../../docs/spec/editions-and-sales.md#create-an-edition); events are under
[Editions](../../docs/integrators/events-and-indexing.md#editions).

## Developer notes

- **Storage layout (QUALITY-5).** An edition is a packed `Record` behind the `Edition` view:
  the content hash; the seller with the creator's cap, the `uint48` minted count and the bound
  adapter's 16-bit ID; the royalty receiver with the rate; the artist ID with the fee share; the
  fee recipient; and the sale kind, currency and params. The edition auction's kind, ETH and
  empty params are stored as zero, so its edition writes five words when its terms name a fee
  recipient, and another sale method pays for its own. The first mint writes no new slot: the
  count and the binding share the seller's word. `bindMinter` before creation writes the
  seller's, royalty and fee words early (the binding and the economics snapshot), and
  `createEdition` then writes only the rest. Changing the struct changes the
  `createEdition` and mint slot counts, which
  [`GasReport.t.sol`](../../test/integration/GasReport.t.sol) and `EditionsGasReport.t.sol`
  assert exactly ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)).
- **Generic minting (ADR 0005, owner decision 14).** `EditionTerms` carries no size, format or
  price; `EditionRules` checks only a nonzero sale kind and at most 1,024 bytes of params, and
  the kind's adapter validates its currency and params when it opens a sale.
- **`mint` returns only the sale kind (QUALITY-2).** An adapter applies the terms it locked
  from `primaryTerms` when its sale opened; building full terms in `mint` would add the record
  reads and an artist-registry call to every mint.
- **Minting reads nothing from Stream.** A master with an edition has settled and Stream never
  burns a settled token, so the cap and binding checks are local. Burned copies still count
  toward the cap.
- **Minter status is three-valued** (never, admitted, removed), so a removed adapter can still
  burn what it holds and call the no-op `settlePrimary`, and keeps minting the editions
  bound to it (its winners claim after the seller was paid; ADR 0005 §6). It binds nothing new.
  Its binding ID survives removal and re-admission; at most 65,535 adapters are ever admitted.
- **Binding at open (ADR 0005 §6).** An adapter binds an edition with `bindMinter` when its sale
  opens, so a second adapter of the same kind cannot open the same edition. Before creation the
  item proves the edition's kind, and the binding snapshots the `PRODUCT_EDITIONS` economics
  that `createEdition` then keeps (`_lockTerms`), so the edition reports the split its sale
  paid.
- **Wiring.** Stream is immutable here: the constructor checks it (code, no EIP-7702
  delegation, ERC-165 `IStream`, the reviewed code hash). The package registry, economics
  resolver and artist registry are read from Stream on every use (`packageRegistry()`,
  `economics()`, `artistRegistry()`), so a governed replacement there (owner decision 16)
  reaches Editions at once. No edition exists before genesis binds `WorkRecords`
  (`WorkRecordsUnbound`).
- **Bytecode:** well inside EIP-170; current figures in the
  [audit scope](../../docs/audit/scope.md#products-and-sales).
- **Tests:** `forge test --match-path 'test/editions/**'` (unit, the edition invariant suite and
  `EditionsGasReport.t.sol`); end to end, [`MasterEdition.t.sol`](../../test/integration/MasterEdition.t.sol)
  and the edition auction's flows in [`test/integration/`](../../test/integration/README.md).
  Coverage and mutation testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions) (with §3 exclusivity and §8
license), [ADR 0003](../../docs/adr/0003-build-time-decisions.md),
[ADR 0005](../../docs/adr/0005-stream-editions-auction.md); the
[differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs) (`ED-*` and
`EA-*` rows), [invariants](../../docs/audit/invariants.md),
[known limitations](../../docs/audit/known-limitations.md#the-edition-auction).
