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
  ([`config/genesis.example.json`](../../config/genesis.example.json)). 6529 Stream Federated
  (v1.1) is out of scope: no federation registry is installed in v1.
- **Review history.** The modules were reviewed adversarially while they were built
  ([ADR 0003](../adr/0003-build-time-decisions.md)), and the integrated system had an
  [internal adversarial review](../security/internal-review-2026-10.md) in October 2026, whose
  fixes merged in PRs #51 to #57. Finding IDs such as MARKET-2 or IDENTITY-1 mark the defenses
  that came from it; each finding's regression tests carry its ID in a `/// Regression:` NatSpec
  line ([the test map](../../test/README.md)). This is not an audit.
- **How to read the tables.** Each row is one entry point and one threat. The mitigation names
  the rule (its spec page holds the enforcing function and the tests) and, in brackets, the
  finding it closed. Delays use the [delay classes](../glossary.md#delay-class): immediate;
  standard, 48 hours; funds, 14 days; successor, 30 days.

## Assets

| Asset | Where it lives | Who may move or change it | What threatens it |
| --- | --- | --- | --- |
| NFTs in auction custody | `EnglishAuction`, from `start` to delivery, a pending delivery, or a burn | Settlement delivers to the winner's recipient; unsold, a 6529 Stream work is moved to the 6529 Network Museum by Stream itself (owner decision 17) and any other token's goes to its artist; an upheld dispute burns it | Blocked or griefed settlement, a hostile receiver, stranding, confiscation |
| Bidder ETH and ERC-20 | The standing high bid; outbid and refunded bids as per-account credits | The bidder: `claim`, and `withdrawBid` while paused or frozen. Settlement pays out only the winning bid | Lock-up, theft, hostile tokens, a currency that never returns |
| Edition bidders' ETH | Every live edition bid's escrow in `UniformEditionAuction`, until it is claimed or withdrawn; refunds credited by `claimBidFor` | The bidder: `claimBid` after settlement, `withdrawBid` while the 1/1 is paused (a bid placed before the pause). Settlement pays out only `count × price` | Lock-up, a wrong clearing or allocation, double claims, an unsold copy |
| Sale proceeds in flight | Payments from the two auctions' `settle` to the seller wallet and fee recipient; failed ERC-20 settlement payouts credited in the English auction | `RevenuePayment` (pay, else escrow); `EnglishAuction.claimFor` | A refusing wallet, a blocking token, gas starvation |
| Split wallet balances | Each `SplitWallet`, for ETH and any ERC-20 | Fixed payees: anyone, to the payee. Artist payees: only the current payout address, or its signature | A push to a lost key, a redirected payout, a replayed release, hostile tokens |
| Escrow credits | `RevenueEscrow` | Anyone flushes a credit to its own wallet; governed `recover` moves it to an equivalent wallet or a consented replacement | Governance taking credits, a blocked wallet |
| Artist identity and payout routing | `ArtistRegistry` | The artist (7-day change); governance (180-day override); captured wallets cancel or contest; guardians veto | Key theft, planted wallets, abuse of recovery, a broken identity source |
| Curation integrity | `PackageRegistry` and `Eip712CurationVerifier` | The curation signer approves; guardians revoke; only the bound Stream consumes | Forged or leaked approvals, signer compromise, reuse, squatting, copies |
| Metadata integrity and permanence | `WorkRecords`, `ContentStore`, the renderer | The artist until finalize; governance with every party's consent; PLATFORM and STORAGE_OPERATOR for copies and routing; nobody for stored bytes | JSON injection, unbounded gas, look-alike traits, script break-out, renderer substitution, locator repointing |
| Governance control | `WorksAccessManager` | ADMIN after 30 days; any guardian cancels, and suspends an operational key at once | Takeover, entrenchment, hidden delay cuts, value through `execute`, a stalled recovery |
| VRF subscription funds | The Chainlink subscription | The coordinator, per request; the subscription owner | Spam draining, seed re-rolls, a compromised owner cancelling it |
| Reputation and display | `StatementLog` entries shown in metadata | PLATFORM, CURATOR, the artist through the resolver, token holders | False, stale or forged statements |

## Actors

| Actor | What it can do on-chain | Trusted for |
| --- | --- | --- |
| Artist (the lead party's active authority) | Accept packages, sign and revoke moves, edit and finalize its records, co-sign amendments, release its share; bid on its own editions like anyone | Its own works and share |
| Collaborator | Accept the package, co-sign amendments, release its own share | Its own consent and share |
| Collector or bidder | Bid on 1/1s and editions, raise edition bids, withdraw while a 1/1 is paused or frozen, claim bids and credits, upload chunks, write OWNER statements | Nothing |
| Winning bidder with a hostile receiver | Name any recipient, which may reject the token, burn gas, re-enter or hand it back | Nothing |
| Platform, curator, storage operator keys | Bounded operational duties ([trust assumptions](trust-assumptions.md#operational-keys)) | Display, evidence and operations |
| Curation signer | Sign approvals off-chain; never calls a contract | Approving only voted packages, after checking the bytes |
| Guardians (three Safes) | Cancel, pause, veto, revoke, disable, deprecate, suspend | Tightening actions; never proposals |
| Admins (hot and cold Safes) | Every governed action at its class delay | Executing the network's decisions |
| Keepers and relayers | Call permissionless entry points; relay signed payloads | Liveness only |
| VRF coordinator | Deliver random words for its requests | Unbiased randomness |
| Token issuers | Blocklist, charge fees, rebase, upgrade token behavior | Standard transfers, judged at admission |
| MEV searchers and block builders | Order, insert and front-run transactions | Nothing |
| Attackers with stolen keys | Any key or Safe above, each bounded in [trust assumptions](trust-assumptions.md) | Nothing |
| Copiers | Submit another artist's content as their own | Nothing |

## Attack surfaces

### Auctions: start, bid, settle

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `start`, `startWithBid` | Start a work whose terms can never settle (the escrow as seller or fee recipient) | [AUC-14][auc]: refused at start, while nothing is in custody (CALLS-1) |
| `start` | Start an unapproved, revoked, reused or copied item, or one without the artist's move | [AUC-3][auc], [CUR-1, CUR-6, CUR-10, CUR-12][cur]: every mint consumes an approved, accepted, moved item, once per content hash; a VRF item also needs its seed ([AUC-4][auc]) |
| `startWithBid` | A searcher front-runs a start with the same move | Accepted: the victim loses only gas, and a move has no "not before" ([LIM-SAL-9][lim-sal], MARKET-4) |
| `bid` | A zero or dust bid claims a work | [AUC-16][auc]: a minimum first bid and a minimum increment |
| `bid` | Sniping in the last seconds | [AUC-17][auc]: a late bid extends the end by the anti-snipe window |
| `bid` | An outbid bidder that reverts on receipt blocks later bids | [AUC-18][auc]: outbid bids become pull credits |
| `settle` | A hostile receiver rejects the token, burns gas or re-enters | [AUC-21][auc]: a failed delivery becomes a pending delivery after payment and settlement; [AUC-31][auc]: no reentry |
| `settle` | A settler starves the call so delivery or a payout fails into its fallback | [AUC-22][auc]: the call reverts unless it forwards the delivery gas and the ERC-20 payout frame in full (MONEY-1) |
| `settle` (no bid) | The artist, or a key under recovery, blocks a no-bid settlement or takes the museum's work | [AUC-24][auc]: the auction reports UNBID and 6529 Stream itself moves the work to the museum the resolver names then, whatever the artist's state, with no receiver callback, so nothing is pending and nobody can claim it ([AUC-33][auc], owner decision 17); any other token's work goes to the active authority, and settlement waits while it is zero (IDENTITY-1) |
| `settle` | A seller wallet or token blocks the payout and so the delivery | [AUC-23][auc]: escrow, else a credit for `claimFor`, while the work is delivered (MONEY-1) |
| Value-moving entry points | Reentrancy through a token, wallet or receiver callback | [AUC-31][auc]: a transient reentrancy guard on every value-moving entry point |
| Currency deprecation | A deprecated currency strands bids and works, or a hasty re-admission undoes it | [AUC-25][auc]: the auction freezes, the bidder may withdraw, and after 30 days it ends unsold (FROZEN_OUT: 6529 Stream moves the work to the museum, owner decision 17); [ECO-33][eco]: re-admission waits 14 days from the deprecation (MARKET-2) |
| `onERC721Received` | Tokens sent to the auction outside a start are stranded | [AUC-29][auc]: every safe transfer but its own mint is refused; a plain `transferFrom` is the sender's loss ([LIM-SAL-10][lim-sal], CALLS-5) |
| Whole lifecycle | Value leaks, or a work ends in two states | [AUC-20][auc]: value conservation and one outcome with exact custody, as stateful invariants |

### Payments

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| ERC-20 bids | Fee-on-transfer, rebasing, no-return or false-returning tokens underpay | Exact balance deltas on both sides on every path ([ECO-23][eco], [AUC-19][auc]). Return values are checked on the direct paths, not on Permit2 pulls, which check only balances. The guard against non-standard tokens is governance vetting at `AssetAllowlist.admitAsset` ([LIM-SAL-7][lim-sal]). Edition bids are ETH only |
| Payouts | A blocklisting token blocks a seller or fee wallet | [ECO-26][eco]: the payment reaches the wallet or a credit under it; with the escrow blocked too, the English auction credits the payout ([AUC-23][auc], MONEY-1) |
| ETH payouts | A wallet that refuses ETH or burns gas blocks a sale | [ECO-26][eco], [EA-12][ed]: 100,000 gas per payout (`PAYOUT_GAS`), escrow on refusal |
| `PERMIT2` payments | Replay, or a relayer redirecting the payment | [AUC-19][auc]: Permit2's nonce is the replay key, and the witness binds the sale or start, the recipient, the amount and the deadline |
| `PERMIT` (EIP-2612) | A front-run permit makes the payment fail | A failing permit is ignored and the pull uses the allowance it set; only the 65-byte form is accepted (QUALITY-7): `test_Bid_Erc20FrontRunPermitStillBids` in [`EnglishAuction.t.sol`](../../test/sales/auction/EnglishAuction.t.sol) |

### Editions

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `Editions.mint` | A second admitted adapter adds copies to a sale another one ran, or copies pass the creator's cap | [ED-5, ED-6][ed]: an edition is bound to the adapter whose sale opened it (or else its first minter), and the cap holds for every minter, a removed bound adapter included |
| `Editions.bindMinter` | A second adapter of the same kind opens a sale of an edition another one sells, stranding one sale's winners; or a permissionless `open` binds an edition to the wrong adapter | [ED-5][ed]: the edition auction binds at `open`, before it records the sale, so the second open reverts (`MinterMismatch`); only an admitted adapter binds, and only one whose kind the master's stored item names (checked against its item hash) |

### Edition auctions

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `open` | Open a sale for a work that is not an edition master, under other terms, or twice | [EA-1][ed]: the item must hash to the one Stream stored, with this sale kind in ETH; one sale per edition, from the 1/1's start until its close; `open` binds the edition (`bindMinter`), so no second adapter of the kind can open it |
| `bid`, `raise` | Underpay, or bid off the ladder | [EA-3, EA-4][ed]: fixed step prices; exact payment, no slippage |
| `bid`, `raise` | Spoof demand with bids withdrawn before the close | [EA-5][ed]: bids are firm; withdrawals open only while the 1/1 is paused for a dispute, and only for bids placed before the pause, so a pause gives no free option to post and pull demand ([ADR 0005 §12](../adr/0005-stream-editions-auction.md#12-amendment-1-november-2026-fix-pass-a-of-the-rc2-review)) |
| `bid` | Shill bids as a reserve; count inflation; the breadth-rule tilt | Accepted: every bid is a real, public purchase, and revenue stays within the margin of the best ([LIM-EA-2, LIM-EA-3][lim-ea]) |
| `bid` | Sniping, or keeping the sale open forever | [EA-10][ed]: the soft close restarts the window after each bid, up to the governed backstop ([LIM-EA-1][lim-ea]) |
| 1/1 `bid` | Close the edition sale early by settling the 1/1 | [EA-10][ed]: the edition close follows the 1/1's final end, anti-snipe and resumption included |
| `settle` | Settle early, settle on a wrong book, misallocate the cut step, or make settlement too costly to finish | [EA-6, EA-8, EA-11][ed]: only after the end and a final 1/1; the clearing equals the per-unit definition; a settler's sweep must be complete and in position order: a reordered one reverts, and one that skips a departure strands only its sender's own sweep, never the sale; settlement runs in calls of bounded gas, each advancing it ([LIM-EA-4, LIM-EA-15][lim-ea]) |
| `claimBid`, `claimBidFor` | Mint more than sold, claim twice, or strand a refund | [EA-9][ed]: exactly `count` copies once every bid is claimed, each bid once; a failed refund reverts, and `claimBidFor` credits it instead |
| Dispute of the 1/1 | Editions of a work later cancelled stay sold | [EA-13][ed]: a cancelled 1/1 voids the sale with full refunds; bidders whose bids predate the pause may withdraw during it ([LIM-EA-14, LIM-EA-16][lim-ea]) |
| Whole lifecycle | Value leaks, or the clearing drifts from its definition | [EA-14][ed]: ETH conservation, the per-unit reference, FIFO and the clocks, as stateful invariants on the real stack |

### Split wallets and releases

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `release` for an artist payee | Anyone pushes an artist's share to a lost or stolen key | [ECO-16][eco]: artist payees are pull-only |
| `release` during a recovery | The key being recovered from pulls the balance | [ECO-18][eco], [ID-16][id]: the payout resolves to zero while a change would move it, and the wallet refuses |
| Payout rotation | A payout points at a contract that can never pull | [ECO-19][eco], [ID-17][id]: such payouts are refused (MONEY-4); a predicted wallet address cannot be ([LIM-ID-12][lim-id]) |
| `releaseWithAuthorization` | A signed release is replayed, on this or another chain or wallet | [ECO-20, ECO-21][eco]: bound to wallet, chain and deadline; replay keyed on the nonce |
| Resolver | Replaced code at the resolver's address redirects artist shares | [ECO-18][eco]: the resolver's code hash is checked at every artist-payee release |
| `ClaimRouter.claim` | A stranger routes an artist's share through the batch router | [ECO-16, ECO-29][eco]: plain items serve fixed payees only, and the router cannot redirect a release |
| `ClaimRouter` continue mode | An item silently runs out of gas and is skipped | [ECO-30][eco]: a shortfall below the ceiling reverts the batch (MONEY-3) |
| Value accounting | Releases exceed entitlements, or rebases distort them | [ECO-13, ECO-14, ECO-24][eco]: cumulative entitlements, conservation, and a high-water mark that freezes on a shrinking balance |

### Escrow recovery

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `RevenueEscrow.recover` (FUNDS_SETTER, 14 days) | Governance moves a blocked wallet's credit where it chooses | [ECO-28][eco]: only to an equivalent wallet or the consented replacement (MONEY-2) |
| `RevenueEscrow.flush` | A hostile token re-enters, or a flush loses the credit | [ECO-27][eco]: a flush pays only the credited wallet, and a failed transfer reverts it; a transient guard blocks reentry (`test_FlushReentryIsBlocked` in [`RevenueEscrow.t.sol`](../../test/economics/RevenueEscrow.t.sol)) |

### Curation

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `registerPackage` | A forged attestation, or one from another chain or deployment | [CUR-4, CUR-5][cur]: an active signer, its current epoch, this domain, and the canonical encoding only |
| `registerPackage` | A leaked attestation is registered before anyone can react | [CUR-2][cur]: a root revoked in advance never registers |
| Signer compromise | A compromised signer keeps approving, or its old approvals revive | [CUR-17][cur]: an immediate, one-way disable; [CUR-4][cur]: approvals bind the signer epoch (SIGS-2). Registered roots stay usable, so guardians revoke them per root ([CUR-16][cur]) |
| `consume` | An item, or its content, is used twice | [CUR-12][cur]: one consume per content hash, through any root |
| `consume` | A copier consumes a work's content hash first | Off-chain first: the signer checks every declared SHA-256 ([LIM-GV-2][lim-gv]). On-chain: an upheld dispute burns the copy and [CUR-14][cur] reserves the hash for the rightful artist (SIGS-1) |
| Copied works | A copier gets another artist's work approved | As above, and guardians revoke every root listing the copier's items ([CUR-16][cur]); after a sale a dispute yields only a statement ([DSP-22][dsp]) |
| `acceptPackage` | Pre-signed acceptances with different profiles race | [CUR-7][cur]: the first relayed sets the profile; the rest revert |
| `revokePackage` | Revoking a root strands a sold master's edition | [ED-1][ed]: a registered root counts, revoked or not (SIGS-4) |
| `setVerifier` (SUCCESSOR_SETTER, 30 days) | A swap back restores a retired verifier's approvals | [CUR-18][cur]: retired verifiers never return; [CUR-3][cur]: the pin is checked at every registration |

### Identity and recovery

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `stageChange` with a stolen key | A thief rotates the authority and payout | [ID-8, ID-9, ID-10][id]: a 7-day wait, cancellable by the previous authority, captured wallets and guardians |
| Consolidation data | A thief revokes or reorders consolidations to strip the cancellers | [ID-21, ID-23][id]: the sticky standing snapshot, and cancellers fixed at staging |
| Consolidation data | Wallets planted with the artist's key gain standing | [ID-20, ID-22][id]: 30 days pending, dropped if unconsolidated (IDENTITY-3); residual in [LIM-ID-4][lim-id] |
| `cancelChange` on an override | A thief's captured wallet kills the network's recovery override | [ID-13, ID-14][id]: the cancel only contests; a later recorded vote decides; the payout stays frozen |
| `stageOverride` (PARAMETER_SETTER, 48 hours) | The network abuses recovery to take an identity | [ID-11, ID-12][id]: 180-day notice, the new authority's acceptance, a year of dormancy for estate and lost-key overrides; captured wallets contest and guardians veto ([ID-10][id]). The restraint is the trade-off ([LIM-ID-2][lim-id]) |
| Signatures during a recovery | The key under recovery, or the reserved new key, acts as the artist | [ID-18][id]: no active authority while an authority-moving override is pending (IDENTITY-1) |
| Rotation back to an old key | Unused signatures of the old key revive | [ID-2, ID-3][id]: no return to a past authority (SIGS-3), and the new key is reserved (IDENTITY-2) |
| Override acceptance | A key holder burns nonces to void an override, or an acceptance is reused | [ID-7, ID-12][id]: acceptances bind no nonce and are consumed once |
| Consolidation source outage | A broken source reads as "not consolidated" and strips standing | [ID-25, ID-26][id]: reads fail closed, with code-hash checks (IDENTITY-4, DEPS-6) |

### Disputes

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `pause(saleId, ref)` (GUARDIAN) | Repeated pauses hold an auction hostage | [DSP-13, DSP-14, DSP-15][dsp]: once per auction, at most 7 days, and bidders may withdraw |
| `resume`, `unpause` (UNPAUSER, 48 hours) | An operation scheduled before the pause undoes it in the same block | [DSP-16][dsp], [EA-15][ed], [GV-23][gv]: nothing lands before 48 hours after the pause (GOV-5) |
| `resume` | Bidders refunded during the pause have no time to return | [DSP-17][dsp]: the resumed auction runs at least the governed duration, with the withdrawn bid as a reserve (LIFECYCLE-1) |
| `cancel` (PARAMETER_SETTER, 48 hours) | A stale outcome, or one about the item, cancels an auction | [DSP-18][dsp]: the token's own latest outcome, recorded after the pause (LIFECYCLE-4) |
| `cancel` window | A cancel lands after the pause lapsed, or too early | [DSP-16, DSP-19][dsp]: from 48 hours after the pause while it is live |
| `resolveContested` (SUCCESSOR_SETTER, 30 days) | An outcome from an earlier contest decides this one | [ID-14][id], [DSP-25][dsp]: the latest outcome, recorded after the contest |
| `StatementLog` appends | Anyone records a dispute outcome or curation evidence | [DSP-4, DSP-11][dsp]: reserved kinds only under their roles, directly or by relay; an ERC-721 outcome needs the token |
| After a sale | A dispute confiscates a sold work | [DSP-20, DSP-22][dsp]: no path burns or moves a settled work |

### Governance

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| Admin operations on the manager | A compromised admin revokes guardians, remaps selectors or grants itself roles | [GV-4][gv]: every admin operation waits 30 days; [GV-1][gv]: any guardian cancels it; [GV-2][gv]: a compromised admin cannot cancel its own removal |
| Revocations on the manager | A hot admin and one dishonest guardian keep the cold admin's recovery from finishing (GOV-1) | [GV-25][gv]: a revocation scheduled by another account is cancellable only by a guardian, never the one it names, so recovery takes two 30-day rounds; admins still cancel each other's other operations |
| Zero-delay operational keys | A stolen PLATFORM, CURATOR or STORAGE_OPERATOR key acts for 30 days while its revocation matures (GOV-2) | [GV-26, GV-27][gv]: any guardian suspends it at once, and it fails `hasRole` in the same block. [GV-28][gv]: an ADMIN grant or revocation of that role to that account lifts it (30 days, guardian-vetoable), as does the holder's own `renounceRole` |
| `suspend` by a dishonest guardian | A guardian stops the operational keys and blocks every lift | [GV-28][gv]: it cannot lift or cancel its own removal, so the lift lands about 60 days later; accepted ([LIM-GV-14][lim-gv]) |
| Guardian rotation | A guardian vetoes its own removal | [GV-2, GV-25][gv]: nobody else's veto applies, and [GV-3][gv]: a revocation wrapped in `multicall` or a nested `execute` never executes |
| `setAuthority` on a target | The admin moves a target to a rogue manager | [GV-1][gv]: guardians cancel operations on every target, which a stock manager's guardians cannot |
| Unmapped selectors | A `restricted` function escapes its class | [GV-17][gv]: every one is mapped or listed; anything else falls back to ADMIN, guardian-vetoable |
| Delay changes | The admin shortens a delay or remaps a funds selector to a faster role | [GV-5][gv]: a cut to a grant delay or target admin delay takes effect after the longer of 5 days (`minSetback`) and the size of the cut, an execution-delay cut after the size of the cut; [GV-4][gv]: remapping takes 30 days; [GV-15][gv]: Verify fails on a pending cut, which readback cannot see |
| `execute` with value | ETH sent through `execute` lands in a target | [GV-18][gv]: every governed function is non-payable |
| Stale operations | An operation written against an old value executes later | [GV-19][gv]: compare-and-set; [GV-7][gv]: operations expire a week after they mature |
| Whole system | A compromised admin gains control against vigilant guardians | [GV-16, GV-30][gv]: stateful invariant campaigns, with Rule 3 and suspensions |

### Content and rendering

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| Inline `Base64` media | JSON or URI injection through a file declared base64 | [RND-18][rnd], [WS-31][ws]: inlined only after a strict, permissionless attestation |
| Strings in metadata | Quotes, escapes, `%` or `#` break the JSON or the `data:` URI | [RND-15][rnd]: validated JSON copied, every other string checked and escaped; [AUC-12][auc]: collection names refuse escaping bytes |
| `tokenURI` | Unbounded gas makes metadata unreadable | [RND-26][rnd]: at most 8M Prague gas with every cap at once; [RND-10][rnd]: record caps |
| Record attributes | A look-alike of a trait the renderer vouches for | [RND-13][rnd]: ASCII trait names, no renderer name in any case or spacing (CONTENT-5) |
| Script works | The artist's script breaks out of the renderer's page | [RND-19][rnd]: `</script` and `<!--` neutralized; large scripts served by locator |
| Renderer reads | A hostile token, satellite or store returns garbage and the renderer reports plausible metadata | [RND-6, RND-7][rnd]: bounded reads that revert on failure or starvation |
| Renderer pins | Code under a pinned renderer address changes | [RND-2, RND-3][rnd]: checked at every use, with no fallback (DEPS-6) |
| `addLocator` | A locator is repointed, or listed twice | [WS-18, WS-19][ws]: canonical content addresses, no duplicates, quotas, PLATFORM alone after finalize (CONTENT-3, LIFECYCLE-3) |
| Preferences | The storage operator points a file at another file's copy | [WS-22][ws]: only the file's own copies |
| Licenses | A CC0 work is relicensed, or names another CC0 text | [WS-5, WS-12][ws]: the pinned CC0 text, irrevocably |

### Entropy

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `requestSeed` | Spam requests drain the subscription | [ENT-1, ENT-2, ENT-5][ent]: the gate is an approved, unconsumed VRF item, one draw per content hash, repeats after `retryDelay`; guardians revoke a hostile package ([LIM-ENT-2][lim-ent]) |
| Repeats and deliveries | An observer re-rolls a seed it dislikes | [ENT-4, ENT-5][ent]: a repeat never invalidates a request, and the first delivery wins. Residual: delivery ordering ([LIM-ENT-1][lim-ent]) |
| Re-packaging | A revised package draws a second seed | [ENT-2][ent]: draws are keyed by content hash (DEPS-1) |
| Coordinator | An old or replaced coordinator delivers | [ENT-6, ENT-7, ENT-8][ent]: requests scoped to their coordinator, code hash checked |
| Coordinator at deployment | A mainnet deployment installs a look-alike coordinator | [GV-31][gv]: only the canonical coordinator with its code hash (DEPS-3) |
| Subscription | Another consumer drains it, or an owner outside governance controls it | [GV-32][gv]: Verify requires the module as sole consumer and the hot admin as owner (DEPS-4); residual in [LIM-ENT-5][lim-ent] |
| Callback gas | A hostile setter starves the callback, or a limit above the coordinator's maximum stops VRF works | [ENT-10, ENT-11][ent]: raise-only with a ceiling, lowering in 30 days above the floor (DEPS-5); [ENT-13][ent]: the callback writes no new slot (DEPS-2) |

### Storage

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| Arweave and IPFS copies | A copy is lost and media disappears | Several copies and a preference ([WS-19, WS-22][ws]); anyone can complete the work on-chain ([WS-17][ws]); see [LIM-CNT-1][lim-cnt] |
| `registerManifest` | A front-run manifest claims a wrong MIME type or digest | [WS-25][ws]: the file ID commits to the whole manifest |
| Content reads | A missing or wrong chunk returns partial or wrong bytes | [WS-27, WS-28][ws]: every chunk checked on every read; a missing one reverts |
| Dependency registry | A registered library version is changed | [WS-34, WS-35][ws]: versions are immutable; deprecation is a flag |

### Deployment

| Entry point | Threat | Mitigation |
| --- | --- | --- |
| `GovernanceConfigurator.configure` | The configuration lands on a stock or pre-seeded manager, or another account configures | [GV-9, GV-11][gv]: its own manager, targets answering it, the named deployer, once |
| Genesis wiring | A zero-delay verifier or recipient change is smuggled in | [GV-12][gv]: only the allow-list, at most 64 calls, before any selector is mapped |
| Holders | A holder nobody can operate becomes permanent | [GV-14][gv]: off anvil, Safes, the required counts, and no placeholder, system or deployment address |
| Safe topology | One key, a module, a guard or a nested owner acts for a Safe, or one person signs for several (GOV-4) | [GV-29][gv]: threshold, plain-key owners, canonical singleton, no module or guard, no shared signer |
| Deployer and namespace | A delegated deployer, or a squatter at predictable addresses | [GV-34][gv]: refused before the broadcast |
| Policy drift | The selector map or wiring differs from the policy, or drops a contract | [GV-14, GV-17][gv]: only holders may differ, and nothing named may be dropped |
| After deployment | The system differs from the record, or drifts later | [GV-15, GV-29, GV-31 to GV-33][gv]: Verify checks code hashes, governance, wiring, events, Safes, suspensions, pending operations and the subscription (GOV-3) |

## Out of scope or not defended

- **Off-chain judgement:** whether a package deserved approval, the signer's tooling, the conduct
  of the TDH vote ([LIM-GV-1, LIM-GV-2, LIM-GV-9][lim-gv]).
- **Collusion beyond the stated bounds:** two or more guardians, both admin Safes, or a Safe's
  signers above its threshold. A hot admin with one guardian is within bounds
  ([GV-25][gv]).
- **A Safe changed between readbacks** ([LIM-GV-15][lim-gv]).
- **Token issuers' powers** over balances a protocol contract holds.
- **Marketplace behavior:** ERC-2981 royalties are advisory ([LIM-SAL-8][lim-sal]).
- **Availability of off-chain copies** before a work is on-chain complete ([LIM-CNT-1][lim-cnt]).
- **Legal effect** of CC0 or any license text.
- **Low prices**: zero opening bids, and demand reduction in the edition auction
  ([LIM-SAL-1][lim-sal], [LIM-EA-5][lim-ea]).
- **Chain-level behavior:** censorship, reorganizations, and mainnet's final Glamsterdam and
  EIP-7825 parameters ([LIM-GAS-1, LIM-GAS-2][lim-gas]).
- **6529 Stream Federated (v1.1)** and **deployed-bytecode verification**
  ([LIM-REL-1][lim-rel]).

## Residual risks

The accepted residual risks this model relies on most, each stated once in
[known limitations](known-limitations.md):

- A trusted curation signer until the 6529 chain ([LIM-GV-1][lim-gv]).
- Guardian liveness and independence, and the suspension durations
  ([LIM-GV-4, LIM-GV-5, LIM-GV-12 to LIM-GV-14][lim-gv]).
- Planted wallets, the restraint, and the payout-only override
  ([LIM-ID-2, LIM-ID-4, LIM-ID-8][lim-id]).
- VRF delivery ordering and the hot admin's subscription ([LIM-ENT-1, LIM-ENT-5][lim-ent]).
- Raise-only parameters per operation, not per window ([LIM-GV-7][lim-gv]).
- Signed releases reviving on a return to an old payout address ([LIM-ECO-2][lim-eco]).
- Front-run starts and tokens sent with a plain transfer ([LIM-SAL-9, LIM-SAL-10][lim-sal]).
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
