# integration

End-to-end flows on the real, wired v1 contracts (integration lane B). Nothing
between v1 modules is mocked. Only external systems are:
- the 6529 delegation contract, using the identity lane's faithful reduction;
- the Chainlink VRF v2.5 coordinator, using the entropy lane's mock;
- Permit2, using the sales lane's faithful reproduction placed at the canonical
  address with `deployCodeTo`;
- an EIP-2612 ERC-20.

```bash
forge test --match-path "test/integration/*"
forge test --match-test test_Gas_Table -vv   # prints the gas table
```

## Deployment

[`WorksDeployment.sol`](WorksDeployment.sol) deploys the system with Lane A's
deploy library, [`script/DeployV1.sol`](../../script/DeployV1.sol), the same code
the deploy script broadcasts:
- `DeployV1.deploy` creates every v1 contract in dependency order, with the immutable
  and pinned dependencies as constructor arguments;
- `DeployV1.install` runs `GovernanceConfigurator.configure` with the committed
  [`config/genesis.example.json`](../../config/genesis.example.json): its role and
  selector map and its genesis wiring.

The JSON's placeholder holders are replaced by the tests' actors, so the curation
signers are keys the tests hold.

[`IntegrationBase.sol`](IntegrationBase.sol) adds the actors and package building.
It signs EIP-712 digests read from the contracts, builds sorted-pair Merkle trees
over `WorksHashing.leaf`, and drives sales and governed actions. A zero-delay role
acts directly; any other role is scheduled, waited out and executed.

## Flows

| File | Flow (integration brief) |
| --- | --- |
| [`CuratedSale.t.sol`](CuratedSale.t.sol) | 1. Package, attestation, registration, acceptance and move signature; `start` and `startWithBid`; bids and anti-snipe; `settle`; split-wallet release (the artist pulls, a keeper pushes the collaborator); `royaltyInfo` against the resolver. Also an ERC-20 auction started with a relayed Permit2 bid, the escrow fallback, a pending delivery, and the guardian's curation controls. |
| [`MasterEdition.t.sol`](MasterEdition.t.sol) | 2. Master settles, then `createEdition` (a revoked root still counts, an unregistered one does not); both directions of the link. A new sale method admitted by governance mints copies. Linked metadata. The edition royalty follows a master re-rate, and a zero-fee edition locks no fee. |
| [`ContentToTokenURI.t.sol`](ContentToTokenURI.t.sol) | 3. The uploader's golden calldata, then `attestBase64`, `openRecord`, `finalize` and `syncOnChain`; `tokenURI` in locator and inline modes; and the gas matrix. |
| [`RecordAmendments.t.sol`](RecordAmendments.t.sol) | 3, continued. Relicense with consent and governance, a new default renderer, the errata repin, and artist and owner statements. |
| [`IdentityRecovery.t.sol`](IdentityRecovery.t.sol) | 4. Registration and consolidation standing; stage, cancel, veto and execute; the payout freeze during a change and an override; sticky standing against a key thief; the split-wallet pull and signed release after recovery. |
| [`Dispute.t.sol`](Dispute.t.sol) | 5. Guardian pause; the PLATFORM `DISPUTE_OUTCOME` statement shown by the renderer; the 48-hour governed `cancel` (refund, then burn); the governed `releaseContent` to the rightful artist, whose item then consumes while another copy is refused; outcomes name existing tokens, and a pre-mint outcome shows on the work and its edition. Also a rejected dispute, a lapsed pause, an after-sale dispute and the emergency pause. |
| [`Museum.t.sol`](Museum.t.sol) | The museum rule (D140, ADR 0005): the museum wired at genesis in the 14-day FUNDS_SETTER class and read back as Verify does; a governed change and its refusals; an unbid work to the museum named at settlement; the 30-day freeze exit to the museum with the bid refunded; the museum's pending delivery that the artist cannot claim; and a federated work's unbid outcome, which stays with its artist. |
| [`VrfWork.t.sol`](VrfWork.t.sol) | 6. `requestSeed`, the mock fulfilment, `start`, and the seed in the metadata. Also the 3-day retry and the artist seed. |
| [`Genesis.t.sol`](Genesis.t.sol) | 7. Deploy, configure and wire. The readback passes and the configurator keeps no ADMIN. Guardians cancel hostile admin operations, the cold admin removes the hot admin, and `configure` fits the transaction cap. |
| [`StreamSaleMethods.t.sol`](StreamSaleMethods.t.sol) | Owner decision 15: a second 1/1 sale method, admitted on Stream through the 30-day governance path, sells a work end to end (mint into custody, price from the item's params, fee and seller paid, delivery, settled); an unadmitted adapter is refused; each adapter sells only its own kind; the English auction works unchanged beside it; removing the English auction stops new starts while a live auction still settles to its winner. |
| [`Helpers.t.sol`](Helpers.t.sol) | The helpers themselves: the package Merkle trees agree with OpenZeppelin's `MerkleProof` for 1 to 17 leaves. |
| [`GasHarness.t.sol`](GasHarness.t.sol) | The gas report's harness against the truth: a start measured from a fully cold state equals the corrected figure after every account it reaches was warmed, and storage the harness does not cool is refused. |
| [`GasReport.t.sol`](GasReport.t.sol) | The budgets ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md)): Prague gas, and the exact new slots and accounts, of `start` and `startWithBid` (one and two parties, VRF, edition master, ERC-20 by Permit2, first ever, new collection, new terms), `bid`, `settle` (with and without a bid), `consume`, `createEdition`, `refreshStanding` and `royaltyInfo`, and `tokenURI` by size. |

