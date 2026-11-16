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
| `Editions.sol` | The token: `createEdition`, minting and burning for admitted adapters, the creator's cap, the binding and the seal at settlement, the price record of every mint, royalties, license and `uri` from the master, ERC-4906 refreshes. Implements [`IEditions`](../interfaces/IEditions.sol) and [`IMintTarget`](../interfaces/IMintTarget.sol). Permanent: never redeployed, and its interface is frozen at launch. |
| `EditionRules.sol` | Internal library: the one validity rule for edition terms, applied by the package registry at `consume` and by `Editions` at `createEdition`. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `createEdition(workId, item)`: checks the master's exact stored item and Stream's content record (permanent facts only, never the mint policy), locks the `PRODUCT_EDITIONS` economics and links both sides | ED-1 to ED-4, ED-7 |
| Admitted sale adapters | `bindMinter` when a sale opens (before the edition exists if need be), `mint` with `abi.encode(currency, unitPrice)`, `sealSupply` when the sale settles (the bound adapter, even if removed), `burn`, `settlePrimary` (a no-op); `primaryTerms` (view) when opening a sale | ED-5, ED-6, ED-8, ED-25, ED-26 |
| The bound `WorkRecords` | `setRoyaltyRate` (with the master's re-rate, up or down), `notifyMasterUpdated`; `notifyAllUpdated` (also from Stream) | ED-7 |
| The network (PARAMETER_SETTER, 24 hours) | `lowerFeeShare(editionId, share)`: lowers a locked edition's fee share, never raises it, and derives its royalty receiver again (R9) | ED rules (paste text in the lane report) |
| Governance | `setAdmittedMinter`, `setContractURI`, `setOwner`; the genesis bind `bindWorkRecords` | [Role matrix: Editions](../../docs/audit/roles.md#editions) |
| Anyone (views) | `edition`, `masterOf`, `contentHashOf`, `exists`, `royaltyInfo`, `licenseOf`, `uri`, `name`, `symbol` | [Reading a work](../../docs/integrators/reading-a-work.md) |

The create flow, with every check in order, is under
[Create an edition](../../docs/spec/editions-and-sales.md#create-an-edition); events are under
[Editions](../../docs/integrators/events-and-indexing.md#editions).

## Developer notes

Behaviour is owned by [Editions and sales](../../docs/spec/editions-and-sales.md): the seal at
settlement (ED-25), the price record of every mint (ED-26), the terms logged at creation
(ED-27), the gas rule for every call out (ED-28), who mints and burns and up to what count
(ED-5, ED-6, ED-8). What follows is only what a change to the code must keep.

- **Storage layout (QUALITY-5).** An edition is one packed `Record` behind the `Edition` view;
  a mint reads only the seller's word (the artist's too for a removed adapter), and the first
  mint and a seal write no new slot. Changing the struct moves the `createEdition` and mint
  slot counts that [`GasReport.t.sol`](../../test/integration/GasReport.t.sol) and
  `EditionsGasReport.t.sol` assert exactly
  ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)).
- **`EditionRules`** is the one terms rule, shared with the package registry: keep both callers
  on it.
- **`mint` returns only the sale kind (QUALITY-2)** and reads nothing from Stream; keep record
  reads and registry calls off the mint path.
- **Wiring.** Stream is immutable here and checked at construction; the economics resolver is
  read from Stream on every use; the artist registry once at deployment; the mint policy never.
- **Bytecode:** current figures in the [audit scope](../../docs/audit/scope.md#products-and-sales).
- **Tests:** `forge test --match-path 'test/editions/**'` (unit, `EditionsSeal.t.sol`,
  `EditionsGasRule.t.sol`, the invariant suite, `EditionsGasReport.t.sol`); end to end,
  [`MasterEdition.t.sol`](../../test/integration/MasterEdition.t.sol) and the edition auction's
  flows in [`test/integration/`](../../test/integration/README.md); coverage and mutation in
  [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions) (with §3 exclusivity and §8
license), [ADR 0003](../../docs/adr/0003-build-time-decisions.md),
[ADR 0005](../../docs/adr/0005-stream-editions-auction.md); the
[differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs) (`ED-*` and
`EA-*` rows), [invariants](../../docs/audit/invariants.md),
[known limitations](../../docs/audit/known-limitations.md#the-edition-auction).
