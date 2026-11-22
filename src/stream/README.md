# stream

Two pieces that serve every token the RECORDS module serves. The token contracts themselves
are in [`src/core`](../core/README.md); the RECORDS module `WorkRules` is in
[`src/records`](../records/README.md). The rules are in
[Works and storage](../../docs/spec/works-and-storage.md) (`WS-*`).

## Files

| File | What it is |
| --- | --- |
| `WorkDelivery.sol` | The first delivery contract of `WorkRules` ([`IWorkDelivery`](../interfaces/IWorkDelivery.sol)): append-only, content-addressed locators per media file (the artist's before finalize, the PLATFORM role's at any time), the storage operator's preferences among them, and its mark on a locator that died. Replaceable as a whole (`WorkRules.setDelivery`); it has no authority over any fact of a work. |
| `SpdxId.sol` | Internal library: the license-ID rule applied by the mint policy at mint and by `WorkRules` at relicense. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Any wallet of the lead artist's account | `addLocator` before finalize | WS-19 |
| PLATFORM | `addLocator` at any time | WS-19 |
| STORAGE_OPERATOR | `setPreferredKind`, `setCollectionPreferredKind`, `setFilePreference`, `markLocatorDead` | WS-20 to WS-22 |
| Anyone | the views (`locators`, `preferredLocator`) | WS-18 |

Who may call what, with delays: [role matrix](../../docs/audit/roles.md).

## Developer notes

- **Reads, never copies.** Every call reads what it needs (open, finalized, on-chain complete,
  the media) from `StreamWorkFacts6529.factsOf` and the artist and collection from the token, so it
  never holds a stale fact.
- **Metadata refresh.** Every change asks `WorkRules` to emit ERC-4906 through the token.
- **Locators are checked twice.** Here, against the URI grammar (Arweave transaction IDs and
  base32 CIDs); and by the renderer, which checks every answer it prints.
- **Replacing it.** A successor starts empty; carrying the predecessor's locators is the
  successor's own choice (WS-39). The content hashes stay in the permanent `StreamWorkFacts6529`.
- **Tests:** `forge test --match-path 'test/stream/**'`.
