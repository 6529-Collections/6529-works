# content

On-chain content and metadata: the permissionless content store that keeps any file as
content-addressed SSTORE2 chunks, the governed registry of pinned script libraries, and the
renderer that builds `tokenURI` for 6529 Stream works and their 6529 Editions editions. The
storage rules are in [Works and storage](../../docs/spec/works-and-storage.md) (`WS-24` to
`WS-35`); the metadata format, media selection, record validation and the 8M gas budget in
[Rendering and tokenURI](../../docs/spec/rendering-and-tokenuri.md) (`RND-*`). Off-chain
tooling to plan, upload, attest and verify files, with gas quotes under Prague and Glamsterdam,
is the [uploader](../../tools/content/README.md).

## Files

| File | What it is |
| --- | --- |
| `ContentStore.sol` | [`IContentStore`](../interfaces/IContentStore.sol): chunks, manifests, completeness, verified chunk and range reads, the one-time base64 attestation. No owner, no governance, nothing payable. |
| `Base64Validator.sol` | Internal library: the strict RFC 4648 alphabet check behind `attestBase64`, 32 bytes per step. |
| `DependencyRegistry.sol` | [`IDependencyRegistry`](../interfaces/IDependencyRegistry.sol): `(name, version)` to a complete store file, forever; deprecation is a one-way flag. |
| `Renderer.sol` | [`IRenderer`](../interfaces/IRenderer.sol): `tokenURI` and `fullTokenURI`. Immutable and stateless. |
| `JsonScan.sol` | Internal library: a strict RFC 8259 scanner that validates the record and reports where each value sits. Never decodes, never reverts. |
| `DataUri.sol`, `HtmlScript.sol` | Internal libraries: percent-escaping of `%` and `#`; neutralizing `</script` and `<!--` in a wrapped script. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone (artist, platform, collector, uploader) | `writeChunk`, `registerManifest`, `attestBase64`, in any order | WS-24 to WS-27, WS-29, WS-31 |
| Anyone; `WorkRecords`; the renderer | `fileInfo`, `sha256Of`, `isComplete`, `missingChunks`, `readChunk`, `read`, `isBase64Attested` | WS-28, WS-30 |
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
- **`MAX_CHUNKS` (512) was sized on Prague.** Registering a 512-chunk manifest fits the EIP-7825
  cap in Prague gas; under Glamsterdam the whole registration is far above it and needs blocks
  that hold it and a gas limit from the uploader's offline model (LIM-CNT-11, LIM-GAS-2).
- **Reads verify whole chunks.** Every touched chunk is read in full and checked against its
  keccak256, and Solidity memory makes large reads superlinear: one `read` of 1 MiB costs about
  9.7M Prague gas. On-chain callers read chunk by chunk or in ranges of a few hundred KiB.
- **A bad record degrades, a broken dependency reverts.** A record that is not open, not
  complete or not acceptable gives core-only metadata with a `record_status` (RND-9); a failed
  read, too little gas, or a state the deployed contracts make impossible (RND-16) reverts.
  Every external read is a `BoundedCall` with its own gas and return cap (RND-6, RND-7), so a
  caller must supply well over the gas the call uses.
- **The 8M budget is a joint bound.** The record caps (size, units, attributes, `%` and `#`,
  number length, nesting) were chosen together with the inline limits and `WorkRecords`'
  preview cap, so that a record at every cap beside the dearest media stays under 8M Prague
  gas. The dearest inputs are white space inside `attributes` (walked twice), `%` and `#`, and
  JSON units. Raising any cap, or changing `JsonScan`, `JsonEscape`, `Utf8`, `HtmlScript` or the
  read path, means rerunning [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol)
  and [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol); the margin is
  small (RND-26).
- **`window.works` is a public API.** Finalized works pin their renderer, so version 1's fields
  never change meaning; a change needs a new `v` and a new renderer.
- **Bytecode: `Renderer` is the second-tightest contract**, barely under EIP-170 (current
  margin in the [audit scope](../../docs/audit/scope.md#content-and-rendering)). New features
  belong in a later renderer, which works pin per work.
- **Tests:** `forge test --match-path 'test/content/**'`: the store (unit, attestation,
  invariant), the dependency registry, the renderer (media, hostile inputs, oracles against
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
