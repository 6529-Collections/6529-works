# Changelog

## Unreleased

- Repository created for the 6529 network's art protocol: 6529 Stream, 6529
  Editions and 6529 Stream Federated.
- ADR 0001 records the accepted v1 scope (originally 6529Stream ADR 0055).
- ADR 0003 records the build-time decisions for v1: ABI package hashing, the Stream
  core and records split, the 350K start-gas budget, pull-only artist payouts,
  sticky identity standing, base64 attestation for inline media, and more.
- ADR 0002 records how the AccessManager hardening in ADR 0001 §13 is implemented:
  a guardian-cancellable subclassed manager, guardian rules, a cold recovery admin
  and the selector delay classes decided during the build.
- ADR 0004 records the gas budgets under Glamsterdam. The budgets stay as Prague gas
  (a steady-state ETH start at most 350K). Each measured operation asserts its exact
  count of new storage slots and new accounts, with a maximum for a steady-state start
  of 6 slots, 7 with a bid. The Sepolia totals are published next to them, the
  EIP-7825 per-transaction cap is restated for regular gas, and payees are assumed to
  exist.
- Tests: `test/helpers/StateGrowth.sol` counts the storage slots and accounts a
  transaction creates, and the accounts it reaches cold, from a Foundry state diff
  and the state before and after the call. The integration gas report adds the
  cold-account cost Foundry cannot model, asserts exact counts and a Prague ceiling
  on every row, adds VRF, edition-master, ERC-20 Permit2, `settle`, `createEdition`,
  `openSale`, `purchase` and `refreshStanding` rows, and prints one table
  (`forge test --match-test test_Gas_Table -vv`). `GasHarness.t.sol` checks the
  correction against a fully cold measurement.
- Deployment: off anvil, `Deploy.s.sol` refuses a `NETWORK_FEE_RECIPIENT` that does
  not exist (`AccountDoesNotExist`).
- Governance: `WorksAccessManager` (guardians cancel any scheduled operation;
  nobody cancels their own revocation), the canonical role and delay-class table
  (`Roles.sol`), a one-shot configurator that owns its manager and reads it back,
  and `BoundedParameter` for raise-only parameters.
- Governance: a genesis wiring phase. `GovernanceConfigurator.configure` executes an
  allow-list of genesis calls (one-shot binds, admitted minters, sale targets and the
  epoch-0 manifest) as zero-delay admin before renouncing. `config/genesis.example.json`
  commits the selector, role and delay map for every v1 contract, checked against the
  compiled selectors by `test/governance/GenesisConfig.t.sol` and against `forge inspect`
  and every `restricted` function in `src/` by `tools/check_genesis.py` in CI.
- Identity: `ArtistRegistry` and `ConsolidationAdapter` (ADR 0001 §11). The
  registry has 7-day STANDARD changes and 180-day two-sided overrides, a sticky
  recovery-standing snapshot (young consolidations recorded as pending, a 30-day
  public grace for missing wallets), a payout freeze while a change would move
  the payout, payout validation, and one-shot bindings. The adapter reads 6529
  consolidations with age and expiry. `IArtistRegistry` gains the standing
  surface, `FederatedListFull` and `AcceptanceUsed`; `IConsolidationSource`
  gains `consolidations` and `effectiveAt`; `OVERRIDE_ACCEPTANCE` is nonce-free
  and consumed once by digest.
- Identity: contested overrides (ADR 0003 owner decision 1). A captured wallet's
  cancel during the notice turns a 180-day override into a contest that a TDH
  vote decides through the governed `resolveContested`, which cites the vote's
  DISPUTE_OUTCOME statement, recorded after the contest.
  The payout stays frozen meanwhile, the guardian may veto, and an unresolved
  contest lapses after a year (`expireContest`). `bindStatementLog` is a new
  genesis wiring call.
- Deployment: `script/` deploys the merged v1 contracts with CREATE2 (`DeployV1`),
  installs the genesis configuration, records the deployment, and confirms it against the
  chain (`Verify.s.sol`), which recomputes every address from the recorded constructor
  parameters. Off anvil, the deploy script refuses the following: placeholder or unreachable
  holders (ADMIN and GUARDIAN must be Safes), a genesis that departs from the committed
  policy, a CC0 text other than the pinned canonical one, a missing entropy-module choice,
  non-canonical dependencies on mainnet, and anything the genesis names but the deployment
  lacks. Each product's first default currency is genesis wiring. `script/README.md` is the
  Sepolia runbook. The canonical CC0 legal code is pinned by digest. The deploy covers every
  v1 contract, the renderer and 6529 Editions included, with no stand-in.
