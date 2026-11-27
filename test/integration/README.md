# integration

End-to-end flows on the real, wired contracts. Nothing between the modules is mocked. Only
external systems are:
- the 6529 delegation contract, using the identity suites' faithful reduction;
- the Chainlink VRF v2.5 coordinator, using the entropy suites' mock.

```bash
forge test --match-path "test/integration/*"
forge test --match-test test_Gas_Table -vv   # prints the gas table
```

## Deployment

[`CoreIntegrationBase.sol`](CoreIntegrationBase.sol) deploys the system with the deploy library,
[`script/DeployCore.sol`](../../script/DeployCore.sol), the same code the deploy script
broadcasts: `DeployCore.deploy` creates every contract, the genesis configuration
([`config/genesis.core.example.json`](../../config/genesis.core.example.json)) is installed with
its role map and wiring, the network accepts, and `VerifyCore` reads everything back. The JSON's
placeholder holders are replaced by the tests' actors, so the curation signers are keys the
tests hold.

[`IntegrationBase.sol`](IntegrationBase.sol) adds the actors and package building: it signs
EIP-712 digests read from the contracts, builds sorted-pair Merkle trees over
`WorksHashing.leaf`, and drives sales and governed actions (a zero-delay role acts directly; any
other role is scheduled, waited out and executed).
[`IndependentIntegrationBase.sol`](IndependentIntegrationBase.sol) adds a listed Independent Stream
pair; [`GasBase.sol`](GasBase.sol) the whole-transaction gas measurement.

## Flows

| File | Flow |
| --- | --- |
| [`CuratedSale.t.sol`](CuratedSale.t.sol) | Package, attestation, registration, acceptance and move signature; `start` and `startWithBid`; bids and the soft close; `settle`; releases from the split vaults |
| [`Museum.t.sol`](Museum.t.sol) | A work with no bid goes to the museum; a governed change of the museum; rescue |
| [`Dispute.t.sol`](Dispute.t.sol), [`DisputeCancelOutcome.t.sol`](DisputeCancelOutcome.t.sol) | Pause, the dispute statement the renderer shows, cancel and the content release; which recorded outcome a cancel accepts |
| [`VrfWork.t.sol`](VrfWork.t.sol) | `requestSeed`, the mock fulfilment, the start, and the seed in the metadata |
| [`Releases.t.sol`](Releases.t.sol), [`Credits.t.sol`](Credits.t.sol), [`EscrowRecovery.t.sol`](EscrowRecovery.t.sol), [`LoweredShareRoyalties.t.sol`](LoweredShareRoyalties.t.sol) | Money: releases, credits that age under a changing unclaimed period, escrow recovery, a lowered network share |
| [`RecordLifecycle.t.sol`](RecordLifecycle.t.sol), [`ContentToTokenURI.t.sol`](ContentToTokenURI.t.sol), [`WorkRecordsStackPorted.t.sol`](WorkRecordsStackPorted.t.sol), [`SyncOnChainResumePorted.t.sol`](SyncOnChainResumePorted.t.sol) | A work's record from open to finalized, and content from upload to `tokenURI` |
| [`IdentityRecovery.t.sol`](IdentityRecovery.t.sol) | Consolidated wallets, an account's own change, a network replacement, a freeze and a contest |
| [`AccountsSuccessor.t.sol`](AccountsSuccessor.t.sol) | The accounts module replaced by a successor that reads through the genesis module ([`ReadThroughAccounts`](../mocks/identity/ReadThroughAccounts.sol), a test double): a moved account keeps its ID, payout address, wallets and freeze, and its money |
| [`PieceLifecycle.t.sol`](PieceLifecycle.t.sol), [`EditionAuction.t.sol`](EditionAuction.t.sol), [`EditionAuctionDifferential.t.sol`](EditionAuctionDifferential.t.sol), [`MasterEditionPorted.t.sol`](MasterEditionPorted.t.sol) | A 1/1 and its edition auction: close, clearing, claims, refunds, adopt and rebind; differential fuzzing against [`UniformClearingReference`](../helpers/UniformClearingReference.sol) |
| [`IndependentPair.t.sol`](IndependentPair.t.sol), [`IndependentEditionSale.t.sol`](IndependentEditionSale.t.sol), [`IndependentEditionRestart.t.sol`](IndependentEditionRestart.t.sol) | An Independent Stream artist's pair on the real stack; its edition sale from the open to the claims, with the 90/10 split released and every wei accounted; an edition sale whose 1/1 is settled unsold and offered again keeps its close, settles and pays |
| [`ModuleLifecycle.t.sol`](ModuleLifecycle.t.sol), [`ModuleSwap.t.sol`](ModuleSwap.t.sol) | Announcing, activating, cancelling and removing modules and minters; every module replaced, with tokens, facts and owed money unchanged |
| [`NetworkHandover.t.sol`](NetworkHandover.t.sol) | What a network handover moves and leaves (GV-4): the network roles move at `acceptNetwork`; an operational role the former network holds, keys it granted and the brake last until the new network revokes or replaces them; the manager's logs name every holder |
| [`GenesisPorted.t.sol`](GenesisPorted.t.sol), [`StreamCorePolicyPorted.t.sol`](StreamCorePolicyPorted.t.sol), [`StreamDependenciesPorted.t.sol`](StreamDependenciesPorted.t.sol), [`StreamSalePorted.t.sol`](StreamSalePorted.t.sol), [`RecipientValidationPorted.t.sol`](RecipientValidationPorted.t.sol), [`CurationSignerPorted.t.sol`](CurationSignerPorted.t.sol), [`HelpersPorted.t.sol`](HelpersPorted.t.sol) | Behaviours carried over from the suites of the earlier contracts, on the current stack |
| [`GasReport.t.sol`](GasReport.t.sol), [`IndependentRestartGas.t.sol`](IndependentRestartGas.t.sol), [`GasHarness.t.sol`](GasHarness.t.sol), [`RoyaltyInfoGas.t.sol`](RoyaltyInfoGas.t.sol), [`TokenUriBudget.t.sol`](TokenUriBudget.t.sol) | The gas table (Prague gas, exact new slots and accounts per row), its harness checked against a cold transaction, `royaltyInfo` under a caller's gas limit, and `tokenURI` inside 8M gas at every cap |

## Invariant suites

The stateful suites in [`invariant/`](invariant/) run on the same real stack:
`StreamLifecycleInvariant` (handler `StreamLifecycleHandler`, with `StreamLifecycleHostile`),
`StreamStatesInvariant` and `EditionAuctionInvariant` (handler `EditionAuctionHandler`). Each
action is bounded, never reverts (`fail_on_revert`), predicts its outcome from the rules and
records any disagreement; the invariant function asserts there is none, then checks the state.
Each suite has a self-test that replays sequences from fixed seeds and asserts that every action
and the paths the invariants are about really ran.

```bash
forge test --match-path "test/integration/invariant/*"            # CI: 256 runs x depth 128
FOUNDRY_PROFILE=deep forge test --match-test "invariant_"         # nightly
```

The fork tests against the real external systems are in [`test/fork/`](../fork/README.md).

## Open findings

While a finding is open, its check runs through `_expectFailure`: the test passes while the
finding stands and fails with "finding fixed" once it is resolved, when the check becomes a
regular test.