## Invariant suites

A stateful invariant suite runs on the same real stack, in [`invariant/`](invariant/). The test
contract inherits its handler and targets itself, so the handler has every helper above and no
handler contract meets the EIP-170 limit. Each action is
bounded, never reverts (`fail_on_revert`), predicts its outcome from the protocol's rules and
records any disagreement; the invariant function asserts there is none, then checks the state.

| Suite | Actions | Invariants |
| --- | --- | --- |
| [`StreamLifecycleInvariant.t.sol`](invariant/StreamLifecycleInvariant.t.sol) (handler [`StreamLifecycleHandler.sol`](invariant/StreamLifecycleHandler.sol)) | register and accept packages; move items to Stream and start auctions (with or without a first bid, a revoked move); bid; settle; dispute pause; cancel (upheld) or resume (rejected, with a withdrawal); `releaseContent`; `openRecord`, `setRecord`, `finalize`, `addLocator`; governed relicense; transfer; stage a recovery override and end it (veto or execution); the restrained keys trying every artist power; time | every token has exactly one known owner, or auction custody while its sale is unsettled; token IDs assigned once, in order, never reused; a content hash held by at most one live item unless released to its beneficiary; a finalized record keeps its content hashes, and media never changes; a CC0 work stays CC0 with the pinned text; locators are append-only; a restrained artist never acts; the auction holds exactly the live bids and credits; an unbid work ends with the museum, at once even while its artist is restrained, and the museum holds nothing else |

A second, smaller suite covers the content store on its own:
[`ContentStoreInvariant.t.sol`](../content/ContentStoreInvariant.t.sol) writes and rewrites chunks,
registers and re-registers manifests (one over the same chunks with another MIME type, one that
breaks the layout rule), refuses malformed manifests and reads ranges back: chunks are written
once at a fixed pointer, manifests are idempotent and immutable, a file is complete exactly when
every chunk it names is stored with its layout length, and a read returns exactly the bytes
written (a range over a missing or mis-sized chunk never reads).

In CI each suite asserts its state every fourth call and after the last call of each run
(`forge-config: default.invariant.check_interval = 4`); every action still checks its own
outcome at once, and the `deep` profile asserts the state after every call.

`test_EveryActionRuns` in the lifecycle suite replays sequences of the campaign's shape from
fixed seeds and asserts that every action, and the paths the invariants are about (cancel,
release and re-consumption, recovery, refusals), really ran, so a campaign cannot pass
vacuously.

```bash
forge test --match-path "test/integration/invariant/*"            # CI: 256 runs x depth 128
forge test --match-contract ContentStoreInvariantTest
FOUNDRY_PROFILE=deep forge test --match-test "invariant_"         # nightly: 2,000 x 256
```

The fork tests against the real external systems are in [`test/fork/`](../fork/README.md).

## Findings

Every integration finding was resolved in the lane that owned it. Each one is now a
regular test.

| ID | Resolved by | Test |
| --- | --- | --- |
| G-1: no default currency at genesis | #31 wires ETH as each product's default | `Genesis.t.sol` `test_DefaultCurrencyIsEthFromGenesis` |
| G-2: two-party `startWithBid` over 350K | #34 and #33 | `GasReport.t.sol` `test_Gas_StartWithBid_TwoPartyWork` |
| E-1: an edition did not take its master's rate | #14 | `MasterEdition.t.sol` `test_EditionTakesTheMastersCurrentRate` |
| L-1: zero-fee terms blocked edition sales | #35 | `MasterEdition.t.sol` `test_ZeroFeeEditionLocksNoFee` |

While a finding is open, its test is named `test_Finding_*`. That test passes while
the finding stands, and fails with "finding fixed" once it is resolved.

`GasReport.t.sol` also tracks one observation, G-3, as its own row. The first bid
under a new set of sale terms pays once to record the terms with their increment
floor. That bid costs about 387K, against about 317K at steady state.