- Deployment, owner decisions: off anvil, at least two admin Safes (hot and cold) and three
  guardian Safes, and no signer shared between admin Safes or between an admin and a
  guardian Safe. The runbook adds an admin-recovery procedure and guardian practice. Sepolia
  mirrors mainnet: throwaway signers, a real VRF subscription, and the official 6529
  delegation deployment. That deployment is the default there, and the canonical code hash is
  pinned. Artists refresh their own recovery standing; a network keeper is optional. The CC0
  legal code is committed as a byte-exact test fixture and is the deploy's default text.
- Content tooling: the uploader's gas model has a `glamsterdam` schedule next to `prague`
  (still the default), fitted to the Sepolia receipts of 11 and 12 October 2026. Under it the
  EIP-7825 cap bounds only regular gas, so a full chunk gets a gas limit of about 42M instead of
  a clamped 16.8M. `calls --schedule glamsterdam` also limits batching to one full chunk per
  transaction and warns above the 50M RPC estimate cap and an assumed block gas limit.
  `--gas-limits rpc` takes limits from the node's `eth_estimateGas`. `plan` and `calls` quote
  the cost under both schedules (`--gwei`). The content READMEs carry both sets of figures.
- CI: the budget gate measures an explicit Foundry profile (`--profile`, default
  `default`) and fails cleanly on malformed `forge build --sizes` output.
- CI: a parallel **Static analysis** job runs Slither (hash-locked, pinned) and fails on
  any High or Medium finding without a row in `docs/security/slither-triage.md`.
- Identity review fixes. IDENTITY-2: a staged change that moves the authority reserves the
  new one for the artist (`IArtistRegistry.reservedFor`, one storage slot while it waits) until
  it executes or ends; `register` and other artists' changes refuse a reserved account with
  `AccountTaken`. IDENTITY-3: a refresh removes a pending standing entry that is no longer
  consolidated at once, so a consolidation revoked before its 30 days never gives standing.
  IDENTITY-4: the consolidation adapter's reads fail closed. Only a getter's no-data revert
  past the end of an array ends a walk; a read that runs out of gas, reverts with data or
  returns too much reverts with `DelegationReadFailed`. `READ_GAS` rises from 50,000 to 200,000.
  SIGS-3: an account that has been an artist's authority can never become its authority again
  (A, then B, then A reverts with `AccountTaken`), so its unused move, consent and acceptance
  signatures stay void after a rotation (recorded in ADR 0003). Review follow-ups: a pending
  standing entry follows its live consolidation's clock in both directions; registration and
  execution skip their standing refresh when the source cannot read (`StandingRefreshSkipped`),
  while staging, heartbeats and `refreshStanding` still fail closed; `DelegationReadFailed`
  moves to `IConsolidationSource`.
- Identity (MONEY-4): an artist's payout address may no longer be the claim router, the
  revenue escrow, a sale adapter or a mint target. These declare their interfaces through
  ERC-165 (the escrow and the router now do too), and `ArtistRegistry` refuses them at
  registration, staging and execution (`src/libraries/ProtocolContracts.sol`). A split
  wallet's predicted address is still refused only once deployed.
- Economics (CALLS-1, resolver side): `EconomicsResolver` refuses a network fee recipient
  that could never be paid (`InvalidFeeRecipient`): itself, its allowlist and split factory,
  and any contract declaring the revenue escrow, claim router, sale adapter or mint target
  interface. Works lock the recipient at mint, so such a recipient made their sales
  unsettleable.
- Economics (MONEY-2): an escrow credit owed to an account that is not a split wallet,
  such as the network fee recipient's Safe when a token blocks it, can be recovered. The
  account names its replacement with `RevenueEscrow.consentToRecovery`, and the governed
  `recover` (14 days) moves the credit only there. The fee recipient's share in existing
  royalty wallets is released with `releaseTo`; the economics README and ADR 0003 say how.
- Economics (MONEY-3, CALLS-4): `ClaimRouter` continue mode reverts with
  `ClaimInsufficientGas` when an item fails after spending all but 1/64 of the gas it was
  given, so gas estimation raises the limit until a first release (which under Glamsterdam
  costs far more than the Prague-sized minimums) is paid, instead of settling where it fails
  silently. A target that burns all its gas now reverts the batch instead of being skipped.
  The NatSpec, the economics README and ADR 0004 restate the minimums and batch sizes.
