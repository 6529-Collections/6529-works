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
forge test --match-contract IntegrationGasReport -vv   # prints the gas table
```

## Deployment

[`WorksDeployment.sol`](WorksDeployment.sol) deploys every v1 contract in
dependency order. It follows the rule in [`config/README.md`](../../config/README.md):
- constructor arguments supply the immutable and pinned dependencies;
- `GovernanceConfigurator.configure` applies the committed
  [`config/genesis.example.json`](../../config/genesis.example.json).

The configuration step uses the JSON's role and selector map and its own wiring
calldata, with each placeholder address replaced by the deployed contract it names.
This fixture stands in for Lane A's `DeployV1` library (PR #31). That library cannot
deploy the pending lanes yet, so it cannot wire them at genesis either. The fixture
should switch to it once those lanes slot into it.

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
| [`GasReport.t.sol`](GasReport.t.sol) | The budgets: `start`, `startWithBid`, `settle`, `bid`, `consume`, `royaltyInfo`, the first start in a new collection, and `tokenURI` by size. |

## Open findings

Each open finding has a test named `test_Finding_*`. That test passes while the
finding stands, and fails with "finding fixed" once it is resolved. The check is
then promoted to a regular test.

| ID | Where | Finding |
| --- | --- | --- |
| G-1 | Genesis configuration, `AssetAllowlist` | No default currency is configured at genesis. An item naming `CURRENCY_DEFAULT` cannot start for 14 days, and a free edition in the default currency cannot open. |
| L-1 | `MintSaleBase._terms` | Fee terms of zero share with no recipient pass `EconomicsResolver` validation, and Stream accepts them, but every edition sale refuses to open. |
