# ADR 0007: Permanence

Status: Accepted by owner instruction, 14-15 November 2026. Recorded by the delivery owner
(Claude Code, acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md) (the
source-line budget; §16, federation moves into v1), [ADR 0002](0002-access-manager-hardening.md)
(governance), [ADR 0004](0004-gas-budgets-under-glamsterdam.md) (the gas rule for permanent
contracts; the start margin), [ADR 0005](0005-stream-editions-auction.md) (edition supply is
sealed at settlement; a per-sale open period with a governed maximum; an abandonment exit;
wallets at open) and [ADR 0006](0006-work-powers-and-conventions.md) (the renderer repin becomes
renounceable).

This is this repository's ADR 0007. The "ADR 0007 (no proxies)" that ADR 0001 retains under
"Superseded or amended" is the 6529Stream repository's, a different record; its rule (no
proxies, no `delegatecall`) is kept here.

The record below describes what was built, in two integration rounds on 15 November 2026:
eleven lanes (the shared gas helper, Stream, Editions, identity, money, store, governance, then
Stream's uniqueness record, WorkRecords, the English auction's refusal exit and the edition
auction), plus the integrator's changes listed in §6. Federation's templates and registry are
the one package not built (§3, P6).

## Context

The owner set four requirements on 14 November 2026:

1. The canonical token contracts (6529 Stream and 6529 Stream Editions) are never redeployed.
2. The system lasts a very long time: decades, and the owner speaks of centuries.
3. No permanent contract is vulnerable to a gas repricing of Glamsterdam's size.
4. The system is part of the 6529 network's consensus, revenue and TDH.

Seven studies against `main` at `59c1d1c1` (Stream core, WorkRecords, an inventory of every
compiled number and external call, governance, a consensus API, money and Editions, store and
log widths), then two more (federation, policy constants), found that release candidate rc.3
did not meet them:

- **Compiled gas numbers.** Calls into other contracts forwarded fixed amounts (100,000 for
  Stream's records read, 200,000 for ERC-1271, 30,000 for OpenZeppelin's ERC-165 probe, a
  `BIND_READ_GAS`, an `OWNER_READ_GAS`), and several read a starved call as a refusal or a
  default answer: a renderer read fell back to the default renderer, an ERC-165 probe answered
  "not a protocol contract", an owner read answered "not authorized". A repricing of about 5x
  on cold reads would have made every `tokenURI` revert through the statement log.
- **Money that depends on future prices.** Each payee configuration's wallet was a 5,097-byte
  contract: 1.17M Prague gas, about 8.5M under Glamsterdam [E]; a second repricing of that size
  could make a wallet undeployable and strand what was paid to its address.
- **Replaceable code with authority over existing tokens.** Stream's dependencies, the artist
  registry among them, were all governance-replaceable, and the federation hook was one-shot
  with a 64-entry append-only list per artist.
- **Facts a logs-only consensus cannot see.** Locked terms, Editions' prices and several state
  changes had no event.
- **Governance that can stall for good.** Two guardians could veto any later migration, and a
  dead admin set had no recovery.

[M] marks a figure measured with Foundry (Prague); [E] an estimate. Every Glamsterdam figure
is [E]: Foundry cannot measure it, and every row is to be re-measured on Sepolia after the
redeploy.

## Decision

### 1. The dividing line

Anything with authority over existing tokens, existing works' facts or funds already owed is
**permanent**, minimal, and takes no instruction from replaceable code. Everything else is
**replaceable** under slow, veto-able governance that can itself be handed to the network.

- **Permanent:** 6529 Stream, 6529 Stream Editions, `WorkRecords`, `StatementLog`,
  `ContentStore`, `ArtistRegistry`, the split ledger and its vaults (the release verifier
  merged in), and the revenue escrow as custodian of its credits.
- **Replaceable:** the mint policy (`PackageRegistry`), the economics resolver, the entropy
  module, renderers, sale adapters, `AssetAllowlist` (already replaceable; reclassified), the
  consolidation adapter, the governed vaults' destinations, and the AccessManager itself
  (`registerSuccessor` and `migrate`, §6).

