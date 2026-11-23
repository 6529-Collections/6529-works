# editions

6529 Stream Editions (`6529STREAMEDITIONS`): the one shared ERC-1155 of editions. Each edition is
anchored by a 6529 Stream work of kind 1 (edition master) and shares its ID. Since
[ADR 0010](../../docs/adr/0010-plain-permanent-core.md) the token is the plain permanent core in
[`src/core/`](../core/): `EditionsBase.sol` (the rules) and `StreamEditions6529.sol` (its minter
list and TERMS slot). The rules that decide when an edition exists and on what economics live in the
replaceable edition sale contract, the uniform-price edition auction in
[`sales/`](../sales/README.md) ([ADR 0005](../../docs/adr/0005-stream-editions-auction.md)).

## Files

| File | What it is |
| --- | --- |
| [`../core/EditionsBase.sol`](../core/EditionsBase.sol) | The permanent ERC-1155, shared with each Independent Stream artist's editions: `create`, `mint`, `seal`, `rebind`, `burn`, `setRoyalty`, `royaltyInfo`, `uri`. Implements [`IEditions`](../interfaces/core/IEditions.sol). |
| [`../core/StreamEditions6529.sol`](../core/StreamEditions6529.sol) | 6529 Stream Editions: `EditionsBase` with `Modules` (minters and the TERMS slot), the network as admin. |
| `EditionRules.sol` | Internal library: the one validity rule for edition terms, applied by the package registry when it admits an edition master. |

## Entry points

| Caller | Calls | Rule |
| --- | --- | --- |
| An active minter (an edition sale contract) | `create(editionId, maxSupply, royaltyReceiver, royaltyRate)`: once, for a master that exists and is not burned; the caller becomes the edition's only minter | An edition is created once |
| The edition's minter | `mint(to, editionId, amount, unitPrice)` within the maximum; `seal(editionId, supply)` once, between the count minted and the maximum | A sealed maximum never grows; burned copies still count |
| A removed minter | `mint` only for editions it sealed before its removal; it seals nothing | Winners of a sealed sale are still served; an edition with no seal waits for `rebind` |
| The TERMS module | `setRoyalty`; `emitMetadataUpdate` (also the master's RECORDS module) | |
| The network | `rebind` an edition with no seal, once `rebindDelay` has passed since its minter's removal; `setRebindDelay`; the module and minter functions; `setOwner`, `setContractURI` | `rebindDelay` is the network's setting, read when a rebind is attempted |
| A holder | `burn` its own copies; transfers and approvals (OpenZeppelin's) | No module or minter can move a copy |

## Developer notes

- **Permanent code is plain**: OpenZeppelin's ERC-1155, one struct per edition (two slots), no
  assembly, no call out on a transfer except the receiver's acceptance check. `royaltyInfo`
  reads storage only.
- **Waiting periods are settings**: `rebindDelay` (14 days at launch) and `moduleDelay` (7 days
  at launch) are the network's, changed at once, zero allowed. Do not write either as a fixed
  promise.
- **Logs rebuild the state**: every change emits an event; `ContractURISet` carries the URI
  that ERC-7572's `ContractURIUpdated` does not. The replay test is
  [`LogReplayEditions.t.sol`](../../test/replay/LogReplayEditions.t.sol).
- **Tests**: `test/core/Editions*.t.sol` (unit, fuzz, hostile modules and minters,
  invariants), `test/symbolic/EditionsCoreSymbolic.t.sol` (Halmos),
  `test/replay/LogReplayEditions.t.sol`.
