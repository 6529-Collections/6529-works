# core

The permanent contracts of 6529 Works ([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)).
They hold only what must never change: who owns which token and the collection's address; the
facts of a finished work; the network's settings for its waiting periods. Every rule (sale
terms, fee shares, who may edit a record and when, identity, rescue routing) lives in a
replaceable module that the network installs in a named slot. The code is plain OpenZeppelin
style: one struct per thing, no assembly, no hand-packed words, no gas numbers, no
`try`/`catch`. The frozen interfaces are in [`interfaces/core/`](../interfaces/core/).

## Files

| File | What it is |
| --- | --- |
| `Modules.sol` | `ModuleSlots` (named module slots: announce, install after `moduleDelay`, remove at once) and `Modules` (the same plus the minter list). Shared by every permanent contract with modules. |
| `StreamBase.sol` | The ERC-721 of works: mint by a minter with checked facts, the first sale's outcome, burn in sale custody, `rescue`, royalties set by the TERMS module, `rendererOf`. Six hooks at the end decide who mints, where the modules are and who administers; they are frozen. |
| `Stream6529.sol` | 6529 Stream: `StreamBase` + `Modules`; the admin is the network through the AccessManager. |
| `EditionsBase.sol`, `StreamEditions6529.sol` | The ERC-1155 of editions, built the same way. |
| `StreamWorkFacts6529.sol` | The permanent record of each work (media, record file, license, pinned renderer, locks), changed only by the token's RECORDS module within fixed rules. |
| `StreamDirectory6529.sol` | The one permanent address of the network's shared modules (ACCOUNTS, INDEPENDENT_STREAM, INDEPENDENT_TERMS, INDEPENDENT_RECORDS) and of `unclaimedPeriod`. The split ledger asks it for payout addresses; Independent Stream tokens ask it for their gate. |

## Entry points of `Stream6529`

| Caller | Calls | What the contract checks |
| --- | --- | --- |
| An active minter (sale contract) | `mint(to, facts)` | Nonzero item hash, content hash and artist ID; artist ID within 160 bits; rate at most 100,000; an existing collection; no live token with the content hash. Next ID in one sequence from 1; next serial in the collection. No receiver callback. |
| A minter (active or removed) holding the token, no outcome yet | `recordPrimarySale(id, sold, buyer, price)` once; or `burn(id)` | The holder is the caller, the caller is or was an active minter, the outcome is `NONE`. The price is logged, not stored. |
| The TERMS module | `setRoyalty(id, receiver, rate)`, `lockRoyaltyRate(id)`, `emitMetadataUpdate` | A live token; rate at most 100,000; a locked rate never changes. |
| `StreamWorkFacts6529`, the RECORDS module | `emitMetadataUpdate(from, to)` | Nothing else. |
| The network (AccessManager) | `addMinter`, `removeMinter`, `proposeModule`, `removeModule`, `setModuleDelay`, `setRescueDelay`, `rescue(id, to)`, `createCollection`, `setOwner`, `setContractURI` | `rescue`: the token is held by a removed minter with no outcome, and `rescueDelay` (read now) has passed since the removal. |
| Anyone | `activateModule(slot)` once its wait has passed; ERC-721 transfers and approvals; views `workOf`, `itemHashOf`, `collectionOf`, `tokenOfContent`, `royaltyInfo`, `rendererOf`, `tokenURI`, counters | Transfers, approvals, `ownerOf` and `royaltyInfo` call nothing outside the contract. |

## Waiting periods

None is fixed. Each is a setting of the network with a launch value, changed at once (no floor,
zero allowed), with an event carrying the old and the new value:

| Setting | Launch value | Where | A change applies to |
| --- | --- | --- | --- |
| `moduleDelay` | 7 days | `Stream6529`, `StreamEditions6529`, `StreamDirectory6529` | Modules announced and minters added after it; one already announced keeps its time |
| `rescueDelay` | 14 days | `Stream6529` (and each Independent Stream token) | Every rescue attempted after it, removals already made included |
| `rebindDelay` | 14 days | `StreamEditions6529` | Every rebind attempted after it |
| `unclaimedPeriod` | 180 days | `StreamDirectory6529`, read by the split ledger, the escrow and both auctions | Every forfeit or expiry attempted after it; the escrow also reads it at every deposit and recovery, and an amount it has already counted as aged stays aged |

## If a module is missing, hostile or out of gas

`ownerOf`, transfers, approvals and `royaltyInfo` never ask a module. `tokenURI` reverts if its
renderer is missing, reverts, runs out of gas or (pinned) changed its code; it never falls back
to another renderer. `mint` needs an active minter. `StreamDirectory6529.payoutAddress` reverts if
the ACCOUNTS module is missing or fails, so the ledger leaves the money in the vault. No path
catches a failure and answers a default.

## Tests

| Suite | What it covers |
| --- | --- |
| `test/core/Stream.t.sol` | Every function, revert (by selector) and event of `Stream6529`. |
| `test/core/StreamSettings.t.sol` | `moduleDelay` through the real `Stream6529` and `StreamDirectory6529`; minters' waits. |
| `test/core/StreamHostile.t.sol` | A hostile module as TERMS, RECORDS, RENDERER, minter (active, pending, removed) and re-entering receiver. |
| `test/core/Directory.t.sol` | Forwarding, never a default, `unclaimedPeriod`. |
| `test/core/invariant/` | Stateful invariants of `Stream6529` with a modelling handler. |
| `test/core/CoreSeam.t.sol` | Smoke tests of the seam across the core. |
| `test/symbolic/StreamCoreSymbolic.t.sol` | Halmos: mint checks, royalty rules, the rescue predicate. |
| `test/medusa/StreamCoreMedusa*.sol` | The Medusa harness (also run under Forge). |
| `test/replay/StreamCoreIndexer.sol`, `LogReplayStreamCore.t.sol` | Every getter of `Stream6529` and `StreamDirectory6529` rebuilt from logs alone. |
