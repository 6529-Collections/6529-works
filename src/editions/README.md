# editions

The single shared 6529 Editions ERC-1155 (`Editions.sol`, implementing `IEditions`
and `IMintTarget`). Every edition is anchored by a Stream work of kind
`EDITION_MASTER`; the edition token records `(stream, workId, contentHash)`,
renders the master's media, carries the master's license, and is created only
from the approved package. Edition sales use the shared fixed-price (allowlist
phases with the recipient-bound leaf fix, ERC-20 permits) and Dutch adapters
from `sales/`. Governed by
[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions), with
the exclusivity rule in §3 and the license rule in §8.

**Link.** `createEdition(workId, item, packageRoot, proof)` is permissionless. It
accepts only the exact item the master was minted from (Stream's stored item
hash), proven by `proof` to be in a package root the registry still reports
approved, so a guardian revocation blocks the edition at no cost to the auction
start. An item listed in two packages passes through whichever is still
approved; this edge case is accepted. It also needs the master's sale to have
settled (`IStream.primarySaleSettled`, marked by the minting adapter at
settle), so a disputed or burned master never gets an edition. It locks the `PRODUCT_EDITIONS` economics (seller, fee, royalty),
claims the content hash in the package registry (which accepts only the item
Stream consumed for that hash, once), calls `IStream.linkEdition`, and
verifies Stream's side before returning. The edition ID is the master's token
ID, and nothing changes or removes a link.

**Minting.** Only admitted adapters (`isAdmittedMinter`, written by the
governed `setAdmittedMinter` in the 30-day class, with ERC-165 and EIP-7702
checks) whose `saleKind()` matches the package's may mint or burn. FIXED
editions stop at `size` copies; OPEN editions sell for `window` seconds from
the first mint, capped at `size` when it is nonzero; minting stops if the
master is burned. Burned copies still count toward the size. The sale
adapter owns the currency: `primaryTerms` and `mint` return the package's
stored currency (possibly `CURRENCY_DEFAULT`), and the adapter resolves and
locks it when it opens a sale.

**Reads.** `royaltyInfo` uses the receiver locked at creation and the current
rate (out of 100,000), from local storage. Only the bound work-records
satellite may change the rate: when a master is re-rated there (every party's
consent plus a governed action), it re-rates the linked edition through
`setRoyaltyRate`. The receiver never changes. `licenseOf` reads the
master's license from the work-records satellite (`RecordNotOpen` until the
record is opened), and `uri` is served by `IStream.rendererOf(id)`. ERC-4906
`MetadataUpdate` is emitted at creation, on a rate change and whenever the
work-records satellite calls `notifyMasterUpdated`; `notifyAllUpdated`, from
Stream (a default-renderer change) or the satellite (a global or collection
preferred location), emits one `BatchMetadataUpdate` over every ID.

**Wiring.** Stream is checked at deployment (code, no EIP-7702 delegation,
ERC-165 for ERC-721, the reviewed code hash), and the package registry,
economics resolver and artist registry are read from it. Genesis binds Editions
in Stream and in the package registry (their one-shot Editions binds), and then
binds Stream's work-records satellite here once (`bindWorkRecords`, ADMIN, with
ERC-165 and EIP-7702 checks).
