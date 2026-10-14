# ADR 0003: Build-time decisions for v1

Status: Accepted by the delivery owner (Claude Code, acting for the repository
owner), 11 October 2026. Amends [ADR 0001](0001-v1-scope.md) and extends
[ADR 0002](0002-access-manager-hardening.md). Its gas budgets are amended by
[ADR 0004](0004-gas-budgets-under-glamsterdam.md).

The owner's decisions on the items this ADR left open are recorded in
[Owner decisions](#owner-decisions-11-october-2026).

## Problem

ADR 0001 fixed v1's scope before any v1 code existed. Building the modules
showed four kinds of gap:
- some rules could not be met as written;
- some rules were ambiguous;
- some rules were unsafe in detail;
- some rules conflicted with the 16,777,216-gas per-transaction cap that
  EIP-7825 (Fusaka) introduced.

Independent adversarial reviews of each module produced the decisions below.
Each records what changed and why, so the code, the tests and the ADRs agree.

## Decision

### Package format and curation (amends ADR 0001 §3)

- **Hashing is ABI encoding, not RFC 8785 JSON.**
  - Package items are hashed with `abi.encode` through `WorksHashing`: a
    domain-separated, double-hashed leaf, compatible with OpenZeppelin's
    `StandardMerkleTree`.
  - Contracts cannot canonicalise JSON within the auction-start gas budget.
    Off-chain tools compute the same bytes with standard ABI encoders.
- **Media is fixed at approval.**
  - An item commits to a hash over every media file (file ID and decoded
    SHA-256), not just the primary file.
  - Descriptive metadata (the work record) stays editable until finalize.
- **Uniqueness and its limits.**
  - Uniqueness keys on the item's declared content hash, the decoded SHA-256 of
    the primary media.
  - The on-chain check is defence in depth. The curation signer must verify
    every declared SHA-256 against the decoded bytes, and its tooling must
    simulate `openRecord` before attesting.
  - Base64 is decoded strictly.
- **Releasing content after a dispute.**
  - After an upheld dispute burns a token, PARAMETER_SETTER calls
    `IStream.releaseContent` (48 hours), naming the rightful artist the
    dispute outcome identifies. (Amended by the 14 October 2026 review,
    SIGS-1; the release was first permissionless.)
  - That reserves the content hash for that artist's items and tombstones the
    copier's item, so it can never be consumed again.
- **Guardian controls over curation.**
  - The guardian can revoke a package before it is registered.
  - The guardian can disable a curation signer immediately and one way.
    Re-enabling is in the 30-day class.
  - At least two signers are provisioned at genesis.
- **Allowlist prices below the package price need the artist's consent.**
  - The signed phase configuration binds the resolved currency, the package
    price and a typed phase list.
- **Statement subjects before mint.**
  - A statement about a work that is not yet minted uses the subject
    `(address(0), uint256(itemHash))`.
  - Artist statements need a minted token.

### Token model and storage (amends ADR 0001 §4 and §8)

- **Stream is split in two.**
  - **Core token (`Stream`):** the ERC-721, mint and burn, royalties,
    collections, the edition link and `tokenURI` forwarding.
  - **Records satellite (`WorkRecords`):** the work record, finalize, licence,
    renderer pin, locators and preferred location.
  - One contract with the full surface would exceed EIP-170.
- **The work record is a content-store file** (JSON, `Identity` encoding, one
  chunk at most).
- **Record access.**
  - Views and mutators for a token revert with `RecordNotOpen` until
    `openRecord` runs.
  - `openRecord` is permissionless and checks the committed media.
  - The renderer falls back to core-only metadata until the record is open.
  - An invalid record also renders as core-only metadata, marked
    `"record_status":"invalid"`. It never reverts.
- **Preferred location: the most specific setting wins.** The order is:
  1. the file override;
  2. the collection setting;
  3. the global setting;
  4. the first registered locator.

  ADR 0001 §8 listed these in the opposite order.
- **Locator kinds.**
  - Locators are ARWEAVE and IPFS only. HTTPS is dropped because its content can
    change.
  - On-chain copies are served once the file is complete.
  - The artist and the platform each have a quota of 8 locators.
- **Content store.**
  - A file holds at most 512 chunks (about 12.58 MB). Registering a manifest
    must fit the Fusaka transaction cap.
  - Two full chunks (about 49 KB) fit in one transaction, not the 72 KB stated
    in ADR 0001 §8. (Pre-Glamsterdam: under Glamsterdam it is one full chunk
    per transaction; see the
    [content module](../../src/content/README.md#upload-flow) and
    [ADR 0004](0004-gas-budgets-under-glamsterdam.md).)
  - Encodings are `Identity`, `Gzip`, `Base64` and `GzipBase64`.
  - The file ID binds the chunk list, length, encoding, MIME type and decoded
    SHA-256.
- **Rendering inline media.**
  - Inline media must be stored as base64 and attested once through
    `ContentStore.attestBase64`, a permissionless strict-alphabet check, before
    the renderer copies it.
  - `Identity` media inlines only up to about 32 KiB, because encoding it
    on-chain costs about 80 gas per byte.
  - Gzip media is never inlined in v1.
  - `fullTokenURI` inlines up to 1 MiB of base64-stored media.
  - `tokenURI` stays at or under 8M gas for every record within bounds. The
    JSON scanner caps values, escapes and nesting.
- **Licence identifiers.**
  - `spdxId` keeps its original case, from the character set `[A-Za-z0-9.+-]`.
  - Comparisons use `licenseKey = keccak256(lowercase(spdxId))`. CC0
    irrevocability is enforced on that key.
  - Other "more permissive" judgements rest on the artist's consent plus
    governance.
  - `license_url` links to spdx.org, which is HTTPS and can change. It is an
    accepted deviation, and the licence text stays in the content store.
- **Finalize** requires the record file to be complete on-chain.

### Sales and auctions (amends ADR 0001 §5, §6 and §9)

- **Starting an auction costs at most 350K gas at steady state, not 300K.**
  - Reaching 300K would need every optimisation at once. The measured design
    sits at about 270–300K.
  - The first start in an empty collection or custody is measured separately.
  - Amended by [ADR 0004](0004-gas-budgets-under-glamsterdam.md): 350K is
    Prague gas, with at most 6 new slots (7 with a bid).
- **Opening bid and increments.**
  - The first bid must be at least `max(openingBid, 1 wei)`, so a zero bid
    cannot claim a work.
  - The increment floor is locked at the first bid.
  - The opening bid is a governed compare-and-set value. It can move in both
    directions, under a ceiling. The raise-only rule in ADR 0001 §13 covers gas
    parameters.
- **Currency.**
  - The adapter resolves and locks the currency.
  - A non-zero fixed price must name an explicit currency. The default currency
    is allowed only for zero-price sales.
  - Deprecating a currency halts running sales in it. Refunds and withdrawals
    are never blocked.
- **No-bid outcome.** With no bids, the token goes to the artist's current
  authority, resolved at settlement.
- **Delivery.** The winner may name a delivery address. A failed delivery
  becomes a pending claim.
- **Emergency pause.**
  - Every sale adapter has one: PAUSER pauses and UNPAUSER unpauses.
  - On the auction it blocks only new starts. Bids on live auctions continue.
- **Editions.**
  - An edition opens only after its master's sale settles.
  - It takes the master's current royalty rate.
- **Fixed-price allowlists.**
  - The allowlist leaf binds chain, adapter, token, ID, phase, account, cap and
    price.
  - Per-wallet counts persist across reopened sales.
  - One sale may be open per edition, and anyone may close a sale whose phases
    have all ended.
- **Dutch sales** have no clearing price and no rebate.
- **Randomness requests happen before minting (amends §9).**
  - Anyone may call `requestSeed` for an approved, unconsumed VRF item. Starting
    the auction requires the seed to have been delivered.
  - Chainlink VRF v2.5 never expires a request, so a retry adds a request and
    the first delivery wins. The minimum retry delay is 3 days.
  - The module uses a dedicated subscription. Chainlink's `migrate` cannot be
    used with it.

### Economics (amends ADR 0001 §7)

- **Split wallets.**
  - A split wallet has at most 64 payees, not "any number", to fit the
    transaction gas cap.
  - Artist-resolved payees are pull-only. Only the artist's current payout
    address, or its signature, can release their share. Recovery therefore
    covers balances already accrued.
  - A split wallet cannot be an artist's payout address.
- **Escrow recovery.**
  - Escrow terminal recovery moves credits to a replacement wallet with an
    identical payee configuration.
  - No account's share changes, so the consent ADR 0001 §7 requires is
    satisfied trivially.
  - A credit owed to an account that is not a split wallet, such as the
    network fee recipient's Safe when a token blocks it, moves only to the
    replacement that account names itself on the escrow
    (`consentToRecovery`), through the same governed `recover`. That is the
    consent ADR 0001 §7 requires, given explicitly and once per recovery: the
    move consumes it (review of 14 October 2026).
  - The fee recipient's share in existing royalty wallets is not escrowed: as
    a fixed payee, it releases that share to another account with
    `releaseTo`.
- **Asset allowlist.** Every admission, deprecation and floor change carries a
  revision counter for compare-and-set.
- **Royalty receiver.**
  - The receiver is derived from the payee configuration through the pinned
    split factory, not stored.
  - It costs one external view call in `royaltyInfo` (about 25K gas), which
    reverts and never returns zero when gas runs short.
  - This is an accepted deviation from ADR 0001 §7's "no external call" wording.

### Identity and recovery (amends ADR 0001 §11)

- **Artist IDs.** An artist ID is `uint256(uint160(first authority))`. The
  registry address never changes, and the consolidation source can be swapped
  inside it.
- **Override acceptance.** An override that changes the authority needs the new
  authority's acceptance. The acceptance is single-use by digest, not by nonce:
  a nonce would let a key thief stall recovery.
- **Sticky standing.**
  - The registry keeps a snapshot of each artist's established wallets.
  - A wallet that stops being consolidated keeps its standing to cancel for 30
    days, with public events.
  - This makes good on ADR 0001's rule that a thief cannot strip the artist's
    wallets of standing, even before staging.
- **Payout freeze.** The payout returns zero only while a pending change or
  override would move it. A change that cannot execute is cleared rather than
  left blocking.
- **No return to an earlier authority (review finding SIGS-3, 14 October
  2026).** A change's new authority must be the current authority or an
  account that has never been an authority, of any artist; a return (A, then
  B, then A) reverts with `AccountTaken`, for STANDARD changes and overrides.
  - Why it suffices: every consumer of an artist's signature (move
    authorizations, package acceptances, fixed-price consents, record consents,
    signed ARTIST statements) checks it against the current authority when it
    is used. A key the artist rotated away from is never that again, so the
    signatures it left unused never verify again. No typehash binds an
    authority epoch.
  - The trade-off: an artist can never return to an earlier key or wallet, not
    even through governance. A recovery, or a rotation back from a temporary
    device, needs a fresh key or Safe.
  - The residual: a new authority that is an ERC-1271 or EIP-7702 wallet and
    accepts the old key's signatures revives them. That is the artist's own
    configuration of its new authority.
- **Activity that resets the one-year dormancy clock:**
  - registration;
  - a staged change;
  - a heartbeat;
  - a cancel by the old key or a captured wallet;
  - a nonce revocation;
  - an executed change.

  Governed overrides and guardian vetoes do not count.

### Disputes and statements (amends ADR 0001 §12)

- **Upheld disputes.**
  - Upheld is a 48-hour governed `cancel`. It must cite the recorded
    `DISPUTE_OUTCOME` statement, and is accepted while the pause is live
    (inclusive of its last second).
- **Reserved statement kinds.**
  - `DISPUTE_OUTCOME` is reserved to PLATFORM, and `CURATION_EVIDENCE` to
    CURATOR.
  - Each subject stores its latest dispute outcome, so metadata can show it.
- **Governance manifests.** `GOVERNANCE_MANIFEST` statements are written only
  through `appendGovernanceManifest` (30-day class). That is the only path the
  AccessManager may sign.
- **Artist statements and the resolver.**
  - An artist statement records the resolver that vouched for it.
  - The resolver is replaced in the 30-day class.

### Governance (extends ADR 0002)

- **No shared SYSTEM role.**
  - Contract-to-contract calls use per-pair, one-time bindings. Each binding
    checks ERC-165, rejects EIP-7702 delegated accounts and verifies the
    satellite points back to the same token.
- **Genesis wiring.**
  - The genesis configurator holds ADMIN with no delay until it renounces.
  - Before renouncing, it performs every binding and minter admission, so the
    system can operate from genesis.
- **Minting.**
  - Minting checks an admitted-adapter mapping, set in the 30-day class.
  - The adapter that minted a token may still burn it after an upheld dispute,
    even if it has since been removed.
- **Selector classes added to the ADR 0002 table:**

| Function | Class |
| --- | --- |
| `RevenueEscrow.recover` | Funds and recipients (14 days) |
| `StatementLog.appendGovernanceManifest` | Verifier and successor (30 days) |
| `StatementLog.appendCurator`, `appendPlatform` | Zero-delay CURATOR, PLATFORM |
| `AssetAllowlist.deprecateAsset` | Immediate, GUARDIAN |
| Sale adapters `openSale`, `closeSale` | Zero-delay PLATFORM |
| Sale adapters `setTarget`, `setFederationRegistry` | Verifier and successor (30 days) |
| Sale adapters `pause` / `unpause` | PAUSER (immediate) / UNPAUSER |
| Auction opening bid | Standard (48 hours), compare-and-set, ceiling |
| Entropy `setCoordinator` | Verifier and successor (30 days) |
| Entropy `setConfig` | Standard (48 hours) |
| Stream and Editions `setAdmittedMinter` | Verifier and successor (30 days) |

### Decisions from integration (11 October 2026, later)

- **Records are at most 12 KiB.** `Limits.MAX_RECORD_BYTES` drops from 24,575 to
  12,288 bytes. At 24 KiB, ordinary multi-byte or escape-heavy text cost the
  renderer more than the 8M `tokenURI` budget, because validating UTF-8 and
  escapes costs per byte. Every escape also counts against the scanner's budget.
- **Record content limits.**
  - A record may carry at most 32 attributes.
  - Each attribute may use only the standard keys `trait_type`, `value`,
    `display_type` and `max_value`.
  - Keys, values and escapes share one 1,024-unit budget, with at most 512
    escapes.
  - Inline scripts are capped at 8 KiB. Larger scripts are served by locator in
    `tokenURI` and in full by `fullTokenURI`.
  - With every cap filled at once, `tokenURI` measures at most about 7.8M gas.
- **Opening a record never fails.** `openRecord` stores the approved record and
  licence as committed. The structural checks (complete, one `Identity` chunk,
  within the bound, licence text registered) run at `setRecord`, `finalize` and
  `relicense`. An invalid record renders as core-only metadata until the artist
  fixes it.
- **Finalize requires the licence text on-chain.** Deployment therefore uploads
  the default CC0 text before any work can finalize. A CC0 work may be
  relicensed to CC0 with a corrected text file; leaving CC0 is still refused.
- **The start-gas gate is for a single artist.** (Amended by
  [ADR 0004](0004-gas-budgets-under-glamsterdam.md), which has the current
  figures.) The 350K steady-state gate
  applies to `start` and `startWithBid` for a work with one artist. Each extra
  party adds a few thousand gas, which is measured and reported but not gated.
  Measured on the integrated stack, steady state, whole transaction:

  | Measure | Gas |
  | --- | --- |
  | `start` | about 276K |
  | `startWithBid` | about 317K |
  | Two-party `startWithBid` | about 325K |
  | `settle` | about 176K |

  One-time costs are measured but not gated:
  - the first work ever, about 437K;
  - the first bid under a new set of sale terms, about 387K, which happens after genesis, a new currency, or a change to the opening bid or the auction configuration.
- **Default currencies are set at genesis.** Genesis wiring may call
  `AssetAllowlist.setDefaultCurrency`, so each product's default (ETH) exists
  from the first block. Without it, default-currency works could not start for
  14 days. This is a scoped exception to the 14-day funds class in ADR 0002: at
  genesis only an already active asset (ETH) can be set, and later changes keep
  the 14-day class.
- **Deployment guards.** Outside a local test chain, the deploy refuses:
  - holders without code (Safes must exist first);
  - fewer than three guardians or two curation signers;
  - a selector map or wiring that differs from the committed genesis policy;
  - an unpinned CC0 text;
  - silently dropped modules.

  The readback verifies every address and constructor parameter against the
  chain, not against the deployment record.
- **Settlement hook.** `markPrimarySettled` belongs to `IMintTarget`, so every
  token a shared adapter serves implements it. Editions implements it as a
  no-op.

## Security impact

- **Closed:**
  - JSON injection through unchecked base64 media;
  - unbounded `tokenURI` gas;
  - a zero bid claiming unsold works;
  - allowlist cap resets;
  - sale prices that change meaning when the default currency changes;
  - a thief stripping an artist's cancellers before staging;
  - keepers pushing an artist's accrued balance to a lost key;
  - selective re-rolls of late randomness deliveries;
  - a content hash locked forever by a copier;
  - unopenable records freezing a work.
- **Residual and accepted:**
  - Before the 6529 chain, curation rests on a trusted signer and its tooling
    obligations.
  - A hostile approved package can spend one randomness draw per VRF item until
    a guardian revokes it.
  - Zero-price artist-approved allowlist entries pay no network fee.
  - Anyone who can send one transaction from an artist's key, or from a
    use-case-998 sub-delegate of it, can consolidate their own wallets, before
    or after a hijack. Once a refresh records them and their consolidations
    stay live for 30 days, those wallets can contest recovery overrides; they
    can fill the standing snapshot's free slots at once. Revoking such a
    consolidation and refreshing before its 30 days end removes it.
    A contested override no longer stalls: a TDH vote decides it (see
    [Owner decisions](#owner-decisions-11-october-2026)).
  - Standing protects only wallets that a refresh has recorded. Artists call
    `refreshStanding` after linking a wallet, prompted by 6529.io.

## Owner decisions (11 October 2026)

**1. Contested recovery overrides go to a TDH vote.**
- When a captured wallet cancels a recovery override, the override moves to a
  contested state instead of being deleted. Further cancels have no effect.
- While it is contested, the payout stays frozen if the override would move
  it, so a key holder cannot collect during the dispute.
- A governed `resolveContested` action decides the outcome, in the 30-day
  class. It must cite the PLATFORM statement in the statement log that records
  the TDH vote's outcome.
  - Upholding executes the override.
  - Voiding deletes it and unfreezes the payout.
- A guardian may still veto. A contested override that nobody resolves expires
  after 365 days.
- Until the 6529 chain exists, the vote is off-chain, and the admin Safe is
  trusted to execute its result. This is the same trust model as every other
  governed action.

**2. A cold recovery admin Safe.** A second admin Safe holds only ADMIN.
- It has distinct signers and is recommended at 3-of-5, on hardware wallets
  kept apart.
- It is used only to replace a compromised hot admin. It schedules the hot
  admin's removal (30 days), which the hot admin cannot cancel, then appoints a
  new hot admin.
- Off a test chain, the deploy requires both admin Safes.

**3. Three guardian Safes, 2-of-3 each.** Their signers are independent of
the admin Safes, they are monitored so at least one can respond within hours,
and pause and unpause have separate holders. The deploy requires at least
three.

**4. Sepolia setup.**
- Throwaway signers, with the mainnet structure and thresholds.
- A Chainlink VRF subscription is set up, so VRF works are available.
- The 6529 delegation contract is deployed from its verified mainnet source
  where possible; otherwise the faithful mock is used.
- Artists pay for their own `refreshStanding` calls, prompted by 6529.io when
  they link a wallet. A network-paid keeper is an optional safety net.

**5. The CC0 legal text is a test fixture.** The official file (7,048 bytes,
SHA-256 `a2010f34…0499`) is committed, so tests and dry runs use the real text.

## Open items

- **Re-measure on Sepolia:** start gas and the `tokenURI` and inline-threshold
  matrix, with the real Chainlink coordinator and the 6529 delegation contract.
