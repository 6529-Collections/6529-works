# Changelog

## Unreleased

- The English auction closes the sale of a rescued work (owner decision 20). If 6529 Stream
  already records the work as settled, which only `rescueToMuseum` does before the auction
  settles, `settle` closes the sale with refunds only. It credits the standing bid back,
  reports, pays, mints and delivers nothing, and marks the auction SETTLED
  (`RescuedSaleClosed`), so the winner's bid and the master's edition sale are no longer
  locked. Before, `settle` reverted `SaleAlreadySettled` for good. The guard is Stream's
  recorded outcome (`primarySale`), never the auction's own state. LIM-SAL-14, AUC-36, and an
  ADR 0005 admission requirement for every later 1/1 adapter.
- Owner decisions 18 to 24 (1 November 2026), the contract and deploy side:
  - Decision 20: `Stream.rescueToMuseum(tokenId)` (SUCCESSOR_SETTER, 30 days) moves a work
    stranded in a removed sale adapter's custody to the museum, and nothing else. It applies
    only to a work whose primary sale never settled, still held by the adapter that minted it,
    90 days after governance removed that adapter. The work is then settled as UNBID
    (`WorkRescued`), so the adapter can neither settle nor burn it. Each adapter's removal
    time is kept in its minter word, whose sale-kind key is now 192 bits. AUC-35; the rescue
    cannot see the adapter's sale, so a sale that can still settle is settled first
    (LIM-SAL-14).
  - Decision 19: genesis wires the English auction's ETH opening bid at 0.05 ETH
    (`setOpeningBid`, now a genesis selector; `DeployV1.ETH_OPENING_BID`; Verify reads it
    back). A self-bid at the floor still keeps a 1/1 from the museum, but it shows as SOLD and
    costs the network fee on it, about 0.0125 ETH (LIM-SAL-1).
  - Decision 24: ADR 0001's source-size budget rises from 12,000 to 13,000 lines, by a dated
    amendment; `check_budgets.py` enforces it.
  - Decision 18: on mainnet, Deploy and Verify refuse a genesis that names the deployer EOA
    as any role holder, or whose community council, security council and curation signer
    roles share an account across groups (`DeployGuards.checkRoleGroups`, GV-36). The security
    council fills the three guardian seats the deploy requires as three guardian Safes with
    disjoint signers, which keeps the guardians' redundancy; the runbook explains it.
  - The museum NatSpec in `EconomicsResolver` and `IEconomicsResolver` now says 6529 Stream,
    not the English auction, reads the museum.
- Docs and runbook after the rc.2 seven-lens review (fix pass C). The museum wording follows
  owner decision 17 everywhere: 6529 Stream moves an unsold work itself, nothing is pending for
  the museum, and after an economics replacement running sales use the new resolver's museum
  (LIM-SAL-12, the threat model, the bidding guide, economics, the runbook). The runbook pauses
  the English auction's starts with the edition auction (LC-2), opens every pending edition sale
  before an adapter-set switch, keeps no edition sale with winners OPEN or SETTLING across a
  package-registry switch (a successor MUST read its predecessor and keep `consume`'s ABI),
  opens right after every edition-master start, warns that a dispute-outcome correction can
  invalidate a scheduled cancel, and has keepers compute the settlement order off-chain beyond
  the lens's limits. Known limitations: the backstop is a hard close (LIM-EA-1, LIM-EA-6), the
  emergency pause (LIM-EA-11), and new rows for the lens views beyond several thousand departures
  (LIM-EA-17), starts beyond ADR 0004's scope (LIM-GAS-12), `entropyModuleOf`'s eras
  (LIM-ENT-6) and Stream's permanent couplings (LIM-GV-17). ADR 0004 states its scope (at most
  two parties; params are bounded to 64 bytes by ADR 0005 §12) and adds the worst edition `bid`
  (106,295) and the worst `settle` call with departures scattered over the log's words (307,070
  execution gas), both re-measured after fix passes A and B; ADR 0005 §4 lists the reachable
  ladders. After fix passes A and B: LIM-EA-17 and the keeper runbook page the settlement order,
  LIM-GAS-12 keeps only large collaborations, the economics-replacement row follows
  `bindMinter`'s one source of truth, and the docs describe pause withdrawals as open only to
  bids placed before the pause.
  `quote` and `lowestWinningStep` are documented as new-bid views that ignore capacity, and the
  economics spec notes that 6529 Stream has no per-collection royalty receiver. The runbook's
  overview and the editions spec's wiring paragraph no longer say the edition auction creates
  its lens: it pins one deployed in its own transaction, and holds no economics resolver.
- Owner decisions of 1 November 2026 in the docs: mainnet roles are network-held from day one
  (decision 18: a community council for the delayed roles, a security council for PAUSER and
  GUARDIAN, a dedicated curation signer, later on-chain TDH governance), in the runbook's
  mainnet governance section and genesis checklist and in LIM-GV-18 (D67, D98; review finding
  G-3). Still open there: the holders of the operational keys and the cold recovery admin, how
  one security council fills the three guardian Safes the deploy requires, and a deploy-side
  guard for the decision, which does not exist yet. LIM-GV-16 is accepted (decision 21); every unsold canonical 6529 Stream 1/1 goes to the
  museum whatever its sale method, and return-to-creator sales belong in their own collections
  (decision 22, ADR 0005 §11 and the Stream spec).
- Fix pass B for the rc.2 seven-lens review.
  - `AssetAllowlist.deprecateAsset` refuses ETH (`EthNotDeprecable`): the native currency, in
    which edition auctions run, is never frozen (MONEY-M1, G-2). The freeze-exit tests now use
    an ERC-20.
  - The English auction reads `ownerOf` after `settlePrimary` to learn where an unsold work
    went. It no longer trusts the `holder` the token reports (CALLS I-2).
  - `Stream.setDependency` refuses a replacement that answers `authority()` with an
    AccessManager other than Stream's (G I-1, GV-35).
  - The English auction's lens is deployed in its own transaction before the auction. The
    lens is now stateless and reads its caller. The auction's constructor takes the lens's
    address and code hash, and checks both together with the lens's dependencies.
    `DeployV1` deploys the lens as its own CREATE2 entry, and Verify checks the lens's
    dependencies (GAS M-2). Verify also checks the edition auction's lens's dependencies.
  - `IEnglishAuctionClock.auctionClock` also returns the dispute pause's start (`pausedAt`,
    exactly as `auction` reports it). Its interface ID is unchanged: return values are not part
    of a selector. The edition auction's `withdrawBid` reads the pause start there instead of
    through the lens, so it costs about 12,500 gas less.
