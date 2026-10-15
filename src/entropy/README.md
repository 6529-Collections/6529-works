# entropy

The optional VRF module of 6529 Stream: one Chainlink VRF v2.5 random word per work, keyed by
the work's content hash and delivered before its auction can start. Most seeded works use an
artist-chosen seed in the package and never touch this module; an item opts in with seed policy
`VRF`. The rules are in [Entropy](../../docs/spec/entropy.md) (`ENT-*`), including the request
gate, the retry rule and the coordinator change.

## Files

| File | What it is |
| --- | --- |
| `VrfEntropyModule.sol` | Implements [`IEntropyModule`](../interfaces/IEntropyModule.sol): the gated `requestSeed`, the coordinator's `rawFulfillRandomWords`, the reads by item hash (`isDelivered`, `seedOf`, `requestOf`), and the governed `setConfig`, `lowerCallbackGasLimit` and `setCoordinator`. |
| `IVRFCoordinatorV2Plus.sol` | The one coordinator function the module calls (`requestRandomWords`), declared locally: the repository has no Chainlink dependency. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone (the artist, a relayer, a bot) | `requestSeed(item, packageRoot, proof)` for a `VRF` item of an approved, unconsumed package; links the item to its content's draw, and asks the coordinator only if the content has no pending or delivered draw | ENT-1, ENT-2, ENT-5, ENT-14, ENT-15, ENT-17 |
| The current coordinator | `rawFulfillRandomWords(requestId, words)`; the first delivery fixes the seed, later ones are silent no-ops | ENT-4, ENT-6 to ENT-8, ENT-13 |
| `Stream.mint`, inside the auction's `start` | `isDelivered(itemHash)`, after the item is consumed; a `VRF` item without a delivered seed reverts the start with `SeedNotDelivered` | ENT-12 |
| `WorkRecords` and the renderer | `seedOf(itemHash)` | ENT-3 |
| Governance | `setConfig`, `lowerCallbackGasLimit`, `setCoordinator` | ENT-9 to ENT-11; [role matrix](../../docs/audit/roles.md#entropymodule) |

Only 6529 Stream holds the module's address (immutably, or zero for a deployment without VRF);
the auction never calls it. Flows are under [Flows](../../docs/spec/entropy.md#flows), events
under [VrfEntropyModule events](../../docs/integrators/events-and-indexing.md#vrfentropymodule).

## Developer notes

- **Storage.** `_seeds[contentHash]` is one `Seed`: a value word that holds the latest request
  ID until delivery and the seed after it, plus the request time and the delivered flag. The
  callback overwrites a word `requestSeed` already made nonzero, so a delivery creates no
  storage slot; keep it that way (ENT-13). `_contentOf[itemHash]` is the item link, and
  `_requests[coordinator][requestId]` remembers every request under the coordinator that
  issued it, never removed.
- **Request cost.** A content's first request creates four slots in the module (link, the
  draw's two words, the request record), a joining item one; the test
  `test_Request_NewStorageSlots` pins both. The request is off the auction's start path, which
  pays only for `isDelivered`.
- **Order inside `requestSeed`.** The request time is written before the coordinator call and
  the request ID after it, so a reentrant call finds a pending draw and cannot deliver the new
  ID. Do not reorder these writes without rerunning the reentrancy tests.
- **A delivery never reverts for a fixed seed**, so the oracle's fulfilment succeeds; a
  malformed callback (not exactly one word) reverts and the item is requested again after
  `retryDelay`. Delivery is tracked by a flag, so a zero seed is valid.
- **Callback gas.** The floor (`MIN_CALLBACK_GAS`) is sized against the callback's measured
  Glamsterdam cost, recorded in
  [ADR 0004, security impact](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#security-impact);
  re-measure both if the callback changes.
- **Operations** (dedicated subscription, the coordinator change in one batch, why Chainlink's
  `migrate` cannot be used) are in the spec's
  [coordinator change](../../docs/spec/entropy.md#coordinator-change) and the
  [runbook, step 7](../../script/README.md#7-chainlink-vrf-the-entropy-module).
- **Bytecode:** wide margin; figures in the
  [audit scope](../../docs/audit/scope.md#curation-identity-and-records).
- **Tests:** `forge test --match-path 'test/entropy/**'`: unit, fuzz, the invariant suite,
  governance and `VrfEntropyManaged.t.sol`, which installs the module under the real
  `GovernanceConfigurator`. End to end: [`VrfWork.t.sol`](../../test/integration/VrfWork.t.sol).
  Mocks are in [`test/mocks/entropy/EntropyMocks.sol`](../../test/mocks/entropy/EntropyMocks.sol). Coverage and
  mutation testing: [Testing](../../docs/testing/README.md).

## Not in v1

Reveals after settlement, per-copy seeds and a fallback randomness source
([ADR 0001 §9](../../docs/adr/0001-v1-scope.md#9-seeded-and-generative-11s)).

## See also

[ADR 0003, sales and auctions](../../docs/adr/0003-build-time-decisions.md#sales-and-auctions-amends-adr-0001-5-6-and-9)
(requests before minting, the lowerable gas limit, additive retries);
[known limitations](../../docs/audit/known-limitations.md#entropy) LIM-ENT-1 to LIM-ENT-5;
[trust assumptions](../../docs/audit/trust-assumptions.md).
