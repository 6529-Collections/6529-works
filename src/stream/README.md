# stream

6529 Stream: the one shared, network-curated ERC-721 that holds every curated
1/1, split into a core token and a records satellite (integrator decision D1).
Governed by [ADR 0001](../../docs/adr/0001-v1-scope.md) §4 (token model), §5
(permissionless start), §7 (royalties), §8 (works, content, storage and
preferred location), §9 (seeded works), §10 (permanence) and §12 (disputes),
with the "Core" row of the §17 reuse plan.

| File | Interface | Role |
| --- | --- | --- |
| `Stream.sol` | [`IStream`](../interfaces/IStream.sol), [`IMintTarget`](../interfaces/IMintTarget.sol) | The ERC-721 core: minting for consumed package items, supply and burns, collections and serials, the terms locked at mint, `royaltyInfo`, the edition link, the marketplace owner and contract URI, `tokenURI` forwarding. |
| `WorkRecords.sol` | [`IWorkRecords`](../interfaces/IWorkRecords.sol) | The records satellite: descriptive record files, media, licenses, ARTIST seeds, the state hash, finalize and renderer pins, on-chain completeness, amendments, locators and preferred location. |
| `SpdxId.sol` | none | The license-ID rule Stream applies at mint and `WorkRecords` at deploy and relicense: 1 to 64 bytes of `[A-Za-z0-9.+-]`, in the ID's original case, one 256-bit mask lookup per byte. |

Tests are in [`test/stream/`](../../test/stream) and mocks of other lanes'
contracts in [`test/mocks/stream/`](../../test/mocks/stream).

## Core token

- **Minting.** Only adapters in the admitted-minter mapping
  (`setAdmittedMinter`, 30-day class) may mint, into their own custody, for an
  item the package registry consumes in the same call. Stream checks what the
  registry does not: the auction sale kind on both the item and the adapter, an
  existing collection, a coherent seed policy, a license ID `WorkRecords`
  accepts, and a delivered VRF seed.
- **Curation obligation.** The media commitments `openRecord` checks (1 to 32
  files, the PRIMARY first and alone, its SHA-256 equal to the item's
  `contentHash`) are not visible at mint, so a mis-committed item would mint
  and never open. The curation signer's tooling MUST simulate `openRecord` for
  every item before attesting it. This is a trust obligation, not an on-chain
  check.
- **IDs.** One chronological global counter from 1; collections keep their own
  serials from 1. A burn leaves a gap; IDs are never reused. The governed
  `releaseContent(tokenId, contentHash, beneficiary)` (PARAMETER_SETTER, 48
  hours) then reserves the burned work's content hash for the rightful artist
  the dispute outcome names.
- **Burns.** Only the adapter that minted a token can burn it, while it holds
  the token and before the primary sale settles: the auction's cancel after an
  upheld dispute. The gate is the minting adapter's index, not current
  admission, so an adapter removed mid-dispute can still cancel, and another
  admitted adapter holding the token never can. After a sale nothing is
  confiscated.
- **Start gas.** A mint writes the ERC-721 owner and balance, one shared counter
  word, the collection's counter word and three work words: the seller, serial,
  collection, kind, seed policy and flags; the lead artist ID, royalty rate, fee
  share, fee-recipient index and minting-adapter index; the item hash.
  Everything else is in `WorkMinted` and in the published package.
- **Royalties.** The rate is stored; the receiver is derived. With no fee it is
  the seller; otherwise it is the split factory's salt-zero wallet for the
  canonical payee list of fee recipient and seller. `royaltyInfo` makes that
  one view call and nothing else, so a gas shortfall reverts and never returns a
  zero royalty. The amount is `floor(price * rate / 100,000)` without overflow.
- **Settlement.** The minting adapter calls `markPrimarySettled` at settlement,
  before delivery; it gates edition creation, and `linkEdition` checks it too.
- **Fee terms.** A fee share of zero may come with a zero fee recipient; a
  nonzero fee share needs a recipient other than the seller.
- **Wiring.** `WorkRecords` and 6529 Editions are bound once each, with ERC-165
  checks, EIP-7702 rejection and a check that the target serves this Stream
  (`stream() == address(this)`). Every installed dependency is checked the same
  way; renderers are also pinned by code hash. `coreOf` is the cheap per-work
  read the satellites use, including the current royalty rate an edition
  inherits.