- Fix pass A of the rc.2 seven-lens review (the edition auction, its lens, 6529 Stream Editions
  and `EditionRules`; ADR 0005 §12):
  - F1 (LC-1, MONEY-L1, G-1): `IEditions.bindMinter` returns the `WorkTerms` it locks, and the
    edition auction pays exactly those, so after an economics replacement (owner decision 16) a
    sale pays the split its edition records. The lens no longer holds a copy of the resolver.
  - F3 (markets M-1, clearing Info 1): during a 1/1 dispute pause, only a bid placed or last
    raised in a minute (from the sale's open) that ended before the pause began may be
    withdrawn; a bid placed during the pause, in its minute or in the withdrawal's block stays.
    The bid word keeps that minute in its spare bits; the lens's `canWithdraw` answers for a bid.
  - F4 (governance L-3): Editions compares the sale kind an adapter reported at its first
    admission, not its live `saleKind()`, and refuses an adapter with no kind.
  - F8 (gas M-2): the edition auction's lens is deployed in its own transaction (its own
    `DeployV1` entry, `UniformEditionAuctionLens`) and pinned by the adapter's constructor (code
    hash, code, and its Editions, Stream, English auction and escrow), so the adapter's deployment
    fits a block. The lens reads its caller and has no `adapter()`.
  - F9 (gas M-1): `settlementOrderFor(saleId, settler, fromPosition, max)` pages a long
    departure log, `O(n log max)`; the lens reads a log four entries a word and sorts with a heap
    in Yul. A page of 96 at 10,000 departures costs 21.9M gas; `clearing` and `quote` stay
    within a 50M `eth_call` up to about 9,000 departures at the cut step.
  - F10 (gas L-1): `EditionRules.MAX_PARAMS_BYTES` is 64 (two words), down from 1,024, so every
    start row stays inside its budget less the 5K margin; a sale method needing more commits to a
    hash in `params` and takes the data at open. Gas rows at the bound.
  - NatSpec: the soft close is strict, a bid event's `endTime` can be stale or `type(uint64).max`
    while paused, `lowestWinningStep` means "wins at least one unit", and `quote` double-counts a
    raise and, with `lowestWinningStep`, ignores a step's queue capacity.
- Docs: the edition auction's specification (rc.2 L6). Editions and sales specifies the
  uniform-price edition auction: the step ladder, bids, the D138 clearing and its one-pass
  algorithm, the cut step and each settler's own departure sweep, the clocks beside the 1/1,
  settlement in calls of bounded gas, payouts and claims, the binding at open, the state
  machine, sequence diagrams, a worked example, rules EA-1 to EA-16 with their tests, failure
  modes and the governed parameters. Stream and auctions shows the 1/1 beside its editions. The
  glossary, architecture, integrator guides (bidding and settling, events with the topic0
  appendix, ABIs), threat model, trust assumptions, invariants (INV-EA-1 to INV-EA-13) and the
  differences register follow. Known limitations take over ADR 0005's LIM-EA-1 to LIM-EA-12 as
  amended and add LIM-EA-13 to LIM-EA-16.
- ADR 0005 is restructured as the text accepted on 31 October 2026 plus dated amendments: §6
  (the binding at open), §7 (the museum branch gated on 6529 Stream in code, now history), §8
  (power-of-ten base prices), §9 (per-settler sweeps), §10 (Stream's governed dependency
  pointers, owner decision 16) and §11 (Stream records each 1/1's primary-sale outcome and moves
  unsold works to the museum, owner decision 17); each amended passage points to its
  amendment.
- The edition auction keeper runbook: settle directly or through the keeper's own contract,
  never through a shared public relayer such as Multicall3, whose callers would share one
  sweep. NatSpec: `InvalidQuantity`'s entered-units limit applies only to capped sales, and the
  Halmos proof of the cut-step sweep covers queues of five entries. The sales README is trimmed,
  and the lens's departure-sort benchmark moves to its test.
- `docs/facts.json`, the machine-readable facts 6529.io syncs, generated by
  `tools/gen_facts.py` from the repository's sources: the deployed addresses per network; the
  governed parameters with their launch defaults and bounds (the 1/1 auction, the edition
  auction from `DeployV1.editionAuctionDefaults` checked against ADR 0005 §4 and `StepLadder`,
  economics, storage, governance delays); the collections' names and symbols; the gas figures of
  ADR 0004's table with their labels; and the links. The Docs CI job runs the generator's unit
  tests and `gen_facts.py --check`.
- 6529 Stream records each 1/1's primary-sale outcome (owner decision 17).
  `IMintTarget.markPrimarySettled(id)` is replaced by `settlePrimary(id, outcome, buyer,
  currency, price)`, which returns the seller and fee terms (`PrimarySettlement`). Stream keeps
  SOLD, UNBID or FROZEN_OUT in the token's flags word and, for SOLD, the currency and price in one
  new word (`primarySale(id)`; the price in 96 bits, saturated); `PrimarySaleSettled` now carries
  the outcome, the buyer, the currency and the exact price (new topic0). For UNBID and FROZEN_OUT
  Stream itself moves the work from the adapter's custody to `IEconomicsResolver.museum()`, read
  then, with no receiver callback: the museum rule (D140) holds for every sale an admitted 1/1
  adapter settles but for a deliberately false SOLD report; that, and an adapter that moves a
  work without settling it, are left to the admission review (ADR 0005). The
  English auction loses its museum branch, the `_MUSEUM` flag and its Stream constructor
  argument, reports FROZEN_OUT for the freeze exit and a delisting, and no longer reads
  `primaryTerms` at settlement. `IMintTarget`'s and `IStream`'s interface IDs change. Prague
  gas: `settle` with a bid 157,140 (one new slot, +11,287), with no bid 121,508 (−14,786);
  the binding row 338,212. Bytes: Stream 23,471 (+1,073), the English auction 22,993 (+266),
  6529 Stream Editions 18,362 (+199)
  ([ADR 0004](docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)).
- 6529 Stream: the package registry, artist registry, economics resolver and entropy module are
  replaceable by governance (owner decision 16): `setDependency(kind, expected, next)`,
  SUCCESSOR_SETTER (30 days), compare-and-set, with the constructor's install checks; never
  zero. Stream's code and address, the split factory and every existing token stay as they are.
  The genesis contracts stay immutables, with a replacement bit each in the counter word
  every mint reads, so a start with no replacement reads no extra slot. 6529 Stream Editions
  and `WorkRecords` read the pointers from Stream instead of holding immutable copies. Stream
  records the entropy module each work minted under (`entropyModuleOf`), which `openRecord`
  stores the VRF seed from and the renderer reads before the record opens, so a replaced
  entropy module never changes an existing work's seed or metadata (ENT-18; the review of #81).
  The artist registry's one `register` caller is governed too
  (`ArtistRegistry.setPackageRegistry(expected, next)`, SUCCESSOR_SETTER, 30 days,
  compare-and-set, event `PackageRegistrySet`), so a successor package registry onboards new
  artists (ID-30). The replacement procedure for each dependency, and what it cannot reach (the
  genesis artist registry stays the payout resolver of every Stream work, LIM-GV-16), is in the
  runbook. `IStream`'s and `IArtistRegistry`'s interface IDs change.