- Tests: the integration gas report measures the split-wallet operations (`createWallet`
  for a seller wallet, an artist's first ETH `release`, and a first and a later signed
  release through the claim router), with exact counts and regression ceilings, also in
  ADR 0004's table.
- Economics: `Splits.entitlement` uses 6529 Stream's exact, overflow-free share formula
  instead of a full-width `mulDiv` (identical results for every canonical share, fuzzed
  over the full range). A split wallet's code shrinks from 5,439 to 5,302 bytes: about
  27,600 less Prague gas per deployment, and about 211,000 less on Sepolia's Glamsterdam.
  With the ETH branch below it ends at 5,350 bytes.
- Economics: split wallets keep no receipts high-water mark for ETH, whose receipts can only
  grow (nothing but a release takes ETH out, and a release counts it first);
  `recordedObserved(address(0))` is now always zero. A wallet's first ETH release writes 2
  new slots instead of 3 (about 111,000 less gas on Sepolia's Glamsterdam), and later ETH
  releases skip the mark's read and write. ERC-20s keep the mark.
- Economics: `ReleaseVerifier` keeps release nonces in a bitmap, 256 to a storage word, like
  the statement log. A payee signing nonces in order writes one new slot per 256 signed
  releases instead of one each (a later signed release: 1 new slot to 0, about 111,000 less
  gas on Sepolia's Glamsterdam). `nonceUsed(account, nonce)` is unchanged.
- Economics (QUALITY-12): split wallets have a constant init code. The wallet's constructor
  reads its payee list back from the factory (`pendingPayees`, transient storage during
  `createWallet`), and the CREATE2 salt commits to the payee configuration hash and the
  caller's salt. `walletFor` no longer hashes the wallet's 6.6 KB creation code: about
  4,400 Prague gas less per `start` and per `royaltyInfo`, and about 9,000 less per
  `createEdition`. Every predicted wallet address changes.
- Economics (review of PR 54, L-1 and L-2): `ClaimRouter` reverts a continue-mode batch on
  an item's gas shortfall only while the item is offered less than
  `SHORTFALL_REVERT_CEILING` (1,500,000, about twice a first signed release on Sepolia's
  Glamsterdam). An item that fails despite the ceiling is skipped, so a party to one item
  cannot revert a well-funded batch. An ERC-1271 check that could not get its gas
  (`BoundedCallInsufficientGas`) also counts as a shortfall. The README gives keepers'
  guidance: simulate privately, and split batches with contract payees or unfamiliar tokens.
- Economics (MONEY-2 follow-up): a `consentToRecovery` consent is single use. The governed
  `recover` that moves the account's credit consumes it, so the account consents again for
  each further asset or later credit.
- Economics and identity (CALLS-1 and MONEY-4 follow-up): `ProtocolContracts` also
  recognises the artist registry, the package registry and the work records (ERC-165 IDs
  they already declare), and `EconomicsResolver` also refuses its factory's release
  verifier as a fee recipient. The resolver NatSpec, the economics README and the runbook
  name the system contracts still not recognised on-chain.
- Entropy (DEPS-1): VRF seeds are drawn once per content hash. Every approved item with the
  same content links to that draw (`SeedLinked`) and reads it by item hash; an item whose
  content already has a delivered or pending draw joins it without a new oracle request.
  `SeedDelivered` is indexed by content hash.
- Entropy (DEPS-2): the VRF callback creates no storage slot. The seed overwrites the word
  that held the request ID (`requestOf` reads zero once delivered), so a delivery costs about
  32,000 gas under Glamsterdam, under a third of the 100,000 callback floor; the floor's
  NatSpec and the entropy README give the Glamsterdam figures.
- Entropy (DEPS-5): `lowerCallbackGasLimit(expected, next)` lowers the VRF callback gas limit,
  never below the floor, in the 30-day SUCCESSOR_SETTER class (new genesis selector), so the
  module can follow a coordinator whose maximum Chainlink lowered below the limit. `setConfig`
  stays raise-only.
- Curation (SIGS-1): `IStream.releaseContent(tokenId, contentHash, beneficiary)` is governed
  (PARAMETER_SETTER, 48 hours, new genesis selector) and names the rightful artist from the
  dispute outcome. The package registry reserves the released content hash for that artist
  (`releasedTo`, `ContentReserved`); `ContentReleased` carries the beneficiary. The dispute
  runbook adds the guardian's revocation of the copier's roots before the cancel executes.
