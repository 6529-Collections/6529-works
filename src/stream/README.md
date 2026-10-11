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

Tests are in [`test/stream/`](../../test/stream) and mocks of other lanes'
contracts in [`test/mocks/stream/`](../../test/mocks/stream).

## Core token

- **Minting.** Only adapters in the admitted-minter mapping
  (`setAdmittedMinter`, 30-day class) may mint, into their own custody, for an
  item the package registry consumes in the same call. Stream checks what the
  registry does not: the auction sale kind on both the item and the adapter, an
  existing collection, a coherent seed policy, and a delivered VRF seed.
- **IDs.** One chronological global counter from 1; collections keep their own
  serials from 1. A burn (an upheld dispute, from the minting adapter's
  custody) leaves a gap; IDs are never reused.
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
  before delivery; it gates edition creation.
- **Wiring.** `WorkRecords` and 6529 Editions are bound once each, with ERC-165
  checks and EIP-7702 rejection. Every installed dependency is checked the same
  way; renderers are also pinned by code hash.

## Records satellite

- **Opening.** Nothing is written at mint. `openRecord` is permissionless: it
  checks the item against the core's item hash, the media list against
  `mediaHash`, the primary's SHA-256 against `contentHash`, and every file's
  SHA-256 against the content store's declaration. It stores the record file ID,
  one word per media file plus one word of roles, an ARTIST seed, and a license
  only when it is not the default CC0. Every per-token function reverts with
  `RecordNotOpen` until then.
- **State hash.** It commits to the token ID, the version, the record file, the
  license key and text, the royalty rate and the effective renderer. The
  version bumps only on a real change; identical re-publishes are no-ops, and
  permissionless actions never change it.
- **Amendments.** Relicensing and royalty-rate changes need every party's
  EIP-712 consent, each by its current authority, plus a governed action. CC0 is
  irrevocable. A repin needs the lead artist and the 30-day class, and binds the
  renderer's code hash.
- **Locators.** Append-only ARWEAVE and IPFS copies of media files, at most 16
  per file. Preferred location: the file's index, then the collection's kind,
  then the global kind, then the first registered locator, then the implicit
  ONCHAIN copy of a complete file. Every locator of a file is a copy of that
  file, so the storage operator can only choose among hash-equal copies.