- The start path, for 5,000 gas of margin under the 350K budget on every start row (the review
  of #81): `PackageRegistry.consume` also returns the lead artist's active authority it checked
  the move against, which 6529 Stream reports as the creator without a second artist-registry
  call (every start about −1,160); the entropy module answers `isDeliveredContent(contentHash)`
  and `seedOfContent(contentHash)` from one word, which Stream's VRF check and
  `WorkRecords.openRecord` use (a VRF start about −2,140 more; a content hash is consumed once,
  CUR-12); Stream resolves the entropy module only for a VRF item. The binding row is 338,200
  and with a VRF seed 343,760. After governance replaces dependencies, the rarest start can pass
  350K by up to about 3K (LIM-GAS-11). `IEntropyModule`'s interface ID changes.
- 6529 Stream: `mint` compares an item's sale kind with the adapter's kind recorded at its first
  admission, the kind `primaryTerms` reports, instead of the adapter's live `saleKind()` (the
  review of #80). The kind is also kept, as 232 bits of its hash, in the minter word `mint`
  reads anyway, so the check costs no extra slot; `mint` resolves its four dependencies from one
  read of the counter word.
- 6529 Stream: `rendererOf` reads the records satellite with a fixed gas cap (`RECORDS_GAS`) and
  serves the default renderer on any fault of it but a changed pinned renderer, which still
  fails closed; one read instead of two. The gas check covers a cold satellite account, so the
  satellite always gets all of `RECORDS_GAS`. Stream grows by 1,399 bytes with the two entries
  above; `start` costs about 40 less Prague gas than before decision 16 at steady state (an
  artist's first two-party start with a bid 338,200; with a VRF seed 343,760, a gated row,
  6,240 under 350K), `settle` 2,280, `createEdition` 5,597, with no new slot
  ([ADR 0004](docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)).
- Tests: the edition auction's invariant suite also checks that nothing is claimed while a sale
  is SETTLING (review of #84). `wideBook` spreads up to two sales a run wider than one settle
  call scans (24 words), so settlement scans over calls; while a scan or a sweep is unfinished,
  `claimBid` and `claimBidFor` must revert with `InvalidAuctionState`. An early settle call may
  advance a wide book's scan before its edition exists; any other early success still fails.
  `test_EveryActionRuns` replays 128 sequences instead of 64, so the multi-settler paths are hit
  more than once.
- Tests: the edition auction on the real stack (rc.2 L5). A stateful invariant suite,
  `EditionAuctionInvariant.t.sol` with `EditionAuctionHandler`, runs six masters with and
  without creator caps beside their 1/1 auctions: opens, bids, raises, soft-close bids, a FIFO
  hole at the cut step, 1/1 anti-snipe bids, dispute pauses with withdrawals, cancels that void,
  settlement by several settlers (a handoff, a sweep that skips a departure, a refused reorder,
  interleaved keepers), claims and pushed claims. It checks no unsold or extra copies, ETH
  conservation, clearing optimality and the breadth rule against a brute-force per-unit
  reference (`test/helpers/UniformClearingReference.sol`), the cap, FIFO fills, the view equal
  to settlement, the clocks, no settlement before the end, and that each settler's sweep is its
  own and a keeper always completes settlement; `test_EveryActionRuns` asserts every action and
  path runs. A differential fuzz (`EditionAuctionDifferential.t.sol`) holds the live clearing,
  every bid's outcome and the settlement order equal to the reference under four margins and
  five caps, lets other settlers make mangled sweeps, then settles and claims every bid.
  `PieceLifecycle.t.sol` runs a piece end to end: the 1/1 and its editions side by side, a 1/1
  anti-snipe moving the edition close, settlement and payouts, claims and the edition royalty;
  and an unbid 1/1 going to the museum while its editions sell. The invariant campaign adds
  about 45 seconds to the "other invariants" CI job. Mutation and coverage floors for the
  edition auction's contracts follow their first weekly and `main` runs.
- 6529 Stream: the 1/1 sale method is pluggable (ADR 0005, owner decision 15). `mint` takes any
  admitted adapter whose `saleKind()` is the item's sale kind, and `_checkItem` requires only a
  nonzero kind; the adapter checks the sale's currency and params (the English auction refuses
  any params, as before). The English auction is admitted at genesis; a later 1/1 method is an
  adapter governance admits (`setAdmittedMinter`, SUCCESSOR_SETTER, 30 days), with no new
  Stream. `primaryTerms` reports a work's minting adapter's kind, recorded at its first
  admission; an adapter reporting no kind is refused. Removing an adapter stops its new mints
  and never strands a live sale (AUC-9). Stream's runtime grows by 181 bytes; `start` costs
  about 230 more Prague gas and `settle` 2,169 more, with no new slot
  ([ADR 0004](docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table)).
- Deploy: genesis deploys the uniform-price edition auction (`UniformEditionAuction`, with
  the stateless lens its constructor creates) at the launch parameters of ADR 0005 §4,
  admits it on 6529 Stream Editions and lists Editions as its target (17 wiring calls, was
  15). Its five governed selectors are in the role matrix: `pause` (PAUSER), `unpause`
  (UNPAUSER), `setConfig` (PARAMETER_SETTER, 48 hours), `setTarget` and
  `setFederationRegistry` (SUCCESSOR_SETTER, 30 days). Every sale adapter's admission,
  `setAdmittedMinter` on Stream and on Editions, stays in the 30-day class. Verify checks the
  lens is the auction's own and its code hash the recorded one. The anvil dry-run record in
  `deployments/31337/` is regenerated.
- 6529 Editions is renamed 6529 Stream Editions (ADR 0005, D139) in every current document and
  NatSpec comment; `name()` is "6529 Stream Editions" and `symbol()` `STREAMEDITIONS`. The
  identifiers `Editions`, `IEditions`, `PRODUCT_EDITIONS` and the `"EDITIONS"` binding label do
  not change, and the records of Sepolia r1 to r3 keep the former name.
- Editions: `EditionTerms` is `{maxCount, currency, saleKind, params}` and edition minting is
  generic (ADR 0005, owner decision 14). `EditionRules` checks only a nonzero sale kind and at
  most 1,024 bytes of params; the sale adapter validates the currency and params when it opens.
  `mint` takes any admitted adapter whose `saleKind()` is the edition's, within the creator's
  optional cap (`maxCount`, 0 for none), and binds each edition to the first adapter that mints
  it (`EditionMinterBound`; any other gets `MinterMismatch`). `formatOf`, `EditionWindowOpened`
  and `PricedDefaultCurrency` are gone, and `Edition.windowStart` is now `minter`. Every
  selector and event that carries a `PackageItem` changed (`createEdition` is `0x26c8844c`), and
  with them the interface IDs of `IWorkRecords`, `IEditions`, `IPackageRegistry` and
  `IEntropyModule`
  ([docs/integrators/abis-and-interface-ids.md](docs/integrators/abis-and-interface-ids.md#changes-since-the-sepolia-r3-build)).
- Sales: the fixed-price and Dutch adapters are deleted (ADR 0005, decision 8): `FixedPriceSale`,
  `DutchSale`, `MintSaleBase`, `DutchPricing`, their interfaces and typehashes,
  `Limits.MAX_PHASES`, and their tests, mocks and invariant suites. The specification retires
  ED-9 to ED-24, and the known limitations LIM-SAL-2, LIM-SAL-5, LIM-SAL-6 and LIM-SAL-11.
  Genesis admits no edition sale adapter until the uniform-price edition auction lands (15
  wiring calls, was 19). `FixedPriceSale` can be restored from `v1.0.0-rc.1` as a newly
  admitted adapter without redeploying Editions (ADR 0005 §3); `SaleKind.FIXED_PRICE` and
  `DUTCH` stay reserved.
- Auction: EIP-170 headroom for the 7-lens review. `EnglishAuction`'s views move to
  `EnglishAuctionLens`, which its constructor creates (`lens()`, immutable): the auction
  forwards every call it does not declare to the lens through a non-payable, read-only
  `staticcall` fallback (no delegatecall), and the lens reads the auction's storage through
  `storageWords`. No signature, selector or ERC-165 ID changes, and a differential test
  compares every moved view, byte for byte, with the pre-lens build over random sequences;
  a layout test pins every slot and offset the lens reads to the compiler's storage layout.
  A cold view call through the lens costs about 7,000 more Prague gas (LIM-SAL-13), so the
  reads other contracts make on their hot paths stay on the auction: `saleKind`, and a new
  integration view, `auctionClock(saleId)` (`IEnglishAuctionClock`, ID `0x968c7b07`, outside
  `IEnglishAuction` and never reported through ERC-165), which returns exactly
  `auction(saleId).state` and `.endTime` from one cold slot. The edition auction reads its
  1/1 through it (`UniformEditionAuction._oneOfOne` and its lens's `masterTerms`), so `open`,
  a bid near the close, the first settle call and `withdrawBid` while the 1/1 is paused each
  cost 6,900 to 9,200 less Prague gas, and their regression ceilings come down with them;
  `UniformEditionAuction` shrinks by 131 bytes (361 under EIP-170). The English auction goes
  from 52 to 1,849 bytes under EIP-170. ADR 0004's table gains
  `auction`, `minimumBid` and `auctionClock` rows. The deployment records the lens as `EnglishAuctionLens` and `Verify.s.sol` checks its
  address (the auction's first CREATE), its code hash and `lens()`.
- ADR 0005, the edition auction and 6529 Stream Editions
  ([docs/adr/0005-stream-editions-auction.md](docs/adr/0005-stream-editions-auction.md)): the
  owner's D138 to D141 and decisions 1 to 14 of 31 October 2026, the design, the governed
  parameters, LIM-EA-1 to LIM-EA-10 and the delivery plan for v1.0.0-rc.2, with amendment
  pointers in ADRs 0001, 0003 and 0004. Frozen interfaces for the lanes that build it:
  `IUniformEditionAuction` (keyed like the English auction by `saleIdOf(token, id)`), the
  `StepLadder` price table, `SaleKind.UNIFORM_AUCTION`, the museum on `IEconomicsResolver`
  (stubs that revert `NotImplemented` until it lands), `name()` "6529 Stream Editions" and
  `symbol()` `STREAMEDITIONS` on Editions, and the museum behaviour in `IEnglishAuction`'s
  NatSpec. `tools/edition_auction_ref.py`, the reference model, generates golden vectors in
  `test/fixtures/edition-auction/`, checked in CI. This entry alone deploys nothing
  differently: the museum entry sends an unbid 6529 Stream work to the museum, and the entry
  on the edition terms removes the fixed-price and Dutch sales.
- Auction (D140, ADR 0005, owner decisions 9 to 11): an unbid canonical 6529 Stream 1/1 goes to
  the 6529 Network Museum, not to its artist, and so does a work a 30-day currency freeze ends
  unsold, with the standing bid credited back. `EconomicsResolver` implements ADR 0005's
  `museum()`, `museumRevision()` and `setMuseum(expectedRevision, next)` (FUNDS_SETTER, 14 days,
  compare-and-set on its revision; event `MuseumSet`, error `InvalidMuseum`), set at genesis
  from the new `MUSEUM` deploy parameter, which off anvil must be an existing account;
  `Verify.s.sol` reads it back. The auction reads the museum at settlement, so a restrained
  artist no longer holds up an unbid canonical work, and only the museum recorded at
  settlement can claim one whose delivery is pending (AUC-33). The museum branch is gated in
  code on 6529 Stream, which `EnglishAuction` now takes as a constructor argument: any other
  token, federated or listed later by governance, keeps the rc.1 behaviour (its artist), at
  settlement and at the freeze exit. ADR 0004's table gains the no-bid settlement (1 new slot, no new
  account), and LIM-SAL-12 records the museum as a governed address.
- Sales: `src/sales/UniformClearing.sol`, the pure core of the 6529 Stream Editions
  uniform-price auction (ADR 0005), as an internal library (the edition auction's lens runs it, and its settlement sweeps and
  splits the cut step with it): the
  clearing rule in one pass over the steps (the largest count whose revenue is within the
  breadth margin of the best, up to the creator's cap) on `StepLadder`'s prices, the
  first-in-first-out split of the cut step with the settler's departure sweep, and the what-if
  quote. Tested against a brute force over unit bids (10,000 fuzz runs), the reference model's
  golden vectors (every clearing, sweep, bid outcome and quote), the plan's worked traces and
  Halmos proofs (`test/symbolic/UniformClearingSymbolic.t.sol`). `StepLadder` packs its 192
  mantissas as 10-bit fields in 8 words instead of 16-bit fields in 12, every price unchanged:
  227 bytes and about 150 gas a lookup less. `StepLadder.isValid` now accepts only a base
  price that is a power of ten from 10^12 to 10^17 wei (the new `StepLadder.isBasePrice`),
  so every price reads as the table does (ADR 0005 decision 3); the reference model and its
  ladder vectors follow, and `UniformClearing.isValidLadder` stays a superset of every
  ladder governance may set. The reference model
  (`tools/edition_auction_ref.py`) now validates a bid or raise before it changes the book, and
  limits a capped step's entered units to 2^32 - 1 as `InvalidQuantity` states; the golden
  vectors are unchanged.
- Sales: `UniformEditionAuction`, the uniform-price edition auction (ADR 0005, D138 to D141),
  with the stateless `UniformEditionAuctionLens` it creates. Bids escrow ETH on the `StepLadder`
  steps and can be raised, never lowered, and withdrawn only while the 1/1 is paused for a
  dispute. The sale closes 15 minutes after the 1/1's final end, extended by its own soft
  close up to the backstop. A cancelled 1/1 voids it. Settlement runs in permissionless calls
  of bounded gas: at most 24 book words scanned per call, then the FIFO departure sweep in
  chunks. It mints exactly the cleared count through `IMintTarget.mint` as bids are claimed.
  Its views (every view of `IUniformEditionAuction`) are the lens's, answered through a
  read-only fallback; `IUniformEditionAuctionStorage` documents the raw words they read.
  `open` binds the edition to the adapter first (see the Editions entry below). Each settler
  sweeps the departures on its own (its progress kept per sender, each call passing the rest
  of its own sweep; the lens's `sweepOf` and `settlementOrderFor` read it), and the first to
  sweep every one settles the sale, so an order that skips a departure strands only its own
  sender. Its views' departure sort is `O(n log n)`; its genesis
  wiring is the Deploy entry above. Gas rows, with exact slot and account counts, are in
  `test/integration/EditionAuctionGasReport.t.sol`; every settlement call stays within 350,000
  execution gas, at most 228,103 in the worst case measured.
- Editions (ADR 0005 §6, an amendment of the frozen interface): `bindMinter(editionId, item)`
  binds an edition to the adapter whose sale opens it, before the edition exists if need be
  (the master's stored item proves its kind), so two admitted adapters of one kind can never
  both sell an edition and strand one sale's winners. Binding before creation also locks the
  edition's `PRODUCT_EDITIONS` economics, which `createEdition` keeps, so the edition reports
  the split its sale paid. A bound adapter keeps minting its edition after removal, within the
  creator's cap (LIM-EA-10); removal stops new bindings. The `IEditions` interface ID becomes
  `0xe183b26f`. The edition auction's `open` writes 6 new slots (278,235 Prague gas) and
  `createEdition` of an edition it bound 2 (140,201); an edition created unbound still writes 6.
- Tests: the mutation baseline's 78 open gaps are closed
  ([docs/testing/mutation-baseline.md](docs/testing/mutation-baseline.md)). 51 new and 4
  extended tests kill 69 of them (one-sided hash and code-hash comparisons, boundary seconds,
  answers an arbitrary token or resolver may give, costly inputs such as a work with every
  trait slot filled); 2 are re-triaged as equivalent and 1 as defensive, and 6 mutated code #66
  moved into the `Dependency` library, which gains its own suite,
  `test/libraries/Dependency.t.sol` (code, the EIP-7702 refusal, ERC-165, and both sides of
  each code-hash pin). None was a bug. The final suite now kills 90.6% of the 11,735 mutants,
  98.9% leaving out the equivalent ones, and `tools/mutation-floors.json` raises the floors of
  the ten contracts whose rate rose. One limitation found on the way is recorded as LIM-SAL-11
  ([docs/audit/known-limitations.md](docs/audit/known-limitations.md)): a free ERC-20 purchase
  paid by Permit2 still asks Permit2 to move 0 tokens.
- Tests: the mutation baseline's last four contracts, Editions, FixedPriceSale, MintSaleBase
  and GovernanceConfig
  ([docs/testing/mutation-baseline.md](docs/testing/mutation-baseline.md)). The baseline now
  covers 11,735 mutants in 50 contracts: 88.2% killed by the campaign, 90.0% by the final
  suite, 98.3% leaving out the equivalent mutants. 10 new and 6 extended tests close the gaps
  the four shards found (interface IDs below the supported ones, a consent's deadline second, a
  phase that starts after it ends, a sale window over phases in any order, ETH payments above
  their amount or by a permit method, the governance configuration's first grant and selector
  and grant pairs in either order, readback of a lower role, a 100% edition royalty), and
  `tools/mutation-floors.json` gains their floors.

## 1.0.0-rc.1 (2026-10-16)

- Release candidate 1, pre-audit and not production-ready: the code deployed as Sepolia
  rehearsal r3. The release notes,
  [docs/releases/v1.0.0-rc.1.md](docs/releases/v1.0.0-rc.1.md), are linked from the README's
  status table and the docs index. ADR 0004's Sepolia column gives the r3 receipts (an
  amendment note; rows r3 has not run keep r2's receipt or show r3's simulation, marked, and
  r2's column is kept below the table), and the known limitations quote r3. The fork tests take
  r3's inputs: the deploy simulation uses r3's record, holders and manifest, and the VRF test
  the code hash r3 pinned. The delivery plan's status is rewritten for the release.
- Tests: the first full mutation baseline
  ([docs/testing/mutation-baseline.md](docs/testing/mutation-baseline.md)). 9,606 mutants of
  `src/` at 054442d, 88.5% killed by the campaign and 90.4% by the final suite (98.1% leaving
  out the equivalent mutants), with every survivor triaged as equivalent, a gas margin,
  defensive, caught by a Halmos proof, or a missing test. 62 new and 38 extended tests close
  the gaps it found: one-sided comparisons (code hashes, interface IDs, sale kinds, license
  keys either side of CC0), exact bounds and deadline seconds, constructor events, zero amounts
  and indexes past an end. `tools/mutation-floors.json` now holds a kill-rate floor per
  contract, which the weekly mutation run enforces; the open gaps are the next testing lane's
  work list.
- Tests organised by contract and function (F7b). The review-round files (`test/adv/`, the
  `Review*`, `ReviewRound2` and `FollowUp` suites) are folded into the suites of the contract and
  function they test, or into real-stack suites named for the behaviour they pin; no test is
  removed. Test names describe behaviour, and a regression test carries its finding's ID in a
  `/// Regression:` NatSpec line. Mocks live in `test/mocks/<module>/` with one behaviour per
  name: the duplicated Permit2, EIP-2612 token and federation registry mocks are merged, and
  the renderer's and the artist registry's Stream stand-ins are one `StreamMock`.
  [`test/README.md`](test/README.md) maps the tree.
- Sepolia rehearsal r3 (15 October 2026): `main` at `e5fe78c` deployed with r1's Safes and keys,
  a new namespace and its own VRF subscription, and every contract verified on Sourcify with an
  exact match ([record](deployments/11155111/README.md#sepolia-r3-15-october-2026-current)).
  Verify passes on a fork advanced five days; the live Verify is due from 20 October 2026. A
  lifecycle check measures the state-growth diet on chain: a steady-state `start` costs 735,859
  gas against r2's 846,963 ([flows](deployments/11155111/flows.md#r3-the-release-candidate-15-october-2026)).
  r3 is now the current Sepolia instance in the integrator docs. The flow driver
  (`script/sepolia/`) signs the epoch-bound curation approval (#55) and defaults to r3.
- Source quality (F7a). One install check for every dependency, `Dependency` (code, no
  EIP-7702 delegation, ERC-165 where implemented, the pinned code hash), with one error,
  `InvalidDependency(address)`, and one for a pinned dependency whose code changed at use,
  `DependencyCodeChanged(address)`. The content store and the 6529 delegation contract are now
  also refused as EIP-7702 delegated accounts, and the fixed-price and Dutch adapters list a
  token only if it has code, is not delegated and reports `IMintTarget` (as the auction requires
  ERC-721). One shared `InvalidSignature(address signer)`
  and `SignatureExpired(uint256 deadline)` in `SignatureVerifier`. `IStream.InvalidMintRequest`
  is split into errors per Stream rule (`InvalidItemSale`, `InvalidLeadArtist`,
  `InvalidSeedPolicy`, `InvalidLicenseId`, `InvalidWorkTerms`, `TermsCapacityExceeded`, and
  `UnknownCollection`) and moved to `IMintTarget` for malformed calls; a burn or settlement mark
  by an adapter that did not mint the token reverts with `NotMintingAdapter`. Errors the
  implementations declared are declared in their interfaces; those only the fixed-price and
  Dutch adapters raise are on a new errors-only `IMintSale`. Selectors change (no function or
  interface ID does).
- NatSpec: every external and public function, event and error in `src/` is documented, with
  `@param` and `@return` for each parameter and return value, checked by
  `tools/check_natspec.py`. Text that contradicted the code is corrected, and the fixed gas
  allowances state how EIP-8037's state-gas reservoir passes through them under Glamsterdam
  (CALLS-3), with keeper guidance (send at most 2^24 gas).
- Removed the unused `JsonEscape.scriptText` (`HtmlScript.neutralize` is what the renderer
  uses), its tests and its Halmos proof.
- Verify pins Permit2's runtime code hash on mainnet.

- Tests: two stateful invariant suites on the real stack (`test/integration/invariant/`), each
  256 runs of depth 128 in CI with a coverage replay that fails if any action or key path never
  runs. The Stream lifecycle suite drives the package registry, Stream, the records satellite,
  the auction and recovery overrides; the Editions sales suite drives Editions with the
  fixed-price and Dutch adapters, pauses, currency deprecations, governed allowlist and
  economics changes and the revenue escrow. A third suite covers the content store. A `deep`
  Foundry profile (2,000 runs of depth 256) is for a nightly run.
- Tests: opt-in fork tests (`test/fork/`, skipped unless `FORK_MAINNET_RPC` or
  `FORK_SEPOLIA_RPC` is set) against the real 6529 delegation contract through the
  `ConsolidationAdapter`, the canonical Permit2 through the sale adapters, the Chainlink VRF
  v2.5 coordinator on Sepolia, and a full simulation of the deploy script on a Sepolia fork with
  sepolia-r2's Safes and dependencies.
- Tooling: `python -m tools.content cid FILE` computes a file's IPFS CID under the fixed
  profile (CIDv1, sha2-256, raw leaves, 262,144-byte chunks, balanced layout) and its `ipfs://`
  locator, checked against IPIP-0499's fixtures and the real `WorkRecords` locator rule.
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
- Governance (GOV-1): only a guardian, or its scheduler, may cancel a role revocation on
  `WorksAccessManager` (Rule 3, ADR 0002 addendum). Admins keep the stock power to cancel
  each other's other operations.
- Governance (GOV-2): any guardian may suspend a holder of a zero-delay operational role
  (PLATFORM, CURATOR, STORAGE_OPERATOR) at once with
  `WorksAccessManager.suspend`; the holder fails `hasRole`, `canCall` and the manual checks
  built on them. Only an ADMIN grant or revocation (30 days) lifts it. The genesis example
  marks the suspendable roles and lists the manager's own functions, and
  `tools/check_genesis.py` checks both; readback names a suspended holder.
- Deployment (GOV-3): off anvil, `Verify.s.sol` repeats the deploy's holder guards
  (`DeployGuards.checkHolders` and `checkHoldersAgainst`) against the chain as it is now.
- Deployment (GOV-4): off anvil, every admin and guardian Safe needs a threshold of at least 2
  (`ThresholdTooLow`) and owners without code (`NestedOwner`, or `DelegatedOwner` for an
  EIP-7702 delegated owner), and no two of the admin and
  guardian Safes may share a signer, guardians included (`SharedSigner`). Each must run a
  canonical Safe 1.3.0 or 1.4.1 singleton (`NotACanonicalSafe`) with no enabled module
  (`SafeHasModules`) and no transaction guard (`SafeHasGuard`).
- Deployment (DEPS-3): on mainnet the VRF coordinator must be the canonical Chainlink v2.5
  coordinator with its pinned code hash; off mainnet `VRF_COORDINATOR_CODEHASH` optionally
  pins it. On mainnet, `Verify.s.sol` requires the canonical coordinator (recorded and the
  module's live one), Permit2 and delegation contract with their pinned code, and no
  delegation mock.
- Deployment (DEPS-4): off anvil, `Verify.s.sol` requires the entropy module to be its VRF
  subscription's only consumer; on mainnet the subscription owner must be the hot admin Safe.
  A subscription read that fails fails Verify, except off mainnet for a coordinator without
  `getSubscription`.
  The runbook makes that the mainnet setup and lists the coordinator events guardians watch.
- Deployment: `Verify.s.sol` gains an epoch mode (`GOVERNANCE_CONFIG`) so readback passes
  after a governance change such as an admin recovery, and fails on any operation still
  pending on the manager unless `ALLOW_PENDING_OPERATIONS=1`. The admin-recovery runbook
  revokes first and grants after, covers a guardian that cancels the recovery, moves the VRF
  subscription, and re-verifies in epoch mode.
- Deployment: `Deploy.s.sol` refuses an EIP-7702 delegated sender (`DelegatedDeployer`),
  requires an explicit `DEPLOY_NAMESPACE` off anvil, and stops before the broadcast when any
  predictable address under the namespace is taken (`AddressTaken`).
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
  `SeedDelivered` is indexed by content hash. The entropy invariant campaign adds items that
  share content and asserts they read one seed.
- Entropy (DEPS-2): the VRF callback creates no storage slot. The seed overwrites the word
  that held the request ID (`requestOf` reads zero once delivered), so a delivery costs about
  34,000 gas under Glamsterdam (with the DEPS-6 pin check), about a third of the 100,000
  callback floor; the floor's NatSpec and the entropy README give the Glamsterdam figures.
- Entropy (DEPS-5): `lowerCallbackGasLimit(expected, next)` lowers the VRF callback gas limit,
  never below the floor, in the 30-day SUCCESSOR_SETTER class (new genesis selector), so the
  module can follow a coordinator whose maximum Chainlink lowered below the limit. `setConfig`
  stays raise-only.
- Curation (SIGS-1): `IStream.releaseContent(tokenId, contentHash, beneficiary)` is governed
  (PARAMETER_SETTER, 48 hours, new genesis selector) and names the rightful artist from the
  dispute outcome, who must be a registered artist. The package registry reserves the
  released content hash for that artist
  (`releasedTo`, `ContentReserved`); `ContentReleased` carries the beneficiary. The dispute
  runbook adds the guardian's revocation of the copier's roots before the cancel executes.
- Curation (SIGS-2): a curation approval binds the signer's epoch,
  `PackageApproval(packageRoot, evidenceHash, signerEpoch)`. The epoch combines the time the
  signer's CURATION_SIGNER grant took effect with a count of its disables and enables
  (`signerEpoch`), so re-enabling a signer or granting its role again never revives an older
  approval. `approvalDigest` takes the epoch. Each disable and enable also draws a salt from
  `block.prevrandao` into the epoch, and `setVerifier` refuses a verifier installed before.
- Editions (SIGS-4): `createEdition` accepts a package root the registry registered, even if it
  was revoked since. A revocation stops a package's unconsumed items; it no longer strands the
  edition of a master already sold from the root.
- Records (LIFECYCLE-4): a `DISPUTE_OUTCOME` about an ERC-721 token needs the token to exist
  when it is recorded, and an ERC-1155 (edition) subject is refused: an edition's outcome is
  recorded on its master (`UnknownDisputeSubject`). `latestDisputeOutcome` of a Stream token
  with no outcome of its own answers the latest outcome about the item it was minted from, so
  pre-mint outcomes are shown on the work and its edition (the display rule);
  `disputeOutcomeOf` answers a subject's own latest outcome and its chain position, in the
  slot of the chain's count. The precedence of a later outcome
  over earlier ones is documented, with the rule that each outcome restates those it keeps in
  force.
- Pins (DEPS-6): the curation verifier (package registry), the VRF coordinator (entropy
  module, at every request and delivery) and the artist resolver (statement log, at every
  ARTIST authorization) are checked against their pinned code hash at every use, not only at
  install.
- Records (CONTENT-3, LIFECYCLE-3): a locator URI must be a content address with nothing
  after it, `ar://` and a 43-character transaction ID or `ipfs://` and a CIDv1 of the fixed
  profile (`bafkrei`/`bafybei`, 59 characters), in its one canonical spelling. After finalize
  only the PLATFORM role adds locators, and may use all 16 of a file's slots; the artist adds
  them until then.
- Records (CONTENT-1): `openRecord` refuses an `Identity` or `Base64` PREVIEW file over
  `Limits.MAX_PREVIEW_BYTES` (16 KiB stored, `Identity` counted four times; gzip files are never
  inlined, so not bounded). With the content-address locators this restores the 8M `tokenURI`
  budget, now proven on the real stack with every cap at once
  (`test/integration/TokenUriBudget.t.sol`: at most 7.80M Prague gas, `Editions.uri` included,
  about 2.5% under the budget).
- Stream: `createCollection` refuses names with control characters, `<`, `"` or `\`, which JSON
  escaping makes up to six bytes in every work's metadata; the budget proof uses the dearest
  name it accepts.
- Records (CONTENT-4): `syncOnChain` is resumable. Each call checks whole media files up to
  512 chunks (about 4.2M gas cold), keeps its place in the record's first word and emits
  `OnChainSyncProgress`, so a work of up to 32 files of 512 chunks becomes on-chain complete
  over calls that each fit the EIP-7825 cap.
- Records: a license whose key is CC0 must name the deployment's CC0 text (`cc0TextFileId`), at
  `openRecord` and at relicense, so a work that reads `CC0-1.0` always carries the pinned CC0
  legal code and its license never changes. An approved CC0 license with another text cannot
  open (the curation simulation of `openRecord` catches it).
- Economics: `EconomicsResolver.setDefaultLicense` refuses a license whose key is CC0 unless it
  names the CC0 text the resolver was deployed with (`cc0TextFileId`, immutable), since
  `openRecord` refuses a CC0 license with any other text.
- Stream and records (DEPS-6): renderer code-hash pins are checked at use. `rendererOf` (the
  `tokenURI` and `Editions.uri` path) compares the default renderer's code with the hash it was
  installed with, and `WorkRecords.pinnedRenderer` a finalized work's renderer with the hash it
  was pinned with at finalize or the errata repin. Changed code makes the metadata view revert
  (fail closed) until a renderer is installed again.
- Renderer (CONTENT-2): a work whose record file the content store does not know (an approved
  manifest that was never registered) renders core-only metadata marked `incomplete` instead of
  reverting `tokenURI`. To make room, the renderer's `image/` prefix test is one comparison.
- Renderer (CONTENT-5): a record's `trait_type` must be printable ASCII with no backslash
  and no two spaces in a row, and the renderer's own trait names are refused in any case and
  with or without spaces, so a record cannot show a look-alike of a trait the renderer
  vouches for. The check reads names a word at a time and is smaller than the one it replaces.
- Tests: differential vectors for the renderer's text checks against oracles outside Solidity
  (CPython's strict JSON and UTF-8, a WHATWG-tokenizer-checked mirror of `HtmlScript`, the
  trait-name rule), generated by `tools/content/oracles.py` into `test/fixtures/oracles/`
  and read by `RendererOracles.t.sol`; the tooling tests keep them current.
- Renderer: the media-list read has its own gas cap (1,000,000; other reads keep 300,000),
  and `ContentStore.sha256Of` reads one storage word, so `mediaOf` at 32 files needs about a
  fifth of its cap cold instead of nine tenths of 300,000.
- Identity, IDENTITY-1 (ADR 0003 owner decision 6): while a recovery override that would move
  the authority is pending, nobody acts as the artist. `IArtistRegistry.activeAuthorityOf` is
  zero until the override executes, is vetoed or voided, or lapses; 6529 Stream and 6529 Editions
  report it as the sale `creator`, and the package registry (acceptances, moves, move
  revocations), the work records (artist actions and party consents) and `isArtist` (ARTIST
  statements) read it. A no-bid auction settlement waits for the outcome.
- Identity, DEPS-6: the artist registry pins the consolidation source's code hash at install
  (`IArtistRegistry.consolidationSourceCodeHash`) and re-checks it at every use. On a
  mismatch, staging, heartbeats and `refreshStanding` revert with `InvalidSource`, and
  registration and execution skip their standing refresh (`StandingRefreshSkipped`).
- Sales review fixes (F2):
  - QUALITY-7: the fixed-price, Dutch and auction adapters share their money-path rules.
    `claim` reverts with `InvalidRecipient` for a zero recipient and `ClaimFailed` for a
    refused ETH claim in all three; a repeated `pause` or an `unpause` while not paused
    reverts (`SalePaused`, `NotPaused`); EIP-2612 takes only the 65-byte signature; a
    misreported payer balance around Permit2 reverts with `TokenBalanceMismatch`. The
    fixed-price and Dutch payout allowance is renamed `PAYOUT_GAS`, as on the auction.
  - GOV-5: an adapter's `unpause`, and the auction's `resume(saleId)`, are refused with
    `UnpauseTooEarly` until 48 hours after the pause they end, so a guardian can always
    cancel them, including one scheduled before the pause. The adapters record `pausedAt`.
  - MARKET-1: a pause of the fixed-price or Dutch adapter, or a deprecation of a sale's
    currency, stops the sale's schedule too. Phase windows and the Dutch curve move later by
    the halt time (`scheduleDelay(saleId)`), so trading resumes where it stopped. The
    adapters keep `pausedTotal`, and `AssetAllowlist.statusClock` reports when an asset's
    status last changed and its total earlier deprecation time (no new storage slot).
  - MARKET-6: alone, PLATFORM opens an edition sale only on the package's approved terms:
    no leaf-priced phase (prices above or below the package price need the artist) and only
    for a listed edition of FIXED size. An OPEN edition's one-time window, or a federated
    token's sale, needs the artist (`ArtistApprovalRequired`): the creator opens it, or
    PLATFORM relays the creator's signed phase configuration (fixed price). `IEditions`
    gains `formatOf(editionId)`. The unreachable `PriceBelowPackage` error is removed.
  - CALLS-1 (adapter side): the auction's `start` and the fixed-price and Dutch `openSale`
    refuse terms whose seller or fee recipient is the revenue escrow (`InvalidTerms`,
    `InvalidSaleTerms`), since the escrow refuses to be paid as a wallet and such a sale
    could never pay out.
  - LIFECYCLE-1: a bid withdrawn during a dispute pause stays as a reserve that the next bid
    must reach (`minimumBid`, `auction().bid` with no bidder), and the resumed auction runs at
    least the governed duration, whether UNPAUSER resumes it or the pause lapses. With no
    bidder, settlement pays nothing and returns the work to the artist, as before.
  - MARKET-2: deprecating an auction's currency freezes the auction, not just its bids. A
    standing bid cannot settle until the currency is re-admitted, and its bidder may withdraw
    meanwhile; the first `settle` after a re-admission in the auction's last window or after
    its end reopens it for at least the anti-snipe window (the governed duration after a
    withdrawal). With no standing bid, the work returns to the artist as before.
  - Auction: the fee and the increment are computed exactly in 96-bit arithmetic instead of
    `Math.mulDiv` (same results), which frees about 330 bytes for these fixes.
  - LIFECYCLE-4 (the auction's `cancel`): the cited dispute outcome must be the token's own
    latest one (`StatementLog.disputeOutcomeOf`, no item fallback) and must have been recorded
    after the dispute pause: the pause records, in spare bits of the sale's third slot, the
    chain position a later outcome must reach. An outcome recorded before the pause, or one
    about the package item, cannot cancel the auction.
  - MARKET-3: a federated auction pays its registry fee share to the economics resolver's
    federated network fee recipient, never to the recipient the token reports, as the
    fixed-price and Dutch adapters do. The auction's constructor takes the economics resolver
    (ERC-165 checked) in place of the asset allowlist, which it derives from the resolver;
    `DeployV1` passes the resolver.
  - MARKET-5: a federated contract delisted while its auction runs takes no more bids
    (`TargetNotAllowed`), and the auction settles by crediting the high bid back and giving the
    work to its artist, as with no bid.
  - MONEY-1: auction delivery never depends on a payout. An ERC-20 settlement payout runs in
    its own call frame (`settlePayout`, callable only by the auction, with 1,000,000 gas the
    settler must forward); if it fails even through the escrow (the token changed behaviour or
    blocks the auction), the amount is credited to the wallet and the work is still delivered.
    `claimFor(account, currency)` lets anyone send an account's credits to that account, so a
    split wallet's credited payout can be paid once the token works again. ETH payouts are
    unchanged.
  - CALLS-5: the auction's NatSpec no longer claims that no transfer can strand a token in it:
    only safe transfers are refused, and a token sent with a plain `transferFrom` is stranded.
    A governed rescue does not fit the auction's remaining EIP-170 headroom; it is documented.
  - Review follow-ups:
    - MARKET-2 (L2, L3, L7): while a sale's currency is deprecated nothing settles, sold or
      unsold; after 30 days frozen anyone may end the sale (the standing bid is credited back,
      the work goes to the artist). Every reopening, after a dispute pause or a freeze, gives
      the governed duration, or the sale's anti-snipe window if longer. ADR 0003 records both
      deviations from ADR 0001 §12 (a resumed auction gets at least the governed duration even
      with a standing bid; a 30-day deprecation ends live auctions), and the guardian runbook
      says when to re-admit a currency to keep its auctions alive.
    - LIFECYCLE-4 (L4): `cancel`, like `resume`, waits 48 hours from the pause.
    - MONEY-1 (L5): `claimFor` refuses ETH; it serves credited ERC-20 payouts.
    - MARKET-3 (L6): a federated start checks the network's federated fee recipient, not the
      token's own. The sales README lists, as a federation install prerequisite, that this
      recipient must stay nonzero while a registry is installed.
    - MARKET-6: PLATFORM closes only a sale it opened without the artist's approval. A Dutch
      sale the creator opens counts as approved, as on fixed price. While the creator
      resolves to zero (a pending recovery override), PLATFORM may close any sale.
    - Re-admitting a deprecated currency waits 14 days from the deprecation
      (`ReadmissionTooEarly`), so a re-admission scheduled ahead cannot undo it at once.
    - The auction refuses an expired PERMIT or PERMIT2 payment with `PaymentExpired`, as the
      fixed-price and Dutch adapters do (the error moves to `ISaleAdapter`).
    - `scheduleDelay` is in `IFixedPriceSale` and `IDutchSale`. Overlapping halts (an adapter
      pause during a deprecation) count twice; the sales README and the guardian runbook say
      so, and tests pin the behaviour.
    - The auction's bound constants (`MIN_DURATION`, `MAX_DURATION`, `MIN_EXTENSION_WINDOW`,
      `MAX_EXTENSION_WINDOW`, `MIN_INCREMENT_SHARE`, `DELIVERY_GAS`, `DELIVERY_RESERVE`) are
      internal, which frees 292 bytes; `setConfig`'s NatSpec states the bounds.
    - The review's auction invariant handler is adopted (`AuctionHaltsInvariant.t.sol`).
- Docs: `docs/security/internal-review-2026-10.md` publishes the internal adversarial review of
  commit `2cd1e34` by AI agents (not an external audit): the findings (0 Critical, 0 High, 9
  Medium, 30 Low, 1 Info after deduplication) and how each was resolved (fixes in #51 to #57),
  the decisions and accepted risks, the coverage record and the residual risks for the external
  audit. SECURITY.md and the docs index link to it.
- Documentation: a current-state protocol specification (`docs/spec/`, one page per area with
  state machines, call sequences with roles and delays, rules linked to their tests, events
  and failure modes); an auditor pack (`docs/audit/`: scope with nSLOC and bytecode sizes,
  trust assumptions, threat model, invariants, known limitations, build and budgets); an
  integrator guide (`docs/integrators/`: reading a work, events and indexing, addresses, ABIs
  and interface IDs, buying and settling, storage); a glossary; and a rewritten README and docs
  index. `tools/gen_role_matrix.py` generates the role and permission matrix
  (`docs/audit/roles.md`) from `config/genesis.example.json`, checking each selector against
  its signature and each delay against its role; CI's Docs job runs it with `--check`.
  `tools/check_docs_facts.py` checks the facts the docs quote from the code (cited test names,
  interface IDs, event topic0 values, nSLOC and bytecode sizes) in the Docs and Contracts
  jobs; `--update` refreshes the figures.
- Gas, the state-growth diet (lane F8, ADR 0004): under Glamsterdam each new storage slot
  costs about 111,000 gas on Sepolia, so the hot paths write fewer.
  - Fixed price (QUALITY-1, integrator decision): an uncapped public phase (no root, no
    `walletCap`) records no purchase count, so a per-wallet cap counts only the purchases
    made in capped phases; `purchased` stays zero for such a phase.
  - 6529 Editions (QUALITY-2): `mint` returns only the sale kind of its terms. The adapters
    apply the terms they locked from `primaryTerms` when the sale opened.
  - Fixed-price and Dutch listings (QUALITY-4): each adapter stores a fee recipient once
    and references it by index, and a phase is one storage word plus its root. `openSale`
    with one public phase writes 6 new slots instead of 8; the adapter's first sale
    registers the fee recipient (8 slots; the counter shares `nextSaleId`'s word, which is
    now a `uint64`). A 65,536th fee recipient fails with `InvalidSaleTerms`.
  - 6529 Editions (QUALITY-5): the record is packed behind the unchanged `edition` view.
    `createEdition` writes 7 new slots instead of 9 (a Dutch edition 9 instead of 13), and a
    purchase writes only the holder's balance.
  - 6529 Stream (QUALITY-6): a token keeps two words, and the lead artist with the locked
    economics is one terms word shared by the artist's works, at the position its hash
    names or in an overflow range. A start under existing terms writes 5 new slots, 6 with
    a bid. A first start under new terms (an artist's first, or every artist's first after
    an economics change or through a newly admitted adapter) writes 6, 7 with a bid, as
    before, so the ADR 0004 maxima stay 6 and 7. Accepted limitation: on a collision of the
    terms' 23-bit position, which a curated artist can force by grinding an address, that
    first start writes one slot more and can exceed 350K with a bid. A re-rate writes the
    terms word for its new rate if no work has it yet.
  - Identity: `activeAuthorityOf` is one storage read: a `restrained` flag beside the
    authority marks a pending override that moves it (about 2,200 gas less per creator read).
  - Tests: the integration gas report adds rows for an artist's first start (with and
    without a bid, and two-party with a bid, the binding row of the 350K budget), a
    re-rate, `openSale` at steady state and on the adapter's first sale, and a Dutch
    `createEdition`, `openSale` and `purchase`, and lowers the counts and ceilings.
    `StreamTermsInvariant.t.sol` runs 36 real collisions of the terms positions, and
    `StreamTermsGrind.t.sol` reproduces a ground one.
- Tests: test strength is measured. `tools/check_coverage.py` reports line and branch
  coverage per src/ contract from `forge coverage` (under a new `lite` profile) and fails
  when a contract drops below its floor in `tools/coverage-floors.json`.
  `tools/mutation.py` runs mutation testing with `slither-mutate` (already pinned with
  Slither), one shard per src/ file, re-checks survivors against the whole suite, adds a rule
  that moves every integer constant, and gates kill rates against per-contract floors (none
  recorded until the first full baseline). `test/symbolic/` holds
  Halmos proofs for the base64 alphabet check, the license-ID rule, `BoundedCall`, the
  curation signer epoch, the split payee rules and the text libraries; Halmos 0.3.3 is pinned
  in `requirements-tools.lock`. `docs/testing/README.md` describes every layer of the suite.
  New tests close cheap coverage gaps (JSON navigation over malformed text, `SpdxId`, a token
  that refuses `approve`, a statement in no role, a delegation contract without code, a
  truncated role revocation) and the gaps mutation testing found so far (UTF-8 leads cut at a
  chunk end, escape letters, reads past the end, odd token return shapes, the resolver's
  bounds, an exact Dutch payment).
- CI: `forge test` runs in three parallel parts (unit, fuzz and integration; the economics
  invariants; the other invariants) beside a Build and checks job; the required check
  Contracts is the summary of all four. Deep invariants (the `deep` profile) and the fork tests
  run nightly in `nightly.yml`.
- CI: `strength.yml` runs after every merge to `main`, nightly and on demand, not on pull
  requests (the organisation's runners are shared). Coverage runs `forge coverage`, prints the
  per-contract table in the job summary and fails when a contract drops below its floor.
  Symbolic (Halmos) runs every proof in `test/symbolic` and fails unless all of them pass. The
  coverage and mutation tools' unit tests run in Build and checks on every pull request. A
  weekly workflow (`mutation.yml`, also on demand) runs every mutation shard as its own job,
  eight at a time, and, once floors are recorded, fails when a contract's kill rate drops
  below its floor; a merge that changes it or the tool runs one small shard.
- Docs: the module READMEs under `src/` are rewritten as code maps (what the module is for,
  its files, entry points with spec rule IDs, developer notes on storage, bytecode headroom,
  gotchas and tests, and links), each about 800 words or fewer (28.3K words to 8.5K). Facts
  the specification, the events page, the role matrix, ADR 0004 or the known limitations
  already own are linked instead of repeated, and stale statements are corrected. The few
  facts only a README held move to the specification (the entropy request gate's rationale and
  subscription notes, the sale adapters' resolver and allowlist install checks, the script
  rewrite cases and the `dependencies` test of the page around a script, and the shared set of
  a file's locator URIs). Known-limitation and integrator links that cited README sections now
  cite the specification. ADR 0002's addendum and ADR 0004 get amendment notes (a revocation or
  the holder's own `renounceRole` also lifts a suspension; later ceilings are in the table),
  ADR 0004's commentary cites its table instead of repeating its figures, AGENTS.md and
  CONTRIBUTING.md state the one-owner-per-fact rule, and every page that pointed at PR #58 or
  at the testing page by URL now links `docs/testing/README.md` relatively.
