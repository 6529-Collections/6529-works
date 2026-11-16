# Threat model

What an attacker can aim at in 6529 Works, who the attackers are, and how each entry point is
defended. It is written for an external audit team and expert Solidity reviewers. Each defense is
cited by the rule ID of the [protocol specification](../spec/README.md) that states and tests it;
a test is named only where no rule covers the defense. The roles and dependencies these defenses
rely on are in [trust assumptions](trust-assumptions.md), the per-selector roles and delays in the
[role and permission matrix](roles.md), and the accepted risks in
[known limitations](known-limitations.md).

> Pre-audit. See the [project status](../../README.md#status).

## Scope and method

- **In scope:** the Solidity under [`src/`](../../src/) and the deployment scripts under
  [`script/`](../../script/README.md), deployed with the committed genesis policy
  ([`config/genesis.example.json`](../../config/genesis.example.json)), 6529 Stream Federated
  included ([ADR 0008](../adr/0008-federation.md)): its templates, registry and federated
  edition auction are installed at genesis.
- **Review history.** The modules were reviewed adversarially while they were built
  ([ADR 0003](../adr/0003-build-time-decisions.md)), and the integrated system had an
  [internal adversarial review](../security/internal-review-2026-10.md) in October 2026, whose
  fixes merged in PRs #51 to #57. Finding IDs such as MARKET-2 or IDENTITY-1 mark the defenses
  that came from it; each finding's regression tests carry its ID in a `/// Regression:` NatSpec
  line ([the test map](../../test/README.md)). This is not an audit.
- **How to read the tables.** Each row is one entry point and one threat. The mitigation names
  the rule (its spec page holds the enforcing function and the tests) and, in brackets, the
  finding it closed. Delays use the [delay classes](../glossary.md#delay-class): at once
  (NETWORK and the operational keys); 24 hours (PARAMETER_SETTER); 3 days (FUNDS_SETTER);
  7 days (SUCCESSOR_SETTER and ADMIN). One address, the network, holds every delayed role.

## Assets

| Asset | Where it lives | Who may move or change it | What threatens it |
| --- | --- | --- | --- |
| NFTs in auction custody | `EnglishAuction`, from `start` to delivery, a pending delivery, or a burn | Settlement delivers to the winner's recipient; unsold, a 6529 Stream work is moved to the 6529 Network Museum by Stream itself (owner decision 17) and any other token's goes to its artist; an upheld dispute burns it | Blocked or griefed settlement, a hostile receiver, stranding, confiscation |
| Bidder ETH and ERC-20 | The standing high bid; outbid and refunded bids as per-account credits | The bidder: `claim`, and `withdrawBid` while paused or frozen; a credit unclaimed for 180 days may be sent to the network ([AUC-49][auc]). Settlement pays out only the winning bid | Lock-up, theft, hostile tokens, a currency that never returns |
| Edition bidders' ETH | Every live edition bid's escrow in `UniformEditionAuction`, until it is claimed; refunds credited by `claimBidFor` | The bidder: `claimBid` after settlement; bids are firm and never withdrawn (R21); a void or abandon refunds them. Settlement pays out only `count × price` | Lock-up, a wrong clearing or allocation, double claims, an unsold copy |
| Sale proceeds in flight | Payments from the two auctions' `settle` to the seller wallet and fee recipient; failed ERC-20 settlement payouts credited in the English auction | `RevenuePayment` (pay, else escrow); `EnglishAuction.claimFor` | A refusing wallet, a blocking token, gas starvation |
| Split wallet balances | Each 66-byte `SplitVault` wallet, for ETH and any ERC-20; its accounting in the permanent `SplitLedger` | Fixed payees: anyone, to the payee; every release also pays the network fee vault its share ([ECO-43][eco]). Artist payees: only the current payout address, or its signature. A marked share unclaimed for 180 days goes to the network ([ECO-44][eco]) | A push to a lost key, a redirected payout, a replayed release, hostile tokens |
| Escrow credits | `RevenueEscrow` | Anyone flushes a credit to its own wallet; governed `recover` moves it to an equivalent wallet, a consented replacement, or, for the network's own credit, anywhere but zero; governed `sweepExcess` moves only the balance above `totalOwed`; a credit unclaimed for 180 days becomes a network credit ([ECO-45][eco]) | A credit paid to the wrong wallet, a blocked wallet |
| Network fee and museum holdings | `FeeRecipientVault` and `MuseumVault` (governed vaults) | Anyone forwards to the vault's destination (ERC-721s and ERC-1155s by safe transfer); FUNDS_SETTER changes the fee vault's destination (3 days), SUCCESSOR_SETTER the museum vault's (7 days), compare-and-set | A mistaken destination change, a refusing destination |
| Artist identity and payout routing | `ArtistRegistry` | Any wallet of the account (2-day own change, cancelled by any wallet); the network (14-day replacement notice, contestable; a 14-day freeze; cancelling changes at once) | Key theft, a mistaken replacement, a broken consolidation source |
| Curation integrity | `PackageRegistry` and `Eip712CurationVerifier` | The curation signer approves; the network revokes roots, disables signers and kills their approvals; only the bound Stream consumes | Forged or leaked approvals, signer compromise, reuse, squatting, copies |
| Metadata integrity and permanence | `WorkRecords`, `ContentStore`, the renderer | The artist until finalize, and after a 14-day notice anyone finalizes a sold work; the network with every party's consent (rate, license); the network repins a finalized work's renderer; PLATFORM and STORAGE_OPERATOR for copies and routing; nobody for stored bytes | JSON injection, unbounded gas, look-alike traits, script break-out, renderer substitution, locator repointing |
| Governance control | `WorksAccessManager` | The network address, at each class delay; the brake can delay a scheduled operation once; a handover needs the new address to accept | Takeover of the network key, hidden delay cuts, value through `execute`, a handover to an address that cannot act |
| VRF subscription funds | The Chainlink subscription | The coordinator, per request; the subscription owner | Spam draining, seed re-rolls, a compromised owner cancelling it |
| Reputation and display | `StatementLog` entries shown in metadata | PLATFORM, CURATOR, the artist through the resolver, token holders | False, stale or forged statements |

## Actors

| Actor | What it can do on-chain | Trusted for |
| --- | --- | --- |
| Artist (any wallet of the lead party's consolidated account) | Accept packages, sign and revoke moves, edit and finalize its records, co-sign amendments, release its share; bid on its own editions like anyone | Its own works and share |
| Collaborator | Accept the package, co-sign amendments, release its own share | Its own consent and share |
| Collector or bidder | Bid on 1/1s and editions, raise edition bids, withdraw a 1/1 bid while it is paused or frozen, claim bids and credits, upload chunks, write OWNER statements | Nothing |
| Winning bidder with a hostile receiver | Name any recipient, which may reject the token, burn gas, re-enter or hand it back | Nothing |
| Pauser, platform, curator, storage operator keys | Bounded operational duties ([trust assumptions](trust-assumptions.md#operational-keys)) | Pauses, display, evidence and operations |
| Curation signer | Sign approvals off-chain; never calls a contract | Approving only voted packages, after checking the bytes |
| The network (one 6529 Safe until the TDH bridge) | Every governed action at its class delay; tightening actions at once | Executing the network's decisions |
| The brake (none at launch) | Delay a scheduled operation once by 7 days | Delay only |
| Keepers and relayers | Call permissionless entry points; relay signed payloads | Liveness only |
| VRF coordinator | Deliver random words for its requests | Unbiased randomness |
| Token issuers | Blocklist, charge fees, rebase, upgrade token behavior | Standard transfers, judged at admission |
| A federated token (uncurated) | Revert, burn gas, answer malformed or unpayable values, re-enter, or change behaviour in any call `settle` makes into it, alone or with its artist, a bidder or a third party | Its own ledger only; never a bidder's funds or the network's fee ([the refusal exit][exit]). A listed token is curated not to fail and has no exit |
| MEV searchers and block builders | Order, insert and front-run transactions | Nothing |
| Attackers with stolen keys | Any key or Safe above, each bounded in [trust assumptions](trust-assumptions.md) | Nothing |
| Copiers | Submit another artist's content as their own | Nothing |

## Attack surfaces

### Auctions: start, bid, settle

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `start`, `startWithBid` | Start a work whose terms can never settle (the escrow as seller or fee recipient) | [AUC-14][auc]: refused at start, while nothing is in custody (CALLS-1) |
| `start` | Start an unapproved, revoked, reused or copied item, or one without the artist's move | [AUC-3][auc], [CUR-1, CUR-6, CUR-10, CUR-12][cur]: every mint consumes an approved, accepted, moved item, once per content hash; a VRF item also needs its seed ([AUC-4][auc]) |
| Stream's mint policy | A replaced or hostile mint policy (`PackageRegistry`) changes existing tokens or mints outside Stream's invariants | [AUC-38][auc]: the policy decides new mints only and has no write path into Stream, which re-checks every record it answers; the artist registry is fixed ([AUC-39][auc]); content uniqueness is Stream's, so no policy mints a content hash twice ([AUC-44][auc]) |
| `startWithBid` | A searcher front-runs a start with the same move | Accepted: the victim loses only gas, and a move has no "not before" ([LIM-SAL-9][lim-sal], MARKET-4) |
| `bid` | A zero or dust bid claims a work | [AUC-16][auc]: a minimum first bid and a minimum increment |
| `bid` | Sniping in the last seconds | [AUC-17][auc]: a late bid extends the end by the anti-snipe window |
| `bid` | An outbid bidder that reverts on receipt blocks later bids | [AUC-18][auc]: outbid bids become pull credits |
| `settle` | A hostile receiver rejects the token, burns gas or re-enters | [AUC-21][auc]: a failed delivery becomes a pending delivery after payment and settlement; [AUC-31][auc]: no reentry |
| `settle` | A settler starves the call so delivery or a payout fails into its fallback | [AUC-22][auc]: the call reverts unless it forwards the delivery gas and the ERC-20 payout frame in full (MONEY-1) |
| `settle` (no bid) | The artist, or a key under recovery, blocks a no-bid settlement or takes the museum's work | [AUC-24][auc]: the auction reports UNBID and 6529 Stream itself moves the work to the museum the resolver names then, whatever the artist's state, with no receiver callback, so nothing is pending and nobody can claim it ([AUC-33][auc], owner decision 17); any other token's work goes to the active authority, and settlement waits while it is zero (IDENTITY-1) |
| `settle` | A seller wallet or token blocks the payout and so the delivery | [AUC-23][auc]: escrow, else a credit for `claimFor`, while the work is delivered (MONEY-1) |
| `settle` | A federated token reverts, burns gas or answers malformed or unpayable values, so `settle` never completes and the bid and the work are held | [The refusal exit][exit]: from 2 days after the end ([AUC-46][auc]), `settleOrRefund` attempts the whole settlement with fixed, governed gas and, if it fails, credits the bid back and leaves the work for its artist; a cooperating token settles exactly as with `settle`; a listed token's sale, 6529 Stream's included, is never refusable. The analysis case by case is in [Stream and auctions](../spec/stream-and-auctions.md#why-this-is-sound) |
| `settleOrRefund` | A token, bidder or third party steers a sale into a refusal, or a refused sale into someone else's hands | The attempt's gas is fixed and must be forwarded in full; the call is refused inside the auction's and the escrow's guards; a recipient's or wallet's failure is absorbed, not a refusal; a refused close credits only the bidder that paid and hands the work only to the artist the token reports; a federated sale's fee share is locked at start ([the refusal exit][exit]) |
| Value-moving entry points | Reentrancy through a token, wallet or receiver callback | [AUC-31][auc]: a transient reentrancy guard on every value-moving entry point |
| Currency deprecation | A deprecated currency strands bids and works, or a hasty re-admission undoes it | ETH can never be deprecated (`EthNotDeprecable`), so only ERC-20 sales can freeze, never an edition auction. [AUC-25][auc]: the auction freezes, the bidder may withdraw, and after 14 days it ends unsold (FROZEN_OUT: 6529 Stream moves the work to the museum, owner decision 17); [ECO-33][eco]: re-admission waits 3 days from the deprecation (MARKET-2) |
| `onERC721Received` | Tokens sent to the auction outside a start are stranded | [AUC-29][auc]: every safe transfer but its own mint is refused; a plain `transferFrom` is the sender's loss ([LIM-SAL-10][lim-sal], CALLS-5) |
| Whole lifecycle | Value leaks, or a work ends in two states | [AUC-20][auc]: value conservation and one outcome with exact custody, as stateful invariants |

### Payments

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| ERC-20 bids | Fee-on-transfer, rebasing, no-return or false-returning tokens underpay | Exact balance deltas on both sides on every path ([ECO-23][eco], [AUC-19][auc]). Return values are checked on the direct paths, not on Permit2 pulls, which check only balances. The guard against non-standard tokens is governance vetting at `AssetAllowlist.admitAsset` ([LIM-SAL-7][lim-sal]). Edition bids are ETH only |
| Payouts | A blocklisting token blocks a seller or fee wallet | [ECO-26][eco]: the payment reaches the wallet or a credit under it; with the escrow blocked too, the English auction credits the payout ([AUC-23][auc], MONEY-1) |
| ETH payouts | A wallet that refuses ETH or burns gas blocks a sale | [ECO-26][eco], [EA-12][ed]: 100,000 gas per payout (the English auction's `PAYOUT_GAS`; the edition auction's governed payout gas, [EA-18][ed]), escrow on refusal; the edition auction deploys its wallets at open ([EA-20][ed]) |
| `PERMIT2` payments | Replay, or a relayer redirecting the payment | [AUC-19][auc]: Permit2's nonce is the replay key, and the witness binds the sale or start, the recipient, the amount and the deadline |
| `PERMIT` (EIP-2612) | A front-run permit makes the payment fail | Not accepted: a `PERMIT` payment is refused (`InvalidPayment`) and the token's `permit` is never called ([AUC-50][auc]) |

### Editions

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `Editions.mint` | A second admitted adapter adds copies to a sale another one ran, or copies pass the creator's cap | [ED-5, ED-6][ed]: an edition is bound to the adapter whose sale opened it (or else its first minter), and the cap holds for every minter, a removed bound adapter included |
| `Editions.bindMinter` | A second adapter of the same kind opens a sale of an edition another one sells, stranding one sale's winners; or a permissionless `open` binds an edition to the wrong adapter | [ED-5][ed]: the edition auction binds at `open`, before it records the sale, so the second open reverts (`MinterMismatch`); only an admitted adapter binds, and only one whose kind the master's stored item names (checked against its item hash) |

### Edition auctions

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `open` | Open a sale for a work that is not an edition master, under other terms, twice, or from a revoked package | [EA-1][ed]: the item must hash to the one Stream stored, with this sale kind in ETH, and be approved in a live package ([CUR-24][cur], C23); one sale per edition, from the 1/1's start until its close; `open` binds the edition (`bindMinter`), so no second adapter of the kind can open it |
| `bid`, `raise` | Underpay, or bid off the ladder | [EA-3, EA-4][ed]: fixed step prices; exact payment, no slippage |
| `bid`, `raise` | Spoof demand with bids withdrawn before the close | [EA-5][ed]: bids are firm and are never withdrawn, also during a dispute pause (R21) |
| `bid` | Shill bids as a reserve; count inflation; the breadth-rule tilt | Accepted: every bid is a real, public purchase, and revenue stays within the margin of the best ([LIM-EA-2, LIM-EA-3][lim-ea]) |
| `bid` | Sniping, or keeping the sale open forever | [EA-10][ed]: the soft close restarts the window after each bid, up to the governed backstop ([LIM-EA-1][lim-ea]) |
| 1/1 `bid` | Close the edition sale early by settling the 1/1 | [EA-10, EA-17][ed]: the edition closes exactly 15 minutes after the 1/1's final end, anti-snipe and resumption included |
| `settle` | Settle early, settle on a wrong book, misallocate the cut step, or make settlement too costly to finish | [EA-6, EA-8, EA-11][ed]: only after the end and a final 1/1; the clearing equals the per-unit definition; a settler's sweep must be complete and in position order: a reordered one reverts, and one that skips a departure strands only its sender's own sweep, never the sale; settlement runs in calls of bounded gas, each advancing it ([LIM-EA-4, LIM-EA-15][lim-ea]) |
| `claimBid`, `claimBidFor` | Mint more than sold, claim twice, or strand a refund | [EA-9][ed]: exactly `count` copies once every bid is claimed, each bid once; a failed refund reverts, and `claimBidFor` credits it instead |
| Dispute of the 1/1 | Editions of a work later cancelled stay sold | [EA-13][ed]: a cancelled 1/1 voids the sale with full refunds; bids are firm until then ([LIM-EA-14, LIM-EA-16][lim-ea]) |
| Whole lifecycle | Value leaks, or the clearing drifts from its definition | [EA-14][ed]: ETH conservation, the per-unit reference, FIFO and the clocks, as stateful invariants on the real stack |

### Split wallets and releases (the split ledger)

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `release` for an artist payee | Anyone pushes an artist's share to a lost or stolen key | [ECO-16][eco]: artist payees are pull-only |
| `release` during a replacement or freeze | The wallet being replaced, or a frozen account, pulls the balance | [ECO-18][eco], [ID-10][id]: the payout resolves to zero while frozen or while a change would move it, and the wallet refuses |
| Payout rotation | A payout points at a contract that can never pull | [ECO-19][eco], [ID-10][id]: such payouts are refused (MONEY-4); a predicted wallet address cannot be ([LIM-ID-12][lim-id]) |
| `releaseWithAuthorization` | A signed release is replayed, on this or another chain or wallet | [ECO-20, ECO-21][eco]: bound to wallet, chain and deadline; replay keyed on the nonce |
| Resolver | Replaced code at the resolver's address redirects artist shares | The resolver is the permanent artist registry, which has no code to replace (no proxy, no `selfdestruct` after EIP-6780); the ledger pins no code hash, so no change can freeze artist shares ([ECO-12][eco]); while the payout is unresolved only artist-resolved payees stop ([ECO-18][eco]) |
| The vault | A call other than the ledger's moves funds out of a wallet | [ECO-39][eco]: a vault executes only its ledger's instructions, accepts plain ETH within a 2,300-gas stipend and refuses any other call with calldata; every move is proved by its balances |
| A dependency that burns gas | A payee, token, resolver or signer that costs 1x to 100x its base changes a release, or a shortfall reads as a refusal | [ECO-42][eco]: no gas number in the ledger; a failure leaving at most 1/8 of the gas reverts with `BoundedCallShortfall` |
| `ClaimRouter.claim` | A stranger routes an artist's share through the batch router | [ECO-16, ECO-29][eco]: plain items serve fixed payees only, and the router cannot redirect a release |
| `ClaimRouter` continue mode | An item silently runs out of gas and is skipped | [ECO-30][eco]: a shortfall below the ceiling reverts the batch (MONEY-3) |
| Value accounting | Releases exceed entitlements, or rebases distort them | [ECO-13, ECO-14, ECO-24][eco]: cumulative entitlements, conservation, and a high-water mark that freezes on a shrinking balance |

### Escrow recovery

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `RevenueEscrow.recover` (FUNDS_SETTER, 3 days) | A recovery moves a blocked wallet's credit to a wallet that is not owed it | [ECO-28][eco]: only to an equivalent wallet or the consented replacement (MONEY-2); the network's own credits move without consent (C19) |
| `RevenueEscrow.flush` | A hostile token re-enters, or a flush loses the credit | [ECO-27][eco]: a flush pays only the credited wallet, and a failed transfer reverts it; a transient guard blocks reentry (`test_FlushReentryIsBlocked` in [`RevenueEscrow.t.sol`](../../test/economics/RevenueEscrow.t.sol)) |
| `RevenueEscrow.sweepExcess` (FUNDS_SETTER, 3 days) | A sweep reaches credited funds | [ECO-40][eco]: it moves only `balance - totalOwed[asset]`, and no credit is reduced |
| `SplitLedger.forfeit`, `RevenueEscrow.expire` | Money is taken before its 180 days, or money that arrived after a mark is taken | [ECO-44, ECO-45][eco]: 180 days from the mark or the last deposit; a forfeit takes at most the marked level less what was released; a running mark cannot be restarted |

### Curation

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `registerPackage` | A forged attestation, or one from another chain or deployment | [CUR-4, CUR-5][cur]: an active signer, its current epoch, this domain, and the canonical encoding only |
| `registerPackage` | A leaked attestation is registered before anyone can react | [CUR-2][cur]: a root revoked in advance never registers |
| Signer compromise | A compromised signer keeps approving, or its old approvals revive | [CUR-17][cur]: an immediate, one-way disable; [CUR-4][cur]: approvals bind the signer epoch (SIGS-2); [CUR-23][cur]: `killSignerApprovals` stops every package it registered before, so their unminted items no longer mint (C32) |
| `authorize` (the mint policy's item check) | An item, or its content, is used twice | [AUC-44][auc]: Stream mints a content hash once, whatever the policy answers; [CUR-12][cur]: the policy also refuses a used content |
| `authorize` | A copier consumes a work's content hash first | Off-chain first: the signer checks every declared SHA-256 ([LIM-GV-2][lim-gv]). On-chain: an upheld dispute burns the copy and [CUR-14][cur] reserves the hash for the rightful artist (SIGS-1) |
| Copied works | A copier gets another artist's work approved | As above, and the network revokes every root listing the copier's items ([CUR-16][cur]); after a sale a dispute yields only a statement ([DSP-22][dsp]) |
| `acceptPackage` | Pre-signed acceptances with different profiles race | [CUR-7][cur]: the first relayed sets the profile; the rest revert |
| `revokePackage` | Revoking a root strands a sold master's edition | [ED-1][ed]: a registered root counts, revoked or not (SIGS-4) |
| `setVerifier` (SUCCESSOR_SETTER, 7 days) | A swap back restores a retired verifier's approvals | [CUR-18][cur]: retired verifiers never return; [CUR-3][cur]: the pin is checked at every registration |

### Identity and recovery

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `stageChange` with a stolen wallet | A thief moves the root and payout | [ID-5][id]: a 2-day wait, cancelled by any wallet of the account or by the network at once; the network can also freeze the account at once ([ID-8][id]) |
| Signatures for an account | A wallet outside the account signs for it, or a signature is replayed | [ID-2, ID-3][id]: `requireSigned` passes only for a wallet of the account, named in the proof (`abi.encodePacked(wallet, signature)`); nonces and acceptances are used once |
| Consolidation source swap or outage | A hostile or broken source names wallets as part of an account | [ID-2, ID-4][id]: the root never reads the source; a failing, malformed or changed answer is "no"; the swap is the network's at 7 days ([LIM-ID-20][lim-id]) |
| `stageReplacement` (PARAMETER_SETTER, 24 hours) | A replacement moves an account's root to the wrong person | [ID-6, ID-7][id]: the new root's acceptance, 14 days' notice; any wallet contests, and a contested replacement runs only if upheld by a vote recorded after the contest within 90 days; the network can cancel it at once ([LIM-ID-2, LIM-ID-3][lim-id]) |
| Signatures during a replacement or freeze | The account being replaced, or a frozen one, acts | [ID-2, ID-8][id]: no wallet acts for it meanwhile (IDENTITY-1) |
| Replacement acceptance | An acceptance is reused | [ID-6][id]: consumed once |

### Disputes

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `pause(saleId, ref)` (PAUSER) | Repeated pauses hold an auction hostage | [AUC-26][auc], [DSP-13, DSP-14, DSP-15][dsp]: once per auction, at most 3 days, then it ends by itself; the high bidder may withdraw |
| `resume`, `cancel` (NETWORK, at once) | A pause is undone, or a cancel lands, at a moment chosen to hurt bidders | [AUC-26][auc]: either may land at any moment of the pause; a cancel credits the high bid in full; [DSP-17][dsp]: a resumed auction runs at least the governed duration, with the withdrawn bid as a reserve (LIFECYCLE-1) |
| `cancel` | A stale outcome, or one about the item, cancels an auction | [DSP-18][dsp]: the token's own latest outcome, recorded after the pause (LIFECYCLE-4) |
| `resolveContested` (PARAMETER_SETTER, 24 hours) | An outcome from an earlier contest decides this one | [ID-7][id], [DSP-25][dsp]: the latest outcome, recorded after the contest |
| `StatementLog` appends | Anyone records a dispute outcome or curation evidence | [DSP-4, DSP-11][dsp]: reserved kinds only under their roles, directly or by relay; an ERC-721 outcome needs the token |
| After a sale | A dispute confiscates a sold work | [DSP-20, DSP-22][dsp]: no path burns or moves a settled work |

### Governance

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| Network roles | Someone other than the network acts with a network role, or two addresses hold them | [GV-1][gv]: only `network()` holds them and nobody can be granted one; [GV-14][gv]: a stateful campaign keeps exactly one holder |
| Handover | A handover to an address that cannot act, or a half handover | [GV-4][gv]: `transferNetwork` only proposes (7 days); the new address takes over only by calling `acceptNetwork` itself, and the old one then holds nothing. A new network that later loses the ability to act is its own design risk ([LIM-GV-26][lim-gv]) |
| The brake | The brake blocks governance | [GV-6][gv]: once per operation, only on a scheduled, unexpired one, 7 days; [GV-7][gv]: a braked operation keeps a week to run; no-delay actions cannot be braked ([LIM-GV-27][lim-gv]) |
| Operational keys | A stolen PAUSER, PLATFORM, CURATOR or STORAGE_OPERATOR key keeps acting | [GV-3][gv]: the network revokes it at once ([LIM-GV-28][lim-gv]) |
| Unmapped selectors | A `restricted` function escapes its class | [GV-15][gv]: every one is mapped or listed; anything else falls back to ADMIN (7 days) |
| Delay changes | A delay is shortened, or a funds selector remapped to a faster role | [GV-2][gv]: remapping a selector is an ADMIN action (7 days); the brake can delay it once |
| `execute` with value | ETH sent through `execute` lands in a target | [GV-16][gv]: every governed function is non-payable |
| Stale operations | An operation written against an old value executes later | [GV-17][gv]: compare-and-set; [GV-7][gv]: operations expire 14 days after they become ready |
| The manager itself | The manager remaps its own functions or is closed | [GV-9][gv]: its own selectors cannot be remapped and it cannot be closed |

### Content and rendering

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| Inline `Base64` media | JSON or URI injection through a file declared base64 | [RND-18][rnd], [WS-31][ws]: inlined only after a strict, permissionless attestation |
| Strings in metadata | Quotes, escapes, `%` or `#` break the JSON or the `data:` URI | [RND-15][rnd]: validated JSON copied, every other string checked and escaped; [AUC-12][auc]: collection names refuse escaping bytes |
| `tokenURI` | Unbounded gas makes metadata unreadable | [RND-26][rnd]: at most 8M Prague gas with every cap at once; [RND-10][rnd]: record caps |
| Record attributes | A look-alike of a trait the renderer vouches for | [RND-13][rnd]: ASCII trait names, no renderer name in any case or spacing (CONTENT-5) |
| Script works | The artist's script breaks out of the renderer's page | [RND-19][rnd]: `</script` and `<!--` neutralized; large scripts served by locator |
| Renderer reads | A hostile token, satellite or store returns garbage, or a repricing starves a read, and the renderer reports plausible metadata | [RND-6, RND-7][rnd]: reads that forward all gas with a return-size cap and revert on failure; a shortfall reverts (`BoundedCallShortfall`), so no compiled cap can break a pinned work's metadata |
| `WorkRecords.setDelivery`, the delivery contract | A replaced or hostile delivery contract changes a work's facts or serves another file | [WS-39, WS-40][ws]: no write path but two refresh hooks; only a well-formed answer is served, else the work's own answer ([LIM-GV-23][lim-gv]) |
| `WorkRecords.addStore`, `syncOnChain` | A store adapter serves wrong bytes, or a caller undoes another's sync | [WS-41 to WS-43][ws]: every chunk re-hashed through `firstMissing`; a file's store is final once complete, and a file in progress switches only away from a missing chunk |
| Renderer pins | Code under a pinned renderer address changes | [RND-2, RND-3][rnd]: checked at every use, with no fallback (DEPS-6) |
| `rendererOf` | A records fault or a starved read serves the default renderer for a pinned work | [AUC-42][auc]: only "no pin" and `RecordNotOpen` serve the default; any other revert is passed on and a shortfall reverts |
| `WorkDelivery.addLocator` | A locator is repointed, or listed twice | [WS-18, WS-19][ws]: canonical content addresses, no duplicates, quotas, PLATFORM alone after finalize (CONTENT-3, LIFECYCLE-3) |
| Preferences | The storage operator points a file at another file's copy | [WS-22][ws]: only the file's own copies |
| Licenses | A CC0 work is relicensed, or names another CC0 text | [WS-5, WS-12][ws]: the pinned CC0 text, irrevocably |

### Entropy

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `requestSeed` | Spam requests drain the subscription | [ENT-1, ENT-2, ENT-5][ent]: the gate is an approved, unconsumed VRF item, one draw per content hash, repeats after an exponential backoff from `retryDelay`, capped at 30 days; the network revokes a hostile package at once ([LIM-ENT-2][lim-ent]) |
| `requestFederatedSeed` | A federated request spends the network's subscription, or a draw is redirected | [ENT-20 to ENT-22][ent]: only a VRF item of a listed contract, from a wallet of its artist, paid by the requester through the VRF wrapper; the subscription is never used; off until the network sets a wrapper ([LIM-ENT-8][lim-ent]) |
| Repeats and deliveries | An observer re-rolls a seed it dislikes | [ENT-4, ENT-5][ent]: a repeat never invalidates a request, and the first delivery wins. Residual: delivery ordering ([LIM-ENT-1][lim-ent]) |
| Re-packaging | A revised package draws a second seed | [ENT-2][ent]: draws are keyed by content hash (DEPS-1) |
| Coordinator | An old or replaced coordinator delivers | [ENT-6, ENT-7, ENT-8][ent]: requests scoped to their coordinator, code hash checked |
| Coordinator at deployment | A mainnet deployment installs a look-alike coordinator | The deploy accepts only the canonical coordinator with its code hash (DEPS-3) |
| Subscription | Another consumer drains it, or an owner outside the network controls it | The deploy and Verify require the module as sole consumer and the network as owner on mainnet (DEPS-4); residual in [LIM-ENT-5][lim-ent] |
| Callback gas | A hostile setter starves the callback, or a limit above the coordinator's maximum stops VRF works | [ENT-10, ENT-11][ent]: raise-only with a ceiling, lowering in 7 days above the floor (DEPS-5); [ENT-13][ent]: the callback writes no new slot (DEPS-2) |

### Storage

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| Arweave and IPFS copies | A copy is lost and media disappears | Several copies, paid for by the network, and a preference; dead locators are passed over ([WS-19, WS-22][ws]); anyone can complete the work on-chain ([WS-17][ws]); see [LIM-CNT-1][lim-cnt] |
| `registerManifest` | A front-run manifest claims a wrong MIME type or digest | [WS-25][ws]: the file ID commits to the whole manifest |
| Content reads | A missing or wrong chunk returns partial or wrong bytes | [WS-27, WS-28][ws]: every chunk checked on every read; a missing one reverts |
| Dependency registry | A registered library version is changed | [WS-34, WS-35][ws]: versions are immutable; deprecation is a flag |

### Deployment

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `GovernanceConfigurator.configure` | The configuration lands on a stock or pre-seeded manager, or another account configures | [GV-10, GV-11][gv]: its own manager, targets answering it, the named deployer, once; it ends with no role |
| Genesis wiring | A zero-delay verifier or recipient change is smuggled in | [GV-12][gv]: only the allow-list, at most 64 calls, before any selector is mapped |
| Holders | The network is not a sound Safe, or an operational holder names a network role | The deploy guard (`DeployGuards`): off anvil the network is a canonical Safe with a threshold of at least 2, plain-key owners, no module or guard; no holder names a network role; at least two curation signers; on mainnet the deployer holds nothing ([LIM-GV-18][lim-gv]) |
| Policy drift | The selector map or wiring differs from the policy, or drops a contract | [GV-13, GV-15][gv]: readback reverts on any difference; only holders, the network and the brake may differ, and nothing named may be dropped |
| After deployment | The system differs from the record, or drifts later | `Verify.s.sol` checks code hashes, governance, wiring, events, the network's acceptance, pending operations and the subscription (GOV-3) |

## Out of scope or not defended

- **Off-chain judgement:** whether a package deserved approval, the signer's tooling, the conduct
  of the TDH vote ([LIM-GV-1, LIM-GV-2, LIM-GV-9][lim-gv]).
- **The network Safe's signers acting together above its threshold.** The network acts within
  the permanent contracts and its class delays ([trust assumptions](trust-assumptions.md)).
- **A Safe changed between readbacks** ([LIM-GV-15][lim-gv]).
- **Token issuers' powers** over balances a protocol contract holds.
- **Marketplace behavior:** ERC-2981 royalties are advisory ([LIM-SAL-8][lim-sal]).
- **Availability of off-chain copies** before a work is on-chain complete ([LIM-CNT-1][lim-cnt]).
- **Legal effect** of CC0 or any license text.
- **Low prices**: an opening bid of 0.05 ETH at genesis (the asset allowlist's; zero in other currencies), a self-bid
  at that floor, and demand reduction in the edition auction
  ([LIM-SAL-1][lim-sal], [LIM-EA-5][lim-ea]).
- **Chain-level behavior:** censorship, reorganizations, and mainnet's final Glamsterdam and
  EIP-7825 parameters ([LIM-GAS-1, LIM-GAS-2][lim-gas]).
- **Deployed-bytecode verification** ([LIM-REL-1][lim-rel]); for 6529 Stream Federated, what
  a template version cannot defend is in [Federation](../spec/federation.md) (LIM-FED-1 to
  LIM-FED-8).

## Residual risks

The accepted residual risks this model relies on most, each stated once in
[known limitations](known-limitations.md):

- A trusted curation signer until the 6529 chain ([LIM-GV-1][lim-gv]).
- One network address until the TDH bridge, the handover and the brake
  ([LIM-GV-18, LIM-GV-26, LIM-GV-27][lim-gv]).
- Equal wallets, the restraint, and the consolidation source
  ([LIM-ID-2, LIM-ID-7, LIM-ID-20][lim-id]).
- VRF delivery ordering and the network's subscription ([LIM-ENT-1, LIM-ENT-5][lim-ent]).
- Raise-only parameters per operation, not per window ([LIM-GV-7][lim-gv]).
- Signed releases reviving on a return to an old payout address ([LIM-ECO-2][lim-eco]).
- Front-run starts and tokens sent with a plain transfer ([LIM-SAL-9, LIM-SAL-10][lim-sal]).
- A token whose settlement fails holds its sale for 2 days after its end, and a token's ledger
  is trusted for delivery ([LIM-SAL-16][lim-sal]).
- The edition auction's game theory: soft-close griefing, the breadth-rule tilt, shill bids and
  firm bids ([LIM-EA-1 to LIM-EA-3, LIM-EA-13][lim-ea]).
- Fixed gas allowances, state gas and the EIP-8037 reservoir under Glamsterdam
  ([LIM-GAS-2, LIM-GAS-5][lim-gas]).

## Differences from the ADRs

See the [register](../spec/README.md#differences-from-the-adrs).

## References

- Specification: [rules and invariants of every area](../spec/README.md); audit pack:
  [trust assumptions](trust-assumptions.md), [role and permission matrix](roles.md),
  [known limitations](known-limitations.md), [invariants](invariants.md).
- Review: [internal adversarial review, October 2026](../security/internal-review-2026-10.md);
  regression tests by finding ID in the
  [appendix](../security/internal-review-2026-10.md#7-appendix-how-to-reproduce).
- ADRs: [0001](../adr/0001-v1-scope.md), [0002](../adr/0002-access-manager-hardening.md),
  [0003](../adr/0003-build-time-decisions.md), [0004](../adr/0004-gas-budgets-under-glamsterdam.md),
  [0005](../adr/0005-stream-editions-auction.md).
- Architecture: [call flows and trust boundaries](../architecture.md#trust-boundaries).

[auc]: ../spec/stream-and-auctions.md#rules-and-invariants
[exit]: ../spec/stream-and-auctions.md#a-token-that-will-not-settle
[cur]: ../spec/curation.md#rules-and-invariants
[dsp]: ../spec/disputes-and-statements.md#rules-and-invariants
[eco]: ../spec/economics-and-payouts.md#rules-and-invariants
[ed]: ../spec/editions-and-sales.md#rules-and-invariants
[ent]: ../spec/entropy.md#rules-and-invariants
[gv]: ../spec/governance.md#rules-and-invariants
[id]: ../spec/identity-and-recovery.md#rules-and-invariants
[rnd]: ../spec/rendering-and-tokenuri.md#rules-and-invariants
[ws]: ../spec/works-and-storage.md#rules-and-invariants
[lim-gas]: known-limitations.md#gas-and-glamsterdam
[lim-gv]: known-limitations.md#trust-and-governance
[lim-id]: known-limitations.md#identity-and-recovery
[lim-sal]: known-limitations.md#sales-and-auctions
[lim-ea]: known-limitations.md#the-edition-auction
[lim-eco]: known-limitations.md#economics-and-payouts
[lim-cnt]: known-limitations.md#content-records-and-rendering
[lim-ent]: known-limitations.md#entropy
[lim-rel]: known-limitations.md#release-evidence