## Records satellite

- **Opening.** Nothing is written at mint. `openRecord` is permissionless: it
  checks the item against the core's item hash, the media list against
  `mediaHash`, the primary's SHA-256 against `contentHash`, every file's
  SHA-256 against the content store's declaration, and every `PREVIEW` file's
  size: at most `Limits.MAX_PREVIEW_BYTES` (16 KiB stored, an `Identity` file
  counting four times), a small image the renderer inlines within the 8M
  `tokenURI` budget (see the content README's budget proof). It stores the approved
  record file ID as it is, one word per media file plus one word of roles, an
  ARTIST seed, and the approved license when it is not the default CC0. Neither
  the record file nor the license text is checked here, so neither can freeze a
  minted work. Every per-token function reverts with `RecordNotOpen` until
  then.
- **Record files.** `setRecord` and `finalize` accept a record file only if it
  is registered, `Identity`-encoded, at most `Limits.MAX_RECORD_BYTES` (one chunk) and
  complete. These checks are O(1). An approved record that breaks them still
  opens; the renderer serves core-only metadata with a record status, and the
  artist replaces it with `setRecord` before finalize. The JSON is not parsed
  on-chain: the renderer validates it the same way.
- **Licenses.** The SPDX ID keeps its original case (`CC0-1.0`); only the
  license key, `keccak256` of the lowercased ID, is case-insensitive.
- **State hash.** It commits to the token ID, the version, the record file, the
  license key and text, the royalty rate and the effective renderer. The
  version bumps only on a real change; identical re-publishes are no-ops, and
  permissionless actions never change it.
- **Amendments.** Relicensing and royalty-rate changes need every party's
  EIP-712 consent, each by its current authority, plus a governed action. Only
  CC0 irrevocability is enforced on-chain, on the canonical license key; whether
  a new license is more permissive is the judgement of the parties' consent plus
  governance, and the contract does not order licenses. A CC0 work may still
  correct its text file (CC0 to CC0). A relicense's text file must be
  registered, and stored on-chain once the work is finalized. A royalty-rate
  change bumps the version before its external calls, emits `RoyaltyRateSet`
  and refreshes the metadata. A repin needs the lead artist and the 30-day
  class, and binds the renderer's code hash.
- **Finalize** applies the record-file checks and requires the license text,
  the default CC0 text included, to be complete on-chain. A finalized work's
  record and license text are therefore permanent and readable on-chain.
- **Locators.** Append-only ARWEAVE and IPFS copies of media files: at most 8
  per file added by the artist and 8 by the platform, so neither can exhaust
  the other's. Each URI is a content address with nothing after it, so the
  content it names cannot be repointed: `ar://` and a 43-character base64url
  transaction ID (an ArNS name is never 43 characters long), or `ipfs://` and a
  base32 CIDv1 with a sha2-256 multihash, a raw leaf (`bafkrei...`) or a dag-pb
  root (`bafybei...`), 59 characters. No path, query or fragment, so no `%` or
  `#` either. A URI already registered for the file is refused, compared as
  exact bytes, so a different spelling of the same content counts as new. The
  set of registered URIs is shared, so whichever side adds a URI first holds it
  against its own quota, and the URI is listed either way. Preferred location:
  the file's index, then the collection's kind, then the global kind, then the
  first registered locator, then the implicit ONCHAIN copy. ONCHAIN matches
  only a work that `syncOnChain` marked on-chain complete (a stored flag, never
  a content-store scan); with nothing found the result is the empty locator
  (kind NONE). Locators are not verified on-chain: each is registered as a copy
  of that one file, and the storage operator chooses only among the copies
  registered for it.
- **Held locators.** "Final" fixes the content, so after finalize an artist's
  new locator does not change what a work shows by itself. It is held: listed
  and emitted like any other, but skipped by the kinds and the first-registered
  fallback, so it is served only while the storage operator selects it with
  `setFilePreference` (after checking that it names the committed bytes). The
  platform's locators, and the artist's from before finalize, are served as
  usual.
