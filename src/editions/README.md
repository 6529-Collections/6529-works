# editions

6529 Editions: the one shared ERC-1155 of editions. Each edition is anchored by a settled 6529
Stream work of kind `EDITION_MASTER`, shares its ID, renders its media and license, and is sold
by the shared fixed-price and Dutch adapters in [`sales/`](../sales/README.md). The rules are
in [Editions and sales](../../docs/spec/editions-and-sales.md) (`ED-*`).

## Files

| File | What it is |
| --- | --- |
| `Editions.sol` | The token: `createEdition`, minting and burning for admitted adapters, supply and window, royalties, license and `uri` from the master, ERC-4906 refreshes. Implements [`IEditions`](../interfaces/IEditions.sol) and [`IMintTarget`](../interfaces/IMintTarget.sol). |
| `EditionRules.sol` | Internal library: the one validity rule for edition terms, applied by the package registry at `consume` and by `Editions` at `createEdition`. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `createEdition(workId, item, packageRoot, proof)`: proves the master's exact item under a registered root, locks the `PRODUCT_EDITIONS` economics, claims the content hash and links both sides | ED-1 to ED-4, ED-7 |
| Admitted sale adapters | `mint`, `burn`, `markPrimarySettled`; `primaryTerms` (view) when opening a sale | ED-5, ED-6, ED-8 |
| The bound `WorkRecords` | `setRoyaltyRate` (with the master's re-rate), `notifyMasterUpdated`; `notifyAllUpdated` (also from Stream) | ED-7 |
| Governance | `setAdmittedMinter`, `setContractURI`, `setOwner`; the genesis bind `bindWorkRecords` | [Role matrix: Editions](../../docs/audit/roles.md#editions) |
| Anyone (views) | `edition`, `masterOf`, `formatOf`, `contentHashOf`, `exists`, `royaltyInfo`, `licenseOf`, `uri` | [Reading a work](../../docs/integrators/reading-a-work.md) |

The create flow, with every check in order, is under
[Create an edition](../../docs/spec/editions-and-sales.md#create-an-edition); events are under
[Editions](../../docs/integrators/events-and-indexing.md#editions).

## Developer notes

- **Storage layout (QUALITY-5).** An edition is a packed `Record` of nine words behind the
  unchanged `Edition` view: the content hash; seller with size, format and kind; royalty
  receiver with window and rate; artist ID with the minted count and fee share; fee recipient
  with the window start; currency (zero for ETH); price; and a Dutch curve kept decoded in two
  words. Creating a priced ETH edition with a fee writes six of them, a Dutch one two more, and
  the first mint writes none because `minted` shares the artist ID's word. An OPEN edition on
  terms without a fee recipient writes the fee-recipient word at its first mint. Changing the
  struct changes `createEdition` and `purchase` slot counts, which
  [`GasReport.t.sol`](../../test/integration/GasReport.t.sol) asserts exactly
  ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)).
- **`mint` returns only the sale kind (QUALITY-2).** The adapters apply the terms they locked
  from `primaryTerms` at `openSale`; building full terms in `mint` would add the record reads and
  an artist-registry call to every purchase. Keep it that way, or the purchase rows of the gas
  report move.
- **Minting reads nothing from Stream.** A master with an edition has settled and Stream never
  burns a settled token, so supply and window checks are local. Burned copies still count
  toward `size`.
- **Minter status is three-valued** (never, admitted, removed), so a removed adapter can still
  burn what it holds and call the no-op `markPrimarySettled`.
- **Wiring is immutable.** The constructor checks Stream (code, no EIP-7702 delegation, ERC-165
  `IStream`, the reviewed code hash) and reads the package registry, economics resolver and
  artist registry from it. No edition exists before genesis binds `WorkRecords`
  (`WorkRecordsUnbound`).
- **Bytecode:** well inside EIP-170; current figures in the
  [audit scope](../../docs/audit/scope.md#products-and-sales).
- **Tests:** `forge test --match-path 'test/editions/**'` (unit, the edition invariant suite and
  `EditionsGasReport.t.sol`); the end-to-end path is
  [`MasterEdition.t.sol`](../../test/integration/MasterEdition.t.sol). Coverage and mutation
  testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions) (with §3 exclusivity and §8
license), [ADR 0003](../../docs/adr/0003-build-time-decisions.md); the
[differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs) (`ED-*` rows),
[invariants](../../docs/audit/invariants.md), [known limitations](../../docs/audit/known-limitations.md#sales-and-auctions).
