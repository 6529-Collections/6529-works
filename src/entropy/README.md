# entropy

The optional VRF module of 6529 Stream: one random seed per work, delivered
by Chainlink VRF v2.5 **before the work's token exists**. Governed by
[ADR 0001](../../docs/adr/0001-v1-scope.md) §9 ("Seeded and generative
1/1s"). Pre-audit; nothing here claims production readiness.

Entropy is never in the Stream's mint path and never gives a copy its own seed.
Most seeded works use an artist-chosen seed committed in the package and never
touch this module. A package item opts in with seed policy `VRF`.

| File | Role |
| --- | --- |
| `VrfEntropyModule.sol` (interface: [`IEntropyModule`](../interfaces/IEntropyModule.sol)) | Requests a seed for a package item, stores it once the coordinator delivers it, answers `isDelivered`, `seedOf`, `requestOf` and ERC-165. Governed `setConfig` and `setCoordinator`. |
| `IVRFCoordinatorV2Plus.sol` | The one coordinator function the module calls (`requestRandomWords`), declared locally. There is no Chainlink dependency. |

Tests are in [`test/entropy/`](../../test/entropy), mocks in
[`test/mocks/EntropyMocks.sol`](../../test/mocks/EntropyMocks.sol).

## Flow (decision D4)

1. **Request.** Anyone calls `requestSeed(item, packageRoot, proof)` for a VRF
   item of an approved package, before any token exists. The module hashes the
   item itself, checks the gate (below), calls the coordinator and records the
   request ID.
2. **Delivery.** The coordinator calls `rawFulfillRandomWords(requestId,
   words)`. The module stores `bytes32(words[0])` under the item hash and emits
   `SeedDelivered`. It calls nothing: not the token, not the auction.
3. **Start.** The auction's `start` requires `isDelivered(itemHash)`, then
   consumes the item, mints and opens the 24-hour clock in one transaction.
   The Stream reads the seed with `seedOf(itemHash)` through the item hash it
   stores for each token.
4. **Repeat.** A request still undelivered `retryDelay` seconds after it was
   made may be requested again by anyone. A repeat **adds** a request and never
   invalidates an earlier one: a delivery for any outstanding request is
   accepted, **the first delivery fixes the seed**, and a later delivery for the
   same item is a silent no-op (it does not revert, so the oracle's fulfilment
   succeeds).

Nothing is in custody while a seed is outstanding, so a missing delivery
delays a work but never strands one. The seed is the VRF output unchanged, so
anyone can check it against the oracle's proof. It is stored once and never
changes: after delivery `requestSeed` reverts with `SeedAlreadyDelivered`.

## Who may call what, and the spam gate

`requestSeed` has no role. Each request spends subscription funds, so the gate
is the item and its package, not the caller. A request is accepted only if all
of these hold, and any failure is `NotRequestable(itemHash)`:

1. `item.seedPolicy` is `VRF` (the module hashes the whole item with
   `WorksHashing`, so the policy is the approved one: changing any field of an
   approved item makes a different, unapproved item);
2. `packageRegistry.packageOf(packageRoot)` is `APPROVED` (a guardian's
   `revokePackage` stops requests at once);
3. `proof` places `WorksHashing.leaf(itemHash)` under `packageRoot` (at most 32
   hashes, so the proof loop is bounded);
4. `packageRegistry.consumedItemOf(item.contentHash)` is zero: the item was not
   consumed, and its content hash was not claimed by another item (either way
   it could never mint).

The gate runs on every call, repeats included.

**Why this and not a fee or a fixed caller.**
- **A fee** would have to track the oracle's cost, which moves with gas prices
  and the payment mode, and would need a payable function and a funding path
  into the subscription.
- **A privileged requester** (a keeper or the platform) would put a trusted step
  into a flow that is otherwise permissionless: the artist could no longer
  start a VRF work without an operator.
- **A rate limit** alone lets a spammer drain the subscription at the cap and
  block honest requests.
- **The package gate** keeps requests open to anyone (the artist, a relayer, a
  bot) with no privileged step. The total possible spend is one draw per VRF
  item the network approved, plus one repeat per `retryDelay` for each item
  whose draw never arrived. The curation signer, the party consent and the
  guardian's revocation already bound that set.

**Accepted limits.**
- A hostile approved package with many VRF items could still drain the
  subscription, one draw per item. The guardian revokes it, and keeping the
  subscription balance topped up in small amounts bounds the loss.
- A request made before a revocation still delivers; the seed can never be
  used because the item can no longer mint.

| Function | Caller | Class |
| --- | --- | --- |
| `requestSeed` | Anyone, for a VRF item of an approved, unconsumed package | none |
| `rawFulfillRandomWords` | The coordinator only | none |
| `setConfig(expected, next)` | `Roles.PARAMETER_SETTER` | 48 hours, compare-and-set |
| `setCoordinator(expected, next)` | `Roles.SUCCESSOR_SETTER` | 30 days, compare-and-set |

Governed functions are non-payable and emit the previous and next values.
`requestSeed` is not payable either; the subscription pays. The deploy
configuration maps the two governed selectors as above; `test/entropy/VrfEntropyManaged.t.sol`
configures the module under the real `GovernanceConfigurator` and proves the
delay classes, the guardian's cancellation and that nothing is payable.

## ERC-165 and installs (decision D8)

The module supports ERC-165 and reports `type(IEntropyModule).interfaceId`, so
an install can check support, pin the code hash and reject an EIP-7702
delegated account. The module applies the same checks to what it depends on:

| Dependency | Checks |
| --- | --- |
| Package registry (constructor, immutable) | Has code, is not an EIP-7702 delegated account, answers ERC-165 for `IPackageRegistry`, and has the code hash passed as a constructor argument. |
| VRF coordinator (constructor and `setCoordinator(expected, next, nextCodeHash)`) | Has code, is not an EIP-7702 delegated account, has the pinned code hash, and (for a swap) differs from the current coordinator. |

The coordinator is a Chainlink contract with no ERC-165, so it gets the code and
hash checks only.

## Configuration

`VrfConfig` holds the subscription ID, key hash, callback gas limit, request
confirmations and the native-payment flag. `setConfig` takes the expected
current struct and reverts with `ExpectedValueMismatch` if it is stale.

| Parameter | Bounds |
| --- | --- |
| Callback gas limit | 100,000 to 2,500,000. **Raise-only** through `BoundedParameter`: each step may at most double it, never above the ceiling, never down (or left unchanged). The callback costs about 35,000 gas with every slot cold (measured), so the floor leaves a wide margin and a hostile setter cannot starve it. |
| Confirmations | 3 to 200 (the coordinator's own limits on Ethereum mainnet). |
| Subscription ID, key hash | Nonzero. |
| `retryDelay` (constructor, immutable) | 3 days to 30 days. Not an expiry: VRF v2.5 never expires a request on-chain, so a repeat waits until a delivery is plainly overdue. |

The coordinator is changeable (`setCoordinator(expected, next, nextCodeHash)`,
30 days) because the Stream and the auction hold this module's address
immutably: when Chainlink retires a coordinator, the module must be able to
follow. A swap affects only undelivered items. Every request is remembered under
the coordinator that issued it (`coordinator => requestId => item`), so the old
coordinator can no longer deliver, the new one cannot deliver what the old one
issued, and the two may use the same numbers, even across A to B to A. Requests
the old coordinator still held are requested again after `retryDelay`.
Delivered seeds never change.

## Trust and failure modes

| Actor | Can | Cannot |
| --- | --- | --- |
| VRF coordinator | Deliver the seed of an item for any request it was given; the first delivery is final | Pick which items are VRF, change a delivered seed, deliver for a request it was not given |
| Anyone | Request a VRF item of an approved, unconsumed package; repeat it after `retryDelay` | Request an unapproved, revoked, consumed or non-VRF item, or one already delivered |
| `PARAMETER_SETTER` | Change the lane, subscription, confirmations, payment mode, and raise the gas limit | Lower the gas limit, exceed the bounds, change the coordinator |
| `SUCCESSOR_SETTER` | Replace the coordinator (30 days, guardians can cancel) | Alter a delivered seed |

- **First delivery wins (and why a repeat does not supersede).** Chainlink VRF
  v2.5 never expires a pending request on-chain, so an earlier request can
  still be delivered after a repeat was made. The pending fulfilment is public
  before it is included, and so is the word in it. If a repeat invalidated the
  earlier request, an observer who dislikes that word could front-run a repeat
  and have the delivery discarded in favour of a fresh draw. Accepting every
  outstanding request, with the first delivery final, removes that option.
  **Residual risk:** while two requests are outstanding at once, whoever orders
  the two deliveries (a searcher or a block builder) chooses which of two
  independent random words becomes the seed. The 3-day minimum `retryDelay` keeps
  that window rare; it is not closed. This deviates from the ADR's "a request
  that never delivered may be re-requested" in being additive (ADR 0003).
- **A malformed callback** (not exactly one word) reverts, is absorbed by the
  coordinator, and leaves the item undelivered; it is requested again after
  `retryDelay`. A callback for an item whose seed is fixed never reverts.
- **Reentrancy.** `requestSeed` records the request time before it calls the
  coordinator and the request ID after, so a reentrant call finds a pending
  request and cannot deliver the new ID, which is not yet recorded. A reentrant
  delivery of an earlier request is valid: if it fixes the seed during the call,
  the new request is recorded (its own delivery is then a no-op) but is not
  announced as the item's current request, and no `SeedRequested` is emitted.
- **Funding.** The subscription pays, never the caller. The module must be added
  as a consumer of the subscription, and an unfunded subscription means
  undelivered items (requested again after the delay).
- **A zero seed** is a valid delivery (probability 2^-256); delivery is
  tracked by a flag, not by a nonzero seed.

## Operations: the subscription and a coordinator change

- **Use a dedicated subscription.** One subscription, this module its only
  consumer. A shared subscription can be drained by its other consumers, and the
  module cannot see or limit them.
- **Chainlink's `migrate` cannot be used.** The subscription migration helper
  calls `setCoordinator(address)` on each consumer, and this module has no such
  function: its `setCoordinator(expected, next, nextCodeHash)` is a governed,
  compare-and-set, code-hash-pinned setter with a 30-day delay.
- **To change coordinators:**
  1. On the new coordinator, create a new subscription, fund it and add the
     module as a consumer.
  2. Schedule `setCoordinator(old, new, newCodeHash)` (30 days, `SUCCESSOR_SETTER`).
  3. Schedule `setConfig` with the new subscription ID and key hash so that it
     becomes executable at the same time (48 hours, `PARAMETER_SETTER`; schedule
     it 48 hours before the swap is due).
  4. Execute the two back to back, in one transaction batch: between them a request
     would go to a coordinator that does not know the subscription (or the reverse)
     and revert.
  Requests the old coordinator still held are orphaned: it can no longer deliver
  them, and they are requested again after `retryDelay`.
- **A request that never delivers blocks cancelling the subscription.** The
  coordinator refuses to cancel a subscription with a pending request (confirm
  against the current Chainlink documentation), and VRF v2.5 never expires one.
  Plan for it: keep the old subscription funded until its requests deliver, and
  do not count on recovering its balance quickly.
- **Keep the balance modest and topped up.** The package gate bounds the total
  spend per approved VRF item; a hostile approved package is stopped by the
  guardian's `revokePackage`, and a small balance bounds what it can drain first.

## Gas

Measured by `test/entropy/VrfEntropyModule.t.sol` (see the test logs):

- **Callback:** about 35,000 gas with every slot cold, against a 100,000
  floor.
- **`requestSeed`:** about 153,000 gas including the two registry reads, hashing
  the item, a two-hash proof, three new storage slots and a mock coordinator
  that stores one slot. A real coordinator costs more. The request is off the
  auction's start path (D4), so the 300,000-gas start budget (ADR 0001 §5) does
  not apply to it; `start` pays only for reading `isDelivered`.

## Out of scope

- Reveals after settlement ("mystery" works) are not in v1 (ADR 0001 §9).
- Per-copy seeds (ADR 0001 §9; "1/1/x" is NextGen).
- A fallback to another randomness source. VRF alone is acceptable.
- Wiring into the Stream and the auction: those lanes read `isDelivered` and
  `seedOf` by item hash.
