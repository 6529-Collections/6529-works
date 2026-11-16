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

- **Delay classes.** At once (NETWORK and the operational keys); 24 hours (PARAMETER_SETTER);
  3 days (FUNDS_SETTER); 7 days (SUCCESSOR_SETTER and ADMIN)
  ([delay class](../glossary.md#delay-class), [GV-2][gv]). A delayed action is scheduled on the
  `WorksAccessManager` and executed after its delay; it expires 14 days after it becomes ready
  ([GV-7][gv]). Actions with no delay are called directly and never scheduled.
- **One authority, one brake.** One address, `network()`, holds every network role: ADMIN,
  NETWORK, PARAMETER_SETTER, FUNDS_SETTER and SUCCESSOR_SETTER. Nobody can be granted one
  ([GV-1][gv]). An optional brake address can delay a scheduled operation once, by 7 days after
  its ready time ([GV-5, GV-6][gv]); no brake is installed at launch. Only the scheduler or the
  network can cancel an operation ([GV-8][gv]).
- **Holders.** [`config/genesis.example.json`](../../config/genesis.example.json) is the committed
  policy: it names the network and the operational keys; a deployment may change only the
  addresses.
- **Worst case** assumes an attacker fully controls the key or Safe in question and every other
  party is honest. A governed action lands only after its delay, in public.

## The model in brief

- **No upgrades.** Every contract is immutable; the network changes parameters, pins and role
  holders, never code ([LIM-GV-8][lim-gv] covers the one `delegatecall`).
- **Fixed durations are compiled.** The identity timers, the freeze, the rescue wait, the
  finalize notice, the edition close and abandon waits, the dispute pause, the refusal exit and
  the unclaimed period are constants in the code; no role can change them.
- **What a work locks at the start.** Seller wallet, fee share and royalty rate are locked at the
  start ([AUC-6][auc]). The rate and license change only with every party's signature and the
  network ([WS-13, WS-14][ws]); the network may lower a work's fee share, never raise it
  (`lowerFeeShare`, 24 hours); sales pay the network fee to the recipient the economics resolver
  names at settlement.
- **Money is pulled or escrowed.** Split wallets have no owner; a failed push goes to the escrow.
  Every release from a royalty wallet also pays the network fee vault its share ([ECO-43][eco]);
  shares and credits unclaimed for 180 days go to the network ([ECO-44, ECO-45][eco],
  [AUC-49][auc]).
- **The dividing line** ([ADR 0007](../adr/0007-permanence.md)). Anything with authority over
  existing tokens, existing works' facts or funds already owed is permanent, minimal, and takes no
  instruction from replaceable code. Permanent: 6529 Stream, 6529 Stream Editions, `WorkRecords`,
  `StatementLog`, `ContentStore`, `ArtistRegistry` (Stream holds it as an immutable with no setter,
  [AUC-39][auc]), the `SplitLedger` and its 66-byte `SplitVault` wallets (the ledger is also the
  release verifier), and the `RevenueEscrow` as custodian of its credits. Replaceable by the
  network: the mint policy (`PackageRegistry`, [AUC-38][auc]; content uniqueness stays in
  Stream, [AUC-44][auc]), `WorkRecords`' delivery contract (`setDelivery`) and its append-only store
  set (`addStore`, [WS-39, WS-41][ws]), the economics resolver, the entropy module, the default
  renderer, sale adapters, `AssetAllowlist` (which also holds each currency's opening bid), the
  consolidation adapter, the two governed vaults' destinations (`FeeRecipientVault`,
  `MuseumVault`, [ECO-41][eco]), the artist registry's package-registry caller, federation-registry
  pointer and consolidation source ([ID-15][id]), and the address that holds the network roles,
  which hands over in two steps ([GV-4][gv]).
- **The gas rule.** A permanent contract's call into another contract forwards all the gas EIP-150
  allows; a call that fails leaving at most 1/8 of the gas held before it reverts the transaction
  with `BoundedCallShortfall`, and is never read as a refusal or a default answer ([ID-9][id],
  [DSP-26][dsp], [AUC-42][auc], [ECO-42][eco]; [LIM-GAS-13][lim-gas]). The renderer, pinned per
  finalized work, follows the same rule. Fixed gas allowances remain only in replaceable
  contracts (the English auction, the edition auction's governed payout gas, the claim router).
- **Off-chain trust is explicit:** the curation signer, the TDH vote that PLATFORM records and the
  network Safe executes, and Arweave and IPFS until a work is on-chain complete
  ([ADR 0001, accepted risks](../adr/0001-v1-scope.md#accepted-risks)).

## Governance roles

One address holds every network role ([GV-1][gv]). Until the TDH bridge exists it is one 6529
Safe; the bridge then takes over with `transferNetwork` (7 days) and its own `acceptNetwork`
([GV-4][gv], [LIM-GV-18][lim-gv]). The operational keys are ordinary hot keys that the network
grants and revokes at once ([GV-3][gv]).

### What each role can do

| Role (delay) | Trusted to | What it can do | Cannot |
| --- | --- | --- | --- |
| ADMIN (7 days) | Map selectors, change role admins, onboard targets, hand the network over (`transferNetwork`), set the brake (`setBrake`) | Remap a selector or close a target; move a target to another authority; propose a new network, which takes over only by accepting itself | Grant a network role to anyone ([GV-1][gv]); remap the manager's own selectors or close the manager ([GV-9][gv]); act faster than 7 days, except by a remap that itself waits 7 days |
| NETWORK (at once) | Tightening and emergency actions: revoke a package root, disable a curation signer, deprecate an ERC-20 currency, deprecate a dependency, freeze and unfreeze an account, cancel an account's own change or a replacement, resume or cancel a dispute-paused auction, lift an adapter's emergency pause; grant and revoke operational keys | Each of these at once | Deprecate ETH ([ECO-38][eco]); move funds; touch a minted token's ownership; cancel an auction that was not dispute-paused, or cite an outcome recorded before the pause ([DSP-18][dsp]) |
| PARAMETER_SETTER (24 hours) | Sale parameters and defaults for new works; the edition auction's configuration and payout gas; upheld disputes (`releaseContent`); rescues to the museum; lowering a work's or an edition's fee share; identity replacements and contest resolutions; account delisting and lowering a federated share; template approval, suspension, revocation and reinstatement; killing a signer's approvals; retiring a store; joining the artist's renunciation of the royalty or licence power; dependency registration; the VRF configuration | Stage a replacement of an account's root (14 days' notice, contestable, [ID-6, ID-7][id]). Set the royalty rate and license of later works. Move auction parameters within bounds, and a currency's opening bid up to `type(uint96).max` (`AssetAllowlist.setOpeningBid`). Move the edition auction's margin, ladder, soft-close window, backstop and payout gas within their bounds ([EA-15, EA-18][ed]). Lower fee shares | Raise a fee share (R9); release an unburned work's content ([AUC-10][auc]); renounce a power without the artist's signature ([WS-37][ws]); lower the VRF callback limit ([ENT-11][ent]) |
| FUNDS_SETTER (3 days) | Network fee terms for new works; a minted work's royalty rate and license with every party's consent; currencies; escrow recovery and `sweepExcess` (only the unowed balance, [ECO-40][eco]); the marketplace `owner()`; the 6529 Network Museum (`setMuseum`); the fee vault's destination (`setDestination`) | Redirect the network fee of every work started afterwards ([ECO-2][eco]) and every fee the fee vault holds or will receive. Admit an ERC-20, since the admission probe is not proof ([ECO-32][eco]). Point the museum elsewhere, for every unbid canonical work settled afterwards ([AUC-24][auc]) | Change a minted work's rate or license without every party ([WS-13, WS-14][ws]); move another account's escrow credit except to an equivalent wallet or a consented replacement ([ECO-28][eco]); re-admit a currency within 3 days of its deprecation ([ECO-33][eco]); set the museum to zero or to a protocol contract |
| SUCCESSOR_SETTER (7 days) | Verifier, default renderer, consolidation source, VRF coordinator and wrapper, artist resolver and federation registry swaps; Stream's mint policy, economics resolver, view extension and entropy module (never its artist registry, [AUC-39][auc]); `WorkRecords`' delivery contract and added stores ([WS-39, WS-41][ws]); admitting sale adapters; repinning a finalized work's renderer ([WS-38][ws]); re-enabling a signer; governance manifests; the museum vault's destination | Install any reviewed replacement of the parts above. Repin a finalized work's renderer alone (C8), unless the artist renounced the repin. Redirect every work and payout the museum vault holds | Change a delivered seed ([ENT-4][ent]); reinstall a retired verifier ([CUR-18][cur]); install a dependency that is delegated, lacks its interface or differs from its code hash ([GV-20][gv]); repin a work whose repin was renounced |

Every governed function is non-payable, and setters for funds, recipients, verifiers and renderers
are compare-and-set ([GV-16, GV-17][gv]).

### The network Safe and the brake

| Holder | Holds | Trusted to | If compromised | Recovery |
| --- | --- | --- | --- | --- |
| The network (one 6529 Safe until the TDH bridge) | Every network role; on mainnet also the VRF subscription (no role) | Execute the network's decisions at each class delay | Everything in the table above, each after its class delay; the NETWORK actions at once. On mainnet it can cancel the VRF subscription at once ([LIM-ENT-5][lim-ent]) | The Safe's own owners replace keys; a handover to a new network takes 7 days and the new network's acceptance ([GV-4][gv]) |
| The brake (none at launch) | No role; `brakeOnce` only | Delay a scheduled operation once by 7 days | Delay each scheduled operation once, and its own removal once | The network replaces or removes it (`setBrake`, 7 days) |

The deploy requires the network to be a canonical Safe with a threshold of at least 2, plain-key
owners, no module and no guard; no operational holder may name a network role; there must be at
least two curation signers; on mainnet the deployer holds nothing and the VRF subscription owner
is the network (`DeployGuards`). Between readbacks nothing on chain stops a Safe from changing
([LIM-GV-15][lim-gv]).

### Operational keys

| Holder (role) | Trusted to | Worst case if compromised | Cannot | Recovery |
| --- | --- | --- | --- | --- |
| Pauser keys (PAUSER) | Pause new starts on the sale adapters; pause a disputed 1/1 auction (once per auction, at most 3 days, [AUC-26][auc]) | Pause each live auction once for up to 3 days; keep the adapters' starts paused until the network unpauses | Cancel or resume an auction; move funds; block claims and refunds ([DSP-15][dsp], [ECO-25][eco]) | The network unpauses or resumes at once and revokes the key at once |
| Curation signer keys (CURATION_SIGNER, at least two; never a caller) | Sign `PackageApproval` only for roots Main Stage approved under the network's routing rule, after checking the bytes ([LIM-GV-2][lim-gv]) | Approve any root, including a copy of another artist's content, until disabled | Mint alone: a start needs every party's acceptance and the lead's move ([CUR-6, CUR-10][cur]). Revive an approval after a disable or re-grant ([CUR-4][cur], SIGS-2) | The network disables it at once and kills its approvals (`killSignerApprovals`, 24 hours, [CUR-23][cur]): its unminted items no longer mint. Re-enabling takes 7 days; a fresh key is preferred. Minted copies go through the dispute flow |
| Curator key (CURATOR) | Append `CURATION_EVIDENCE`, directly (`appendCurator`) or by relay (`appendSigned`) | Append misleading evidence, permanently | Approve packages; write another reserved kind or an ARTIST or OWNER entry ([DSP-4, DSP-6][dsp]) | The network revokes it at once and grants a new key. A later entry supersedes |
| Platform key (PLATFORM) | Create collections; add locators; record dispute outcomes and TDH votes. It is the only `DISPUTE_OUTCOME` writer, directly (`appendPlatform`) or by relay (`appendSigned`) | Record false dispute outcomes, which metadata shows and governed actions cite. Register junk locators, which the network can mark dead | Open, price or close a sale. Cancel an auction. Remove or change a locator ([WS-20][ws]). Write an ARTIST entry | The network revokes it at once and grants a new key. A new key's outcome supersedes a false one |
| Storage operator key (STORAGE_OPERATOR) | Choose the preferred copy among registered copies, serving only verified ones; mark dead locators; walk an added store for `syncOnChain` | Point works at a missing or wrong copy until switched back | Add or change a locator, prefer another file's locator ([WS-22][ws]), or override inline media ([RND-17][rnd]) | Revoke at once; a new operator restores the preferences |

### Deployment and upkeep

| Actor | Trusted to | Worst case | Cannot | Recovery |
| --- | --- | --- | --- | --- |
| Genesis deployer and `GovernanceConfigurator` | Deploy with the reviewed parameters and call `configure` once, with the committed policy and holders; propose the network, which then accepts | Bypass the script's checks to configure other holders, policy or dependencies; `GovernanceConfigured` carries the configuration and wiring hashes, so nothing is hidden | Keep a role or configure twice ([GV-11][gv]); make a genesis call outside the allow-list ([GV-12][gv]) | `Verify.s.sol` checks the deployment against the chain and the policy, including that the network accepted; a deployment that fails is not adopted. Verify does not rebuild bytecode ([LIM-REL-1][lim-rel]) |
| Keepers and relayers (no role; KEEPER is unused) | Liveness only: settlement, execution, sync, attestation, VRF repeats, flushes, claim batches, marks and expiries are permissionless. The network's keeper starts 1/1s through `SaleStarter` | Withhold or delay calls; choose the order of relayed payloads ([CUR-7][cur]); see a hostile item revert a batch ([LIM-GAS-6][lim-gas]) | Alter anything signed; push an artist's share ([ECO-16][eco]); starve a call into a worse outcome ([AUC-22][auc], [ECO-26][eco], [ID-9][id]) | Anyone else makes the call |

### Worst case by role

What each role, compromised, can do to existing tokens, existing works' facts and funds already
owed.

| Role (delay) | Worst it can do |
| --- | --- |
| PAUSER (at once) | One dispute pause per auction (3 days at most); keep new starts paused until the network unpauses. It moves no funds and touches no minted token |
| PLATFORM, STORAGE_OPERATOR, CURATOR (at once) | Statements, the platform's `DISPUTE_OUTCOME` (one ingredient of an auction cancel), locators and preferences of existing works |
| NETWORK (at once) | With a pauser's dispute pause and a PLATFORM outcome, `EnglishAuction.cancel` burns a live, unsettled 1/1. Freeze an account for 14 days (its payout reads zero meanwhile). Deprecate an ERC-20, freezing its auctions (after 14 days anyone ends them unsold) |
| PARAMETER_SETTER (24 hours) | Stage a replacement of any account's root (14 days' notice; contestable). Rescue a stranded work to the museum (14 days after its adapter's removal). Lower fee shares. Otherwise new-sale parameters only |
| FUNDS_SETTER (3 days) | Redirect the fee vault: every held and future network fee. `setMuseum`: where works that settle unbid, or are rescued, go from then on. `sweepExcess` (unowed balance only); `recover` (equivalent wallet or consent, or the network's own credits) |
| SUCCESSOR_SETTER (7 days) | Redirect the museum vault: every museum-held work and payout. `setDependency`: economics (the museum for unsettled works), extension, policy and entropy (new mints only); `setDelivery` (served URLs of every work not on chain, [LIM-GV-23][lim-gv]); `addStore`; repin finalized works' renderers; remove an adapter |
| ADMIN (7 days) | Remap any selector to another class, or move a target to another authority. Hand the network to another address, which must accept. Any authority acts within the permanent contracts: no authority can move a collector's token, change a minted work's facts, mint a content again or reduce what the escrow owes |

### Accounts with no role

| Account | Trusted to | If lost, blocked or hostile | Recovery |
| --- | --- | --- | --- |
| Network fee recipient (the `FeeRecipientVault`, a governed vault whose destination FUNDS_SETTER sets, 3 days; the museum's vault is SUCCESSOR_SETTER's, 7 days) | Receive the network fee and royalty share and forward them only to its destination ([ECO-41][eco]); accept ETH from a 100,000-gas call | A refused payment is escrowed | The network moves its own escrow credits without consent (`recover`, 3 days, [ECO-28][eco]) |
| Marketplace owner (`owner()`) | Administer the collections on marketplaces | Change marketplace settings; it gates nothing on-chain | FUNDS_SETTER `setOwner` (3 days) |
| VRF subscription owner (the network Safe on mainnet, DEPS-4) | Keep a dedicated subscription funded, the module its only consumer | Cancel the subscription at once: curated VRF works cannot start; nothing is in custody | A new subscription and `setConfig` (24 hours) ([LIM-ENT-5][lim-ent]) |

MINTER and KEEPER exist in `Roles.sol`, but no v1 selector maps to them and nobody holds them.
Artists, collaborators, collectors and copiers are trusted only with their own works and funds
([threat model](threat-model.md#actors)).

## External dependencies

| Dependency | Trusted to | If it fails or is hostile | Bounded by | Recovery |
| --- | --- | --- | --- | --- |
| 6529 delegation contract `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, through the consolidation adapter | Report live two-way, all-collections consolidations | Which wallets act for each account besides its root ([ID-2][id], [LIM-ID-20][lim-id]) | The root never reads it; a failing, malformed or changed answer is "no" ([ID-4][id]); forward-all reads, a shortfall reverts ([ID-9][id]); the adapter's code hash at every use; the canonical address on mainnet | Only the root acts until it is fixed; swap the adapter (7 days) ([LIM-ID-9][lim-id]) |
| Chainlink VRF v2.5 coordinator and subscription | Deliver an unbiased word per request; the subscription stays funded | No delivery stalls a VRF work, which cannot start without its seed. A hostile coordinator could choose the word: the module does not verify the proof | Only the current coordinator, code-hash checked at every use ([ENT-6 to ENT-8][ent]), canonical on mainnet (DEPS-3); one draw per content hash, first delivery final ([ENT-2, ENT-4][ent]) | Repeat after the backoff wait, at most 30 days ([ENT-5][ent]); change coordinators with `setCoordinator` and `setConfig` together, never Chainlink's `migrate` ([coordinator change](../spec/entropy.md#coordinator-change)) |
| Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Enforce the payer's signature, witness and nonce | A broken Permit2 could move a signer's tokens beyond its intent; only PERMIT2 payments use it | Fixed per adapter and canonical on mainnet; the adapter checks the deadline and both balance deltas, and the witness binds the sale ([AUC-19][auc]). Its pulls check balances only, not the token's return value. No code-hash pin. The edition auction takes ETH only and never calls it | None: the address is immutable |
| Safe wallets | Execute only what a threshold of independent owners signs | The Safe's role, as above | The deploy and every Verify; between readbacks, the owners | The Safe's owners |
| Admitted ERC-20 tokens, including blocklisting tokens such as USDC | Standard transfer semantics | Exact balance deltas are enforced on every path, so fee-on-transfer and rebasing tokens fail closed ([ECO-23][eco]); return values are not, since a Permit2 pull checks only balances, and split-wallet releases also accept a `transfer` that returns nothing. A blocked wallet's payment is escrowed; with the escrow blocked too, the auction credits the payout and still delivers ([ECO-36][eco], MONEY-1). An issuer can freeze or seize what a contract holds | The real guard is governance vetting at `AssetAllowlist.admitAsset` (3 days), which admits standard ERC-20s only; its probe is not proof ([LIM-SAL-7][lim-sal]) | The network deprecates the token at once; escrow recovery moves blocked credits; withdrawals never read the allowlist ([ECO-25][eco]) |
| Arweave, IPFS and the off-chain storage monitor | Keep the bytes each locator names; verify and re-pin copies | Missing media in wallets; content hashes and records do not change | Canonical content-address locators ([WS-18, WS-19][ws]); preferences within a file's copies ([WS-22][ws]) | Register another copy, switch the preference, or complete the work on-chain ([WS-17][ws]) |
| 6529 waves and the TDH vote (off-chain) | Decide approvals, dispute outcomes and contested replacements | The chain sees only the signer's attestation, PLATFORM's `DISPUTE_OUTCOME` and the governed action citing it ([LIM-GV-9][lim-gv]) | Actions cite the subject's latest outcome, recorded after the pause or contest ([DSP-18][dsp], [ID-7][id]) | A superseding statement |
| The CC0 1.0 legal text | Be the official legal code: 7,048 bytes, SHA-256 `0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499` (`DeployV1.CC0_LEGALCODE_SHA256`); legal effect is for counsel | A wrong text would bind every CC0 work for good | Deploy and Verify refuse any other text; every CC0 license names it and finalize requires it on-chain ([WS-5, WS-9][ws]) | None: fixed per deployment |

### EVM and network assumptions

| Assumption | What the code relies on | If it does not hold |
| --- | --- | --- |
| **Prague bytecode** (solc 0.8.37, [`foundry.toml`](../../foundry.toml)) | Transient storage and EIP-7702 account detection | The contracts cannot run before Cancun |
| **Glamsterdam pricing** on Sepolia since 6 October 2026 ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#problem)) | Fixed gas allowances sized on Prague (`DELIVERY_GAS`, `PAYOUT_GAS`, the ERC-20 payout frame, the VRF floor, the claim router's minimums) | Each degrades to a recoverable path and is re-checked before mainnet ([LIM-GAS-5][lim-gas]) |
| **EIP-7825 cap of 16,777,216 gas** | Bounded arrays (`Limits.sol`) so the worst transaction fits in Prague gas | State gas sits outside the cap on Sepolia, an observation only ([LIM-GAS-2][lim-gas]) |
| **EIP-7702 delegated EOAs exist** | Every install, bind, deploy and Verify holder check rejects a delegated account; `SignatureVerifier` accepts a delegated EOA's own signature, then ERC-1271 | A wallet that gains code verifies by ERC-1271 from then on ([ID-16][id]); a payee that gains code and refuses ETH is escrowed |

## Trust between protocol components

### One-shot bindings

Contract-to-contract calls use no AccessManager role: each target accepts one caller, bound once
by the genesis wiring and then locked ([GV-22][gv]).

| Binding | Install checks | What the bound contract may call | Rule |
| --- | --- | --- | --- |
| `Stream.bindWorkRecords`, `bindEditions` | Code, no EIP-7702, ERC-165, and its `stream()` is this Stream | `setRoyaltyRate`, `emitMetadataUpdate`; `linkEdition` once per settled master | [AUC-11][auc] |
| `Editions.bindWorkRecords` | Code, no EIP-7702, ERC-165 | `setRoyaltyRate`, `notifyMasterUpdated`, `notifyAllUpdated` | [ED-7][ed] |
| `PackageRegistry.bindStream`, `bindEditions` | Code, no EIP-7702, ERC-165 | `authorize` (Stream's mint-policy call, [AUC-38][auc]); the Editions binding is informational (Editions reads Stream's content record, [ED-3][ed]) | [CUR-15][cur] |
| `WorkRecords.setDelivery` (SUCCESSOR_SETTER, 7 days, compare-and-set; the first is deployed by `WorkRecords`' constructor) | ERC-165 `IWorkDelivery`, no EIP-7702, `records()` is this `WorkRecords`, `predecessor()` the current one | `refreshMetadata`, `refreshAllMetadata` only | [WS-39][ws] |
| `ArtistRegistry.bindPackageRegistry`, `bindStream`, `bindSplitFactory`, `bindStatementLog` | Code and no EIP-7702; ERC-165 for the first two; the log's resolver is this registry | `register`; `isWallet`; `latestDisputeOutcome` | [ID-15][id] |
| `ArtistRegistry.setPackageRegistry` (a 7-day SUCCESSOR_SETTER action, compare-and-set) | As `bindPackageRegistry` | `register`, moved to Stream's successor package registry | [ID-15][id] |
| `ArtistRegistry.bindFederationRegistry`, then `setFederationRegistry` (SUCCESSOR_SETTER, 7 days, compare-and-set) | Code, no EIP-7702, ERC-165, never zero | `registerFederated` (with the account's own signature), `listFederatedContract` (with a wallet of the listed artist's account consenting to that contract and its facts) and `setFederatedStatus` on a per-token directory entry; none of them touches an identity, payout or canonical token | [ID-1, ID-12][id] |

Stream and Editions check only `IWorkRecords` when binding; no contract depends on `IWorkPowers`,
the renounceable powers `WorkRecords` also reports through ERC-165
([ADR 0006](../adr/0006-work-powers-and-conventions.md)).

### Admitted sale adapters

- **Full trust over what it mints.** Stream mints into the adapter's own custody, and the move
  signature names no adapter, so an admitted adapter holds every work it starts. Admission
  (`setAdmittedMinter`) is therefore a 7-day action
  ([AUC-1][auc]).
- **Removal stops new mints only.** The minting adapter keeps `burn` and `settlePrimary`, so
  a running dispute can finish ([AUC-8, AUC-9][auc]).
- **An adapter's SOLD report is trusted, and so is its settling at all.** Stream moves every
  UNBID or FROZEN_OUT work to the museum itself (owner decision 17), so an adapter that settles
  escapes the museum rule only with a deliberately false SOLD report, such as one naming the
  artist as the buyer of a work nobody bought. An adapter that never settles can still transfer
  (or burn) the unsold work it holds: Stream does not refuse transfers of unsettled works, and
  such a work stays NONE in `primarySale`. The 7-day admission review covers both
  ([ADR 0005](../adr/0005-stream-editions-auction.md)).
- **On 6529 Stream Editions,** an admitted adapter of an edition's sale kind may mint copies up
  to the creator's cap. Each edition is bound to one adapter, the one whose sale opened it
  (`bindMinter`) or else the first to mint it, which alone mints it, even after the network
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
  same kind is a 7-day action, and it could never add copies to a sale the first one ran.

### Pinned code hashes

Besides the install checks ([GV-20][gv]), these
dependencies are pinned to a reviewed code hash, and all but the last row are checked again at use
(DEPS-6). Stream's other dependencies and admitted sale adapters are checked at install only. The
split ledger pins no code hash of its payout resolver, the artist registry: a re-check guards
nothing after EIP-6780 and could freeze every artist share ([ECO-12][eco]).

| Dependency | Held by | Pinned at | Checked again at | On mismatch | Rule or test |
| --- | --- | --- | --- | --- | --- |
| Curation verifier | `PackageRegistry` | Constructor, `setVerifier` | Every `registerPackage` | Nothing registers | [CUR-3][cur] |
| Consolidation source | `ArtistRegistry` | Constructor, `setConsolidationSource` | Every read | "No" for every wallet but the root | [ID-4][id] |
| VRF coordinator | `VrfEntropyModule` | Constructor, `setCoordinator` | Every request and delivery | `DependencyCodeChanged` | [ENT-7][ent] |
| Artist resolver | `StatementLog` | Constructor, `setArtistResolver` | Every ARTIST authorization | `DependencyCodeChanged` | [DSP-7][dsp] |
| Federation registry ([Federation](../spec/federation.md)) | The English auction (6529 Stream Editions' edition auction keeps none; the federated edition auction reads the artist registry's pointer); once replaced in the artist registry, the registry it names answers as the current one (FED-69) | `setFederationRegistry` | Every `isTarget`, every federated start's `entry` | The registry is ignored | `test_Federation_CodeHashesArePinned` in [`EnglishAuctionFederation.t.sol`](../../test/sales/auction/EnglishAuctionFederation.t.sol) |
| Default renderer; a finalized work's renderer | `Stream`; `WorkRecords` | `setDefaultRenderer`; `finalize`, `repinRenderer` | Every `tokenURI` and `uri` | Revert, with no fallback | [RND-2, RND-3][rnd] |
| An added store | `WorkRecords` | `addStore` (append-only) | Every sync and switch through it | `UnknownStore` | [WS-41][ws] |
| Stream; the artist registry; the package registry | `Editions`; `PackageRegistry`; `VrfEntropyModule` | Constructor | Not checked again | Construction reverts | [ENT-16][ent] (the module's) |

### Resolvers and renderer pins

- **ARTIST statements** are exactly as strong as the statement log's artist resolver and the
  7-day `setArtistResolver`; every entry records its resolver ([DSP-7, DSP-8][dsp]). Today's
  resolver, the artist registry, answers `isArtist` for a wallet of the work's lead account, and
  for nobody while the account is frozen or its root is being replaced ([ID-2, ID-11][id]).
- **Payouts.** The split ledger names the artist registry immutably and refuses to release an
  artist-resolved share while it answers zero, while frozen or for a pending payout move
  ([ECO-18][eco], [ID-10][id]).
- **Renderers.** A default-renderer swap reaches every unfinalized work at once; a finalized work's
  pin moves only by the network's repin (7 days, C8), and a changed pinned renderer leaves the
  work without metadata until a repin ([RND-1, RND-5][rnd], [LIM-CNT-10][lim-cnt]). Once the lead artist renounces the repin (`RENDERER_REPIN`, after
  finalize), the pin never moves again ([LIM-CNT-16][lim-cnt]).
- **Delivery.** `WorkRecords` forwards `preferredLocator` to the governed delivery contract with
  all gas and serves its answer only when it is well formed; a reverting or malformed answer
  falls back to the work's own answer, a shortfall reverts. The delivery contract can call
  `WorkRecords` only through its two refresh hooks and changes no fact ([WS-39, WS-40][ws];
  [LIM-GV-23, LIM-GV-24][lim-gv]).
- **Renunciations.** `WorkRecords.renounce` needs the lead artist's signature by a wallet of the
  account; renouncing the royalty or licence power also needs the network (24 hours, C7). A
  frozen account or one whose root is being replaced cannot sign. A renunciation cannot be undone
  ([WS-37, WS-38][ws], [LIM-CNT-14][lim-cnt]).

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
