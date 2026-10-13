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
| [`MasterEdition.t.sol`](MasterEdition.t.sol) | 2. Master settles, then `createEdition`. A fixed-price sale with allowlist phases, artist consent and a relayed Permit2 payment. A Dutch sale. Linked metadata. The edition royalty follows a master re-rate. |
| [`ContentToTokenURI.t.sol`](ContentToTokenURI.t.sol) | 3. The uploader's golden calldata, then `attestBase64`, `openRecord`, `finalize` and `syncOnChain`; `tokenURI` in locator and inline modes; and the gas matrix. |
| [`RecordAmendments.t.sol`](RecordAmendments.t.sol) | 3, continued. Relicense with consent and governance, a new default renderer, the errata repin, and artist and owner statements. |
| [`IdentityRecovery.t.sol`](IdentityRecovery.t.sol) | 4. Registration and consolidation standing; stage, cancel, veto and execute; the payout freeze during a change and an override; sticky standing against a key thief; the split-wallet pull and signed release after recovery. |
| [`Dispute.t.sol`](Dispute.t.sol) | 5. Guardian pause; the PLATFORM `DISPUTE_OUTCOME` statement shown by the renderer; the 48-hour governed `cancel` (refund, then burn); `releaseContent`; the rightful artist's item consumes. Also a rejected dispute, a lapsed pause, an after-sale dispute and the emergency pause. |
| [`VrfWork.t.sol`](VrfWork.t.sol) | 6. `requestSeed`, the mock fulfilment, `start`, and the seed in the metadata. Also the 3-day retry and the artist seed. |
| [`Genesis.t.sol`](Genesis.t.sol) | 7. Deploy, configure and wire. The readback passes and the configurator keeps no ADMIN. Guardians cancel hostile admin operations, the cold admin removes the hot admin, and `configure` fits the transaction cap. |
| [`Helpers.t.sol`](Helpers.t.sol) | The helpers themselves: the package Merkle trees agree with OpenZeppelin's `MerkleProof` for 1 to 17 leaves. |
| [`GasReport.t.sol`](GasReport.t.sol) | The budgets ([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md)): Prague gas and the new slots and accounts of `start`, `startWithBid`, `bid`, `settle`, `consume`, `createEdition`, `openSale`, `purchase`, `refreshStanding` and `royaltyInfo`, the first start in a new collection, and `tokenURI` by size. |

## Findings

Every integration finding was resolved in the lane that owned it. Each one is now a
regular test.

| ID | Resolved by | Test |
| --- | --- | --- |
| G-1: no default currency at genesis | #31 wires ETH as each product's default | `Genesis.t.sol` `test_DefaultCurrencyIsEthFromGenesis` |
| G-2: two-party `startWithBid` over 350K | #34 and #33 | `GasReport.t.sol` `test_Gas_StartWithBid_TwoPartyWork` |
| E-1: an edition did not take its master's rate | #14 | `MasterEdition.t.sol` `test_EditionTakesTheMastersCurrentRate` |
| L-1: zero-fee terms blocked edition sales | #35 | `MasterEdition.t.sol` `test_ZeroFeeEditionSaleOpensAndSettles` |

While a finding is open, its test is named `test_Finding_*`. That test passes while
the finding stands, and fails with "finding fixed" once it is resolved.

`GasReport.t.sol` also tracks one observation, G-3, as its own row. The first bid
under a new set of sale terms pays once to record the terms with their increment
floor. That bid costs about 387K, against about 317K at steady state.
