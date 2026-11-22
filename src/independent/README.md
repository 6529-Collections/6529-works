# Independent Stream

6529 Independent Stream: artist-run token contracts, listed in the network's directory without
curation, sold through the network's shared sale contracts at the network's share (recorded at
listing, which the network can lower and nothing can raise), and earning no TDH. Joining is for
good: there is no exit. An Independent Stream artist's pair is **the same plain permanent token as
6529 Stream and 6529 Stream Editions with a different gate**
([ADR 0010](../../docs/adr/0010-plain-permanent-core.md); [Independent Stream](../../docs/spec/independent-stream.md)).

## Files

| File | What it is | Permanence |
| --- | --- | --- |
| [`IndependentStream6529.sol`](IndependentStream6529.sol) | `StreamBase` with the gate: minters are the Independent Stream module's answer, the artist administers the collection page and the renderer slot, the network rescues. One collection. | Permanent per copy once deployed |
| [`IndependentStreamEditions6529.sol`](IndependentStreamEditions6529.sol) | `EditionsBase` with the gate, the partner of one `IndependentStream6529` | Permanent per copy once deployed |
| [`IndependentStreamMembership.sol`](IndependentStreamMembership.sol) | Source both inherit: the artist ID, the directory, and the answers the hooks read from them | (inherited) |
| [`IndependentStreamDeployer.sol`](IndependentStreamDeployer.sol) | One per template version: holds its creation code, deploys copies for anyone with the caller's constructor arguments and records each; no owner, role, fee or upgrade | Permanent (ownerless) |
| [`IndependentStreamRegistry.sol`](IndependentStreamRegistry.sol) | The Independent Stream module: template versions, listings, delisting by contract and by account, the lower-only fee share, the Independent Stream sale contracts, item approval, and the Independent Stream mint policy (`IMintPolicy`) that checks items, consents and payees and deploys the vaults | Replaceable (the directory's `INDEPENDENT_STREAM` slot) |
| [`IndependentEditionAuction.sol`](IndependentEditionAuction.sol), [`IndependentEditionAuctionLens.sol`](IndependentEditionAuctionLens.sol) | The uniform-price edition sale for Independent Stream pairs and its lens | Replaceable |

## What an Independent Stream token asks, and whom

| Hook | Answer |
| --- | --- |
| May `a` mint? | `IIndependentStreamGate(directory.moduleOf(INDEPENDENT_STREAM)).canMint(token, a)`; false while the slot is empty |
| May `a` record an outcome or burn? | `a` minted here (`hasMinted`) and still holds the token with no outcome; no module is asked |
| When was `a` removed (rescue, rebind)? | The Independent Stream module's `minterRemovedAt(a)`; for the 1/1 token only if `a` minted here |
| TERMS, RECORDS | The directory's `INDEPENDENT_TERMS`, `INDEPENDENT_RECORDS` |
| RENDERER | The token's own slot: any wallet of the artist's account announces and removes; anyone installs after `moduleDelay` |
| Admin (owner, contract URI, renderer) | Any wallet of the artist's account (`IAccounts.isWallet`) |
| Network (`rescue`, `setRescueDelay`, `rebind`, `setRebindDelay`, `setModuleDelay`) | Whoever the directory's AccessManager lets call the same function on the directory at once |

The waits an Independent Stream token holds (`rescueDelay`, `rebindDelay`, `moduleDelay` of its
renderer slot) are settings of the network: a launch value, changed by the network at once, zero
allowed. The network maps those five selectors on the `StreamDirectory6529` target once, at the
no-delay class, and that serves every Independent Stream token.

## Entry points

- **Deploy and list.** The artist deploys `IndependentStream6529` through the 1/1 version's
  `IndependentStreamDeployer` (`deploy(salt, abi.encode(name, symbol, facts, directory, artistId,
  owner, renderer))`), then anyone relays `IndependentStreamRegistry.register(token, Join)` with a
  wallet's consent (`listingSubject`) and, for a new artist, the registration signature.
  Editions deploy naming the stream and list after it.
- **Sell a 1/1.** `approveItem(token, itemHash, royaltyRate)` (any wallet of the artist), then an
  Independent Stream sale contract calls `authorize(token, abi.encode(IndependentMint(item, media,
  consents)))` and mints the facts it answers. Each collaborator consents to
  `Core.independentConsent(itemHash, royaltyRate)` for the token. An unsold work stays in the sale
  contract's custody and can be offered again there.
- **Govern.** The network's: `approveTemplate`, `suspendTemplate`, `resumeTemplate`,
  `revokeTemplate`, `reinstateTemplate`, `setAdapter`, `setStatus`, `setAccountDelisted`,
  `lowerFeeShare`, `setEntropyModule`, `releaseContent`.
- **Replace.** A new `IndependentStreamRegistry` names its predecessor and inherits its listings,
  account delistings, template versions and sale contracts with no artist signature; once the
  directory installs it, the old one authorizes nothing.

## Developer notes

- **No records, items, locators, vaults or custody in a token.** Records are the shared
  `StreamWorkFacts6529`; rules are the shared modules; the token holds ownership and the facts of
  mint.
- **Template versions are deployers, not code hashes.** Each copy's constructor arguments are
  immutables, so copies differ in runtime code; a contract lists only if an approved deployer
  recorded it.
- **Tests:** `test/independent/` (run with `FOUNDRY_TEST=test/independent FOUNDRY_SCRIPT=src` and
  `--skip IndependentPair --skip IndependentStreamEditionsRules` until integration), replay
  `test/replay/LogReplayIndependentStream.t.sol`, Halmos `test/symbolic/IndependentSymbolic.t.sol`.

## See also

[Glossary: 6529 Independent Stream](../../docs/glossary.md#6529-independent-stream),
[trust assumptions](../../docs/audit/trust-assumptions.md), [sales module](../sales/README.md).