Rules for permanent contracts (the lanes' shared rules): no `delegatecall`, proxies or
`selfdestruct`; every state-changing operation can be completed in pieces of a caller-chosen
size; no fund movement depends on the future price of creating state, deploying code or
sending ETH; invariants, not policy numbers (§7); every consensus-relevant state change has an
event sufficient to rebuild the new state without a call (§8).

### 2. The gas rule (replaces the first plan's "bounded gas" rule)

1. **No gas numbers in permanent contracts.** A call into another contract forwards all the gas
   EIP-150 allows (all but 1/64).
2. **A shortfall never yields an answer.** A call that fails having left at most **1/8** of the
   gas held just before it reverts the whole transaction with
   `BoundedCallShortfall(target)`; only a failure with more than 1/8 left is a refusal.
   - *Why 1/8, not the 1/64 first proposed:* a callee that runs out of gas leaves its caller
     the 1/64 EIP-150 retained, but through k all-forwarding frames (a Safe proxy, its
     implementation, an owner wallet) the caller can be left up to 1 - (63/64)^k of what it
     held: 11.8% at k = 8. A 1/64 test would read such an honest out-of-gas inside a proxy as a
     refusal, a success-shaped answer the rule forbids; with 1/8, an out-of-gas up to eight
     frames deep is a shortfall at any transaction gas limit. The price is the residual below:
     a refusal that burns more than about 7/8 of its gas first reads as a shortfall until it is
     resent with more gas, which only delays a refusal and never turns one into an answer. Residuals, in NatSpec and LIM-GAS-13: a
     refusal that itself burns more than about 7/8 of its gas reads as a shortfall until resent
     with more gas; a callee that catches its own out-of-gas and returns has answered;
     OpenZeppelin's `restricted` reports a starved authority check as unauthorized (the
     transaction still reverts).
3. **Pieces.** Every state-changing operation can be completed in pieces of a caller-chosen
   size.
4. **No fund movement depends on future prices** of state creation, code deployment or ETH
   transfers.
5. **Budgets are test policy.** The 350K start budget and the 8M `tokenURI` budget stay as CI
   gates of Prague gas (ADR 0004); they are not compiled into any contract.

The shared helper is `BoundedCall`'s forward-all family (`tryReadAll`, `tryCallAll`,
`tryReadWordAll` and OpenZeppelin-equivalent ERC-165 probes); the fixed-gas family remains for
replaceable callers. A burner harness (`test/helpers/GasRule.sol`, tests named
`test_GasRule_*`) runs every call out of a permanent contract against a dependency burning 1x
to 100x its cost and sweeps the gas limit to show a shortfall never answers. `SignatureVerifier`
drops its 200,000-gas ERC-1271 cap and accepts signatures up to 65,536 bytes (room for
post-quantum schemes). Spec: DSP-26, AUC-42, ED-28, ID-38, ECO-42.

### 3. Packages as built

**P1, Stream: a permanent core with a replaceable mint policy** (AUC-38 to AUC-43).
- `mint` hands the adapter's request, unread, to one replaceable `IMintPolicy` (the package
  registry, `authorize`) on the call a mint already made. The policy does consent, item rules,
  VRF delivery and the terms quote and returns a flat record; Stream checks its own invariants
  on it (adapter kind, item hash, artist ID width, kind and seed in range, economics bounds,
  collection exists), interns terms and mints into the adapter's custody. The policy has no
  write path into Stream; a hostile policy changes nothing on existing tokens
  (`StreamPolicySafety.t.sol`, with an invariant).
- The artist registry is an immutable with no setter (AUC-39); entropy eras, settle, burn,
  rescue and museum routing stay native; every view another contract reads stays native.
