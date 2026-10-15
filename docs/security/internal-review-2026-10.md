# Internal adversarial review, October 2026

**What this is.** An internal review of 6529 Works v1 carried out by AI agents working for the
project. It is not an external audit, and nothing in it says the contracts are free of defects.
6529 Works remains pre-audit and not production-ready ([SECURITY.md](../../SECURITY.md)). This
report records what was attacked, what was found, how each finding was resolved, and what is
left for the external audit.

| | |
| --- | --- |
| Commit reviewed | `2cd1e3462e795124f6f51a80f319fa812506f2a1` (`main` on 14 October 2026, the merge of #49, ADR 0004) |
| Review dates | Findings 14 October 2026; fixes and fix reviews 14 and 15 October 2026 |
| Fixes | #51, #52, #53, #54, #55, #56, #57 (all merged before this report was published) |
| Reviewers | Ten AI attacker agents (one per lens), then one independent AI reviewer per fix PR, coordinated by the project's AI integrator |
| Disclosure | The findings were kept private until every fix had merged ([SECURITY.md](../../SECURITY.md)) |

## Contents

1. [Summary](#1-summary)
2. [Findings](#2-findings)
3. [Medium findings](#3-medium-findings)
4. [Decisions and accepted risks](#4-decisions-and-accepted-risks)
5. [Coverage record](#5-coverage-record)
6. [Residual risks and recommended next steps](#6-residual-risks-and-recommended-next-steps)
7. [Appendix: how to reproduce](#7-appendix-how-to-reproduce)

## 1. Summary

### Scope

All Solidity under `src/` at the reviewed commit: 82 files, **9,616 nSLOC** (non-blank,
non-comment lines as `tools/check_budgets.py` counts them, interfaces and libraries included),
24 deployable contracts and one abstract base.

| Module | Contracts | nSLOC |
| --- | --- | ---: |
| `stream` | `Stream`, `WorkRecords` | 1,081 |
| `editions` | `Editions` | 326 |
| `curation` | `PackageRegistry`, `Eip712CurationVerifier` | 446 |
| `sales` | `EnglishAuction`, `FixedPriceSale`, `DutchSale`, `MintSaleBase` (abstract) | 1,456 |
| `economics` | `SplitFactory`, `SplitWallet`, `RevenueEscrow`, `ClaimRouter`, `ReleaseVerifier`, `EconomicsResolver`, `AssetAllowlist` | 1,126 |
| `identity` | `ArtistRegistry`, `ConsolidationAdapter` | 619 |
| `content` | `ContentStore`, `DependencyRegistry`, `Renderer` | 1,731 |
| `records` | `StatementLog` | 274 |
| `entropy` | `VrfEntropyModule` | 226 |
| `governance` | `WorksAccessManager`, `GovernanceConfigurator` | 394 |
| `libraries` | 24 internal libraries | 597 |
| `interfaces` | 31 interfaces and shared types | 1,340 |
| **Total** | | **9,616** |

Also in scope: the deploy pipeline (`script/DeployV1.sol`, `Deploy.s.sol`, `DeployGuards.sol`,
`Verify.s.sol`, `VerifyV1.sol`), the committed genesis policy (`config/genesis.example.json`), the
content uploader (`tools/content`), and the two Sepolia rehearsal deployments as live evidence
(#43, #45, #48). ADR 0004 (#49) and the Sepolia measurements supplied the Glamsterdam inputs the
reviewers used: about 111K gas per new storage slot, about 1,542 gas per byte of contract code,
about 205K to fund a new account, and transactions above the EIP-7825 cap accepted when the excess
is state-creation gas.

Out of scope: OpenZeppelin and other vendored code under `lib/`; external contracts (the 6529
delegation contract, the Chainlink VRF coordinator, Permit2, Safe); off-chain services (6529.io,
relayers, keepers, curation tooling) except where the contracts' documentation makes promises
about them; the v1.1 federation contracts, which do not exist yet (federated paths were tested
against mocks).

### Method

1. **Ten independent attacker lenses.** Each lens was one AI agent in its own worktree, with a
   shared brief: money flows, external calls and re-entry (calls), signatures and replay (sigs),
   governance and access (gov), identity and recovery, token lifecycle, content and rendering,
   markets (auctions, sales and MEV), dependencies, entropy and deployment (deps), and code quality.
   The brief asked each to break the system within its lens, prefer cross-module paths, and reason
   explicitly about Glamsterdam, which Foundry cannot execute.
2. **PoC first.** A finding counted only with a passing Foundry test. Most PoCs ran on the real
   system, deployed through `DeployV1` with the committed genesis wiring
   (`test/integration/IntegrationBase.sol`); the VRF subscription findings used a read-only
   Sepolia fork of the real Chainlink coordinator. One finding without a PoC is marked plausible.
3. **Triage.** The integrator deduplicated the reports, decided how each finding would be fixed
   (section 4) and split the work into six fix lanes.
4. **Fixes.** Each finding's PoC became a regression test that fails on the code before its fix,
   with one commit per finding, plus happy-path, negative and event tests.
5. **Independent fix reviews.** Each fix PR was reviewed by a separate AI agent that had not
   written it, against a fixed brief: re-run the original PoC (closure), try to get around the fix
   (bypass), look for new denial-of-service levers, stuck funds and broken ADR promises
   (regressions), and remove each new guard to check that a test fails (mutation testing). Two PRs
   had a second review round after changes. Each PR also received the repository's automated bot
   reviews.

Severity followed the brief:

| Severity | Meaning |
| --- | --- |
| Critical | Direct theft or permanent loss of funds or tokens, or governance capture, without privileged keys |
| High | Theft or loss under realistic conditions; funds or tokens locked without a practical recovery; bypass of a governance delay or of the guardian veto; a broken ADR promise |
| Medium | Griefing with a cost asymmetry, temporary denial of service of a core flow, a broken invariant without direct loss, or a recovery that needs governance where it should not |
| Low | Edge cases, defence in depth, missing validation with limited impact |
| Info / improvement | Quality, clarity, gas, documentation |

### Counts

| Severity | As reported by the lenses | Unique | Fixed | Accepted or deferred |
| --- | ---: | ---: | ---: | ---: |
| Critical | 0 | 0 | 0 | 0 |
| High | 0 | 0 | 0 | 0 |
| Medium | 9 | 9 | 9 | 0 |
| Low | 32 | 30 | 28 | 2 (CALLS-3, MARKET-4) |
| Info | 2 | 1 | 0 | 1 (CALLS-5, documented) |
| Improvements | 115 listed | about 85 distinct | see [section 2](#improvements) | |

How duplicates are counted:
- **SIGS-1 = LIFECYCLE-2.** Found independently; the signatures lens rated it Medium and the
  lifecycle lens Low. It is counted once, at Medium.
- **DEPS-2 = CALLS-2** (both Low) and **MONEY-3 = CALLS-4** (Low and Info) are counted once each,
  at Low.
- **LIFECYCLE-3 and CONTENT-3** overlap (both concern locators that are not content addresses) and
  were fixed together, but each has a scenario the other lacks, so both are counted.
- The improvements overlap heavily across lenses (for example the VRF callback's storage slot
  appears in three reports). "About 85 distinct" is an estimate after removing items that repeat
  another lens's item or restate a finding.

### Headline outcomes

- **No lens found a Critical or High issue.** Nine Medium findings were confirmed by PoC and all
  nine are fixed. The most consequential were:
  - governance: a compromised hot admin and one compromised guardian could keep each other in
    office indefinitely (GOV-1), and the zero-delay operational keys had no way to be stopped
    for 30 days (GOV-2);
  - recovery: a stolen artist key kept every creator power during a 180-day recovery
    (IDENTITY-1), and a natural action by the artist's new key could void the recovery
    (IDENTITY-2);
  - disputes and sales: an upheld dispute's released content could be taken by a second copy
    (SIGS-1), a dispute pause could reset an auction to a 1-wei opening bid (LIFECYCLE-1), and an
    emergency pause let sale clocks run so a bot bought at the Dutch floor (MARKET-1);
  - entropy: a VRF work could draw several seeds and keep the one its artist preferred (DEPS-1);
  - federation (latent): the auction would have paid the network's federated fee to whatever
    recipient the token reported (MARKET-3).
- **Glamsterdam.** Several fixed gas allowances had been sized on Prague costs. After the fixes,
  the VRF callback creates no storage slot, the claim router fails loudly instead of silently
  when an item runs out of gas, and an ERC-20 payout that fails no longer blocks delivery. The
  lenses found no path where Glamsterdam pricing locks funds or tokens; what remains are costs and
  retries. One residual (CALLS-3, the EIP-8037 state-gas reservoir) cannot be fixed on chain.
- **Fix reviews.** Seven fix PRs had nine review rounds: eight ended "approve with nits" and one
  "changes required" (#56, first round: the `tokenURI` budget could still be exceeded, at 8.06M
  gas, through a collection name). The reviewers found no High or Medium issue in any fix, and 35
  further items at Low or below in the fixes themselves. Each was fixed before merge or recorded
  as an accepted trade-off (section 4). Mutation testing ran about 190 mutants; most survivors
  were turned into tests, and the rest were redundant or equivalent code (appendix).
- **Tests.** The suite grew from 2,051 tests (54 invariants) at the reviewed commit to 2,331 with
  the fixes, including the regression tests listed in the [appendix](#7-appendix-how-to-reproduce).

### Limitations

- **AI reviewers.** Every reviewer was an AI agent, and the code was written by AI agents of the
  same model family, so blind spots may be shared. Each lens ran as a single session of about 20 to
  45 minutes of wall-clock time and chose its own attack paths. An area with no finding has been
  looked at, not proven correct. This review does not replace an external audit.
- **Glamsterdam cannot be executed in Foundry.** Foundry 1.7.1 has no Amsterdam EVM. Glamsterdam
  figures are models built from Prague measurements, exact counts of new slots and accounts, the
  EIP texts (EIP-8037 was in Last Call) and Sepolia receipts. Mainnet's final parameters are not
  known.
- **No formal verification.** The review used unit, integration, fuzz and invariant tests and
  mutation testing. Symbolic (Halmos) proofs are being added separately (#58, #59) and were not
  part of this review.
- **Deployed rehearsals are unchanged.** The Sepolia r1 and r2 instances run code from before
  the reviewed commit (r1 from `60edd9b`, r2 from `400f96d`), without the fixes.

## 2. Findings

Status values: **Fixed in #N** (merged), **Accepted** (behaviour kept and documented, with a
reason), **Deferred** (a change is wanted but not made). "Residual" names what a fix deliberately
leaves.

### Money flows (MONEY)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| MONEY-1 | An admitted ERC-20 that changes behaviour after bidding blocks settlement and delivery | Low | Fixed in #57 | Each ERC-20 payout runs in its own call frame (1,000,000 gas). A payout that fails even through the escrow is credited to its wallet (`claimFor`) and delivery proceeds. Residual: credits in a token that still misbehaves wait until it behaves. |
| MONEY-2 | Escrowed credits of a payee that is not a split wallet (the network fee recipient) cannot be recovered | Low | Fixed in #54 | The holder names its replacement on the escrow (`consentToRecovery`, single use) and the governed `recover` (14 days) moves the credit only there. The fee recipient's royalty share moves with `releaseTo`. Residual: an account that can no longer act cannot consent. |
| MONEY-3 | Claim router continue mode reports success while first-time items run out of gas under Glamsterdam | Low | Fixed in #54 | Continue mode reverts the batch (`ClaimInsufficientGas`) when an item offered less than 1,500,000 gas fails after spending its share, so gas estimation raises the limit. Same issue as CALLS-4. |
| MONEY-4 | Payout-address validation misses protocol contracts and undeployed split wallets | Low | Fixed in #54 | The registry refuses contracts that declare a protocol interface through ERC-165 (escrow, router, adapters, mint targets, registries, records). Residual: an undeployed CREATE2 wallet address is indistinguishable on chain; the docs now say so. |

### External calls and re-entry (CALLS)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| CALLS-1 | The revenue escrow is accepted as fee recipient or seller, so settlement reverts permanently | Low | Fixed in #54 and #57 | The resolver refuses itself, its dependencies and ERC-165-recognised protocol contracts as fee recipient (`InvalidFeeRecipient`); the auction's start and the sales' `openSale` refuse the escrow as seller or fee recipient. Residual: system contracts without a recognisable interface are listed in the runbook. |
| CALLS-2 | The VRF callback floor is a Prague figure; under Glamsterdam the callback needs about 123K | Low | Fixed in #55 | Same issue as DEPS-2. The callback writes no new slot (about 20K Prague gas, about 34K under Glamsterdam); the 100K floor stays. |
| CALLS-3 | The EIP-8037 state-gas reservoir passes through fixed-gas calls (plausible, no PoC) | Low | Accepted; documentation deferred | No on-chain fix exists. The NatSpec of `BoundedCall`, `RevenuePayment`, `TokenTransfer`, `ClaimRouter` and `DELIVERY_GAS` still states the Prague property, and keeper gas-limit guidance is still to be written. See [section 6](#6-residual-risks-and-recommended-next-steps). |
| CALLS-4 | Claim router minimums and batch budgets are Prague figures | Info | Fixed in #54 | Duplicate of MONEY-3. |
| CALLS-5 | A token sent to the auction with a plain `transferFrom` is stranded | Info | Accepted | The NatSpec now says only safe transfers are refused. A governed rescue would need about 180 bytes the auction does not have. |

### Signatures and replay (SIGS)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| SIGS-1 | After an upheld dispute, released content can be consumed by any approved item with the same content | Medium | Fixed in #55 | See [3.5](#35-sigs-1--lifecycle-2-released-content-after-an-upheld-dispute). Same issue as LIFECYCLE-2. |
| SIGS-2 | Re-enabling a curation signer revives every approval it ever signed | Low | Fixed in #55 | Approvals bind a signer epoch (grant time, a `prevrandao` salt drawn at each disable and enable, and a change count). `setVerifier` refuses a verifier installed before. |
| SIGS-3 | Rotating an artist's authority away and back revives its unused signatures | Low | Fixed in #51 | No account may become an artist's authority again once it has been one (`AccountTaken`). Residual: a new authority that is an ERC-1271 or EIP-7702 wallet accepting the old key's signatures. |
| SIGS-4 | Revoking a root blocks the edition of a master already sold from it | Low | Fixed in #55 | `createEdition` accepts a root the registry registered, even if revoked since. |

### Governance and access (GOV)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| GOV-1 | A compromised hot admin and one compromised guardian can block each other's removal | Medium | Fixed in #52 | See [3.1](#31-gov-1-a-hot-admin-and-one-guardian-can-block-each-others-removal). |
| GOV-2 | Zero-delay operational keys cannot be stopped for 30 days | Medium | Fixed in #52 | See [3.2](#32-gov-2-no-way-to-stop-a-zero-delay-operational-key-quickly). |
| GOV-3 | Verify does not repeat the deploy's holder guards | Low | Fixed in #52 | Off anvil, `Verify.s.sol` runs `DeployGuards.checkHolders` and `checkHoldersAgainst` against the chain at readback. |
| GOV-4 | Deploy guards accept one key behind every guardian Safe, and nested owners | Low | Fixed in #52 | Off anvil, admin and guardian Safes need a threshold of at least 2, plain-key owners, pairwise-distinct signers, a canonical Safe 1.3.0 or 1.4.1 singleton, no module and no guard. |
| GOV-5 | A pre-scheduled unpause or `resume` can execute in the block of the pause | Low | Fixed in #57 | The targets refuse `unpause`, `resume` and the dispute `cancel` before `pausedAt` + 48 hours (`UnpauseTooEarly`). |

### Identity and recovery (IDENTITY)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| IDENTITY-1 | A pending recovery override restrains only the payout, not the stolen key's creator powers | Medium | Fixed in #53 | See [3.3](#33-identity-1-creator-powers-during-a-pending-recovery). Owner decision A. |
| IDENTITY-2 | A relayed acceptance by the new key registers it as a separate artist and voids the recovery | Medium | Fixed in #51 | See [3.4](#34-identity-2-the-new-key-could-be-registered-as-another-artist). |
| IDENTITY-3 | A consolidation revoked before its 30 days can still gain recovery standing | Low | Fixed in #51 | A refresh removes a pending entry that is no longer consolidated; a pending entry follows its live consolidation's clock. |
| IDENTITY-4 | A failed delegation-contract read counts as "not consolidated" | Low | Fixed in #51 | Reads fail closed (`DelegationReadFailed`); `READ_GAS` rises from 50,000 to 200,000. Registration and execution skip their standing refresh during an outage; staging, heartbeats and refreshes revert. |

### Token lifecycle (LIFECYCLE)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| LIFECYCLE-1 | A dispute pause can reset an auction to its opening bid with minutes left | Medium | Fixed in #57 | See [3.6](#36-lifecycle-1-a-dispute-pause-could-reset-an-auction). |
| LIFECYCLE-2 | Released content goes to whoever consumes it first | Low | Fixed in #55 | Duplicate of SIGS-1, counted there at Medium. |
| LIFECYCLE-3 | Unverified, possibly mutable artist locators are served for finalized works | Low | Fixed in #56 | With CONTENT-3: locators must be canonical content addresses, and after finalize only PLATFORM adds locators. |
| LIFECYCLE-4 | Dispute statements are not shown, or are shown on the wrong work | Low | Fixed in #55 and #57 | A `DISPUTE_OUTCOME` needs an existing ERC-721 token (ERC-1155 subjects are refused); a pre-mint outcome on the item is shown on the work; `cancel` must cite the token's own latest outcome, recorded after the pause, and waits 48 hours from the pause. Residual: precedence of later outcomes is documented, not enforced. |

### Content and rendering (CONTENT)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| CONTENT-1 | The 8M `tokenURI` budget did not hold with every cap filled | Low | Fixed in #56 | Inlinable previews are capped at 16 KiB (`Identity` counted four times); collection names refuse control characters, `<`, `"` and `\`; locators are short content addresses. The budget test runs on the real stack: highest found 7.80M Prague gas, 2.5% under 8M. |
| CONTENT-2 | An unregistered record file makes `tokenURI` revert once anyone opens the record | Low | Fixed in #56 | The work renders core-only metadata with `incomplete` status instead. |
| CONTENT-3 | Locator URIs are not checked to be content addresses | Low | Fixed in #56 | `ar://` with a 43-character base64url transaction ID, or `ipfs://` with a base32 CIDv1 of the fixed profile, in one canonical spelling. |
| CONTENT-4 | `syncOnChain` cannot finish for works above about 2,080 chunks | Low | Fixed in #56 | The sync is resumable: whole files up to 512 chunks per call (about 4.2M gas), with a cursor and an `OnChainSyncProgress` event. |
| CONTENT-5 | Reserved trait names are matched byte-exactly, so look-alikes pass | Low | Fixed in #56 | Trait names must be printable ASCII with no backslash or double space; the renderer's names are refused in any case and spacing. Residual: font-dependent look-alikes (`l`/`I`, `0`/`O`) are not folded. |

### Markets: auctions and sales (MARKET)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| MARKET-1 | An emergency pause stops fixed-price and Dutch purchases but not their clocks | Medium | Fixed in #57 | See [3.7](#37-market-1-sale-clocks-kept-running-during-a-pause). |
| MARKET-2 | Deprecating an auction's currency stops bidding but not the clock | Low | Fixed in #57 | A deprecated currency freezes the auction: nothing settles and the high bidder may withdraw. A re-admission reopens it for at least the governed duration; after 30 days frozen anyone may end it unsold (bid credited back, work to the artist). Re-admission waits 14 days from the deprecation. |
| MARKET-3 | For a federated token, the auction pays the network fee to the token's own fee recipient (latent) | Medium | Fixed in #57 | See [3.8](#38-market-3-federated-auction-fee-recipient-latent). |
| MARKET-4 | `startWithBid` can be front-run, and a move authorization has no "not before" | Low | Accepted (front-running); deferred ("not before") | Front-running costs the victim only gas. A `notBefore` field would change the signed `MoveToStream` struct for every signer and tool. |
| MARKET-5 | A federated contract delisted by vote keeps selling through running auctions (latent) | Low | Fixed in #57 | Bids are refused (`TargetNotAllowed`), and settlement credits the high bid back and gives the work to its artist. |
| MARKET-6 | PLATFORM can price an edition above the package price and spend an OPEN edition's window | Low | Fixed in #57 | PLATFORM alone opens only sales of listed FIXED editions at the package price with no leaf pricing; anything else needs the artist (the creator opens, or PLATFORM relays the creator's signed configuration). PLATFORM closes only sales it opened alone, or any sale while the creator is restrained. |

### Dependencies, entropy and deployment (DEPS)

| ID | Title | Severity | Status | Resolution |
| --- | --- | --- | --- | --- |
| DEPS-1 | VRF seeds are keyed by item hash, so one work can draw several seeds | Medium | Fixed in #55 | See [3.9](#39-deps-1-one-work-could-draw-several-vrf-seeds). |
| DEPS-2 | The callback-gas floor is below the callback's Glamsterdam cost, and the deploy accepts it | Low | Fixed in #55 | Duplicate of CALLS-2. |
| DEPS-3 | The mainnet VRF coordinator is not pinned, and Verify does not check dependencies are canonical | Low | Fixed in #52 | On mainnet the coordinator must be Chainlink's v2.5 coordinator with its pinned code hash; Verify requires the canonical coordinator (recorded and live), Permit2 and delegation contract. |
| DEPS-4 | The VRF subscription owner sits outside governance | Low | Fixed in #52 | On mainnet the owner must be the hot admin Safe and the module the only consumer; Verify checks both. Residual (accepted): a hot-admin compromise stops VRF starts for about 64 days or more. |
| DEPS-5 | The raise-only callback limit cannot follow a lowered coordinator maximum | Low | Fixed in #55 | `lowerCallbackGasLimit` lowers it in the 30-day class, never below the floor (a recorded deviation from ADR 0001's "raise-only"). |
| DEPS-6 | Install-time code-hash pins are not re-checked after installation | Low | Fixed in #53, #55 and #56 | Re-checked at use: the curation verifier, VRF coordinator and statement-log resolver (#55), the consolidation source (#53), and the default and pinned renderers (#56). A changed renderer fails closed until governance installs one again. |

### Code quality (QUALITY)

The quality lens reported no vulnerability. Its 27 improvement items include two that were taken
up with the fixes: QUALITY-7 (the three sale adapters' diverged money code, aligned in #57) and
QUALITY-12 (a constant init-code hash for split wallets, #54).

### Improvements

| Lens | Listed | Taken up with the fixes (where the fix touched the same code) |
| --- | ---: | --- |
| Money | 10 | Split-wallet share formula and no ETH high-water mark (#54); escrow refused as fee recipient (with CALLS-1) |
| Calls | 7 | ETH high-water mark (#54); VRF callback writes no slot (#55) |
| Sigs | 10 | Release-verifier nonces in a bitmap (#54); one PERMIT signature length (#57) |
| Gov | 11 | Admin-recovery runbook order, Verify epoch mode, pending-operation report (#52) |
| Identity | 9 | Residual-risk wording (#51); the auction's zero-creator branch made live (#53) |
| Lifecycle | 10 | CC0 text pinned (#56); look-alike trait names (with CONTENT-5) |
| Content | 12 | `mediaOf` read gets its own larger cap (#56) |
| Market | 9 | Idempotent pause and unpause (#57, with QUALITY-7) |
| Deps | 10 | Callback slot and request-ID slot (#55); deployer-independent addresses and a delegated deployer (#52); Verify reads the live coordinator and subscription (#52) |
| Quality | 27 | QUALITY-7 (#57), QUALITY-12 (#54) |
| **Total** | **115** | |

The rest are queued: NatSpec corrections, a single dependency-install check, errors declared in
interfaces and test reorganisation for a quality pass; the storage-slot reductions (QUALITY-1, 2,
4, 5 and 6, and Stream's token record from four words to three) for a gas pass, which needs an
owner decision on how FixedPriceSale counts purchases in uncapped phases.

## 3. Medium findings

Each section gives the mechanism at the level an auditor needs, the fix, the regression tests
and the independent fix review's verdict. Test paths are relative to the repository root.

### 3.1 GOV-1: a hot admin and one guardian can block each other's removal

**What it was.** `WorksAccessManager` lets any guardian cancel any scheduled operation (Rule 1)
and stops anyone cancelling their own revocation (Rule 2); otherwise the stock OpenZeppelin rules
apply, under which any ADMIN may cancel any operation. With the hot admin Safe and one guardian
Safe compromised, a fault set inside the documented tolerance (the cold admin exists for a
compromised hot admin, and liveness assumes two honest guardians), each could cancel the
revocation of the other, and the hot admin could cancel the cold admin's replacement grants.

**Impact.** Governance could not be recovered: the cold-admin recovery (ADR 0002 decision 5,
ADR 0003 owner decision 2) never executed. The rogue guardian kept its immediate powers
indefinitely (pausing the adapters, with only the compromised hot admin able to unpause;
disabling curation signers; vetoing identity changes; cancelling any operation). No funds were at
direct risk, because pauses never block settlement, claims or withdrawals. The lens rated this
Medium because it needs two independent privileged keys, and noted it could reasonably be rated
High as a broken ADR promise.

**Fix (#52).** Rule 3: a `revokeRole` operation on the manager that another account scheduled
can be cancelled only by a guardian; every other cancellation keeps the stock rules. ADR 0002
gains an addendum. Trade-off: a guardian targeted by a hostile admin now relies on another honest
guardian, not the cold admin, to cancel the revocation.

**Regression tests.** `test/integration/GovernanceRecovery.t.sol`
(`test_GOV1_ColdAdminRemovesAHotAdminAndAGuardianActingTogether`,
`test_GOV1_TheGuardianVetoIsUnchanged`, `test_GOV1_DemotionsByGrantStayCancellable`);
`test/governance/GuardianCancel.t.sol` (`test_AdminCannotCancelAnotherAccountsRevocation`,
`testFuzz_OnlyGuardiansCancelAnotherAccountsRevocation`,
`testFuzz_NobodyCancelsTheirOwnRevocation`);
`test/governance/GovernanceInvariant.t.sol` (`invariant_GovernanceStaysContained`).

**Fix review: approve with nits.** The original PoC now reverts with
`AccessManagerUnauthorizedCancel`. The reviewer found no entrenchment path: only `revokeRole`
removes a member, batched and `execute`-routed cancels keep the real sender or none, and a
compromised guardian gains nothing it did not already have. Its other items (Safe modules and
guards under GOV-4, suspension durations, Verify on the live coordinator) were applied.

### 3.2 GOV-2: no way to stop a zero-delay operational key quickly

**What it was.** PLATFORM, CURATOR and STORAGE_OPERATOR are hot keys with zero execution delay.
Revoking one is an ADMIN operation in the 30-day class, and the contracts they write to (the
statement log, locators, collections) have no pause. Their writes are permanent: statements and
locators are append-only.

**Impact.** A stolen PLATFORM key could keep writing for at least 30 days after detection: a
dispute statement on any work (shown as a trait), the platform's whole locator quota for a file,
the first locator of works that had none (which the metadata then serves), junk collections, and
closing open sales. A stolen CURATOR or STORAGE_OPERATOR key had the equivalent reach in its own
area. Only curation signers had an immediate kill switch.

**Fix (#52).** `WorksAccessManager.suspend(roleId, account)`: guardian-only, immediate and
one-way, for PLATFORM, CURATOR and STORAGE_OPERATOR (`Roles.isSuspendable`). A suspended holder
fails `hasRole`, so the `restricted` modifier and every manual `canCall` check close in the same
block, with no change to the target contracts. Only an ADMIN grant or revocation lifts it (30-day
class, guardian-vetoable). Curation signers are not suspendable: `disableSigner` is their kill
switch and also ends their signing epoch (SIGS-2). The governance README and ADR 0002 addendum
state how long a suspension lasts: 30 days for a mistaken one, about 60 with one dishonest
guardian, about 90 with a dishonest guardian and a compromised hot admin.

**Regression tests.** `test/governance/Suspension.t.sol` (12 tests, including
`test_AGuardianSuspendsAKeyInTheSameBlock`, `testFuzz_OnlyOperationalRolesCanBeSuspended`,
`test_OnlyAnAdminGrantLiftsItAndAGuardianCanVetoThat`);
`test/integration/GovernanceRecovery.t.sol` (`test_GOV2_AGuardianSuspendsThePlatformKeyAtOnce`,
`test_GOV2_EveryOperationalRoleCanBeSuspended`, `test_GOV2_ReplacingASuspendedKey`,
`test_GOV2_ADishonestGuardiansSuspensionLastsAboutSixtyDays`);
`test/governance/GovernanceInvariant.t.sol` (`invariant_SuspensionsStayContained`).

**Fix review: approve with nits.** With a suspension added at detection, the original PoC reverts
with `AccessManagedUnauthorized` on day 29. The reviewer confirmed that "suspended fails
`hasRole`" holds on every path that checks these roles (the `restricted` modifier,
`MintSaleBase._isPlatform`, `StatementLog._isAuthorized`, `WorkRecords.addLocator`) and that no
contract caches membership. The review of #55 had shown that lifting a curation signer's
suspension by a grant would revive its older approvals, which is why curation signers were made
non-suspendable.

### 3.3 IDENTITY-1: creator powers during a pending recovery

**What it was.** When governance stages a recovery override for a stolen artist key, the payout
is frozen for the 180-day notice (and any contest), but `authorityOf` kept returning the stolen
key. Every contract that treats the authority as "the artist acting" read it: sale creator paths,
move and acceptance signatures, record amendments and locators.

**Impact.** For the whole notice the stolen key could open its own zero-price sale of an edition
and mint every copy (the PoC took all 50 copies of a 0.1 ETH edition for nothing), start an
approved, unminted work and receive it on a no-bid settlement, and fill the artist's locator quota
and finalize the record so the recovered key could never correct it. The network could see the
theft but had only blunt tools (pausing every adapter, or revoking the artist's own roots).

**Fix (#53, owner decision A, recorded as ADR 0003 owner decision 6).**
`IArtistRegistry.activeAuthorityOf(artistId)` returns zero from the staging of an override that
would move the authority until it executes, is vetoed or voided, or its contest lapses. Every
consumer of creator power reads it: `primaryTerms().creator` in Stream and Editions (and through
them the sale adapters and the auction's no-bid delivery), the package registry's acceptance and
move signers, `WorkRecords` amendments and consents, and `isArtist` for ARTIST statements. A no-bid
settlement waits (`InvalidRecipient(address(0))`) and anyone retries after the outcome. Sales
already running continue with the artist's share frozen. `authorityOf` still identifies the
artist; a STANDARD change or a payout-only override restrains nothing. Trade-off accepted by the
owner: a network that abused the recovery path would also freeze the real artist, until a
guardian veto, a contest decided by the TDH vote, or the lapse.

**Regression tests.** `test/integration/RecoveryRestraint.t.sol` (14 tests on the real
deployment, including `test_RestrainedKeyCannotManageTheEditionSale`,
`test_NobodyStartsAnUnmintedWorkDuringTheNotice`, `test_RestrainedKeyCannotAmendTheRecord`,
`test_NoBidAuctionRunningAtStagingWaitsForTheOutcome`,
`test_PreSignedAcceptanceRefusedWhileRestrained`,
`test_PowersReturnWhenAVoteVoidsTheOverride`); `test/identity/ArtistRegistry.t.sol`
(`test_ActiveAuthority_RestrainedUntilTheOverrideExecutes`);
`test/identity/ArtistRegistry.invariant.t.sol`
(`invariant_ActiveAuthorityIsRestrainedOnlyByAnAuthorityMovingOverride`).

**Fix review: approve with nits.** All three original PoCs now fail with the intended errors. The
reviewer confirmed every creator-power read moved to the active authority and that the remaining
`authorityOf` reads are identification only. Two restraint guards survived the PR's own tests;
the reviewer's tests for pre-signed acceptances and royalty consents kill them and were adopted.
A changed consolidation source was made to behave like an outage on the best-effort paths, so it
cannot block a recovery's execution.

### 3.4 IDENTITY-2: the new key could be registered as another artist

**What it was.** During an override's notice the artist cannot act under its own identity (the
stolen key is still the authority). If the artist kept working with its new key and accepted a
package with it, anyone could relay that acceptance, which registered the new key as a separate
artist. At execution the override then found its next authority taken and cleared itself.

**Impact.** The recovery was voided, the payout unfroze to the stolen key (0.75 ETH in the PoC),
the 180 days were lost, and the artist's identity was split in two for good. Nothing the network
could do after the registration prevented it.

**Fix (#51).** A staged change that moves the authority reserves the new authority for the artist
(`IArtistRegistry.reservedFor`) until the change executes or ends by any route (cancel, veto,
void, lapse, clear). `register` and other artists' changes refuse a reserved account with
`AccountTaken`.

**Regression tests.** `test/integration/IdentityRecovery.t.sol`
(`test_PendingNextAuthorityIsReservedUntilTheRecoveryExecutes`,
`test_StandardChangeReservesItsNewAuthorityUntilVetoed`); `test/identity/ArtistRegistry.t.sol`
(`test_Reservation_FollowsThePendingChange`, `test_Reservation_ReleasedWhenExecutionClears`,
`test_ExecuteChange_NewAuthorityCannotBeTakenMeanwhile`);
`test/identity/ArtistRegistry.invariant.t.sol` (`invariant_OnlyThePendingNextAuthorityIsReserved`).

**Fix review: approve with nits.** The original PoC now reverts with `AccountTaken`. The reviewer
checked that every way a change ends releases the reservation, that reserving a key needs that
key's own signature (so a thief cannot reserve the victim's new key first), and that a reservation
can never be overwritten.

### 3.5 SIGS-1 = LIFECYCLE-2: released content after an upheld dispute

**What it was.** After an upheld dispute burns a copied work, `releaseContent` frees its content
hash. Release was permissionless, and the registry let any approved item with that content hash
consume the freed slot. A copier holding a second approved item with the same content could start
it first.

**Impact.** The dispute outcome was defeated: the copy was on sale again, and the rightful artist
was blocked until a second dispute cycle. A VRF work by the rightful artist could never win the
race. No funds were lost. It needed a second curation-approved copy, and a guardian revocation of
the copier's roots before the release closed it, a step the runbook did not contain.

**Fix (#55).** `Stream.releaseContent(tokenId, contentHash, beneficiary)` is governed
(PARAMETER_SETTER, 48 hours, the class of the auction's `cancel`; a new genesis selector) and
names a registered artist ID from the dispute outcome. The registry reserves the hash for that
artist (`releasedTo`; anyone else gets `ContentReserved`). The dispute runbook now has the
guardian revoke the copier's roots. Trade-off: the release names an artist, not an item, so the
rightful artist may still need to package and curate the work; guardians check the beneficiary
during the 48 hours.

**Regression tests.** `test/integration/Dispute.t.sol`
(`test_ReleasedContentIsReservedForTheNamedArtist`,
`test_ReleaseIsGovernedNamesAnArtistAndHappensOnce`,
`test_TheRightfulVrfItemReadsTheContentsSeed`, `test_AGuardianCancelsAPendingRelease`);
`test/curation/PackageRegistry.t.sol` (`test_releaseContent_reservesTheContentForTheNamedArtist`).

**Fix review: approve with nits.** The copier's release now reverts with
`AccessManagedUnauthorized`, and a sibling item reverts with `ContentReserved`. The reviewer found
that naming an unregistered artist ID would lock the hash for good; the fix now requires a
registered beneficiary (`UnknownArtist`).

### 3.6 LIFECYCLE-1: a dispute pause could reset an auction

**What it was.** During a dispute pause, the high bidder may withdraw its bid. With no bidder, the
minimum bid fell back to the opening bid (1 wei at the default of zero), and a resumed auction got
only its remaining time or the 15-minute anti-snipe window. The pause also lapsed silently after 7
days.

**Impact.** After a rejected dispute or a lapse, a work could sell for 1 wei to whoever acted
first; in the PoC a 5 ETH work went to a sniper for 1 wei. The artist and the network lost the
auction's price discovery. It needed no privileged key beyond a guardian pausing in good faith.

**Fix (#57).** A bid withdrawn during the pause stays as a reserve the next bid must reach (the
existing bid field, with no bidder; no new storage). A resumed auction, whether UNPAUSER resumes it
or the pause lapses, runs at least the governed auction duration, or the sale's locked anti-snipe
window if longer, even when a bid is standing. ADR 0003 records this as a deviation from ADR 0001
§12 ("resumes with its remaining time").

**Regression tests.** `test/adv/Lifecycle1Regression.t.sol`
(`test_LIFECYCLE1_WithdrawnBidStaysAsReserveThroughALapse`,
`test_LIFECYCLE1_RejectedDisputeResumesWithTheReserveAndTheDuration`,
`test_LIFECYCLE1_APauseWithAStandingBidAlsoReopensForTheDuration`);
`test/sales/auction/EnglishAuctionDisputes.t.sol` (`test_Resume_GivesAtLeastTheDuration`);
`test/sales/auction/EnglishAuctionFollowUp.t.sol`
(`test_L7_ReopeningIsNeverShorterThanTheLockedWindow`);
`test/sales/auction/invariant/AuctionHaltsInvariant.t.sol`.

**Fix review: approve with nits (two rounds).** Both original PoCs fail. The first round asked
that a reopening never be shorter than the sale's locked anti-snipe window, even if governance
shortens the duration; the second asked for the deviation from ADR 0001 §12 to be recorded in
ADR 0003. Both were applied. The reviewer's auction invariant handler, which covers pauses,
freezes, withdrawals and re-admissions, was adopted.

### 3.7 MARKET-1: sale clocks kept running during a pause

**What it was.** A guardian's emergency pause of the fixed-price or Dutch adapter (immediate)
stopped purchases, but the Dutch price curve and the fixed-price phase windows ran on wall-clock
time. The earliest unpause is a 48-hour UNPAUSER operation. A currency deprecation had the same
effect.

**Impact.** When the unpause executed, a bot in the same block could buy the remaining supply at
the Dutch floor (in the PoC, 1.9 ETH for copies selling at 18.29 ETH when trading stopped), and
allowlist phases could expire during the pause. Any Dutch curve shorter than about 48 hours was
always at its floor after a pause.

**Fix (#57).** A pause of the adapter or a deprecation of the sale's currency moves the sale's
schedule later by the halt time: phase windows, the anyone-may-close rule and the Dutch curve
(`scheduleDelay(saleId)`). Each listing records the halt total at open; `AssetAllowlist.statusClock`
reports deprecation time in the existing status word. Residual (documented, with a guardian
runbook rule not to overlap halts): an adapter pause during a deprecation counts twice, so the
schedule moves back by the overlap.

**Regression tests.** `test/adv/Market1Regression.t.sol` (6 tests, including
`test_MARKET1_PauseStopsTheDutchCurve`,
`test_MARKET1_PauseKeepsAnAllowlistPhaseOpenForItsRemainingLength`,
`test_MARKET1_CurrencyDeprecationStopsTheDutchCurve`); `test/adv/SalesFollowUpRegression.t.sol`
(`test_MARKET1_OverlappingHaltsCountTwice_DutchCurveRewinds`,
`test_MARKET1_ARunningDeprecationMovesViewsAndTheCloseRule`,
`test_MARKET1_AHaltBeforeTheStartMovesTheDutchStart`).

**Fix review: approve with nits.** The Dutch price resumes where it stopped and the allowlist phase
stays open. The reviewer found the overlapping-halt double count; no exact fix exists with
cumulative counters, so it is documented and pinned by tests.

### 3.8 MARKET-3: federated auction fee recipient (latent)

**What it was.** For a federated token, the auction locked the registry's fee share but paid it
to the fee recipient the token itself reported. The fixed-price and Dutch adapters already used
the economics resolver's federated network recipient.

**Impact.** Latent, because v1 installs no federation registry. Once federation was installed, a
template that let the artist influence its reported fee recipient would have redirected the
network's fee on every federated auction.

**Fix (#57).** The auction's constructor takes the economics resolver (ERC-165 checked). Federated
auctions pay, and check at start, the resolver's federated network recipient; the token's own
recipient is ignored. Residual: the recipient is read at settlement, so a later governance change
to a zero recipient would recreate a stuck path; the sales README lists this as a prerequisite for
installing federation.

**Regression tests.** `test/adv/Market3Regression.t.sol`
(`test_MARKET3_FederatedAuctionPaysTheNetworksFederatedRecipient`,
`test_MARKET3_ListedWorksKeepTheirOwnFeeRecipient`).

**Fix review: approve with nits.** The fee now reaches the resolver's federated recipient. The
reviewer's zero-recipient case led to the check at start.

### 3.9 DEPS-1: one work could draw several VRF seeds

**What it was.** VRF seeds were keyed by item hash. Any change to an approved item (a revised
package, even one spelling the same currency differently) gives a new item hash for the same
content, and each could draw its own seed.

**Impact.** An artist could see several public draws and start the item whose seed it preferred,
while the token reported a VRF seed. This broke the "one seed per work" rule (ADR 0001 §9) and
reopened a selective re-roll that ADR 0003 lists as closed. Each extra draw was paid from the
network's subscription. Revoking the earlier root did not prevent it.

**Fix (#55).** One draw per content hash. Every approved item with the same content links to that
draw (`SeedLinked`) and reads it by item hash; an item whose content already has a delivered or
pending draw joins it without a new request. Residual: a media revision changes the content hash
and draws again; the curation runbook requires revoking the old root before approving a media
revision of a VRF work whose seed was delivered.

**Regression tests.** `test/entropy/VrfEntropyModule.t.sol`
(`test_Content_TheFirstRequestLinksTheItem`,
`test_Content_ASecondItemJoinsTheDeliveredDrawWithoutARequest`,
`test_Content_ASecondItemJoinsAPendingDrawAndSharesItsClock`); `test/integration/VrfWork.t.sol`
(`test_ARevisionOfTheWorkReadsTheSameSeed`, `test_ARevisionJoinsAPendingDraw`);
`test/integration/Dispute.t.sol` (`test_TheRightfulVrfItemReadsTheContentsSeed`);
`test/entropy/VrfEntropyInvariant.t.sol` (`invariant_ItemsThatShareContentReadOneSeed`).

**Fix review: approve with nits.** The second request now returns without a new draw. The
reviewer confirmed a joined item is never stuck (it can retry a pending draw, and a late first
delivery is a no-op) and that a release and re-consumption keeps the seed.

## 4. Decisions and accepted risks

The integrator made these decisions during triage and the fix reviews; the owner made one.
Several are recorded in ADR 0003 as amendments to ADR 0001.

### Owner decision

| Decision | Trade-off accepted |
| --- | --- |
| **IDENTITY-1, option A (14 October 2026, ADR 0003 owner decision 6).** While an override that would move the authority is pending, nobody acts as the artist: `activeAuthorityOf` is zero for the old key and the reserved new key alike. | A network that abused the recovery path would also freeze the real artist, until a guardian veto, a contest decided by the TDH vote, or the lapse. `isArtist` can be withheld from a 48-hour staging. The statement log's resolver rule now reads "never made true faster than the 30-day class", with this guardian-vetoable withholding as a stated exception: it never grants or redirects the answer, and a veto restores it. |

### Integrator decisions

| Area | Decision | Trade-off or residual |
| --- | --- | --- |
| Governance | GOV-1: only guardians may cancel a revocation another account scheduled (Rule 3). | A guardian attacked by a hostile admin depends on another honest guardian within 30 days. |
| Governance | GOV-2: guardians suspend PLATFORM, CURATOR and STORAGE_OPERATOR at once; lifting stays a 30-day ADMIN action. | A faster lift would make meta-governance faster than its slowest class. A mistaken suspension lasts 30 days; one dishonest guardian can hold one about 60, or about 90 with a compromised hot admin. |
| Governance | GOV-2: curation signers are not suspendable. | `disableSigner` is their kill switch and also ends the signing epoch. |
| Governance | GOV-4: admin and guardian Safes need threshold of at least 2, plain-key owners, distinct signers, a canonical Safe singleton (1.3.0 or 1.4.1), no module and no guard. | Passkey or contract signers are refused; a signer that adds an EIP-7702 delegation makes Verify fail until cleared; new Safe versions need the allow-list updated. |
| Governance | GOV-5: the 48-hour unpause delay counts from the pause, enforced in the targets; the dispute `cancel` waits too. | An honest resume or cancel after a pause also waits 48 hours from the pause. |
| Identity | SIGS-3: no return to a past authority, instead of an authority epoch bound into every signature. | An artist can never go back to an earlier key or Safe, even through governance. A new authority that is an ERC-1271 or EIP-7702 wallet accepting the old key's signatures revives them. |
| Identity | IDENTITY-4: delegation reads fail closed for staging, heartbeats and refreshes; registration and execution skip their refresh during an outage (`StandingRefreshSkipped`). A changed consolidation-source code hash is treated the same way. | An outage stops staging, heartbeats and refreshes until the source is fixed or swapped (30-day class). |
| Identity | Guardians who veto one override cancel any other override queued for the same artist. | Operational rule; a second queued override would otherwise restrain the artist again. |
| Curation and disputes | SIGS-1: a release reserves the content hash for a named, registered artist ID (48 hours, guardian-vetoable). | The rightful artist may still need to package the work; guardians check the beneficiary. |
| Curation and disputes | SIGS-2: approvals bind a signer epoch salted from `prevrandao` at each disable and enable; a verifier can never be reinstalled. | After a suspected compromise, use a fresh key. Toggling CURATION_SIGNER's execution delay (an ADMIN power) suspends a signer without ending its epoch; only `disableSigner` or a revoke and re-grant ends it. |
| Curation and disputes | SIGS-4: a sold master's edition survives a later revocation of its root. | The guardian loses that block; there is no per-edition stop. |
| Curation and disputes | LIFECYCLE-4: dispute outcomes need an existing ERC-721 token; ERC-1155 subjects are refused; precedence of later outcomes is documented, not enforced. | Outcomes about federated ERC-1155 works cannot be recorded. |
| Sales and auctions | MARKET-1, MARKET-2, LIFECYCLE-1: pauses and deprecations stop sale clocks; a reopened auction gets at least the governed duration; a withdrawn bid stays as a reserve; after 30 days frozen an auction ends unsold; re-admission waits at least 14 days. Recorded in ADR 0003 as amendments to ADR 0001 §12. | A dispute pause with a standing bid near the end extends the auction by the full duration. A long deprecation ends live auctions unsold (runbook: re-admit between day 14 and day 30). Overlapping halts count twice (runbook: do not overlap). |
| Sales and auctions | MARKET-6: PLATFORM alone may open only fixed-size, non-leaf-priced sales of listed editions at the package terms, and close only sales it opened alone; while the creator is restrained it may close any sale. | PLATFORM cannot run premium-priced phases or OPEN-edition drops without the artist's signature. |
| Sales and auctions | MONEY-1: ERC-20 payouts run in their own 1,000,000-gas frame; a failure becomes a credit and delivery proceeds; `claimFor` is ERC-20 only. | An ERC-20 `settle` needs a call gas limit of about 1.11M although it uses about 140K. Under Glamsterdam, a token that burns the whole frame can make settlement revert, to be retried with more gas. |
| Sales and auctions | MARKET-4: front-running accepted; a "not before" field deferred. | A shared move can be started at a time the artist did not choose. |
| Sales and auctions | CALLS-5: no rescue for tokens sent to the auction with a plain transfer. | Such a token is the sender's loss. The auction has about 127 bytes of EIP-170 headroom; a per-contract optimizer profile may free more. |
| Economics | MONEY-3: continue mode fails loudly below a 1,500,000-gas ceiling instead of raising the fixed minimums. | Works under any gas schedule, but a party to an item (a co-payee, signed recipient or token) can revert a keeper's batch while its item is offered less than the ceiling. Keepers simulate privately and split batches. |
| Economics | MONEY-2: credits of non-wallet accounts move only with that account's single-use consent. | A fee Safe that can no longer act cannot consent; its credits stay. |
| Economics | MONEY-4 and CALLS-1: protocol contracts are refused as payouts and fee recipients where they declare an interface. | Undeployed split-wallet addresses and system contracts without a recognisable interface cannot be refused on chain; tooling and the runbook check them. |
| Content | CONTENT-1: restore the 8M `tokenURI` budget with write-time caps (16 KiB inlinable previews, collection-name characters), not renderer code. | Larger previews must be stored as auxiliary or non-inlinable files. The margin is about 2.5% in Prague gas; any repricing of compute, memory or cold reads needs a re-measure. |
| Content | CONTENT-3 and LIFECYCLE-3: locators are bare content addresses in canonical spelling; after finalize only PLATFORM adds locators, and it may use all 16 slots of a file. | Artists cannot add mirrors after finalize. |
| Content | CONTENT-4: `syncOnChain` checks at most 512 chunks per call. | Large works need several calls. |
| Content | CONTENT-5: trait names must be printable ASCII; reserved names matched case- and space-insensitively. | Non-Latin trait names are refused (values may be any UTF-8). |
| Content | A CC0 licence must name the deployment's pinned CC0 text, at `openRecord`, at relicense, and in the resolver's default. | A work whose item names another CC0 text cannot open; curation's mandatory `openRecord` simulation catches it. |
| Entropy | DEPS-1: one seed per content hash. | A media revision draws again; curation revokes the old root first. |
| Entropy | DEPS-2: the callback writes no new slot; the floor stays 100K, about three times the callback's Glamsterdam cost. | |
| Entropy | DEPS-5: the callback limit may be lowered in the 30-day class, a recorded deviation from "raise-only". | |
| Entropy | DEPS-4: on mainnet the hot admin Safe owns the VRF subscription. | A hot-admin compromise stops VRF starts for about 64 days or more. |
| Dependencies | DEPS-6: pinned code hashes are re-checked at use; a changed renderer makes `tokenURI` revert until governance installs one again. | A finalized work whose artist key is lost cannot be re-pinned until the identity is recovered. |
| Gas budgets | ADR 0004 decision 6: an ERC-20 start by Permit2 gets a regression ceiling (388K) and exact counts, not the 350K budget. | Admitting the first ERC-20 needs a re-measurement on the target chain. |
| Deferred | CALLS-3 documentation; MARKET-4 "not before"; the quality pass; the gas pass (needs an owner decision on purchase counting in uncapped fixed-price phases); packing a restraint flag into the authority slot (about 2.4K gas per creator read). | |

## 5. Coverage record

What each lens attacked that the code withstood, condensed from the lens reports. Unless a
test is named, the evidence is the lens's reasoning against the code at the reviewed commit. This
list describes the reviewed commit; the fixes have changed some of these paths since.

### Money flows
- Terms are locked per sale: seller wallet, fee recipient and fee share are stored at mint (the
  auction's start) and read back at settlement; a `setFeeTerms` during a live sale does not change
  its payout.
- Predicted split wallets: the CREATE2 init code commits to the payee list, so nobody can deploy
  different payees at a predicted address; pre-funding, including forced ETH, is split after
  deployment.
- Cumulative entitlements (`floor(observed × share / 100,000) − released`) cannot over-pay
  through release order, the claim router or rounding; dust stays below the payee count.
- Permit2 witnesses bind the sale (or token and mint data), recipient, amount and deadline, and
  the locked currency; a relayer cannot redirect a bid.
- Fee-on-transfer, no-return, false-return, rebasing and blocklisting tokens fail closed or go to
  the escrow; a caller cannot force the escrow route by limiting gas.
- Escrow `recover` moves a credit only to a wallet with an identical payee hash, in the 14-day
  class.
- Price = fee + seller exactly in all three adapters; `royaltyInfo` is overflow-free and exact.

### External calls and re-entry
- A winner's `onERC721Received` re-entering settle, claim, `claimDelivery` or another sale's bid
  hits the auction-wide transient guard; status and payouts are final before delivery.
- Hand-backs, 1 MB return bombs and wrong magic values leave a delivery pending and claimable;
  settle gas stays bounded (126K plain, at most 334K hostile).
- Every fixed allowance is preceded by a gas-sufficiency check, so a starved call reverts instead
  of reporting a failure or burning a nonce.
- Return data is size-checked before copying on every external call path.
- ERC-1155 receiver hooks during a purchase cannot mint past supply or re-enter.
- `multicall` is non-payable, so `execute` cannot replay `msg.value`.

### Signatures and replay
- Every EIP-712 payload hashed from a JSON type definition (what a wallet signs) equals the
  contract's digest, including Permit2 witness types.
- Each signing contract has its own domain, rebuilt on a chain-ID change; no typehash is accepted
  by two verifiers.
- Replay protection never keys on signature bytes; ERC-2098 and high-s forms cannot revive a used
  nonce.
- ERC-1271 checks are capped staticcalls needing exactly the magic value; an EIP-7702-delegated
  artist still signs with its key; a consent withdrawn before execution is refused.
- Signed CURATOR, PLATFORM and CURATION_SIGNER paths require a zero execution delay, so no
  signature bypasses an AccessManager delay.

### Governance and access
- `tools/check_genesis.py` and an ABI enumeration: every `restricted` function is mapped, and
  every unmapped external function has its own caller check or is permissionless by design.
- No selector collides across all compiled artifacts; shared selectors map to the same class on
  every target.
- Every mapping matches the ADR 0002, ADR 0003 and architecture class tables.
- Rule 2 holds through `multicall`, through `execute` and for PAUSER as well as GUARDIAN.
- The `minSetback` window gives no shortcut; guardians can never schedule.
- The configurator is one-shot and can never keep a role; no permissionless call can pre-empt a
  genesis wiring call.

### Identity and recovery
- A thief cannot block recovery beyond one notice and one vote: contest and execution windows
  never overlap, and an override replaces a pending STANDARD change.
- Gas griefing of refresh, staging and execution is bounded (bounded reads that revert when
  starved, at most 32 wallets).
- Malicious delegation registrants cannot gain standing without the artist's two-way consent.
- A contest resolution must cite an outcome on the right artist's subject, recorded after the
  contest, written only by PLATFORM.
- Attribution: the lead artist ID is fixed at acceptance; `artistIdOf` is write-once.

### Token lifecycle
- A stateful campaign on the real stack (256 runs × depth 128, 20 actions) held six invariants:
  token and sale states, content uniqueness, frozen finalized records, edition supply, auction
  solvency and no forbidden success.
- No item started twice, no tombstoned item consumed, no settled token burned, no edit after
  finalize, no second edition, no mint past supply.
- Stream and the registry decode the same calldata, so no parser differential.

### Content and rendering
- No JSON injection through the record: only validated value spans are copied and keys cannot be
  re-spelled. Of 4,000 generated documents, every one JsonScan accepted was also accepted by
  CPython's strict parser.
- `Utf8.isValid` agreed with CPython on 3,000 strings covering overlongs, surrogates and
  truncation.
- `HtmlScript.neutralize`, checked with a transcription of the WHATWG tokenizer's script states:
  all 6,000 neutralized scripts close at the renderer's own `</script>` (left raw, 691 of a
  1,500-script sample would close early, so the check is not vacuous).
- Base64 attestation agreed with the uploader tool on 13 edge texts; store integrity (CREATE2
  chunks, keccak-checked reads, manifest completeness) held.
- The uploader's keccak and file IDs matched the contracts on 3,621 inputs and the 512-chunk
  maximum.
- Every bounded read's return cap fits its encoding at the protocol limits.

### Markets
- Outbid refunds are pull credits; a rejecting or blocklisted bidder cannot block outbidding or
  settlement.
- Extension abuse is priced out (holding an auction 24 extra hours took 97 self-bids).
- Settle-before-end, same-block ordering and increment edge cases at zero and at the 96-bit cap
  hold.
- Merkle leaves are double-hashed and bind chain, adapter, token, ID, phase, account, cap and
  price; proofs cannot cross phases, adapters or chains.
- Dutch pricing is monotonic and has no clearing price to sandwich.

### Dependencies, entropy and deployment
- No `prevrandao`, `blockhash` or `block.number` in `src/` at the reviewed commit; the VRF output
  does not depend on who requests or when.
- A delivered seed is final; double or late delivery is a no-op; the subscription owner cannot
  cancel or remove the consumer while a request is pending (checked on the real coordinator).
- No seed can arrive after an auction starts: minting requires a delivered seed.
- Squatting a CREATE2 address with identical init code yields an identical contract; the
  configurator address is checked.
- Verify recomputes every address from recorded parameters and checks code hashes and the
  genesis hashes.

### Code quality
- Bounded reads and EIP-712 each have one implementation; Stream's packed writes and the
  auction's sale packing are already minimal.
- Every `restricted` setter emits an event with previous and next values where not a flag; every
  declared error is used.
- 1,448 `expectRevert` calls, of which only 12 are bare (8 justified).

## 6. Residual risks and recommended next steps

Recommended focus for the external audit, most important first.

1. **Glamsterdam and mainnet gas parameters.** Every fixed allowance must be re-checked against
   mainnet's final Glamsterdam parameters (ADR 0004, "Security impact"): `DELIVERY_GAS` (300K),
   `PAYOUT_GAS` (100K), the auction's ERC-20 payout frame (1M), the VRF callback limit and floor,
   the claim router's minimums and its 1.5M shortfall ceiling, the consolidation adapter's 200K
   read stipend, the 200K ERC-1271 cap, and `MAX_PAYEES = 64` (a 64-payee wallet was estimated at
   about 23M gas under Sepolia's pricing at the reviewed commit). Tight margins in Prague gas: the
   two-party `startWithBid` at 342,121 against the 350K budget, and `tokenURI` at 7.80M against
   8M.
2. **EIP-8037 reservoir semantics (CALLS-3, accepted, documentation deferred).** An explicit call
   gas limit bounds only regular gas; state creation in the callee can draw on the caller's
   reservoir when the transaction's gas exceeds 2^24. Settlers and batchers who send such limits
   can be charged for a hostile receiver's state growth, and delivery outcomes can depend on the
   settler's gas limit. Nothing is lost, but the NatSpec of `BoundedCall`, `RevenuePayment`,
   `TokenTransfer`, `ClaimRouter` and `DELIVERY_GAS` still states the Prague property. Recommended:
   qualify the NatSpec, advise keepers to send at most 2^24, and compare two Sepolia receipts as
   the lens proposed.
3. **Bytecode headroom.** EnglishAuction has about 127 bytes of EIP-170 headroom, and the Renderer
   about 179. Any further auction or renderer change must first free bytes (a per-contract
   optimizer profile, or splitting record validation out of the Renderer). Review the
   byte-saving changes in #57 (exact 96-bit arithmetic in place of `mulDiv`, shared lookups).
4. **Suspension and recovery timing.** Review the suspension durations (30, about 60 and about 90
   days), Rule 3's trade-off, and whether lifting a suspension should be faster. Review the
   recovery restraint (IDENTITY-1) for liveness: a no-bid settlement waits for the outcome, and a
   restraint lasts at most about 545 days from staging (the 180-day notice plus a contest that
   lapses after 365 days) unless a veto or a vote ends it sooner.
5. **Federation prerequisites (v1.1).** Before installing a federation registry: the federated
   fee recipient is read at settlement and must stay non-zero (MARKET-3 residual); delisting stops
   auctions (MARKET-5); outcomes about ERC-1155 works cannot be recorded (LIFECYCLE-4); the
   adapters' federated paths were tested only against mocks.
6. **Safe singleton allow-list.** GOV-4 pins Safe 1.3.0 and 1.4.1 singletons (L1 and L2) by
   address and code hash. A new Safe release, or a signer's wallet adding an EIP-7702 delegation,
   makes Verify fail until the allow-list or the signer changes; Verify must be run after every
   holder change.
7. **Halts and freezes.** Overlapping halts count twice (MARKET-1 residual); a 30-day currency
   freeze ends live auctions unsold; re-admission is possible only between day 14 and day 30 if
   auctions are to survive. Review the guardian runbook rules that carry these.
8. **Keeper griefing below the shortfall ceiling.** A party to a claim item can revert a
   continue-mode batch while the item is offered less than 1.5M gas (MONEY-3 trade-off).
9. **Off-chain obligations the contracts rely on.** The curation signer and its tooling
   (`openRecord` simulation, VRF media-revision rule, beneficiary checks), the guardians'
   monitoring (scheduled overrides, suspensions, VRF subscription events), the predicted-wallet
   check for payouts (MONEY-4), and Verify after every governance change.
10. **Areas this review covered least.** The uploader tooling beyond the differential tests, the
    economic design of Dutch and fixed-price drops under MEV beyond the cases above, and
    interactions between the fixes merged in parallel (each fix review checked merges with the
    other open lanes, but the merged whole has not been re-attacked as a unit).

Other recorded residuals: MONEY-2 (a fee Safe that cannot act cannot consent), SIGS-3 (contract
authorities accepting the old key), DEPS-1 (media revisions draw again), DEPS-4 (hot admin owns the
subscription), DEPS-6 (a lost artist key prevents re-pinning a finalized work's renderer),
CONTENT-5 (glyph look-alikes), CALLS-5 and MARKET-4.

## 7. Appendix: how to reproduce

**Toolchain.** Foundry 1.7.1, solc 0.8.37, EVM `prague`, Python 3.12 for the tools. From the
repository root, after `git submodule update --init`:

```bash
forge build --sizes
forge test                                        # full suite, about 10 minutes
forge test --match-path "test/adv/*" -vv          # the sales and auction regression tests
forge test --match-test test_Gas_Table -vv        # ADR 0004 gas table with exact slot counts
python tools/check_budgets.py --profile default
python tools/check_genesis.py
python tools/check_markdown_links.py
```

The lens PoCs were turned into the regression tests below, adapted to the fixed interfaces. Each
was shown to fail on the code before its fix, as recorded in the fix PRs. The original PoC files
are not part of the repository.

| Finding | Regression tests |
| --- | --- |
| GOV-1 | `test/integration/GovernanceRecovery.t.sol`, `test/governance/GuardianCancel.t.sol`, `test/governance/GovernanceInvariant.t.sol` |
| GOV-2 | `test/governance/Suspension.t.sol`, `test/integration/GovernanceRecovery.t.sol`, `test/governance/GovernanceInvariant.t.sol` |
| GOV-3, GOV-4, DEPS-3, DEPS-4 | `test/deploy/DeployScript.t.sol` (`test_GOV3_*`, `test_GOV4_*`, `test_DEPS3_*`, `test_DEPS4_*`, Safe module, guard and singleton tests) |
| GOV-5 | `test/adv/Gov5Regression.t.sol`, `test/adv/SalesFollowUpRegression.t.sol` |
| IDENTITY-1 | `test/integration/RecoveryRestraint.t.sol`, `test/identity/ArtistRegistry.t.sol`, `test/identity/ArtistRegistry.invariant.t.sol` |
| IDENTITY-2 | `test/integration/IdentityRecovery.t.sol`, `test/identity/ArtistRegistry.t.sol`, `test/identity/ArtistRegistry.invariant.t.sol` |
| IDENTITY-3 | `test/identity/ArtistRegistryReview.t.sol` (`test_Standing_*`) |
| IDENTITY-4 | `test/identity/ConsolidationAdapter.t.sol` (`test_Reads_*`), `test/identity/ArtistRegistry.t.sol` (`test_SourceReadFailure_FailsClosed`) |
| SIGS-1 = LIFECYCLE-2 | `test/integration/Dispute.t.sol`, `test/curation/PackageRegistry.t.sol` |
| SIGS-2 | `test/curation/Eip712CurationVerifier.t.sol`, `test/integration/CuratedSale.t.sol`, `test/curation/PackageRegistry.t.sol` (`test_setVerifier_refusesARetiredVerifier`) |
| SIGS-3 | `test/integration/IdentityRecovery.t.sol` (`test_RotationBackToAPreviousAuthorityIsRefused`), `test/identity/ArtistRegistry.t.sol` |
| SIGS-4 | `test/integration/MasterEdition.t.sol` (`test_RevokingTheRootDoesNotStrandASoldMastersEdition`) |
| LIFECYCLE-1 | `test/adv/Lifecycle1Regression.t.sol`, `test/sales/auction/EnglishAuctionDisputes.t.sol`, `test/sales/auction/invariant/AuctionHaltsInvariant.t.sol` |
| LIFECYCLE-3, CONTENT-3 | `test/integration/ContentReviewRegressions.t.sol` (`test_Locator_*`) |
| LIFECYCLE-4 | `test/integration/Dispute.t.sol`, `test/records/StatementLogPolicy.t.sol`, `test/adv/Lifecycle4AuctionRegression.t.sol` |
| MARKET-1 | `test/adv/Market1Regression.t.sol`, `test/adv/SalesFollowUpRegression.t.sol` |
| MARKET-2 | `test/adv/Market2Regression.t.sol`, `test/sales/auction/EnglishAuction.t.sol` (`test_DeprecatedCurrencyFreezesTheAuction`) |
| MARKET-3 | `test/adv/Market3Regression.t.sol` |
| MARKET-5 | `test/adv/Market5Regression.t.sol` |
| MARKET-6 | `test/adv/Market6Regression.t.sol`, `test/sales/fixed/FixedPriceSale.t.sol`, `test/sales/fixed/FederationRegistry.t.sol` |
| MONEY-1 | `test/adv/Money1Regression.t.sol`, `test/sales/auction/EnglishAuctionFollowUp.t.sol` |
| MONEY-2 | `test/integration/EscrowRecovery.t.sol`, `test/economics/RevenueEscrow.t.sol` |
| MONEY-3 = CALLS-4 | `test/economics/ClaimRouter.t.sol` (`test_ContinueMode*`, `test_ShortfallRevertsOnlyBelowTheCeiling`) |
| MONEY-4 | `test/integration/RecipientValidation.t.sol` |
| CALLS-1 | `test/integration/RecipientValidation.t.sol`, `test/economics/EconomicsResolver.t.sol`, `test_CALLS1_*` in the auction, fixed-price and Dutch suites |
| CALLS-2 = DEPS-2 | `test/entropy/VrfEntropyModule.t.sol` (`test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam`) |
| CALLS-5 | `test/adv/Calls5Regression.t.sol` |
| CONTENT-1 | `test/integration/TokenUriBudget.t.sol` |
| CONTENT-2 | `test/integration/ContentReviewRegressions.t.sol`, `test/content/renderer/Renderer.t.sol` |
| CONTENT-4 | `test/integration/SyncOnChainResume.t.sol` |
| CONTENT-5 | `test/content/renderer/RendererReview.t.sol` (`test_TraitNames_*`), `test/content/renderer/RendererOracles.t.sol` |
| DEPS-1 | `test/entropy/VrfEntropyModule.t.sol` (`test_Content_*`), `test/integration/VrfWork.t.sol`, `test/entropy/VrfEntropyInvariant.t.sol` |
| DEPS-5 | `test/entropy/VrfEntropyManaged.t.sol` |
| DEPS-6 | `test/curation/PackageRegistry.t.sol`, `test/entropy/VrfEntropyModule.t.sol`, `test/records/StatementLog.t.sol`, `test/identity/ArtistRegistry.t.sol`, `test/integration/RecoveryRestraint.t.sol`, `test/integration/RendererCodePin.t.sol` (the DEPS-6 cases use `vm.etch`) |
| QUALITY-7 | `test/sales/fixed/FixedPricePayments.t.sol`, `test/sales/fixed/ReviewRegressions.t.sol` |

### Fix reviews

| PR | Findings | Verdict | Mutation testing |
| --- | --- | --- | --- |
| #51 | IDENTITY-2, IDENTITY-3, IDENTITY-4, SIGS-3 | Approve with nits | 16 mutants, 14 killed; the 2 survivors were a redundant condition and an unreachable defence-in-depth check |
| #52 | GOV-1, GOV-2, GOV-3, GOV-4, DEPS-3, DEPS-4 | Approve with nits | 9 mutants, 8 killed; the survivor (a Verify code-hash check) is now covered by a tampered-record test |
| #53 | IDENTITY-1, DEPS-6 (consolidation source) | Approve with nits | 16 mutants: 13 killed by the PR's tests, 2 by the reviewer's tests (adopted), 1 equivalent |
| #54 | MONEY-2, MONEY-3 = CALLS-4, MONEY-4, CALLS-1 (resolver), improvements | Approve with nits | 13 mutants, 11 killed; tests for the 2 survivors were adopted |
| #55 | DEPS-1, DEPS-2, DEPS-5, DEPS-6, SIGS-1, SIGS-2, SIGS-4, LIFECYCLE-4 | Approve with nits | 13 guard removals, all killed |
| #56 | CONTENT-1 to CONTENT-5, LIFECYCLE-3, DEPS-6 (renderer) | Changes required, then approve with nits | 15 of 15 killed, then 10 of 10 on the changes |
| #57 | MARKET-1, 2, 3, 5, 6, LIFECYCLE-1, LIFECYCLE-4 (cancel), GOV-5, CALLS-1 (adapters), CALLS-5, MONEY-1, QUALITY-7 | Approve with nits, twice | 43 mutants, 39 killed (tests added for the 4 survivors); then 54 applicable mutants, 52 killed, 2 near-equivalent survivors |

Each fix review also ran the full `forge test`, `forge fmt --check`, `forge build --sizes` against
`main`, and the budget, genesis and markdown-link checkers.
