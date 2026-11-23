# Entropy (optional VRF seeds)

A seeded 1/1 gets its seed from the artist, in the package, or from a Chainlink VRF v2.5 draw
delivered before the work's auction can start. This page covers the draw: `VrfEntropyModule`
requests one random word per content hash, keeps the first delivery for good, and answers
`isDelivered` and `seedOf`. The module is **replaceable**: the mint policy names it
(`PackageRegistry.setEntropyModule`) and reads the delivered seed at mint, and the token then
stores the seed (`Work.seed`) for good. Replacing the module changes no existing work's seed.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`VrfEntropyModule`](../../src/entropy/VrfEntropyModule.sol) ([`IEntropyModule`](../../src/interfaces/IEntropyModule.sol)) | module | Gated seed requests, item links, deliveries, `isDelivered`, `seedOf`, `requestOf`; Independent Stream requests through the VRF wrapper; governed configuration, coordinator and wrapper. |
| [`IVRFCoordinatorV2Plus`](../../src/entropy/IVRFCoordinatorV2Plus.sol), [`IVRFV2PlusWrapper`](../../src/entropy/IVRFV2PlusWrapper.sol) | interfaces | The Chainlink functions the module calls, declared locally (no Chainlink dependency). |
| [`PackageRegistry`](../../src/curation/PackageRegistry.sol) | module | Answers the request gate (root approved, content consumed); at mint refuses a VRF item whose seed is not delivered and states the seed in the mint facts. |
| [`Stream6529`](../../src/core/Stream6529.sol) | permanent | Stores each work's seed at mint (`workOf(id).seed`); never asks the module. |

## Concepts

