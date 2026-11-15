# content

On-chain content and metadata: the permissionless content store that keeps any file as
content-addressed SSTORE2 chunks, the governed registry of pinned script libraries, and the
renderer that builds `tokenURI` for 6529 Stream works and their editions in 6529 Stream
Editions. The storage rules are in [Works and storage](../../docs/spec/works-and-storage.md)
(`WS-24` to `WS-35`, `WS-50` to `WS-54`); the metadata format, media selection, record validation and the 8M gas budget in
[Rendering and tokenURI](../../docs/spec/rendering-and-tokenuri.md) (`RND-*`). Off-chain
tooling to plan, upload, attest and verify files, with gas quotes under Prague and Glamsterdam,
is the [uploader](../../tools/content/README.md).

## Files

| File | What it is |
| --- | --- |
| `ContentStore.sol` | [`IContentStore`](../interfaces/IContentStore.sol): chunks (whole or linked from parts), manifests (in one call or from list chunks), completeness by range, verified chunk and range reads, the base64 attestation in pieces, and [`IChunkStore`](../interfaces/IChunkStore.sol) for store adapters. No owner, no governance, nothing payable. |
| `Base64Validator.sol` | Internal library: the strict RFC 4648 alphabet check behind `attestBase64`, 32 bytes per step. |
| `DependencyRegistry.sol` | [`IDependencyRegistry`](../interfaces/IDependencyRegistry.sol): `(name, version)` to a complete store file, forever; deprecation is a one-way flag. |
| `Renderer.sol` | [`IRenderer`](../interfaces/IRenderer.sol): `tokenURI` and `fullTokenURI`. Immutable and stateless. |
| `JsonScan.sol` | Internal library: a strict RFC 8259 scanner that validates the record and reports where each value sits. Never decodes, never reverts. |
| `DataUri.sol`, `HtmlScript.sol` | Internal libraries: percent-escaping of `%` and `#`; neutralizing `</script` and `<!--` in a wrapped script. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone (artist, platform, collector, uploader) | `writeChunk`, `linkChunk`, `registerManifest`, `registerManifestList`, `attestBase64`, in any order | WS-24 to WS-27, WS-29, WS-31, WS-50, WS-51 |
| Anyone; `WorkRecords`; the renderer | `fileInfo`, `sha256Of`, `isComplete`, `firstMissing`, `missingChunks`, `readChunk`, `chunkData`, `read`, `isBase64Attested` | WS-28, WS-30, WS-52, WS-53 |
| Governance | `DependencyRegistry.register`, `deprecate` | WS-34, WS-35; [role matrix](../../docs/audit/roles.md#dependencyregistry) |
| `Stream.tokenURI`, `Editions.uri` (through `rendererOf`); anyone by `eth_call` | `Renderer.tokenURI(token, id)`, `fullTokenURI(token, id)` | RND-1 to RND-27 |

The upload flow is under [Upload and register a file](../../docs/spec/works-and-storage.md#upload-and-register-a-file),
and what the renderer reads, in order, under
[Inside the renderer](../../docs/spec/rendering-and-tokenuri.md#inside-the-renderer).
Integrators start at [Reading a work](../../docs/integrators/reading-a-work.md) and
[Storage](../../docs/integrators/storage.md).

## Developer notes

- **The file ID is permanent and chain-independent.** It commits to the whole manifest (chunk
  hashes, stored length, encoding, MIME type, declared SHA-256 of the decoded file), so a package
  can name it before deployment. Changing the formula, `CHUNK_SIZE` or the layout rule breaks
  every package and the uploader's golden vectors (WS-33).
- **Every write is piecewise (WS-50, WS-51).** A full chunk can be linked from parts of any
  size, so no write needs one large contract creation; a manifest of up to `MAX_CHUNKS` (4,096)
  is registered from list chunks by one small call; attestation takes a caller-chosen count;
  completeness is checked by range (`firstMissing`). `registerManifest` (one call, one slot per
  hash) remains for small files. Storage layout: a file's `entries` are its chunk hashes
  (`hashesPerList` 0) or its list chunks' pointers; a link is one `(length, count)` word and one
  pointer per part.
- **Links are the same chunks (WS-50).** A link is keyed by the keccak256 of what it concatenates,
  re-checked on every read; parts are whole chunks only; a link from fewer parts may replace a
  longer one, never the bytes. `chunkPointer` is zero for a linked chunk: read it with
  `chunkData` or `readChunk`.
- **Open ids (WS-54).** Encodings and digest kinds are `uint8` ids the store records; it
  interprets only encodings 2 and 3 (attestation) and digest kind 0 (`sha256Of`). The enum
  `IContentStore.Encoding` names the four defined ids.
- **Writes trust CREATE2's result (WS-24).** `SSTORE2.write` keeps the address the chain
  returns and checks the code size; no read or write recomputes an address, and the store
  deduplicates by `chunkPointer` before writing (a repeat CREATE2 would collide).
- **Reads verify whole chunks.** Every touched chunk is read in full and checked against its
  keccak256, and Solidity memory makes large reads superlinear: one `read` of 1 MiB costs about
  9.7M Prague gas. On-chain callers read chunk by chunk or in ranges of a few hundred KiB.
- **A bad record degrades, a broken dependency reverts.** A record that is not open, not
  complete or not acceptable gives core-only metadata with a `record_status` (RND-9); a failed
  read, too little gas, or a state the deployed contracts make impossible (RND-16) reverts.
  Every external read forwards all the gas it may with a return-size cap
  (`BoundedCall.tryReadAll`, the gas rule of ADR 0007): no gas figure is compiled in, since a
  finalized work pins its renderer, possibly for good; a read that runs short reverts with
  `BoundedCallShortfall`.
- **The 8M budget is a joint bound.** The record caps (size, units, attributes, `%` and `#`,
  number length, nesting) were chosen together with the inline limits and the renderer's
  preview bound (`PREVIEW_LIMIT`, `Limits.MAX_PREVIEW_BYTES`; `WorkRecords` holds none), so
  that a record at every cap beside the dearest media stays under 8M Prague
  gas. The dearest inputs are white space inside `attributes` (walked twice), `%` and `#`, and
  JSON units. Raising any cap, or changing `JsonScan`, `JsonEscape`, `Utf8`, `HtmlScript` or the
  read path, means rerunning [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol)
  and [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol); the margin is
  small (RND-26).
- **Native reads only.** A work's facts come from Stream's `coreOf` and `extsload` (slots 17
  and 18, in `_native`), never its fallback, which reaches the replaceable view extension: a
  finalized work pins this renderer, so nothing replaceable may decide what it shows (RND-22).
  Locators come from `WorkRecords.preferredLocator`, which serves only UTF-8 URIs, and the
  PREVIEW is read only when used, so an inlined image primary never asks the delivery contract.
- **`window.works` is a public API.** Finalized works pin their renderer, so version 1's fields
  never change meaning; a change needs a new `v` and a new renderer.
- **Bytecode: `Renderer` is the second-tightest contract**, barely under EIP-170 (current
  margin in the [audit scope](../../docs/audit/scope.md#content-and-rendering)). New features
  belong in a later renderer, which works pin per work.
- **Tests:** `forge test --match-path 'test/content/**'`: the store (unit, attestation,
  invariant, links, list manifests, sources and their gas in `ContentStorePermanence.t.sol`), the dependency registry, the renderer (media, hostile inputs, oracles against
  independent mirrors, gas) and the uploader's golden and CID vectors. Halmos proofs of
  `Base64Validator`, `DataUri` and `HtmlScript` are in `test/symbolic/` ([Testing](../../docs/testing/README.md)). End to end:
  `ContentToTokenURI.t.sol`, `TokenUriBudget.t.sol` and `SyncOnChainResume.t.sol` in
  [`test/integration/`](../../test/integration/).

## Known gaps in v1

No gzip page (compressed media is served by locator), no dependency bundling, and small inline
limits for scripts and `Identity` media: LIM-CNT-5 to LIM-CNT-9 in
[known limitations](../../docs/audit/known-limitations.md#content-records-and-rendering).

## See also

[ADR 0001 §8](../../docs/adr/0001-v1-scope.md#8-works-content-and-storage) and
[§10](../../docs/adr/0001-v1-scope.md#10-permanence),
[ADR 0003, token model and storage](../../docs/adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8),
[ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md) (Glamsterdam storage costs);
[Sepolia content receipts](../../deployments/11155111/flows.md#1-content).
