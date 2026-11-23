# Editions and sales

6529 Stream Editions (`StreamEditions6529`) is the one shared ERC-1155. Each edition belongs to a
6529 Stream work of kind 1 (the master) and has the master's token ID. `StreamEditions6529` is
permanent and plain ([ADR 0010](../adr/0010-plain-permanent-core.md)): it keeps who owns each copy
and each edition's supply. The rules for creating and selling an edition live in its sale contract,
the replaceable `UniformEditionAuction`, which sells copies beside the master's 1/1 auction.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`StreamEditions6529`](../../src/core/StreamEditions6529.sol) on [`EditionsBase`](../../src/core/EditionsBase.sol) ([`IEditions`](../../src/interfaces/core/IEditions.sol)) | permanent | ERC-1155, ERC-2981, ERC-4906. `create`, `mint`, `seal` from the edition's own minter; `rebind` by the network; holders `burn` their own copies; the TERMS module sets royalties; `uri` through the master's renderer. |
| [`UniformEditionAuction`](../../src/sales/UniformEditionAuction.sol) and its lens | module (minter) | Opens an edition's sale, checks the master, works out seller, fee share and royalty receiver, deploys the split wallets, creates the edition, takes bids on a price ladder, clears at one price, mints copies as winners claim. |
| [`EditionRules`](../../src/editions/EditionRules.sol) | library | The edition terms rule. |
| [`IndependentEditionAuction`](../../src/independent/IndependentEditionAuction.sol) | module (minter) | The same auction for an Independent Stream artist's editions ([Independent Stream](independent-stream.md)). |

## The edition token

- **Create.** The sale contract creates an edition once, in one call:
  `create(editionId, maxSupply, royaltyReceiver, royaltyRate)`. Nobody else can create one. The
  edition's minter is that sale contract.
- **Mint.** Only the edition's minter mints, `mint(to, editionId, amount, unitPrice)`; the unit
  price is logged, not stored. Copies minted never exceed the maximum; burned copies still count.
- **Seal.** The minter seals the supply once, between the copies minted and the maximum. A
  sealed maximum never grows. A removed minter can still seal, and can mint only an edition it
  has sealed, so removing a sale contract never strands its winners.
- **Rebind.** If an edition's minter was removed before it minted or sealed anything, the
  network may move the edition to another active minter once `rebindDelay` has passed since the
  removal. The new sale contract then `adopt`s the edition and opens its sale.
