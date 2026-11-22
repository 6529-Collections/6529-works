# federated

6529 Stream Federated: artist-run token contracts, listed in the network's directory without
curation, sold through the network's shared sale contracts at the network's share (recorded at
listing, which the network can lower and nothing can raise), and earning no TDH. Joining is for
good: there is no exit. A federated artist's pair is **the same plain permanent token as 6529
Stream and 6529 Stream Editions with a different gate**
([ADR 0010](../../docs/adr/0010-plain-permanent-core.md); [Federation](../../docs/spec/federation.md)).

## Files

| File | What it is | Permanence |
| --- | --- | --- |
| [`FederatedStream.sol`](FederatedStream.sol) | `StreamBase` with the gate: minters are the federation module's answer, the artist administers the collection page and the renderer slot, the network rescues. One collection. | Permanent per copy once deployed |
| [`FederatedEditions.sol`](FederatedEditions.sol) | `EditionsBase` with the gate, the partner of one `FederatedStream` | Permanent per copy once deployed |
| [`FederatedMembership.sol`](FederatedMembership.sol) | Source both inherit: the artist ID, the directory, and the answers the hooks read from them | (inherited) |
| [`FederatedDeployer.sol`](FederatedDeployer.sol) | One per template version: holds its creation code, deploys copies for anyone with the caller's constructor arguments and records each; no owner, role, fee or upgrade | Permanent (ownerless) |
| [`FederationRegistry.sol`](FederationRegistry.sol) | The federation module: template versions, listings, delisting by contract and by account, the lower-only fee share, the federated sale contracts, item approval, and the federated mint policy (`IMintPolicy`) that checks items, consents and payees and deploys the vaults | Replaceable (the directory's `FEDERATION` slot) |
| [`FederatedEditionAuction.sol`](FederatedEditionAuction.sol), [`FederatedEditionAuctionLens.sol`](FederatedEditionAuctionLens.sol) | The uniform-price edition sale for federated pairs and its lens | Replaceable |

## What a federated token asks, and whom

| Hook | Answer |
| --- | --- |
| May `a` mint? | `IFederationGate(directory.moduleOf(FEDERATION)).canMint(token, a)`; false while the slot is empty |
| May `a` record an outcome or burn? | `a` minted here (`hasMinted`) and still holds the token with no outcome; no module is asked |
| When was `a` removed (rescue, rebind)? | The federation module's `minterRemovedAt(a)`; for the 1/1 token only if `a` minted here |
| TERMS, RECORDS | The directory's `FEDERATED_TERMS`, `FEDERATED_RECORDS` |
| RENDERER | The token's own slot: any wallet of the artist's account announces and removes; anyone installs after `moduleDelay` |
| Admin (owner, contract URI, renderer) | Any wallet of the artist's account (`IAccounts.isWallet`) |
| Network (`rescue`, `setRescueDelay`, `rebind`, `setRebindDelay`, `setModuleDelay`) | Whoever the directory's AccessManager lets call the same function on the directory at once |

The waits a federated token holds (`rescueDelay`, `rebindDelay`, `moduleDelay` of its renderer
slot) are settings of the network: a launch value, changed by the network at once, zero allowed.
The network maps those five selectors on the `Directory` target once, at the no-delay class, and
that serves every federated token.

## Entry points

- **Deploy and list.** The artist deploys `FederatedStream` through the 1/1 version's
  `FederatedDeployer` (`deploy(salt, abi.encode(name, symbol, facts, directory, artistId,
  owner, renderer))`), then anyone relays `FederationRegistry.register(token, Join)` with a
  wallet's consent (`listingSubject`) and, for a new artist, the registration signature.
  Editions deploy naming the stream and list after it.
- **Sell a 1/1.** `approveItem(token, itemHash, royaltyRate)` (any wallet of the artist), then a
  federated sale contract calls `authorize(token, abi.encode(FederatedMint(item, media,
  consents)))` and mints the facts it answers. Each collaborator consents to
  `Core.federatedConsent(itemHash, royaltyRate)` for the token. An unsold work stays in the sale
  contract's custody and can be offered again there.
- **Govern.** The network's: `approveTemplate`, `suspendTemplate`, `resumeTemplate`,
  `revokeTemplate`, `reinstateTemplate`, `setAdapter`, `setStatus`, `setAccountDelisted`,
  `lowerFeeShare`, `setEntropyModule`, `releaseContent`.
- **Replace.** A new `FederationRegistry` names its predecessor and inherits its listings,
  account delistings, template versions and sale contracts with no artist signature; once the
  directory installs it, the old one authorizes nothing.

## Developer notes

- **No records, items, locators, vaults or custody in a token.** Records are the shared
  `WorkFacts`; rules are the shared modules; the token holds ownership and the facts of mint.
- **Template versions are deployers, not code hashes.** Each copy's constructor arguments are
  immutables, so copies differ in runtime code; a contract lists only if an approved deployer
  recorded it.
- **Tests:** `test/federated/` (run with `FOUNDRY_TEST=test/federated FOUNDRY_SCRIPT=src` and
  `--skip FederatedPair --skip FederatedEditionsRules` until integration), replay
  `test/replay/LogReplayFederation.t.sol`, Halmos `test/symbolic/FederatedSymbolic.t.sol`.

## See also

[Glossary: 6529 Stream Federated](../../docs/glossary.md#6529-stream-federated),
[trust assumptions](../../docs/audit/trust-assumptions.md), [sales module](../sales/README.md).
