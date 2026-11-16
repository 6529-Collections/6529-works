# federated

6529 Stream Federated: artist-run token contracts built from the network's templates, listed
in the network's directory without curation, sold through the network's shared adapters at the
network's locked 10% share, and earning no TDH
([ADR 0008](../../docs/adr/0008-federation.md); rules FED-1 to FED-63 in
[Federation](../../docs/spec/federation.md)).

## Files

| File | What it is | Permanence |
| --- | --- | --- |
| [`FederatedStream.sol`](FederatedStream.sol) | The 1/1 template (ERC-721): works approved on chain by the artist, minted only into an admitted adapter's custody, unsold works held and restarted, the record the shared renderer reads, the 90/10 royalty vault | Permanent per artist once deployed |
| [`FederatedEditions.sol`](FederatedEditions.sol) | The pair's ERC-1155: editions of the partner's EDITION_MASTER works, bound to one sale adapter and sealed at its count | Permanent per artist once deployed |
| [`FederatedMembership.sol`](FederatedMembership.sol) | Source both templates inherit: locked terms, the artist's authority, joining and leaving, minter admission, marketplace metadata | (inherited) |
| [`FederationRegistry.sol`](FederationRegistry.sol) | Approved template code hashes, admitted adapters, permissionless joining, delisting by vote; stores no entry | Replaceable (governed) |
| [`FederatedEditionAuction.sol`](FederatedEditionAuction.sol) | The uniform-price edition auction for federated pairs: `UniformEditionAuctionBase` deployed a second time | Replaceable adapter |
| [`FederatedEditionAuctionLens.sol`](FederatedEditionAuctionLens.sol) | Its lens: the shared lens base plus the federation rules (served contracts, the locked fee, the clock a delisting cancels) | Replaceable |

Interfaces: [`IFederationRegistry`](../interfaces/IFederationRegistry.sol) (what adapters and
templates call), [`IFederatedToken`](../interfaces/IFederatedToken.sol),
[`IFederatedStream`](../interfaces/IFederatedStream.sol),
[`IFederatedEditions`](../interfaces/IFederatedEditions.sol). The permanent directory is the
artist registry's (`IArtistRegistry.federatedListing` and its events).

## Entry points

- **Deploy and join.** The artist deploys `FederatedStream` (and, for a pair,
  `FederatedEditions` naming it, then `linkEditions`), then calls `joinFederation` on each.
  The token itself calls the current registry's `register` (FED-6, FED-43), which checks the
  code hash and the locked terms, creates the artist's identity from its signature if needed,
  and lists the token in the artist registry; the token confirms the listing in the same
  transaction (`FederationJoined`), or reverts.
- **Sell a 1/1.** `approveItem(itemHash, royaltyRate)` (artist), then anyone calls
  `EnglishAuction.start(token, abi.encode(FederatedMint(item, media)))` (FED-11 to FED-15).
  Settlement, the refusal exit and claims are the auction's (AUC-45 to AUC-48); an unsold work
  goes to the template's own custody (FED-17), `reclaim` brings back a refused one (FED-19),
  and a fresh approval restarts it under the next token ID (FED-18).
- **Sell editions.** `FederatedEditionAuction.open(editions, masterTokenId, abi.encode(item))`
  beside the master's 1/1; `FederatedEditions.createEdition` once the master settled
  (FED-31 to FED-38, FED-53 to FED-58).
- **Govern.** `approveTemplate`, `revokeTemplate`, `setAdapter` (SUCCESSOR_SETTER, 30 days);
  `suspendTemplate` (GUARDIAN, immediate); `resumeTemplate`, `setStatus` (PARAMETER_SETTER,
  48 hours); `propagateRevocation` (anyone) (FED-44 to FED-50).
- **Leave.** `leaveFederation` (artist), one-way; then `setAdmittedMinter` (FED-8, FED-9). A
  contract that left has no registry entry, so no shared adapter starts a new sale of it, even
  one the artist admits as its own minter; its running sales finish (FED-59).

## Developer notes

- **No immutables in the templates.** Every value is in storage, so every deployment of a
  version has one runtime code hash; the registry recognises a genuine copy by that hash alone,
  with no factory. Do not add an immutable or a constructor-dependent constant to a template.
- **Settlement makes no external call** and reads no identity state (the nine template
  guarantees, [stream-and-auctions](../../docs/spec/stream-and-auctions.md#what-a-federated-template-must-guarantee));
  keep it so. Every other call out is a plain call that forwards all gas and reverts on any
  failure (the gas rule, `FederationGasRule.t.sol`).
- **The renderer's native path (FED-61).** The shared renderer reads `coreOf` and, with
  `extsload`, slots 17 (the one collection, its name two slots in) and 18 (the token words:
  the minting adapter in bits 0-159, the work ID in 160-191), the slots `StreamLayout`
  publishes for 6529 Stream. Do not reorder `FederatedStream`'s storage above `_tokens`; a
  test pins both slots (`test_Layout_TheTemplateAnswersTheRenderersNativeReads`).
- **What an item may say (FED-13, FED-27, FED-60).** Parties and artist-resolved payees name
  only the artist; the license ID follows `SpdxId`; locators are printable ASCII without `"`
  or `\`, at most `Limits.MAX_URI_BYTES`, so a work's own data never breaks its metadata.
- **Token IDs are not work IDs.** A sale adapter keys a sale by token and ID, so a restart
  burns the unsold token and mints the next ID for the same work (`liveTokenOf`). An edition
  master whose edition sale began never restarts (its edition is keyed by that token ID).
- **Edition auction.** The two deployments share `UniformEditionAuctionBase` and
  `UniformEditionAuctionLensBase` (src/sales); the federated adapter's extra slot (14: each
  sale's edition contract) is read by its lens. The federation logic lives in the lens to keep
  the adapter inside EIP-170. Its abandonment waits the locked delay alone (a federated 1/1
  has no rescue; `_rescueDelay` answers the 90-day floor, FED-62).
- **Sizes** are in [audit scope](../../docs/audit/scope.md); deployment gas, Prague and the
  Glamsterdam estimate, in ADR 0008.
- **Tests:** `test/federated/` (sales, pair, refusal exit, governance and exit, invariants, gas
  rows, gas rule).

## Genesis

Genesis deploys the registry, the federated edition auction's lens and the federated edition
auction, binds the registry in the artist registry, points the English auction at it, admits
both shared adapters and approves the two v1 template code hashes, computed by
`DeployV1.templateCodeHash` from the build (FED-63); `VerifyV1.checkFederation` reads them
back. The economics resolver's `PRODUCT_FEDERATED` fee recipient is the governed fee vault
from construction, with a 10% share: joining checks that a template locked the same recipient
and share, and the English auction locks them for each sale at start (AUC-48).

## See also

[Glossary: 6529 Stream Federated](../../docs/glossary.md#6529-stream-federated),
[trust assumptions](../../docs/audit/trust-assumptions.md), [sales module](../sales/README.md).