- **Content uniqueness is in the core** (AUC-44): Stream keeps the consumed-content record
  (a content hash mints once, whatever mint policy is installed; `releaseContent` and its
  tombstones are Stream's), so a replaced or blank policy cannot re-mint existing content. The
  one new slot per start moved from the registry to Stream; no start row gained a slot.
- Informational views (`work`, `collection`, `totalSupply`, `contractURI`, `owner`) and
  collection-name validation move to `StreamViews`, a read-only extension Stream's constructor
  deploys and reaches by `STATICCALL`.
- `IStream` is one flat interface ID covering the whole native surface; `IStreamViews` has its
  own (AUC-40).
- `ItemKind` and `SeedPolicy` are carried as `uint8`, so a future kind cannot brick records.
- Lower-only royalty is also enforced in the core; `rendererOf` forwards all gas and fails
  closed, with no silent fallback to the default renderer (AUC-42); terms indices are 24 bits.
- The rescue delay is governed with a 90-day floor (`RESCUE_DELAY_FLOOR`, the guarantee):
  `setRescueDelay` only lengthens it, at most doubling per change (AUC-41).
- Consensus events (AUC-43): `WorkMinted` carries the token, collection, lead artist (indexed),
  item hash, serial, kind, package root, content hash, media hash, record file, seller and a
  terms ID; `TermsInterned` carries rate, fee share, fee recipient and minter on each new terms
  word; `FeeRecipientRegistered`, `ContentReleased`, `RescueDelaySet`; `AdmittedMinterSet`
  carries the sale kind. No `recipient` on `PrimarySaleSettled` (owner, §5).

**P2, WorkRecords and ContentStore.**
- `ContentStore` (WS-50 to WS-54): linked chunks (`linkChunk`, a full chunk from 1 to 256 whole
  stored parts, re-verified on read, replaceable only by a link from fewer parts) so a
  code-price or cap change cannot end on-chain storage; manifests up to 4,096 chunks
  registered in pieces from list chunks (`registerManifestList`, same file IDs); ranged
  completeness against the store or any `IChunkStore` adapter (`firstMissing`); caller-sized
  `attestBase64`; open `uint8` encoding and digest-kind IDs; `ManifestRegistered` carries the
  chunk hashes; `SSTORE2.write` trusts the deployed address.
- `WorkRecords` stays the permanent, bind-once fact holder (WS-39 to WS-46). What may change
  sits behind two governed pointers: a replaceable delivery contract (`WorkDelivery`: locators,
  kinds, preferences, the URI grammar; `setDelivery`, SUCCESSOR_SETTER, 30 days, which must
  name its predecessor), forwarded fail-soft with all the gas (a revert or malformed answer
  serves the work's own answer, a shortfall reverts); and an append-only store set (`addStore`,
  code hash pinned), so a future medium can count as on-chain complete for new works and
  collector upgrades while no existing work is ever re-pointed or unmarked. `syncOnChain(tokenId,
  storeId, maxChunks)` resumes from a chunk cursor in a spare word, with no compiled budget, so
  files of any size (up to the store's 4,096 chunks) sync. The third work power,
  `RENDERER_REPIN`, is renounceable after finalize (amends ADR 0006). `RecordOpened` carries the
  whole item, media list, licence key and seed; every amendment event carries the state hash.
  Bounds are structural only: a record is one chunk; a preview has no bound in WorkRecords; the
  pinned renderer decides what it shows.
- The shared package types carry kind, seed policy and party and media roles as open `uint8`s
  (the enums only name today's values), so no permanent contract's decode can revert on a
  value a later mint policy defines; the genesis mint policy refuses values it does not know
  for new items. Selectors, interface IDs, topics and item hashes are unchanged.
- The default renderer (replaceable, but pinned by every finalized work, possibly for good once
  the repin is renounced) forwards all gas on every read and compiles no gas figure; its
  preview bound is `Limits.MAX_PREVIEW_BYTES`.

**P3, money, Editions, identity and the statement log.**
- **Split ledger** (ECO-39 to ECO-42): one permanent `SplitLedger` replaces the split factory,
  every split wallet and the release verifier. A wallet is a 66-byte `SplitVault` at the same
  CREATE2 derivation (ledger, payee-list hash, salt), which executes only its ledger's
  instructions and accepts plain ETH within a 2,300-gas stipend; it has no storage,
  `delegatecall`, proxy or `selfdestruct`. The ledger keeps every wallet's accounting,
  verifies signed releases (merged: a separate verifier would have to trust the ledger, a
  circular pin) and proves every move by balances. `createWallet` costs 95,950 Prague gas
  [M] (was 1,185,635), about 0.43M under Glamsterdam [E] (was about 8.5M). Releases name a
  wallet by its payee list and salt. No code-hash re-checks; no rescue from a wallet (every unit
  is some payee's).
- **Revenue escrow:** `sweepExcess` moves only `balance - totalOwed` (FUNDS_SETTER, 14 days;
  ECO-40).
- **Governed vaults:** the network fee recipient and the museum are `GovernedVault` contracts
  at genesis (`FeeRecipientVault`, `MuseumVault`), not plain addresses: they move what they
  hold only to their destination, which only FUNDS_SETTER changes (14 days, compare-and-set;
  ECO-41). The deployment's `NETWORK_FEE_RECIPIENT` and `MUSEUM` become their first
  destinations.
- **Editions** (ED-25 to ED-28): the bound adapter seals an edition's supply at its sale's
  settlement (`sealSupply`, once; the maximum drops to the count sold, and a removed adapter
  mints only an edition it sealed), closing LIM-EA-10. Editions holds no duration. `mint`'s
  data is `abi.encode(currency, unitPrice)`, logged by `EditionPrimaryMint`; `createEdition`
  emits `EditionTermsLocked`. Every call out forwards all gas, the ERC-1155 receiver hook
  included; `uri` inherits the fail-closed `rendererOf`; royalty is lower-only in Editions too.
- **Artist registry** (ID-33 to ID-39): permanent, so the federation hook is hardened instead of
  dropped (owner, 15 November 2026: federated contracts must be listed so the network knows
  them; they earn no TDH). The federation-registry pointer becomes replaceable
  (`setFederationRegistry`, SUCCESSOR_SETTER, 30 days); a per-token directory replaces the
  64-entry list; listings record the code hash the registry reads itself and move only between
  ACTIVE and DELISTED, while LEFT is set by the token, terminal; canonical addresses are
  refused. A hostile federation registry has no authority over any artist's identity, payout,
  standing or timers. The five identity timers become governed between floors (today's values,
  the guarantees) and ceilings, locked at staging. Every refresh but `refreshStanding` is
  best-effort, a shortfall always reverts, source times are clamped, and a payout-only override
  needs dormancy.
- **Edition auction** (replaceable; EA-17 to EA-20): seals at its final count and prices every
  mint; an edition's close offset is chosen per sale in the artist-signed terms, up to a
  governed maximum (`setLimits`: maximum close offset, abandonment delay, payout gas); a sale
  that has paid nothing can be abandoned after its end plus a locked delay (full refunds, the
  edition sealed at zero); `open` deploys the seller and royalty wallets, so rule 4 holds for
  edition sales.
- **English auction** (replaceable; AUC-45 to AUC-48): `settleOrRefund` ends a federated sale
  whose token will not settle (after a governed refusal delay, in a frame given exactly the
  governed refusal gas, so the keeper's gas limit cannot steer the outcome), crediting the bid;
  6529 Stream's own sales never take this exit (LIM-SAL-16). It solves LIM-SAL-16 for federated
  sales, as the owner asked, and lays down nine guarantees a federated template must meet
  (gas within the refusal gas less the auction's measured 2.43M, no early `primarySale`, no
  third-party guard, no buyer code in settlement, settlement independent of identity state,
  payees locked and payable, an honest `ownerOf`, one settlement by the minting adapter, fixed
  code). Opening bids moved to the asset allowlist (§6).
- **Statement log:** forward-all reads; any non-zero hash-algorithm ID recorded uninterpreted
  (1 to 3 keep their names); URIs up to 8,192 bytes (DSP-2, DSP-26).

**P4, governance for decades** (GV-37 to GV-47; no bytes in any permanent contract).
- **Bounded veto:** a guardian's removal and a successor registration, once struck by a
  guardian's cancellation, are re-proposed on an escalated lane (120 days by default) that only
  a majority of guardian seats, at least two, can stop.
- **Dead-admin recovery:** after a year without admin activity and a 180-day public delay any
  live admin can void, a guardian majority (or, unless a majority objects, a pre-registered
  recovery address) installs a new sole admin.
- **Successor and `migrate`:** a successor registered through the slow lane takes over at once;
  `migrate` re-points every managed target, in pieces, permissionlessly. A test hands the whole
  genesis stack to a non-OpenZeppelin authority and operates it (`GovernanceHandover.t.sol`).
- **Seats and floors:** ADMIN at most 5, GUARDIAN at most 7 seat records; every ADMIN grant
  waits at least 30 days; the manager cannot remap or close itself; its parameters are
  compare-and-set within compiled bounds.
- **Deployment:** a third admin seat (genesis holders now name three admin Safes; the deploy
  guard requires three off anvil); the cold and third admin holders are for the owner to name.
- **Finding, stated plainly:** with three guardian seats any two are a majority, so the bounded
  veto only bites with five or more seats (LIM-GV-4); the seat count is the owner's call.
- The permanent contracts need no change for a handover: they use stock `AccessManaged`.

**P5, the consensus API.** The permanent contracts' events and native views are protocol API.
TDH reads Stream's `PrimarySaleSettled` and Editions' `EditionPrimaryMint`, not a replaceable
adapter's `SaleSettled` ([events and indexing](../integrators/events-and-indexing.md)). The
"no governance can ever" list is kept as tested invariants
([invariants](../audit/invariants.md)), with the items this record adds: the artist registry is
fixed in Stream, a sealed edition supply never grows, no renderer fallback, the escrow sweeps
only the unowed, a governed vault pays only its destination, and a federation registry has no
authority over artists.

**P6, federation in v1.** Federated Stream and Federated Stream Editions ship in v1 (owner,
15 November 2026; previously deferred to v1.1 by ADR 0001 §16): templates, a federation
registry, federated targets in the shared adapters, listing in the permanent artist registry,
complete events. Federated contracts earn no TDH. Defaults approved by the owner: full copies
only in v1 (clones later, as a new template version), forms 721 and the linked pair, unbid
federated works stay in template custody and can be re-auctioned, no royalty floor, no VRF for
federated works in v1, registration by code hash with no trusted factory, one-way exit, fees
locked per contract. Only the permanent part has landed (the artist registry's directory,
above); the rest is **in v1, specified by a later ADR**.

**P7, policy numbers** (study I). No number in a permanent contract had a setter. Decided:
- moved out with the packages: signature size and ERC-1271 gas (forward all gas, 64 KiB), the
  federated list cap (per-token directory), collection-name length (the views extension),
  locator count and URI grammar (the delivery contract), record and preview size budgets (the
  pinned renderer);
- closed lists become open IDs recorded but not interpreted: hash algorithms, content
  encodings and digest kinds, item kind and seed policy;
- governed floors that can only be lengthened: the artist registry's timers (with ceilings,
  locked at staging) and Stream's rescue delay;
- kept as safety bounds or guarantees, each documented: `MAX_PAYEES` 64 (now a calldata bound),
  `MAX_MEDIA_FILES` 32, `MAX_PARTS` 256, the content store's 4,096-chunk cap, Editions'
  `UNCAPPED` 2^40 - 1, the statement log's 8,192-byte URI cap, the 185-day uphold window;
- no royalty ceiling at mint; unanimous-party consent unchanged until the owner chooses.

### 4. Budgets

- **Source lines:** the budget rises from 13,000 to **15,000** non-comment lines under `src/`
  (owner decision, 15 November 2026), for federation and the hardening above;
  `tools/check_budgets.py` enforces it. Lines are still spent carefully.
- **Start margin:** the 350K steady-state start budget and the slot maxima are unchanged; the
  suite's margin under 350K falls from 5,000 to what the merged rows support (ADR 0004's
  table; set in `START_MARGIN`). The mint-policy hop costs more than estimated
  (about +1.4K on steady starts, +3.8K on an artist's first start, not +0.5 to 1.0K), and 350K
  fits only because the policy's redundant `ItemConsumed` event was dropped (`WorkMinted`
  carries everything it said).
- **EIP-170:** every contract keeps 512 bytes of margin, with no exemption left
  (`tools/size-margins.json` is empty): the renderer gained margin by dropping its gas caps, and
  the English auction by moving opening bids to the allowlist (§6).

### 5. Owner decisions

Decided 15 November 2026 ("yes to all"), unless dated otherwise:

- The artist registry is permanent: Stream's pointer is set once at genesis.
- Store adapters for future on-chain media: yes (built: the append-only store set).
- Hardened manager: one year of admin silence, a 180-day public delay, guardian majority in the
  slow lane; a third admin seat. The cold admin, third admin and recovery-address holders, and
  the guardian seat count, are the owner's to name.
- Uncapped editions are sealed at settlement, and may stay open much longer than about a day:
  the close offset becomes per sale, chosen in the edition's artist-signed terms, with any
  bound a governed parameter of the replaceable auction, never a compiled constant. Bids are
  firm, so bidders' ETH is locked for the whole window, and editions mint only after the close.
  Built: the seal (Editions) and the per-sale window with a governed maximum (30 days at
  launch) and an abandonment exit (150 days at launch); both launch values are for the owner to
  confirm.
- The errata repin becomes optionally renounceable: a third `WorkPowers` bit,
  `RENDERER_REPIN`, only after finalize; once renounced, a pinned renderer a protocol change
  breaks can never be repaired for that work (built; amends ADR 0006).
- TDH: 6529 Stream and 6529 Stream Editions earn TDH; Federated Stream and Federated Stream
  Editions do not. Eligibility is by contract address; no on-chain flag.
- Consensus reads logs only: every fact the consensus study found needing a call is emitted by a
  permanent contract.
- TDH during sale custody (superseding the same day's earlier answer): TDH is computed
  off-chain from standard `Transfer` events and credits whoever holds the token, a sale contract
  included; no `recipient` on `PrimarySaleSettled`.
- No global time rule for editions; permanent contracts hold invariants, not policy numbers;
  every compiled policy constant was swept (§3, P7).
- Federation ships in v1 (§3, P6), with the defaults listed there.
- The line budget may increase; set at 15,000 once federation was sized.
- LIM-SAL-16 (a token whose settlement calls fail holds the bid forever) is to be solved, not
  documented. Built for federated sales (`settleOrRefund`); 6529 Stream's sales never take
  the exit, because a refused Stream sale would strand its master's edition sale (review F1);
  a listed token other than Stream must prove at its 30-day listing review that its
  settlement cannot fail.

### 6. Integration

Eleven lanes merged in two rounds. The integrator also:
- wired genesis: the new governed selectors (`setRescueDelay`, `setFederationRegistry`,
  `setTimer`, `sweepExcess`, both vaults' `setDestination`, `setDelivery`, `addStore`, the
  edition auction's `setLimits`, `AssetAllowlist.setOpeningBid`, the manager's functions), the
  two governed vaults, the delivery contract and a third admin seat; the role matrix is
  regenerated;
- moved the English auction's opening bids to the asset allowlist, which already owns each
  currency's increment floor: the bid sits in the asset's status word, so a start reads status
  and opening bid in one call, and the auction regains its 512-byte margin without dropping a
  payment method (the review's suggestion; the EIP-2612 permit path stays);
- made the shared package types' enum fields open `uint8`s, removing the records lane's copies;
- moved the default renderer to forward-all reads and the preview bound to
  `Limits.MAX_PREVIEW_BYTES`.

## What this amends

ADRs stay as written; each amended record gets a dated amendment note pointing here.

- **ADR 0001.** The source-line budget is 15,000 (Intended behavior, "Size"). §16 (6529 Stream
  Federated) moves into v1, specified by a later ADR; the artist registry's directory and
  replaceable federation-registry pointer are built. §11: the artist registry is permanent.
  §7: wallets are 66-byte vaults of one split ledger. §13: the governance additions in P4.
- **ADR 0002.** The manager gains the bounded veto, dead-admin recovery, a pre-registered
  successor with `migrate`, seat caps, a 30-day floor on admin grants and no self-remapping
  (GV-37 to GV-47). Rules 1 to 3, suspension and the delay classes are unchanged outside the
  escalated lane.
- **ADR 0004.** The gas rule above governs permanent contracts' calls; budgets stay test
  policy. The start margin is 5,000 after both rounds (2,500 between them). The table is
  re-measured with reasons for each moved regression ceiling.
- **ADR 0005.** An edition's supply is sealed at its sale's settlement; §4's governed
  0-to-1-day close offset becomes a per-sale offset up to a governed maximum, with an
  abandonment exit and wallets deployed at open (its §14).
- **ADR 0006.** §2's "the errata repin cannot be renounced" is superseded by a third, optional
  power, `RENDERER_REPIN`.

## Not fixable (documented)

- State expiry with no way to resurrect code would make stored works unreadable.
- Renderer pins are by code hash; a chain change to how existing code hashes are computed needs
  each artist to repin. Lost collaborators block amendments that need every party.
- Lost-key recovery for artists always needs some live governance (PARAMETER_SETTER).
- Funds paid to a wallet address before its vault exists need one future `createWallet` (a
  CREATE2 of 66 bytes and one storage word; LIM-ECO-7).

## Alternatives considered

- **"Views out only"** (P0's fallback: move only views, keep the start path): not needed; the
  gate measured every steady-state start row under 350K with the mint policy.
- **Version 1's rule: bounded gas with compiled numbers.** Rejected: every stress case at 10x
  failed somewhere, and each number is a bet on future prices.
- **A 1/64 shortfall threshold.** Rejected for 1/8: it would read an honest out-of-gas inside a
  Safe proxy as a refusal.
- **A consumed-content bit added in Stream's core on top of the policy's record.** Measured:
  +21,350 gas and one more slot per start, over 350K and the slot maximum. Built instead: the
  record itself moved from the policy into Stream, at no extra slot (LIM-GV-22 closed).
- **Locked terms inline in `WorkMinted`** (option A): cheaper on first-terms rows, dearer on
  steady rows; the owner preferred a terms ID with `TermsInterned`.
- **Licence, seed and parties in `WorkMinted`:** +3.3K and +5.5K to +7.9K per start, over 350K;
  they go in `RecordOpened` instead, off the start path.
- **A separate release verifier:** it would have to trust the ledger, a circular pin; merged.
- **A permissionless or time-based edition seal:** without the adapter's count any seal could
  strand winners, and the owner forbade a compiled duration.
- **Dropping the federation hook:** federated contracts must be known to the network.
- **First-writer-wins linked chunks:** anyone could front-run a link with 256 tiny parts and
  make that chunk about 25x dearer to read for good; a link from fewer parts replaces it.
- **`recipient` on `PrimarySaleSettled`:** superseded by the owner's TDH-from-`Transfer`
  decision.

## Consequences

- **Sizes** (runtime bytes, the `default` profile): see
  [Audit scope](../audit/scope.md) for every contract; Stream falls from 24,373 to 22,616,
  WorkRecords from 23,946 to 22,206, the split wallet from 5,097 to 66 bytes, the renderer from
  24,365 to 23,714 and the English auction ends at 24,062; no exemption remains.
- **Gas:** ADR 0004's table, re-measured on the merged tree.
- **Interfaces:** pre-launch reshaping of `IStream`, `IPackageRegistry`, `IEditions`,
  `IArtistRegistry`, `IContentStore`, the money interfaces and the manager; the IDs are in
  [ABIs and interface IDs](../integrators/abis-and-interface-ids.md). They freeze at launch.
- **Tests:** each lane's behaviour tests fail without its change; the stress harness runs in
  plain `forge test`.

## Open items

- The owner:
  - the guardian seat count: 3 (genesis today) or 5 (the bounded veto bites only from 5);
  - who holds the cold admin, the third admin seat and the recovery address;
  - the identity timers' ceilings (CHANGE_DELAY 7 to 30 days, OVERRIDE_DELAY 180 to 365,
    DORMANCY 365 to 1,825, CONTEST_TIMEOUT 365 to 730, STANDING_GRACE 30 to 90);
  - the English auction's size: it now keeps 514 bytes of margin; any later growth needs a
    decision (dropping the EIP-2612 permit path frees about 412 bytes);
  - launch values of the edition auction's maximum open period (30 days) and abandonment delay
    (150 days);
  - unanimous-party consent for amendments (unchanged until the owner chooses).
- A federation ADR, then the federation lane.
- Two independent reviews (contracts; governance), then a Sepolia redeploy and a Glamsterdam
  measurement of every row.
