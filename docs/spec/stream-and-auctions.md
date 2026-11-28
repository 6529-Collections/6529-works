# Stream and auctions

6529 Stream is one shared ERC-721, `Stream6529`, holding every curated 1/1. It is permanent and
plain ([ADR 0010](../adr/0010-plain-permanent-core.md)): it keeps who owns each token, the
facts fixed at mint and how the first sale ended. Everything else is a replaceable module. The
1/1s sell through `EnglishAuction`, a replaceable sale contract that Stream lists as a minter.
Payments are in ETH only.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`Stream6529`](../../src/core/Stream6529.sol) on [`StreamBase`](../../src/core/StreamBase.sol) | permanent | ERC-721, ERC-2981, ERC-4906. Mints for an active minter, records the outcome of the first sale, `royaltyInfo`, `tokenURI`, `rescue`, module slots and minters ([`Modules`](../../src/core/Modules.sol)). Interface: [`IStream`](../../src/interfaces/core/IStream.sol), [`IModules`](../../src/interfaces/core/IModules.sol). |
| [`EnglishAuction`](../../src/sales/EnglishAuction.sol) | module (minter) | Starts a sale by asking the mint policy and minting into its own custody; bids, pull credits, settlement, the dispute pause, the emergency pause, the Independent Stream refusal exit. Stores each sale's seller and fee share. |
| Mint policy: [`PackageRegistry`](../../src/curation/PackageRegistry.sol) | module | Decides what may be minted and answers the mint facts and sale terms ([`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol), [Curation](curation.md)). Holds content release and tombstones. |
| `TERMS` module: `StreamTerms` | module | Sets a token's royalty receiver and rate, locks the rate, lowers the network's fee share ([Economics and payouts](economics-and-payouts.md)). |
| `RENDERER` module: [`Renderer`](../../src/content/Renderer.sol) | module | Draws a work that is not finalized ([Rendering](rendering-and-tokenuri.md)). |
| `RECORDS` module: `WorkRules` | module | Edits a work's record within what `StreamWorkFacts6529` allows ([Works and storage](works-and-storage.md)). |

## The seam

Stream accepts four things from modules and nothing else:

1. An active **minter** mints a new token and states its facts. While it still holds a token
   whose sale has no outcome, it may record the outcome once, or burn the token.
2. The **TERMS** module sets a token's royalty receiver and rate, and may lock the rate for good.
3. The **RENDERER** module draws a work that is not finalized. A finalized work is drawn by the
   renderer pinned in `StreamWorkFacts6529`.
4. The **RECORDS** module changes a work's record within what `StreamWorkFacts6529` allows.

No module can move a token, change a fact fixed at mint, or touch money in a vault or the escrow.
The one move by anyone but the owner is `rescue` (below).

## Settings and fixed numbers

Stream holds no fixed waiting period. Its two waits are the network's settings, changed at once
(no floor, zero allowed), each with an event carrying the old and new value:

| Setting | Launch value | What it governs |
| --- | --- | --- |
| `moduleDelay` | 7 days | Between announcing a module or adding a minter and its first use. An addition already announced keeps the time it was given. Removal is immediate. |
| `rescueDelay` | 14 days | Between a minter's removal and a `rescue` of a token it still holds unsold. Read when the rescue is attempted. |

The auction is replaceable, so its timers are compiled constants or governed values of that
contract, not promises of the token:

| Auction value | Launch value | Kind |
| --- | --- | --- |
| Duration | 24 hours (1 hour to 7 days) | governed |
| Anti-snipe window | 15 minutes (1 minute to 1 day) | governed |
| Increment | 5% of the high bid, at least 0.001 ETH | governed |
| Opening bid | 0.05 ETH | governed |
| Dispute pause | at most 3 days, once per auction | compiled |
| Independent Stream refusal exit | 2 days after the end | compiled |
| Recipient's redirect of a pending delivery | 14 days after the end | compiled |
| Unclaimed credit | the unclaimed period in force (180 days at launch), counted from when that money itself started waiting | network setting read by the auction |
| Delivery gas; ETH payout gas | 300,000; 100,000 per wallet | compiled |

## How a sale flows

1. **Start** (anyone). The auction calls `policy.authorize(token, request)`. The policy checks
   the approved item, the artist's signature and the content rules, consumes the item and
   answers `MintFacts` (with the royalty receiver and rate) and `MintTerms` (seller, fee
   recipient, fee share). The auction checks the terms it sells by (the sale kind, empty params,
   the seller and the fee share; it does not read the terms' fee recipient or creator), calls
   `Stream.mint(address(this), facts)`, stores the seller and fee share in the sale, and opens
   the clock. `startWithBid` also places the first bid.
2. **Bid** (anyone). A bid must reach the minimum; a bid in the last window extends the end. The
   opening bid, the increment and the window are the governed values in force when the bid is
   placed, not those at the start. An outbid bid is credited to its payer, never pushed.
3. **Settle** (anyone, after the end). With a bid, the auction calls
   `Stream6529.recordPrimarySale(tokenId, true, buyer, price)`, delivers the token and pays the
   seller and the network (the seller's part rounds down and the fee is the remainder, paid to
   the recipient the economics resolver names at that moment); a refused payout goes to the
   escrow, a failed delivery waits as a pending delivery. With no bid, it records `UNSOLD`; a 6529 Stream work is then transferred by
   the auction to the museum the economics resolver names at that moment; an unsold Independent
   Stream work stays in the auction and can be started again there for the same item.
4. **Cancel after an upheld dispute** (network). The auction calls `Stream6529.burn(tokenId)`.

Stream stores only the outcome. The price is in the `PrimarySale` log.

### Unclaimed credits: one rule for both auctions

The English auction and both edition auctions keep credits by one shared rule,
[`AgedCredits`](../../src/libraries/AgedCredits.sol). Each account has a total, a waiting part
and the time that part started waiting. A credit to an account with nothing starts a wait for
that amount; a credit while a wait runs joins the total only. Once the unclaimed period in force
(`StreamDirectory6529.unclaimedPeriod()`, read when the expiry is attempted) has passed since the
wait started, anyone may send the waiting part, and nothing else, to the network; the rest starts a
new wait at that moment. The account's own claim takes everything. So no money goes to the network
before it has itself waited the period, and no deposit or call by anyone else can shorten or
postpone a running wait. The revenue escrow's rule
([Economics and payouts](economics-and-payouts.md)) gives the same guarantee differently: it groups
credits in windows that stay open for one period and expire a period after their last credit (a
deposit into an open window can move its due time later, at most to two periods after the window's
first deposit), so an amount waits at least one period and, while the period stays the same, less
than two; its due time can be computed without anyone calling `expire`. The auctions use the simpler
rule because their credits are short-lived refunds that their owners usually claim at once, so a
batch that waits longer until someone calls `expireCredit` costs nobody anything, and one storage
word with three fields is easier to prove than four words of windows. The escrow, which is permanent
and was reviewed on its own, is left as it is.

### A token that will not settle

An Independent Stream token may fail a call `settle` makes into it. From 2 days after the sale's end
(compiled in the auction), anyone may call `settleOrRefund(saleId)`. It attempts the whole
settlement in a frame of fixed, governed gas; if the attempt fails, the sale closes with the
standing bid credited back and the work left in the auction. 6529 Stream's sales are never
refused (`SaleNotRefusable`).

#### Why this is sound

A token that settles is never affected: the exit only opens after the end plus the delay, and a
cooperating settlement inside the refusal gas always succeeds. The bidder's money comes back in
full; the network's fee is paid exactly on completed sales.

### What an Independent Stream template must guarantee

An Independent Stream token is the same token code as Stream (`StreamBase`), so it inherits every
rule of this page; its minters are the Independent Stream module's answer. It must settle within the
refusal gas and must not depend on a reentrancy guard a third party can hold.

**Rescue.** If the network removes a minter that still holds a token with no outcome, the
network may `rescue(tokenId, to)` once `rescueDelay` has passed since the removal. The outcome
becomes `RESCUED`. Re-adding the minter clears its removal. A rescue can never reach a token
whose outcome is set, or one held by anyone but that removed minter. The English auction mints
every work to itself and records its outcome before the work leaves it (AUC-57), so no work it
sold, sent to the museum or holds for a pending delivery can be rescued. `rescue` checks the
token's own record and nothing else: it does not record who minted a token or where the token
has been, so the rule for a later sale contract is in its admission
([LIM-SAL-14](../audit/known-limitations.md#sales-and-auctions)).

A sale whose work was rescued closes with refunds only. `settle` reads the outcome the token
recorded, credits the standing bid back and ends the sale CANCELLED, so an edition sale that
followed it is void with every bid refunded (EA-22). The work is usually with the rescue's
recipient by then. If it is in the auction's custody instead, because the network named the
auction as the recipient or the recipient sent it back, the sale closes the same way and the
auction sends the work to the museum (AUC-56). A rescued work that arrives after its sale closed
is sent to the museum by anyone (`sendRescuedToMuseum`, AUC-58).

**Royalties.** `royaltyInfo` is two storage reads of the token's receiver and rate; no module is
asked. The receiver at mint is the split wallet for the seller and the network's fee share, or
the seller when the share is zero.

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| AUC-1 | Only an active minter mints: added, past the `moduleDelay` it was given, and not removed. Genesis minters are active at once. | `test_Mint_OnlyAMinterAndOneLiveTokenPerContent`, `testFuzz_AddMinter_NeverActiveBeforeTheWait`, `test_Genesis_ModuleAndMinterAreActiveAtOnce` |
| AUC-2 | A mint needs a nonzero item hash, content hash and artist ID, a rate of at most 100,000 and an existing collection. | `test_Mint_StoresFactsAndCountsSerial`, `test_Mint_OnlyAMinterAndOneLiveTokenPerContent` |
| AUC-3 | Every start asks the mint policy in the same call; a policy revert reverts the start and mints nothing. | `test_Start_AsksTheMintPolicyInTheSameCall`, `test_HostilePolicy_RevertingMintsNothing`, `test_StartWithBid_APolicyRevertMintsNothingAndTakesNoBid` |
| AUC-4 | A VRF work mints only once its seed is delivered; the seed is stored in the token at mint and never changes. | `test_VrfWork_SeedRequestedDeliveredThenStartedStoredAndRendered`, `test_VrfWork_RetryAfterTheDelayAndTheFirstDeliveryWins` |
| AUC-5 | Token IDs are one sequence from 1, never reused; serials count per collection from 1; `totalSupply` is minted minus burned. | `test_Mint_StoresFactsAndCountsSerial` |
| AUC-6 | A token's royalty receiver and rate change only through the TERMS module; a locked rate never changes again. | `test_Hostile_NoSeamPositionReachesACollectorsToken` |
| AUC-7 | `royaltyInfo` returns the stored receiver and exactly `floor(price × rate / 100,000)` for any price, asking no module. | `testFuzz_RoyaltyInfo_ExactForAnyPrice`, `test_RoyaltyInfo_NeedsNoModule`, `test_RoyaltyInfo_EdgesAndUnminted` |
| AUC-8 | Only the minter holding a token records its outcome, once: SOLD with a buyer, or UNSOLD. An outcome never changes. | `test_Sold_TheMinterCanDoNothingMore` |
| AUC-9 | Only the minter holding a token burns it, and only before an outcome, even after its removal. | `test_Sold_TheMinterCanDoNothingMore` |
| AUC-10 | Retired: content release moved to the mint policy (CUR rules). | |
| AUC-11 | Retired: Stream has no satellites to bind and no edition link. | |
| AUC-12 | Retired: collection names are checked by the keeper; the renderer tolerates any name. | |
| AUC-13 | The emergency pause stops only new starts. | `test_Pause_StopsStartsOnly`, `test_Start_RefusedWhileStartsArePaused` |
| AUC-14 | A start refuses terms it cannot sell by: a sale kind other than the English auction, params that are not empty, a zero seller, the escrow or the auction itself as seller, a fee share above 100,000, or a token not in the auction's custody after the mint. It does not read the terms' fee recipient or creator. The fee goes to the recipient the economics resolver names at settlement, which is checked where it is set (ECO-3); the creator is the mint policy's own answer (for 6529 Stream, the wallet whose signed move the package registry accepted, CUR-10). | `test_Start_RefusesTermsItCannotSellBy`, `test_HostilePolicy_LyingTermsAreRefused`, `test_HostileToken_AMintThatLandsElsewhereIsRefused`, `test_Start_ReadsNeitherTheFeeRecipientNorTheCreatorOfTheTerms`, `test_Settle_TheFeeGoesToTheRecipientNamedAtSettlement`, `test_FeeRecipient_RefusesSystemContracts` |
| AUC-15 | A sale stores its seller, its fee share and its end at start, and nothing else of the settings. The opening bid, the increment share, the increment floor and the anti-snipe window are read when a bid is placed, so a running sale follows the governed values in force at each bid. | `test_Bid_ARunningSaleFollowsTheSettingsInForceWhenTheBidIsPlaced`, `test_Bid_FirstBidReachesTheOpeningBidReadWhenBidding`, `test_Independent_TheFeeShareIsTheModulesKeptFromTheStart` |
| AUC-16 | The first bid is at least the opening bid (and 1 wei); a later bid adds at least the larger of the increment share and the floor. | `test_Bid_FirstBidReachesTheOpeningBidReadWhenBidding`, `test_Bid_ZeroIsNeverABid`, `testFuzz_Bid_IncrementRule` |
| AUC-17 | A bid in the last window moves the end to the bid's time plus the window; no bid is accepted at or after the end. | `test_Bid_InTheLastWindowExtendsTheEnd`, `test_Bid_BeforeTheWindowDoesNotExtend`, `test_Bid_RefusedAfterTheEnd` |
| AUC-18 | Outbid bids are credited to their payer, never pushed; only that account claims them. | `test_Bid_AnOutbidBidIsCreditedNotPushed`, `test_Claim_OnlyTheCreditedAccountClaimsItsCredit`, `test_Claim_SendsTheWholeCredit` |
| AUC-19 | Retired: ETH only; no ERC-20 payments. | |
| AUC-20 | The auction holds exactly its live high bids plus its credits; every sale ends at most once. | `test_Balance_EqualsStandingBidsPlusCredits`, `invariant_BalanceIsStandingBidsPlusCredits`, `test_Settle_RefusedBeforeTheEndAndOnce`, `test_Cancel_ThenNothingSettles` |
| AUC-21 | Settlement never depends on the recipient accepting the token: a failed delivery leaves a pending delivery. | `test_Settle_ARecipientThatRefusesLeavesAPendingDelivery`, `test_Settle_ARecipientThatBurnsGasLeavesAPendingDelivery` |
| AUC-22 | A settler that does not forward the delivery and payout gas is refused. | `test_Settle_RefusesASettlerThatWithholdsThePayoutOrDeliveryGas` |
| AUC-23 | A refused payout goes to the escrow for that wallet. | `test_Settle_ASellerThatRefusesIsPaidThroughTheEscrow`, `test_HostileFeeRecipient_IsPaidThroughTheEscrow` |
| AUC-24 | With no bid, a 6529 Stream work goes to the museum the economics resolver names at settlement; the auction transfers it. | `test_Settle_UnsoldStreamWorkGoesToTheMuseum`, `test_Settle_TheMuseumIsReadAtSettlement`, `test_Museum_UnbidWorkGoesToTheMuseum` |
| AUC-25 | Retired: no currency freeze (ETH only). | |
| AUC-26 | A dispute pause is once per live auction and lasts at most 3 days (a compiled value of the auction). | `test_Pause_OncePerSale`, `test_Pause_OnlyALiveSale`, `test_Pause_EndsByItselfAfterMaxPause` |
| AUC-27 | A resumed auction runs at least the longer of the governed duration and the governed anti-snipe window, both as they stand when it resumes. | `test_Resume_GivesBackAtLeastTheDuration`, `testFuzz_Resume_RunsAtLeastTheLongerOfTheDurationAndTheWindow`, `test_Pause_EndsByItselfAfterMaxPause` |
| AUC-28 | An Independent Stream token sells only while the Independent Stream module reports it active; an unsold Independent Stream work stays in the auction and can be started again there for the same item. | `test_Independent_AnUnlistedTokenCannotStart`, `test_Delisted_RefusesBidsAndEndsUnsoldWithARefund`, `test_Independent_AnUnsoldWorkStaysInCustodyWithNoOutcome`, `test_Restart_OffersAnUnsoldWorkAgainAndSellsIt` |
| AUC-29 | The auction refuses every safe transfer into it except its own mint. | `test_OnERC721Received_RefusesEverySafeTransferIn`, `test_OnERC721Received_AcceptsOnlyItsOwnMintDuringAStart` |
| AUC-30 | Governed auction parameters stay within bounds and are compare-and-set. | `test_SetConfig_WithinBoundsAndCompareAndSet`, `test_SetStreamPolicy_CompareAndSetAndChecked` |
| AUC-31 | No reentrant call reaches a value-moving function. | `test_HostilePolicy_CannotReenter`, `test_HostileToken_CannotReenterFromItsMint`, `test_HostileRecipient_ReenteringOnDeliveryChangesNothing`, `test_ExpireCredit_AReentrantClaimIsBlocked` |
| AUC-32 | Gas: every steady-state start row, with or without a bid, costs at most 370,000 Prague gas and writes at most 8 new slots. A start with a bid of a VRF work also writes the seed: at most 395,000 Prague gas and 9 new slots. Three other rows have regression ceilings of their own: the deployment's first start ever (357,000 Prague gas, 9 new slots), the auction's first bid (353,000, 8 new slots) and `SaleStarter.start`, which also deploys the vaults and opens the record (579,000, 13 new slots). These are test budgets, asserted in the gas report; no contract enforces them. | `test_Gas_Start_SteadyState`, `test_Gas_StartWithBid_TwoPartyWork`, `test_Gas_StartWithBid_VrfWork`, `test_Gas_StartWithBid_ArtistsFirstWork_TwoParty_Vrf_MaxParams`, `test_Gas_Start_FirstWorkInANewCollection`, `test_Gas_Start_FirstWorkEver`, `test_Gas_StartWithBid_FirstBid`, `test_Gas_SaleStarter_Start` |
| AUC-33 | An unsold 6529 Stream work is never a pending delivery: the auction moves it with a plain transfer, no receiver callback. | `test_Settle_AnUnsoldStreamWorkIsMovedWithoutAskingTheMuseum` |
| AUC-34 | Retired: the auction's views are its own. | |
| AUC-35 | The network may `rescue` a token only while a removed minter holds it with no outcome, once `rescueDelay` has passed since the removal; re-adding the minter clears the removal. | `test_Rescue_AfterFourteenDaysOnlyTheNetworkOnlyUnsold`, `testFuzz_Rescue_RefusedBeforeThePeriodInForce` |
| AUC-36 | A sale whose work was rescued closes with refunds only, and ends CANCELLED: the standing bid is credited back once, and nothing is recorded, paid or delivered. A rescued sale that is still running takes bids until its end; each is credited back once. | `test_Settle_ARescuedWorkClosesWithRefunds`, `test_Museum_RescueOfAWorkARemovedMinterHoldsAndTheSaleCloses`, `test_RescuedSale_WorkWithItsRecipient_TheBidIsRefunded`, `test_RescuedIndependentSale_WorkWithItsRecipient_TheBidIsRefunded`, `test_Settle_ARescueDuringTheSaleRefundsEveryBidOnce`, `test_Settle_ARescuedSaleDoesNotRefundAWithdrawnBidAgain` |
| AUC-37 | An outcome is NONE until recorded, then SOLD, UNSOLD or RESCUED for good. | `test_Sold_TheMinterCanDoNothingMore` |
| AUC-38 | The mint policy decides new mints only; Stream never calls it, and no answer of it changes an existing token. | `test_MintPolicy_DecidesNewMintsOnlyAndIsNeverCalledForAnExistingToken`, `test_ModuleSwap_TheMintPolicyComesOnlyFromTheNewRegistry` |
| AUC-39 | Retired: Stream holds no dependencies. | |
| AUC-40 | `supportsInterface` answers ERC-165, ERC-721, ERC-721 Metadata, ERC-2981, ERC-4906, `IStream`, `IModules` and `IModuleSlots`, and nothing else. | `StreamTest.test_SupportsInterface`, `testFuzz_SupportsInterface_NothingElse` |
| AUC-41 | `rescueDelay` is the network's setting (14 days at launch), changed at once, zero allowed, with old and new in `RescueDelaySet`. | `test_RescueDelay_FourteenDaysAtDeploymentOnlyTheNetworkSetsIt`, `testFuzz_Rescue_RefusedBeforeThePeriodInForce` |
| AUC-42 | `tokenURI` of a finalized work uses the renderer pinned in `StreamWorkFacts6529`; otherwise the RENDERER module. A missing, failing or changed renderer reverts; there is no fallback. | `test_RendererOf_PinnedThenModuleThenNone`, `test_RendererOf_AFailingReadFailsClosed`, `test_RendererOf_ShortGasNeverServesAnotherRenderer`, `test_Hostile_AsRenderer` |
| AUC-43 | `WorkMinted` carries the whole `MintFacts`; Stream's state is rebuilt from its logs alone. | `test_Mint_EmitsTransferAndWorkMintedWithEveryFact`, `test_Stream_EveryEventReplaysToTheSameState`, `test_Stream_ReplayFailsOnADroppedLog` |
| AUC-44 | One live token per content hash: a content mints again only after the token it names is burned, and then only as the mint policy allows. | `test_Mint_OnlyAMinterAndOneLiveTokenPerContent` |
| AUC-45 | `settleOrRefund` is for Independent Stream sales only, from 2 days after the end; a failed attempt closes the sale with the bid credited back. | `test_SettleOrRefund_OnlyIndependentAndOnlyAfterTheDelay`, `test_SettleOrRefund_ClosesWithARefundWhenTheTokenRefuses`, `test_SettleOrRefund_SettlesWhenTheTokenCooperates` |
| AUC-46 | The refusal delay is 2 days, compiled in the auction. | `test_SettleOrRefund_OpensAtTheEndPlusTheCompiledRefusalDelay`, `test_SettleOrRefund_OnlyIndependentAndOnlyAfterTheDelay` |
| AUC-47 | The refusal gas is governed, raise-only, at most doubled per step, between bounds in code. | `test_SetConfig_RefusalGasIsRaiseOnlyAtMostDoubledWithinItsBounds`, `test_SetConfig_WithinBoundsAndCompareAndSet` |
| AUC-48 | An Independent Stream sale's fee share is the Independent Stream module's, stored in the sale at start; the fee goes to the recipient the economics resolver names. | `test_Independent_TheFeeShareIsTheModulesKeptFromTheStart`, `test_Independent_SoldPaysTheIndependentFeeRecipient`, `test_Restart_TakesTheLoweredShare` |
| AUC-49 | Retired: there is no view extension. | |
| AUC-50 | The TERMS module may lower a work's fee share, never raise it, and deploys the new split wallet before naming it. | `test_LowerFeeShare_DeploysTheNewVaultFirstAndKeepsTheRate`, `testFuzz_LowerFeeShare_LowerOnlyNeverAnUndeployedReceiver`, `testFuzz_LowerFeeShare_TheFeeVaultsShareNeverRises` |
| AUC-51 | Only money that has itself waited the unclaimed period in force goes from a credit to the network; a later credit starts no earlier clock and no third party can shorten or postpone one. | `test_Expire_TakesOnlyTheMoneyThatWaitedThePeriod`, `test_AThirdPartyCanNeitherShortenNorPostponeAWait`, `testFuzz_NeverTakesMoneyYoungerThanThePeriod` |
| AUC-52 | Retired: ETH only; no permit payments. | |
| AUC-53 | Removing a minter is immediate: it mints nothing new but still records outcomes and burns for tokens it holds. | `test_RemoveMinter_AtOnceKeepsItsRecord` |
| AUC-54 | `moduleDelay` is the network's setting (7 days at launch), changed at once, zero allowed; a pending addition keeps its time. | `test_SetDelay_OnlyTheNetworkAtOnceWithOldAndNew`, `test_SetDelay_PendingAdditionsKeepTheirTime`, `test_SetDelay_ZeroIsAllowed` |
| AUC-55 | An unsold Independent Stream work is offered again (`restart`) only from 15 minutes after its last sale's end (`RESTART_DELAY`, compiled in the auction; `RestartTooEarly` before), with no later limit. The 15 minutes are the time an edition sale stays open after its 1/1's end (EA-17), so a sale that followed the ended sale has closed before the work has a new sale and a new end. | `test_Restart_RefusedBeforeTheRestartDelay`, `test_Restart_RefusedUntilTheEditionCloseOffsetAfterTheEnd`, `test_Restart_OffersAnUnsoldWorkAgainAndSellsIt` |
| AUC-56 | The auction knows a rescue by the outcome the token recorded, not only by where the work is. A rescued work that is in the auction's custody when its sale is settled (the network named the auction as the recipient, or the recipient sent the work back) closes the sale as AUC-36 says, and the auction sends the work to the museum the economics resolver names then, with a plain transfer. Adding the auction as a minter again changes nothing. A sale closed this way is never offered again. | `test_Settle_AWorkRescuedToTheAuctionItselfClosesWithRefunds`, `test_Settle_ARescuedWorkSentBackClosesWithRefunds`, `test_Settle_ARescuedWorkBackInCustodyWithNoBidGoesToTheMuseum`, `test_RescuedSale_RescuedToTheAuctionItself_TheBidIsRefundedAndTheWorkGoesToTheMuseum`, `test_RescuedSale_SentBackToTheAuction_TheBidIsRefundedAndTheWorkGoesToTheMuseum`, `test_RescuedSale_BackInCustodyWithNoBid_ClosesAndTheWorkGoesToTheMuseum`, `test_RescuedSale_ClosesTheSameAfterTheAuctionIsAddedAgain`, `test_Rescued_ToTheAuctionItselfClosesAtOnceAndNeverRestarts`, `test_Rescued_SentBackWithNoBidClosesAndGoesToTheMuseum`, `test_RescuedIndependentSale_RescuedToTheAuctionItself_ClosesAtTheEnd`, `test_RescuedIndependentSale_SentBackWithNoBid_ClosesAndGoesToTheMuseum` |
| AUC-57 | The English auction mints every work to itself and records the work's outcome before the work leaves it: SOLD before the delivery, UNSOLD before the transfer to the museum; a work waiting for a pending delivery stays with SOLD recorded. So a rescue reaches no work the auction sold, sent to the museum or holds for a buyer, whatever the network does to the minter list. | `test_Rescue_NeverReachesAWorkTheAuctionSold`, `test_Rescue_NeverReachesAWorkTheAuctionSentToTheMuseum`, `test_Rescue_NeverReachesAWorkWaitingForItsDelivery` |
| AUC-58 | A rescued work that reaches the auction when no settlement is left to forward it (rescued to the auction, or sent back, after its sale closed: an unsold Independent Stream work waits there with its sale settled) is sent to the museum by anyone with `sendRescuedToMuseum(saleId)`. Only a work whose recorded outcome is RESCUED qualifies, so a work waiting for a sale, a restart or a pending delivery is never moved, and no sale or credit changes. | `test_SendRescuedToMuseum_AWorkRescuedIntoTheAuctionAfterItsSaleClosed`, `test_SendRescuedToMuseum_ARescuedWorkSentBackAfterItsSaleClosed`, `test_SendRescuedToMuseum_OnlyARescuedWork`, `test_SendRescuedToMuseum_RefusesAPendingDeliveryAndAnUnsoldWork` |

## Events

Signatures and topics are on the [events page](../integrators/events-and-indexing.md). Stream:
`WorkMinted`, `PrimarySale` (outcome, buyer, price), `WorkRescued`, `RoyaltySet`,
`RoyaltyRateLocked`, `CollectionCreated`, `MinterAdded`, `MinterRemoved`, `ModuleProposed`,
`ModuleSet`, `ModuleDelaySet`, `RescueDelaySet`, `OwnershipTransferred`, `ContractURIUpdated`,
ERC-721 and ERC-4906.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| Start while paused | `SalePaused` | Wait for `unpause`. |
| The policy refuses | The policy's error; nothing mints | Fix the item or wait (a frozen account, an undelivered seed). |
| Bid too low or late | `BidTooLow(required, offered)`, `InvalidAuctionState` | Read `minimumBid(saleId)`. |
| Recipient refuses the token | `DeliveryPending`; settlement completes | The winner calls `claimDelivery` to any address. |
| A payout wallet refuses ETH | Credited in the escrow | Anyone flushes the escrow to the wallet. |
| An Independent Stream token will not settle | `settle` reverts | `settleOrRefund` from 2 days after the end. |
| The minter holding a work was removed | The work waits | The network re-adds the minter, or rescues after `rescueDelay`. |
| The network rescued a work whose sale was not settled | `settle` closes the sale CANCELLED (`RescuedSaleClosed`): the bid is credited back, a rescued work in the auction's custody goes to the museum, and an edition sale that followed is void | Anyone calls `settle`; the bidders claim. |
| `tokenURI`'s renderer is missing or fails | Reverts | Install a RENDERER module, or finalize to pin one. |
