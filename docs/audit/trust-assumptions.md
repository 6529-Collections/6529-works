# Trust assumptions

Who and what 6529 Works trusts, written for an audit team starting an engagement. For each
governance role, operational key and external dependency, this page says what it is trusted to
do, the worst it can do if it is hostile or its key is compromised, what bounds it, and how the
system recovers. The selector, role and delay of every restricted function are in the generated
[role and permission matrix](roles.md). Mechanics are cited by the rule IDs of the
[protocol specification](../spec/README.md), each linking to its page's rules table. The
attacker's view is the [threat model](threat-model.md); accepted risks are in
[known limitations](known-limitations.md).

> Pre-audit. See the [project status](../../README.md#status).

## How to read this page

- **Delay classes.** Immediate; standard, 48 hours; funds, 14 days; successor, 30 days
  ([delay class](../glossary.md#delay-class)). A delayed role schedules its call on the
  `WorksAccessManager` and executes it after the delay, within one week ([GV-7][gv]).
- **Who can cancel a scheduled operation.**
  [`WorksAccessManager._canCancel`](../../src/governance/WorksAccessManager.sol) adds three rules
  to OpenZeppelin 5.7.0's `AccessManager`:
  - Rule 1: any guardian can cancel any scheduled operation ([GV-1][gv]).
  - Rule 2: nobody but its scheduler can cancel an operation that revokes one of the canceller's
    own roles ([GV-2][gv]).
  - Rule 3: an operation that revokes a role on the manager, scheduled by another account, can
    be cancelled only by a guardian, and Rule 2 still bars the account it names
    ([GV-25][gv], review finding GOV-1).

  Every other operation keeps the stock OpenZeppelin rules: its scheduler and any ADMIN holder
  can cancel it, so admins can still cancel each other's grants, remaps and authority moves.
- **Suspension.** Any guardian can stop a PLATFORM, CURATOR or STORAGE_OPERATOR holder at once
  with `suspend`: it fails `hasRole`, and so every check built on it ([GV-26, GV-27][gv],
  review finding GOV-2). An ADMIN grant or revocation of that role to that account lifts it
  (30 days, guardian-vetoable), and so does the holder's own `renounceRole`, which OpenZeppelin
  runs through `_revokeRole` ([GV-28][gv]). No guardian can lift or cancel one.
- **Holders.** [`config/genesis.example.json`](../../config/genesis.example.json) is the committed
  policy; a deployment may change only the addresses.
- **Worst case** assumes an attacker fully controls the key or Safe in question and every other
  party is honest. A governed worst case lands only after its delay, and any guardian can cancel
  it meanwhile.

## The model in brief

- **No upgrades.** Every contract is immutable; governance changes parameters, pins and role
  holders, never code ([LIM-GV-8][lim-gv] covers the one `delegatecall`).
- **Nothing that moves funds, recipients, verifiers or renderers is immediate.** The immediate
  powers are the guardians' tightening actions and the operational keys' bounded duties.
- **What a work locks, governance cannot reach.** Seller wallet, fee recipient, fee share and
  royalty rate are locked at the start ([AUC-6][auc]); the rate and license change only with
  every party's signature ([WS-13, WS-14][ws]).
- **Money is pulled or escrowed.** Split wallets have no owner; a failed push goes to the escrow.
- **Off-chain trust is explicit:** the curation signer, the TDH vote that PLATFORM records and the
  admin Safe executes, and Arweave and IPFS until a work is on-chain complete
  ([ADR 0001, accepted risks](../adr/0001-v1-scope.md#accepted-risks)).

## Governance roles

The hot admin Safe holds ADMIN, UNPAUSER and the three setter roles; the cold recovery admin Safe
holds ADMIN only; the guardian Safes hold GUARDIAN and PAUSER only. The code enforces at least two
guardians holding nothing else, and no account holding both PAUSER and UNPAUSER ([GV-8][gv]);
the deploy enforces the Safe counts; the admin split is policy.

### What each role can do

| Role | Delay (grant delay) | Trusted to | Worst case if its holder is hostile | Cannot |
| --- | --- | --- | --- | --- |
| ADMIN | 30 days (30 days) | Grant and revoke roles, map selectors, set target admin delays, onboard targets; v1.1's `bindFederationRegistry` | Grant any role to any account (30 days, then the role's grant delay). Remap a selector or close a target. Move a target to another authority (`updateAuthority`, or `setAuthority` on the target). Cancel another account's operations, except a role revocation | Act faster than 30 days, or shorten a delay without waiting ([GV-4, GV-5][gv]). Cancel its own revocation (Rule 2) or another account's (Rule 3). Suspend a key |
| UNPAUSER | 48 hours (48 hours) | Lift an adapter's emergency pause; resume a dispute-paused auction | Resume a disputed auction, after which an upheld `cancel` can no longer land | Act before 48 hours after the pause, even if scheduled earlier ([GV-23][gv], GOV-5) |
| PARAMETER_SETTER | 48 hours (48 hours) | Sale parameters and defaults for new works; the edition auction's configuration for new sales; upheld disputes; recovery overrides; relicensing with consent; dependency registration; the VRF configuration | Stage a recovery override against any artist, which from the staging restrains the artist or freezes the payout for the 180-day notice; a payout-only override needs no consent ([LIM-ID-8][lim-id]). Set the royalty rate and license of later works. Move auction parameters within bounds, and the opening bid up to 1,000 increment floors (`EnglishAuction.OPENING_BID_FLOORS`). Move the edition auction's margin, ladder, offset, soft-close window and backstop within their bounds, for sales opened afterwards ([EA-2, EA-15][ed]). Point the entropy module at another subscription | Relicense without every party, or leave CC0 ([WS-12, WS-13][ws]). Cancel an auction a guardian did not pause, or cite an earlier outcome ([DSP-18][dsp]). Release an unburned work's content ([AUC-10][auc]). Lower the VRF callback limit ([ENT-10][ent]) |
| FUNDS_SETTER | 14 days (14 days) | Network fee terms for new works; a minted work's royalty rate with every party's consent; currencies; escrow recovery; the marketplace `owner()`; the 6529 Network Museum | Redirect the network fee of every work started afterwards, approved works included, at a share just under 100% ([ECO-2][eco]). Admit a hostile ERC-20, since the admission probe is not proof ([ECO-32][eco]). Change the marketplace owner. Point the museum at an account it controls, which then receives every unbid canonical work settled afterwards, running auctions included ([AUC-24][auc]) | Reach a minted work's fee terms ([ECO-6][eco]) or rate ([WS-14][ws]). Move an escrow credit except to an equivalent wallet or a consented replacement ([ECO-28][eco], MONEY-2). Re-admit a currency within 14 days of its deprecation ([ECO-33][eco]). Set the museum to zero or to a protocol contract that could never hold a work |
| SUCCESSOR_SETTER | 30 days (30 days) | Verifier, default renderer, consolidation source, VRF coordinator, artist resolver and federation registry swaps; admitting sale adapters; the errata repin; re-enabling a signer; resolving contests; governance manifests | Install a verifier that approves anything, a renderer that misrepresents every unfinalized work, a sale adapter that takes custody of every work it starts, a consolidation source that grants or denies standing, or an artist resolver that vouches for anyone. Swap the VRF coordinator. Uphold or void a contest on a recorded outcome | Repin a finalized work without the artist ([RND-5][rnd]). Reinstall a retired verifier ([CUR-18][cur]). Install a dependency that is delegated, lacks its interface or differs from the reviewed code hash ([GV-22][gv]). Resolve a contest on an outcome older than it ([ID-14][id]). Change a delivered seed ([ENT-4][ent]) |
| GUARDIAN, PAUSER | immediate (30 days, 48 hours) | Veto: cancel, pause, revoke, disable, deprecate, suspend | See [Guardian Safes](#guardian-safes) | See [Guardian Safes](#guardian-safes) |

Every governed function is non-payable, and setters for funds, recipients, verifiers and renderers
are compare-and-set ([GV-18, GV-19][gv]).

### Admin Safes

| Safe | Holds | Trusted to | If compromised | Recovery |
| --- | --- | --- | --- | --- |
| Hot admin Safe | ADMIN, UNPAUSER and the three setters; on mainnet also the VRF subscription (no role) | Every governed change at its class delay, executing the network's decisions | Everything in the table above, each after its delay and cancellable by any guardian; it can also cancel another account's operations other than revocations. On mainnet it can cancel the VRF subscription at once ([LIM-ENT-5][lim-ent]) | The cold admin schedules `revokeRole` for all five roles (30 days), which the hot Safe cannot cancel (Rules 2 and 3); guardians cancel its counter-moves and suspend the keys it could reach; the cold admin then grants the roles to a new Safe. If a guardian cancels the revocations, the cold admin first removes that guardian: two 30-day rounds ([script README, admin recovery](../../script/README.md#admin-recovery); [governance flows](../spec/governance.md#flows)) |
| Cold recovery admin Safe | ADMIN only; offline; 3-of-5 recommended | Replace a compromised hot admin and nothing else ([ADR 0003, owner decision 2](../adr/0003-build-time-decisions.md#owner-decisions-11-october-2026)) | Grants, remaps and authority moves after 30 days, guardian-vetoable; it can stall governance by cancelling the hot admin's other operations | The hot admin schedules `revokeRole(ADMIN, cold)`, which the cold Safe cannot cancel (Rule 2). A sole compromised admin could be vetoed forever but never removed ([ADR 0002, decision 5](../adr/0002-access-manager-hardening.md#decision)) |

Off a local chain the deploy requires two admin Safes and three guardian Safes, each with a
threshold of at least 2, plain-key owners, a canonical Safe singleton, no module, no guard and no
signer shared with another, and `Verify.s.sol` repeats the checks at every readback
([GV-14, GV-29][gv], GOV-3, GOV-4). Between readbacks
nothing on chain stops a Safe from changing ([LIM-GV-15][lim-gv]).

### Guardian Safes

Three Safes, 2-of-3 each, with signers independent of the admin Safes and of each other
([ADR 0003, owner decision 3](../adr/0003-build-time-decisions.md#owner-decisions-11-october-2026)).
They hold GUARDIAN and PAUSER only.

| | |
| --- | --- |
| Trusted to | Watch every scheduled operation and cancel hostile ones; pause a disputed auction; veto identity changes; revoke package roots; disable a curation signer; suspend an operational key; deprecate an ERC-20 currency (never ETH); pause the sale adapters |
| Worst case, one compromised guardian Safe | Cancel every operation except its own removal, so governance stalls until it is removed. Pause each live auction once, for up to 7 days ([DSP-13, DSP-17][dsp]). Re-pause the sale adapters after each 48-hour unpause. Veto every pending identity change. Revoke any package root for good and disable every curation signer ([CUR-16, CUR-17][cur]). Deprecate any admitted ERC-20, freezing its auctions; after 30 days frozen anyone may end an auction unsold ([AUC-25][auc], MARKET-2). Never ETH: `deprecateAsset` refuses it (`EthNotDeprecable`, the rc.2 review's MONEY-M1 and G-2), so no guardian can freeze an ETH sale or an edition auction. Suspend the three operational keys for about 60 days ([LIM-GV-14][lim-gv]) |
| Cannot | Schedule anything or hold another role ([GV-6, GV-8][gv]). Cancel or resume an auction. Redirect funds or identities: a veto only deletes ([ID-10][id]). Block refunds and withdrawals ([DSP-15][dsp], [ECO-25][eco]). Cancel its own removal (Rule 2). Suspend another role, or lift or cancel a suspension ([GV-26, GV-28][gv]) |
| Recovery | An admin schedules `revokeRole(GUARDIAN, g)` and `revokeRole(PAUSER, g)` (30 days). As revocations another account scheduled, only a guardian can cancel them (Rule 3), never `g` itself (Rule 2), and no admin. Revoke first, then grant a replacement, because a guardian in office can cancel the grant. Then lift its suspensions |
| Residual | Colluding guardians shield each other ([LIM-GV-4][lim-gv]); one honest guardian online is not enough ([LIM-GV-5][lim-gv]); only guardians can defend a guardian against an admin's revocation ([LIM-GV-12][lim-gv]) |

### Operational keys

| Holder (role) | Trusted to | Worst case if compromised | Cannot | Recovery |
| --- | --- | --- | --- | --- |
| Curation signer keys (CURATION_SIGNER, at least two; never a caller) | Sign `PackageApproval` only for roots Main Stage approved under the network's routing rule, after checking the bytes ([LIM-GV-2][lim-gv]) | Approve any root, including a copy of another artist's content, until disabled; roots registered before the disable stay usable ([CUR-17][cur]) | Mint alone: a start needs every party's acceptance and the lead's move ([CUR-6, CUR-10][cur]). Revive an approval after a disable or re-grant, or approve elsewhere or while delayed ([CUR-4][cur], SIGS-2) | A guardian disables it (one-way, ending its epoch) and revokes each root it wrongly approved. It is not suspendable. Re-enabling takes 30 days; a fresh key is preferred. Minted copies go through the dispute flow |
| Curator key (CURATOR) | Append `CURATION_EVIDENCE`, directly (`appendCurator`) or by relay (`appendSigned`) | Append misleading evidence, permanently | Approve packages; write another reserved kind or an ARTIST or OWNER entry ([DSP-4, DSP-6][dsp]). While its role carries a delay, it cannot write at once or by relay ([DSP-3][dsp]), but could schedule the call and then make it itself; genesis grants CURATOR and PLATFORM with no delay | A guardian suspends it, which also closes its relayed statements; an admin revokes it and grants a new key (30 days, then 30 days). A later entry supersedes |
| Platform key (PLATFORM) | Create collections; add locators (alone after finalize); record dispute outcomes and TDH votes. It is the only `DISPUTE_OUTCOME` writer, directly (`appendPlatform`) or by relay (`appendSigned`). It has no sale selector: edition sales open permissionlessly | Record false dispute outcomes, which metadata shows and governed actions cite. Register junk locators (8 per file before finalize, 16 after) | Open, price or close a sale. Cancel an auction. Remove, change or prefer a locator ([WS-20][ws]). Write an ARTIST entry | A guardian suspends it, closing every PLATFORM path in the same block ([GV-27][gv]); an admin replaces it (30 days, then 48 hours). A new key's outcome supersedes a false one |
| Storage operator key (STORAGE_OPERATOR) | Choose the preferred copy among registered copies, serving only verified ones | Point works at a missing or wrong copy until switched back | Add or change a locator, prefer another file's locator ([WS-22][ws]), or override inline media ([RND-17][rnd]) | Suspend; revoke (30 days); a new operator restores the preferences |

### Deployment and upkeep

| Actor | Trusted to | Worst case | Cannot | Recovery |
| --- | --- | --- | --- | --- |
| Genesis deployer and `GovernanceConfigurator` | Deploy with the reviewed parameters and call `configure` once, with the committed policy and the owner's holders | Bypass the script's checks to configure other holders, policy or dependencies; `GovernanceConfigured` carries the configuration and wiring hashes, so nothing is hidden. A namespace squatter only stops the deploy before the broadcast | Keep a role or configure twice ([GV-11][gv]); make a genesis call outside the allow-list ([GV-12][gv]); deploy from a delegated account ([GV-34][gv]) | After the 5-day `minSetback`, `Verify.s.sol` checks the deployment against the chain and the policy ([GV-15, GV-31 to GV-33][gv]); a deployment that fails is not adopted. Verify does not rebuild bytecode ([LIM-REL-1][lim-rel]) |
| Keepers and relayers (no role; KEEPER is unused) | Liveness only: settlement, execution, refreshes, sync, attestation, VRF repeats, flushes and claim batches are permissionless | Withhold or delay calls; choose the order of relayed payloads ([CUR-7][cur]); see a hostile item revert a batch ([LIM-GAS-6][lim-gas]) | Alter anything signed; push an artist's share ([ECO-16][eco]); starve a call into a worse outcome ([AUC-22][auc], [ECO-26][eco], [ID-25][id]) | Anyone else makes the call |

### Accounts with no role

| Account | Trusted to | If lost, blocked or hostile | Recovery |
| --- | --- | --- | --- |
| Network fee recipient | Receive the network fee and royalty share; exist and accept ETH from a 100,000-gas call | Locked into every work at mint; a refused payment is escrowed | It consents to a replacement and FUNDS_SETTER runs `recover` (14 days); `setFeeTerms` helps only new works ([LIM-ECO-4][lim-eco]) |
| Marketplace owner (`owner()`) | Administer the collections on marketplaces | Change marketplace settings; it gates nothing on-chain | FUNDS_SETTER `setOwner` (14 days) |
| VRF subscription owner (the hot admin Safe on mainnet, DEPS-4) | Keep a dedicated subscription funded, the module its only consumer ([GV-32][gv]) | Cancel the subscription at once, outside governance: VRF works cannot start; nothing is in custody | A new subscription and `setConfig` (48 hours); after a hot-admin compromise, about 64 days or more ([LIM-ENT-5][lim-ent]) |

MINTER and KEEPER exist in `Roles.sol`, but no v1 selector maps to them and nobody holds them.
Artists, collaborators, collectors and copiers are trusted only with their own works and funds
([threat model](threat-model.md#actors)).

## External dependencies

| Dependency | Trusted to | If it fails or is hostile | Bounded by | Recovery |
| --- | --- | --- | --- | --- |
| 6529 delegation contract `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` | Report two-way, all-collections, use-case-999 consolidations with their dates; a revocation deletes every registration of a pair | It decides which wallets gain standing to cancel or contest a change ([LIM-ID-4][lim-id]) | Consolidations at least 30 days old ([ID-24][id]); fixed-gas reads that fail closed ([ID-25][id]); a public 30-day grace ([ID-21][id]); the adapter's code hash at every use ([ID-27][id]); the canonical address on mainnet ([GV-31][gv]) | In an outage, staging and refreshes revert while registration and execution skip their refresh ([ID-26][id]); swap the adapter (30 days) ([LIM-ID-9][lim-id]) |
| Chainlink VRF v2.5 coordinator and subscription | Deliver an unbiased word per request; the subscription stays funded | No delivery stalls a VRF work, which cannot start without its seed. A hostile coordinator could choose the word: the module does not verify the proof | Only the current coordinator, code-hash checked at every use ([ENT-6 to ENT-8][ent]), canonical on mainnet ([GV-31][gv], DEPS-3); one draw per content hash, first delivery final ([ENT-2, ENT-4][ent]) | Repeat after `retryDelay` ([ENT-5][ent]); change coordinators with `setCoordinator` and `setConfig` together, never Chainlink's `migrate` ([coordinator change](../spec/entropy.md#coordinator-change)) |
| Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Enforce the payer's signature, witness and nonce | A broken Permit2 could move a signer's tokens beyond its intent; only PERMIT2 payments use it | Fixed per adapter and canonical on mainnet ([GV-31][gv]); the adapter checks the deadline and both balance deltas, and the witness binds the sale ([AUC-19][auc]). Its pulls check balances only, not the token's return value. No code-hash pin. The edition auction takes ETH only and never calls it | None: the address is immutable |
| Safe wallets | Execute only what a threshold of independent owners signs | The Safe's role, as above | The deploy and every Verify ([GV-14, GV-29][gv]); between readbacks, the owners | The role recoveries above |
| Admitted ERC-20 tokens, including blocklisting tokens such as USDC | Standard transfer semantics | Exact balance deltas are enforced on every path, so fee-on-transfer and rebasing tokens fail closed ([ECO-23][eco]); return values are not, since a Permit2 pull checks only balances. A blocked wallet's payment is escrowed; with the escrow blocked too, the auction credits the payout and still delivers ([ECO-36][eco], MONEY-1). An issuer can freeze or seize what a contract holds | The real guard is governance vetting at `AssetAllowlist.admitAsset` (14 days), which admits standard ERC-20s only; its probe is not proof ([LIM-SAL-7][lim-sal]) | A guardian deprecates the token at once; escrow recovery moves blocked credits; withdrawals never read the allowlist ([ECO-25][eco]) |
| Arweave, IPFS and the off-chain storage monitor | Keep the bytes each locator names; verify and re-pin copies | Missing media in wallets; content hashes and records do not change | Canonical content-address locators ([WS-18, WS-19][ws]); preferences within a file's copies ([WS-22][ws]) | Register another copy, switch the preference, or complete the work on-chain ([WS-17][ws]) |
| 6529 waves and the TDH vote (off-chain) | Decide approvals, dispute outcomes and contested overrides | The chain sees only the signer's attestation, PLATFORM's `DISPUTE_OUTCOME` and the governed action citing it ([LIM-GV-9][lim-gv]) | Actions cite the subject's latest outcome, recorded after the pause or contest ([DSP-18][dsp], [ID-14][id]) | Guardian veto; a superseding statement |
| The CC0 1.0 legal text | Be the official legal code: 7,048 bytes, SHA-256 `0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499` (`DeployV1.CC0_LEGALCODE_SHA256`); legal effect is for counsel | A wrong text would bind every CC0 work for good | Deploy and Verify refuse any other text; every CC0 license names it and finalize requires it on-chain ([WS-5, WS-9][ws]) | None: fixed per deployment |

### EVM and network assumptions

| Assumption | What the code relies on | If it does not hold |
| --- | --- | --- |
| **Prague bytecode** (solc 0.8.37, [`foundry.toml`](../../foundry.toml)) | Transient storage and EIP-7702 account detection | The contracts cannot run before Cancun |
| **Glamsterdam pricing** on Sepolia since 6 October 2026 ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#problem)) | Fixed gas allowances sized on Prague (`DELIVERY_GAS`, `PAYOUT_GAS`, the ERC-20 payout frame, the VRF floor, the claim router's minimums) | Each degrades to a recoverable path and is re-checked before mainnet ([LIM-GAS-5][lim-gas]) |
| **EIP-7825 cap of 16,777,216 gas** | Bounded arrays (`Limits.sol`) so the worst transaction fits in Prague gas | State gas sits outside the cap on Sepolia, an observation only ([LIM-GAS-2][lim-gas]) |
| **EIP-7702 delegated EOAs exist** | Every install, bind, deploy and Verify holder check rejects a delegated account; `SignatureVerifier` accepts a delegated EOA's own signature, then ERC-1271 | A new authority accepting the old key's signatures revives them ([LIM-ID-1][lim-id]); a payee that gains code and refuses ETH is escrowed |

## Trust between protocol components

### One-shot bindings

Contract-to-contract calls use no AccessManager role: each target accepts one caller, bound once
by the genesis wiring and then locked ([GV-24][gv]).

| Binding | Install checks | What the bound contract may call | Rule |
| --- | --- | --- | --- |
| `Stream.bindWorkRecords`, `bindEditions` | Code, no EIP-7702, ERC-165, and its `stream()` is this Stream | `setRoyaltyRate`, `emitMetadataUpdate`; `linkEdition` once per settled master | [AUC-11][auc] |
| `Editions.bindWorkRecords` | Code, no EIP-7702, ERC-165 | `setRoyaltyRate`, `notifyMasterUpdated`, `notifyAllUpdated` | [ED-7][ed] |
| `PackageRegistry.bindStream`, `bindEditions` | Code, no EIP-7702, ERC-165 | `consume`, `releaseContent`; `claimContent` for the consumed item | [CUR-15][cur] |
| `ArtistRegistry.bindPackageRegistry`, `bindStream`, `bindSplitFactory`, `bindStatementLog` | Code and no EIP-7702; ERC-165 for the first two; the log's resolver is this registry | `register`; `isWallet`; `latestDisputeOutcome` | [ID-29][id] |
| `ArtistRegistry.setPackageRegistry` (a 30-day SUCCESSOR_SETTER action, compare-and-set) | As `bindPackageRegistry` | `register`, moved to Stream's successor package registry | [ID-30][id] |
| `ArtistRegistry.bindFederationRegistry` (v1.1) | As above; a 30-day ADMIN action | `listFederatedContract`, at most 64 per artist | None in v1 |

### Admitted sale adapters

- **Full trust over what it mints.** Stream mints into the adapter's own custody, and the move
  signature names no adapter, so an admitted adapter holds every work it starts. Admission
  (`setAdmittedMinter`) is therefore a 30-day action
  ([AUC-1][auc]).
- **Removal stops new mints only.** The minting adapter keeps `burn` and `settlePrimary`, so
  a running dispute can finish ([AUC-8, AUC-9][auc]).
- **An adapter's SOLD report is trusted, and so is its settling at all.** Stream moves every
  UNBID or FROZEN_OUT work to the museum itself (owner decision 17), so an adapter that settles
  escapes the museum rule only with a deliberately false SOLD report, such as one naming the
  artist as the buyer of a work nobody bought. An adapter that never settles can still transfer
  (or burn) the unsold work it holds: Stream does not refuse transfers of unsettled works, and
  such a work stays NONE in `primarySale`. The 30-day admission review covers both
  ([ADR 0005](../adr/0005-stream-editions-auction.md)).
- **On 6529 Stream Editions,** an admitted adapter of an edition's sale kind may mint copies up
  to the creator's cap. Each edition is bound to one adapter, the one whose sale opened it
  (`bindMinter`) or else the first to mint it, which alone mints it, even after governance
  removes it, so that winners already charged can claim ([ED-5, ED-6][ed]; LIM-EA-10 in
  [ADR 0005](../adr/0005-stream-editions-auction.md#known-limitations)).
- **The auction holds nothing it did not mint**
  ([AUC-29][auc]), except a token sent with a
  plain `transferFrom` ([LIM-SAL-10][lim-sal]).
- **An Editions adapter mints what its kind sells.** Editions mints for any admitted adapter whose
  `saleKind()` equals an edition's terms, within the creator's cap; once an adapter is bound to an
  edition (when its sale opens, or else at its first mint), only it may mint that edition (owner
  decision 14, [ED-5][ed]). The edition
  auction mints only what its settled clearing sold ([EA-9][ed]); admitting another adapter of the
  same kind is a 30-day action, and it could never add copies to a sale the first one ran.

### Pinned code hashes

Besides the install checks ([GV-22][gv]), these
dependencies are pinned to a reviewed code hash, and all but the last row are checked again at use
(DEPS-6). Stream's other dependencies and admitted sale adapters are checked at install only.

| Dependency | Held by | Pinned at | Checked again at | On mismatch | Rule or test |
| --- | --- | --- | --- | --- | --- |
| Curation verifier | `PackageRegistry` | Constructor, `setVerifier` | Every `registerPackage` | Nothing registers | [CUR-3][cur] |
| Consolidation source | `ArtistRegistry` | Constructor, `setConsolidationSource` | Every read | Staging and refreshes revert; registration and execution skip their refresh | [ID-26][id] |
| VRF coordinator | `VrfEntropyModule` | Constructor, `setCoordinator` | Every request and delivery | `DependencyCodeChanged` | [ENT-7][ent] |
| Artist resolver | `StatementLog` | Constructor, `setArtistResolver` | Every ARTIST authorization | `DependencyCodeChanged` | [DSP-7][dsp] |
| Payout resolver and release verifier | `SplitFactory`, each `SplitWallet` | Factory constructor | Resolver at every artist-payee release; both at `createWallet` | Artist payees stop; no wallet deploys | [ECO-12, ECO-18][eco] |
| Federation registry (v1.1) | Each sale adapter | `setFederationRegistry` | Every `isTarget` | The registry is ignored | `test_Federation_CodeHashesArePinned` in [`EnglishAuctionFederation.t.sol`](../../test/sales/auction/EnglishAuctionFederation.t.sol) |
| Default renderer; a finalized work's renderer | `Stream`; `WorkRecords` | `setDefaultRenderer`; `finalize`, `repinRenderer` | Every `tokenURI` and `uri` | Revert, with no fallback | [RND-2, RND-3][rnd] |
| Stream; the artist registry; the package registry | `Editions`; `PackageRegistry`; `VrfEntropyModule` | Constructor | Not checked again | Construction reverts | [ENT-16][ent] (the module's) |

### Resolvers and renderer pins

- **ARTIST statements** are exactly as strong as the statement log's artist resolver and the
  30-day `setArtistResolver`; every entry records its resolver
  ([DSP-7, DSP-8][dsp]). A resolver must
  never make `isArtist` true faster than the 30-day class; the artist registry withholds it only
  while an authority-moving override is pending
  ([ADR 0003, owner decision 6](../adr/0003-build-time-decisions.md#owner-decisions-11-october-2026)).
- **Payouts.** Split wallets pin the artist registry immutably and refuse to release while it
  answers zero for a pending payout move
  ([ECO-18][eco],
  [ID-16][id]).
- **Renderers.** A default-renderer swap reaches every unfinalized work at once; a finalized work's
  pin moves only with the lead artist's signature, and a changed pinned renderer leaves the work
  without metadata until a repin ([RND-1, RND-5][rnd],
  [LIM-CNT-10][lim-cnt]).

## Differences from the ADRs

See the [register](../spec/README.md#differences-from-the-adrs).

## References

- Code: [`WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol),
  [`Roles.sol`](../../src/governance/Roles.sol), [`DeployGuards.sol`](../../script/DeployGuards.sol),
  [`config/genesis.example.json`](../../config/genesis.example.json).
- ADRs: [0001](../adr/0001-v1-scope.md), [0002](../adr/0002-access-manager-hardening.md),
  [0003](../adr/0003-build-time-decisions.md), [0004](../adr/0004-gas-budgets-under-glamsterdam.md).
- Review: [internal adversarial review, October 2026](../security/internal-review-2026-10.md).
- Operations: [script README](../../script/README.md),
  [architecture: trust boundaries](../architecture.md#trust-boundaries).

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
[lim-eco]: known-limitations.md#economics-and-payouts
[lim-cnt]: known-limitations.md#content-records-and-rendering
[lim-ent]: known-limitations.md#entropy
[lim-rel]: known-limitations.md#release-evidence