- **Royalties.** Receiver and rate are stored per edition, set at creation (the master's rate)
  and changed only by the TERMS module. `royaltyInfo` asks no module.

| Setting (network's, changed at once, zero allowed) | Launch value |
| --- | --- |
| `moduleDelay` (adding a module or minter) | 7 days |
| `rebindDelay` (after a minter's removal, before `rebind`) | 14 days, read when the rebind is attempted |

## The edition auction

The auction is replaceable; its numbers below are compiled or governed values of that contract.

### Create an edition

- **Open.** Anyone opens a sale from the 1/1's start until the edition close. The auction checks
  the item against `IStream.itemHashOf` and that the master's kind is 1, takes seller, fee share
  and royalty receiver from the economics resolver, deploys the split wallets, then calls
  `StreamEditions6529.create`. It stores the seller and fee share itself.
### The step ladder

- **Ladder.** Bids sit on fixed price steps: step `i` costs
  `basePrice × M[(i mod N) × 192 / N] × 10^(i div N) / 100`, from one table of 192 mantissas.
  Prices are exact and strictly increasing.
- **Bids are firm.** A bid pays `quantity × stepPrice(step)` in ETH. The bidder may raise it,
  never lower or withdraw it. An upheld dispute on the 1/1 voids the sale and refunds every bid.
### The clearing

- **Clearing.** With `P(k)` the k-th highest unit price, the count is the largest `k` (within the
  creator's cap) whose revenue `k × P(k)` is within the breadth margin of the best revenue. Every
  winner pays `P(k)`.

### The cut step

- When a cap binds inside a step, that step fills in order of entry; a raise rejoins at the back
  of its new step and leaves a hole. Settlement sweeps the holes in position order, each settler
  on its own, so exactly the capped count is sold.
### Timing: alongside the 1/1

- **Timing.** The sale closes 15 minutes after the 1/1's final end, extended by a soft close up
  to a backstop. Settlement waits for the 1/1 to settle or be cancelled.
### Settlement, payouts and claims

- **Settle and claim.** Settlement pays `count × price` once: the seller and the network, a
  refused payout to the escrow. Each winner claims, minting its copies and refunding the rest.
  The supply is sealed at the count sold.
- **Abandon.** From 21 days after the close, anyone may abandon a sale that paid nothing once the
  1/1 is settled or cancelled; it refunds every bid and seals the edition at zero.
- **Credits.** A refund that cannot be pushed is a credit. Only money that has itself waited the
  unclaimed period in force (180 days at launch) may go to the network; a third party's
  `claimBidFor` never puts a fresh refund on an old clock. The rule is the one both auctions share
  ([Unclaimed credits](stream-and-auctions.md#unclaimed-credits-one-rule-for-both-auctions)).

| Auction value | Launch value | Kind |
| --- | --- | --- |
| Edition close | 15 minutes after the 1/1's end | compiled |
| Abandon delay | 21 days after the close | compiled |
| Steps per decade, base price, margin, soft window, backstop | per config | governed, bounded in code |
| Payout gas | 30,000 to 3,000,000, raise-only | governed |

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| ED-1 | Only an active minter creates an edition, for an existing master, once; the edition's minter is that caller. | `test_Edition_CreateMintSealAndTheSealNeverGrows` |
| ED-2 | An edition's ID is its master's token ID; an edition is created at most once. | `test_Create_StoresTheEditionAndLogsIt`, `test_Create_RefusesAMissingOrBurnedMaster`, `test_Create_OnceOnlyEvenByAnotherMinter` |
| ED-3 | Retired: one edition per master (ED-2) makes a separate content check unnecessary. | |
| ED-4 | Edition terms: a nonzero sale kind and at most 64 bytes of params, checked by the sale contract. | `test_invalidItem_masterEditionTerms`, `test_invalidItem_masterEditionTermsSharedRule`, `test_Open_ChecksTheItem` |
| ED-5 | Only the edition's own minter mints, a nonzero amount. | `test_Edition_CreateMintSealAndTheSealNeverGrows` |
| ED-6 | Copies minted never exceed the maximum; burns never free room. | `test_Mint_UpToTheCapExactlyAndNotOneMore`, `testFuzz_Mint_NeverPassesTheMaximum`, `test_Burn_AHolderBurnsItsOwnCopiesAndTheyStillCount` |
| ED-7 | Royalty receiver and rate are set at creation and changed only by the TERMS module. | `test_Create_StoresTheEditionAndLogsIt`, `test_SetRoyalty_OnlyTheTermsModule`, `test_HostileTerms_ReachesOnlyRoyaltiesAndMetadata` |
| ED-8 | A holder burns only its own copies; burned copies still count as minted. | `test_Burn_AHolderBurnsItsOwnCopiesAndTheyStillCount`, `test_Burn_NeverMoreThanTheCallersOwn` |
| ED-25 | The minter seals once, between the copies minted and the maximum; a sealed maximum never grows; a removed minter seals nothing and mints only what it sealed before its removal; a minter added again gains nothing while it waits to become active. | `test_Edition_CreateMintSealAndTheSealNeverGrows` |
| ED-26 | Every mint logs `EditionMinted(editionId, to, amount, unitPrice)`. | `test_Mint_MintsCountsAndLogsThePrice`, `test_Claims_MintThroughEditionsWithTheClearingPrice` |
| ED-27 | Editions' state is rebuilt from its logs alone. | `test_Editions_EveryEventReplaysToTheSameState`, `test_Editions_ReplayFailsOnStateNoLogExplains`, `test_Editions_ReplayFailsOnADroppedLog` |
| ED-28 | Retired: `StreamEditions6529` holds no gas figure and asks no module for a mint. | |
| ED-29 | The TERMS module may lower an edition's fee share with its master's, never raise it. | `test_LowerFeeShare_AnEditionsShareGoesDownAndNeverUp`, `test_LowerFeeShare_AnEditionOnItsMastersReceiverIsLoweredWithIt`, `test_LowerFeeShare_TheEditionMovesWhenItSharesTheReceiver` |
| ED-30 | The network may `rebind` only an edition with no seal, whose minter was removed at least `rebindDelay` ago, to an active minter. | `test_Rebind_AfterFourteenDaysOnlyUnsealed`, `testFuzz_Rebind_RefusedBeforeTheLaunchPeriod`, `test_RemovedEditionMinter_AnEditionWithCopiesAndNoSealIsRebound` |
| ED-31 | `rebindDelay` is the network's setting (14 days at launch), changed at once, zero allowed, with old and new in `RebindDelaySet`. | `test_RebindDelay_FourteenDaysAtDeploymentOnlyTheNetworkSetsIt` |
| EA-1 | Anyone opens an edition's sale once, from its 1/1's start until the close, with the master's stored item, in ETH. | `test_Open_LocksTermsAndEmits`, `test_Open_ChecksTheItem`, `test_Open_Timing` |
| EA-2 | A sale stores at open the cap, the configuration, the seller and the fee share. | `test_Open_LocksTermsAndEmits`, `test_SetConfig_CompareAndSetAndLocksPerSale` |
| EA-3 | Step prices follow the ladder formula, exact and strictly increasing. | `test_MantissasMatchTheGoldenVector`, `test_EveryLadderRisesAndNests` |
| EA-4 | A bid pays exactly `quantity × stepPrice(step)`; a raise pays exactly the difference. | `test_Bid_EscrowsExactlyAndEmits`, `test_Raise_PaysTheDifferenceAndMoves` |
| EA-5 | Bids are firm; an upheld dispute voids the sale and refunds every bid in full. | `test_FirmBids_StayDuringADisputeAndAreRefundedWhenUpheld` |
| EA-6 | The clearing equals the per-unit definition; every winner pays one price. | `test_Vector_03_Trace2DefaultLadder` |
| EA-7 | A cap inside a step fills in order of entry; a raise rejoins at the back. | `test_Raise_RejoinsAtTheBackInACappedSale`, `test_Vector_14_FifoHoles` |
| EA-8 | Settlement sweeps the clearing step's departures in order; each settler sweeps on its own. | `test_Settle_CapWithFifoAndHoles_ChunkedSweep`, `test_Settle_RejectsAnOutOfOrderSweep` |
| EA-9 | Exactly `count` copies exist once every winner has claimed; a removed sale contract's winners still claim. | `test_Settle_PaysAndClaimsMintExactlyK` |
| EA-10 | The sale ends at the later of the 1/1's end plus 15 minutes and the soft end. | `test_SoftClose_ExtendsOnlyInTheWindow`, `test_Coupling_FollowsTheOneOfOneAntiSnipe` |
| EA-11 | Settlement waits for the end and a settled or cancelled 1/1. | `test_Settle_NotReady`, `test_Settle_ZeroBidsMintsNothing` |
| EA-12 | Settlement pays `count × price` once, seller and network; a refused payout goes to the escrow. | `test_Settle_RefusedPayoutsGoToTheEscrow`, `test_Settle_PaysTheFeeRecipientCurrentAtSettlement` |
| EA-13 | A cancelled 1/1 voids its edition sale: nothing minted or paid, every bid refunded. | `test_Settle_VoidOnCancel` |
| EA-14 | The auction holds exactly the unclaimed escrow plus its credits. | `test_Holdings_AreTheUnclaimedEscrowPlusTheCredits`, `invariant_editionAuction` |
| EA-15 | `setConfig` is compare-and-set within bounds in code; `pause` stops new opens only. | `test_SetConfig_Bounds`, `test_Pause_BlocksOpensOnly` |
| EA-16 | Claims are never blocked or re-entered; only money that has itself waited the unclaimed period in force goes from a credit to the network. | `test_Claims_RejectAndCredit` |
| EA-17 | Every edition sale closes exactly 15 minutes after its 1/1's final end (compiled in the auction). | `test_Window_FifteenMinutesAfterTheOneOfOne` |
| EA-18 | `setLimits` is compare-and-set within bounds; payout gas only rises. | `test_SetLimits_CompareAndSetBoundsAndEvent` |
| EA-19 | From 21 days after the close, anyone may abandon a sale that paid nothing once the 1/1 is finished; it refunds every bid and seals the edition at zero. | |
| EA-20 | No payment reaches an undeployed wallet: `open` deploys the split wallets first. | `test_PayoutGas_IsTheGovernedFigure` |
| EA-21 | After a network `rebind`, the new auction may `adopt` an edition whose minter is itself and open its sale. | `test_Adopt_AfterRebind_RunsOnItsOwnAndSettlesWithoutTheOneOfOne`, `test_Adopt_TheNetworkOnly`, `test_Adopt_RefusesAnEditionThatIsNotItsOwn`, `test_Rebind_TheNetworkMovesAnUnsoldEditionAndTheNewAdapterSellsIt` |

## Events

`StreamEditions6529`: `EditionCreated`, `EditionMinted`, `EditionSupplySealed`, `EditionRebound`,
`RoyaltySet`, `RebindDelaySet`, `MinterAdded`, `MinterRemoved`, `ModuleProposed`, `ModuleSet`,
`ModuleDelaySet`, ERC-1155 and ERC-4906. Signatures on the
[events page](../integrators/events-and-indexing.md).

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| The edition's sale contract was removed before it minted or sealed | The edition waits | The network rebinds it after `rebindDelay`; the new auction adopts it. |
| The sale contract was removed after sealing | Winners still claim | None needed. |
| The 1/1 is cancelled | The edition sale is void; bids refunded | None needed. |
| Nobody settles | The sale waits | Anyone settles; after 21 days anyone may abandon a sale that paid nothing. |