The glossary defines [seed](../glossary.md#seed), [seed policy](../glossary.md#seed-policy) and
[VRF](../glossary.md#vrf).

| Policy | `seed` in the package | Source of the seed |
| --- | --- | --- |
| `NONE` | zero | No seed. |
| `ARTIST` | nonzero, chosen by the artist | The package (CUR-9). |
| `VRF` | zero | `VrfEntropyModule`, drawn before the start. |

- **One draw per content hash.** Every approved item that carries the same work (a revised
  package, or the rightful artist's item after a content release) reads the same seed. Reads are
  keyed by item hash through a link that `requestSeed` records (`SeedLinked`); an item that joins
  a pending or delivered draw only links and returns zero.

### The request gate

Each request spends subscription funds, so `requestSeed(item, packageRoot, proof)` accepts only a
curated item that needs a seed. Anyone may call it; there is no fee. Every failure is
`NotRequestable(itemHash)`:

1. `item.seedPolicy` is `VRF` and `item.contentHash` is nonzero (the module hashes the item
   itself);
2. the root is `APPROVED` in the package registry, so `revokePackage` stops requests at once;
3. the proof has at most 32 hashes and places the item under the root;
4. no item has consumed the content. One exception requests nothing: the item that consumed the
   content (`consumedItemOf`) may still link to the content's delivered seed (ENT-19).

### First delivery wins

Chainlink VRF v2.5 never expires a pending request, so any outstanding request of the current
coordinator may deliver until the seed is fixed; later deliveries return without reverting. A
repeat never invalidates an earlier request. While several requests are outstanding, whoever can
withhold or order their deliveries chooses which word becomes the seed
([LIM-ENT-1](../audit/known-limitations.md#entropy)); the backoff bounds how many there are.

### Retry delay

`retryDelay` (immutable, 3 to 30 days) is the base of an exponential backoff: the k-th repeat of
an undelivered content may be made `retryDelay * 2^(k-1)` after the previous request, capped at
`MAX_RETRY_DELAY` (30 days). At a 3-day base the repeats fall on days 3, 9, 21 and 45, then every
30 days: at most 15 requests in a year. The count belongs to the content and to the coordinator's
tenure; after `setCoordinator` the first request to the new coordinator is made at once.

### Independent Stream seeds (requester pays)

`requestIndependentSeed(token, item)` serves a VRF work of an Independent Stream contract: only a
wallet of the contract's artist (`IAccounts.isWallet`, read through `StreamDirectory6529.ACCOUNTS`),
while the Independent Stream module (`StreamDirectory6529.INDEPENDENT_STREAM`) lists the contract
active, and the caller pays the wrapper's quoted price, all forwarded to the Chainlink VRF v2.5
wrapper. The network's subscription is never used. The draw is keyed by
`keccak256(abi.encode(token, contentHash))` and kept apart from curated draws.

<a id="coordinator-change"></a>

## Flows

1. **Request.** Anyone calls `requestSeed` for an approved VRF item.
2. **Deliver.** The coordinator calls `rawFulfillRandomWords`; the first delivery stores the seed
   and emits `SeedDelivered` (keyed by content hash).
3. **Start.** The sale contract's `authorize` call reaches the mint policy, which refuses an
   undelivered VRF item and states `seedOfContent(contentHash)` in the mint facts.
4. **Retry.** If nothing arrives, anyone repeats the request once the backoff wait has passed.
5. **Coordinator change.** The network calls `setCoordinator` (SUCCESSOR_SETTER, 7 days),
   compare-and-set with a pinned code hash. Request IDs are scoped to their coordinator, so the old
   one's requests can no longer deliver; each pending content is requested again at once. If
   Chainlink lowers its maximum callback gas, `lowerCallbackGasLimit` (7 days) follows it.

## Rules and invariants

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| ENT-1 | A request is accepted only for a `VRF` item with a nonzero content hash, placed by a proof of at most 32 hashes under an `APPROVED` root, whose content is unconsumed; checked on every call, with the one link-only exception of ENT-19. | `VrfEntropyModule.requestSeed` | `test_Gate_RejectsAnUnknownOrRevokedPackage`, `test_Gate_RejectsAnItemThatIsNotInThePackage`, `test_Gate_ThePolicyCannotBeFlippedToVrf`, `test_Gate_RejectsAConsumedItem`, `test_Gate_RejectsAnItemWithoutAContentHash`, `test_Gate_RevocationStopsARepeatButNotTheReads`, `testFuzz_OnlyItemsOfAnApprovedPackageCanBeRequested`, `testFuzz_NonVrfItemsAreAlwaysRefused` |
| ENT-2 | One draw per content hash: every linked item carrying the content reads the same seed, and joining never asks the coordinator. | `VrfEntropyModule.requestSeed` | `test_Content_ASecondItemJoinsTheDeliveredDrawWithoutARequest`, `test_Content_ASecondItemJoinsAPendingDrawAndSharesItsClock`, `invariant_ItemsThatShareContentReadOneSeed` |
| ENT-3 | An item never linked reads as undelivered; `seedOf` reverts until delivery. | `VrfEntropyModule.isDelivered`, `seedOf` | `test_Content_AnUnlinkedItemReadsAsUndelivered`, `test_SeedOf_RevertsBeforeDelivery` |
| ENT-4 | The first delivery fixes the seed for good, whichever outstanding request it answers; a later delivery for the content is a no-op that does not revert; no request is accepted after delivery. | `VrfEntropyModule.rawFulfillRandomWords`, `requestSeed` | `test_Fulfill_TheFirstDeliveryWinsInEitherOrder`, `test_Fulfill_ADoubleFulfilIsANoOp`, `test_NoRequestAfterDelivery`, `test_Repeat_TheFirstDeliveryStillWinsUnderTheBackoff`, `testFuzz_TheFirstDeliveryOfManyRequestsWins`, `testFuzz_SeedIsTheDeliveredWord`, `invariant_AtMostOneSeedPerItemAndItNeverChanges` |
| ENT-5 | The k-th repeat is possible only once `retryDelay * 2^(k-1)`, capped at 30 days, has passed since the previous request, for any caller; the count belongs to the coordinator tenure of the latest request, so the first request after a coordinator replacement is made at once; once the capped wait has passed a repeat is always accepted. A repeat never invalidates an earlier request. | `VrfEntropyModule.requestSeed` | `test_Repeat_BeforeTheTimeoutReverts`, `test_Repeat_AfterTheTimeoutIsOpenToAnyone`, `test_Repeat_TheWaitDoublesForTheFirstFourRepeats`, `test_Repeat_TheWaitIsCappedAtTheMaximumRetryDelay`, `test_Repeat_ARepeatIsAlwaysEventuallyAccepted`, `testFuzz_Repeat_IsAcceptedOnceTheCappedWaitHasPassed`, `test_Repeat_NoCallerRepeatsBeforeTheCurrentWait`, `test_Repeat_ACoordinatorSwapRestartsTheBackoff`, `test_Repeat_WithoutASwapTheScheduleIsUnchanged`, `test_Repeat_ARestoredCoordinatorsEarlierRequestsMayDeliverAgain`, `test_Repeat_TheBoundHoldsPerCoordinatorTenure`, `test_Repeat_AtMostFifteenRequestsInAYearAtAThreeDayBase`, `test_Repeat_CreatesOnlyTheRequestRecord`, `test_Fulfill_AnEarlierRequestStillDeliversAfterARepeat`, `test_Fulfill_ARepeatCannotDiscardAPendingDelivery`, `test_Repeat_UsesTheCurrentConfiguration`, `testFuzz_RetryWindow`, `invariant_TheCurrentRequestIsTheLastIssued`, `invariant_TheBackoffBoundsTheRequestsOfAContent` |
| ENT-6 | Only the current coordinator, or the current wrapper for an Independent Stream request, delivers, only a request it issued to this module, with exactly one word. | `VrfEntropyModule.rawFulfillRandomWords` | `test_Fulfill_OnlyTheCoordinatorMay`, `test_Fulfill_AnUnissuedRequestIdReverts`, `test_Fulfill_ExactlyOneWordIsRequired`, `test_Fulfill_AMalformedDeliveryRevertsAndTheItemStaysUndelivered`, `testFuzz_OnlyTheCoordinatorMayFulfill`, `testFuzz_RequestIdsRouteToTheirOwnItems` |
| ENT-7 | The coordinator's pinned code hash is checked at install, at every request and at every delivery. | `Dependency.checkPinned`, `checkUnchanged` | `test_Constructor_PinsTheCoordinatorCodeHash`, `test_Pin_ACoordinatorWhoseCodeChangedIsRefused`, `test_SetCoordinator_PinsTheCodeHash` |
| ENT-8 | Request IDs are scoped to their coordinator: a swap orphans the old coordinator's requests, the new one cannot deliver them, and delivered seeds survive. | `VrfEntropyModule.rawFulfillRandomWords` | `test_SetCoordinator_OldCoordinatorCanNoLongerDeliver`, `test_SetCoordinator_OrphanedRequestIsRerequestedThroughTheNewOne`, `test_SetCoordinator_RequestIdsAreScopedToTheirCoordinator`, `test_SetCoordinator_DeliveredSeedsSurviveTheSwap`, `test_Repeat_RequestIdsDoNotMixAcrossCoordinators` |
| ENT-9 | `setCoordinator` is compare-and-set, never a no-op, and refuses a codeless or delegated coordinator. | `VrfEntropyModule.setCoordinator`; genesis role map | `test_SetCoordinator_NeedsTheSuccessorClassRole`, `test_SetCoordinator_RejectsStaleAndCodelessValues`, `test_SetCoordinator_ASwapToTheCurrentCoordinatorIsRefused`, `test_SetCoordinatorIsInTheSuccessorClass`, `test_TheNetworkCancelsAPendingCoordinatorSwap` |
| ENT-10 | `setConfig` is compare-and-set on the whole configuration, within bounds; the callback gas limit only rises, at most doubling per step, never above 2,500,000. | `VrfEntropyModule.setConfig`; `BoundedParameter.raise` | `test_SetConfig_NeedsTheStandardClassRole`, `test_SetConfig_StaleExpectedValueReverts`, `test_SetConfig_GasLimitCanOnlyBeRaised`, `test_SetConfig_GasLimitAtMostDoublesPerStep`, `testFuzz_SetConfig_GasLimitRule`, `test_SetConfig_ScheduledThroughTheManagerAndStaleOperationsRevert`, `test_SetConfigIsInTheStandardClass` |
| ENT-11 | `lowerCallbackGasLimit` is compare-and-set, strictly lower, never below 100,000. | `VrfEntropyModule.lowerCallbackGasLimit` | `test_ALoweredCoordinatorMaximumIsFollowedInTheSuccessorClass`, `test_ALoweringStaysAboveTheFloorAndBelowTheCurrentLimit`, `test_OnlyTheSettersCanCallTheGovernedFunctions` |
| ENT-12 | A `VRF` work starts only once the seed of its item's content is delivered; the mint policy checks it and states the seed in the mint facts. | `PackageRegistry._seed` | `test_facts_vrfSeedOnlyOnceDelivered`, `test_VrfWork_SeedRequestedDeliveredThenStartedStoredAndRendered` |
| ENT-13 | The callback creates no storage slot and its cost stays at most half the 100,000 floor under Glamsterdam pricing. | `VrfEntropyModule.rawFulfillRandomWords` | `test_Callback_CreatesNoStorageSlot`, `test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam`, `test_Callback_GasStaysUnderTheConfiguredLimit` |
| ENT-14 | A reentrant call during a request cannot deliver the new request or overwrite a seed delivered meanwhile. | `VrfEntropyModule.requestSeed` | `test_Request_ReentrancyFromTheCoordinatorFindsNothingToUse`, `test_Repeat_AnEarlierRequestDeliveredDuringTheRepeatIsNotOverwritten` |
| ENT-15 | A coordinator's request ID must be nonzero and unused; a failing coordinator leaves no state. | `VrfEntropyModule.requestSeed` | `test_Request_RejectsAZeroRequestId`, `test_Request_RejectsADuplicateRequestId`, `test_Request_CoordinatorFailureLeavesNoState` |
| ENT-16 | Installation checks: `retryDelay` within 3 to 30 days; a valid configuration; the registry has code, is not delegated, answers ERC-165 for `IPackageRegistry` and has its pinned code hash. | `VrfEntropyModule` constructor | `test_Constructor_RejectsBadRetryDelay`, `test_Constructor_TheMinimumRetryDelayIsThreeDays`, `test_Constructor_RejectsARegistryWithoutErc165Support`, `test_Constructor_PinsTheRegistryCodeHash`, `test_Constructor_RejectsADelegatedRegistry` |
| ENT-17 | Anyone may request a curated seed; `requestSeed` is not payable (only `requestIndependentSeed` takes a payment, all forwarded to the wrapper). | `VrfEntropyModule` | `test_AnyoneMayRequestASeedUnderTheRealManager`, `test_NothingIsPayable`, `test_Request_NoRoleIsNeeded`, `test_Request_IsNonPayable` |
| ENT-18 | A work's seed is stored in the token at mint and never changes; replacing the entropy module changes no existing work's seed. | `Stream6529.mint` | `test_Mint_StoresFactsAndCountsSerial` |
| ENT-19 | After its content is consumed, only the consuming item, a `VRF` item not yet linked, links to the content's delivered seed, with no proof or package check and no request; every other call for a consumed content reverts with `NotRequestable`. | `VrfEntropyModule.requestSeed` | `test_Content_TheConsumingItemLinksToTheDeliveredSeedAfterConsumption`, `test_Gate_AfterConsumptionNoDrawIsRequested`, `test_Gate_AfterConsumptionOnlyTheConsumingItemLinksToItsOwnContent`, `test_Gate_RejectsAConsumedItem` |
| ENT-20 | `requestIndependentSeed` accepts only a `VRF` item with a nonzero content hash, for a contract the Independent Stream module lists active, from a wallet of its artist, with a wrapper set, and a payment of at least the wrapper's quote; all of `msg.value` goes to the wrapper. | `VrfEntropyModule.requestIndependentSeed` | |
| ENT-21 | An Independent Stream request never touches the network's subscription; only the wrapper that issued it delivers it. | `VrfEntropyModule.requestIndependentSeed`, `rawFulfillRandomWords` | `test_RequestIndependentSeed_AnArtistWalletPaysTheQuoteAndTheWrapperDelivers`, `test_Fulfill_TheProviderAloneDeliversItsRequests`, `test_Fulfill_ACuratedDrawNeverFillsAnIndependentSeed` |
| ENT-22 | `setWrapper` is compare-and-set, never a no-op; a nonzero wrapper must have code, no delegation and the pinned code hash, checked again at every request and delivery; zero turns Independent Stream requests off. | `VrfEntropyModule.setWrapper` | `test_SetWrapper_IsGovernedCompareAndSetAndPinned`, `test_SetWrapper_RefusesADelegatedAccount`, `test_SetWrapper_RefusesAnAccountWithoutCode`, `test_RequestIndependentSeed_RefusesAProviderWhoseCodeChanged`, `test_SetWrapper_ZeroTurnsPaidDrawsOff` |

## Events

Signatures and topic0 are under [VrfEntropyModule](../integrators/events-and-indexing.md#vrfentropymodule).
`SeedDelivered` is keyed by content hash: map items to it through `SeedLinked`.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| The oracle does not deliver (outage, unfunded subscription). | The work cannot start; nothing is in custody. | Fund the subscription; anyone repeats the request after the backoff wait. |
| Code at the coordinator's address changed. | Requests and deliveries revert (`DependencyCodeChanged`). | `setCoordinator` to a reviewed coordinator. |
| Chainlink lowers the coordinator's maximum callback gas. | Every request reverts at the coordinator. | `lowerCallbackGasLimit`, never below 100,000. |
| A hostile approved package requests many draws. | One draw per content plus repeats, until the root is revoked. | [LIM-ENT-2](../audit/known-limitations.md#entropy); a dedicated subscription with a modest balance. |

Use a dedicated subscription with this module as its only consumer, keep its balance modest, and
keep an old subscription funded until its requests deliver
([LIM-ENT-3](../audit/known-limitations.md#entropy)).

## Parameters and limits

| Parameter | Value | Source |
| --- | --- | --- |
| Callback gas limit | 100,000 to 2,500,000; raised at most 2x per `setConfig` | `MIN_CALLBACK_GAS`, `MAX_CALLBACK_GAS`, `BoundedParameter.raise` |
| Confirmations | 3 to 200 | `MIN_CONFIRMATIONS`, `MAX_CONFIRMATIONS` |
| `retryDelay` (immutable) | 3 to 30 days | `MIN_RETRY_DELAY`, `MAX_RETRY_DELAY` |
| Proof length | at most 32 hashes | `MAX_PROOF_LENGTH` |
| Deploy defaults | callback gas 200,000; 3 confirmations; `retryDelay` 3 days; no module when `VRF_COORDINATOR` is unset | [`script/ScriptIO.sol`](../../script/ScriptIO.sol), [runbook](../../script/README.md) |

## References

- Code: the sources under [Contracts](#contracts), [`src/entropy/README.md`](../../src/entropy/README.md).
- ADRs: [ADR 0001 §9](../adr/0001-v1-scope.md#9-seeded-and-generative-11s),
  [ADR 0003](../adr/0003-build-time-decisions.md#sales-and-auctions-amends-adr-0001-5-6-and-9).
- Tests: [`test/entropy/`](../../test/entropy/); how to run them: [testing](../testing/README.md).
- Related: [curation.md](curation.md), [stream-and-auctions.md](stream-and-auctions.md),
  [Independent Stream.md](independent-stream.md).
