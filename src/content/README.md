# content

Work and content records (title, description, artists, media list with sha256,
size, MIME type and append-only locators, license), the content store of
SSTORE2 chunks of up to 24,575 bytes with range reads, the shared dependency
registry, and the renderer that builds a small `tokenURI` with the preferred
locator, inline media only once a work is on-chain complete, and a bounded read
large enough for the inline threshold. Governed by
[ADR 0001](../../docs/adr/0001-v1-scope.md) §8 (works, content, storage,
preferred location, on-chain upgrade, `tokenURI` size) and §10 (finalize pins
the renderer; delivery routing stays operable).

## Content store and dependency registry

| File | Role |
| --- | --- |
| `ContentStore.sol` (interface: [`IContentStore`](../interfaces/IContentStore.sol)) | Permissionless, content-addressed file storage: chunks, manifests, completeness, verified range reads. No owner, no governance, no payable function. |
| `Base64Validator.sol` | Internal library behind base64 attestation: the strict RFC 4648 alphabet check, 32 bytes at a time. Nothing is linked. |
| `DependencyRegistry.sol` (interface: [`IDependencyRegistry`](../interfaces/IDependencyRegistry.sol)) | Governed `(name, version)` to store-file map for shared libraries (p5.js, three.js). Immutable versions, deprecation as a flag. |

Other contracts should depend on the interfaces. Tests are in
[`test/content/`](../../test/content).

### The model

- **Chunk.** Up to 24,575 bytes (EIP-170's 24,576 minus the STOP byte), stored
  as the code of a CREATE2 contract by `src/libraries/SSTORE2.sol`. Its identity
  is `keccak256(bytes)`. Writing bytes that are already stored is a no-op that
  returns the same pointer and emits nothing.
- **Manifest.** An ordered list of chunk hashes, the total stored `length`, a
  MIME type, an `encoding` and a declared SHA-256. It can be registered before,
  during or after the upload of its chunks.
- **Layout rule.** Every chunk except the last is exactly 24,575 bytes. An
  offset maps to a chunk by division, one canonical chunking exists for any
  bytes, and a manifest that breaks the rule never completes and never reads.
  The same holds for a manifest that lists a chunk that cannot exist, such as a
  zero hash: registration does not check chunks (they may not be uploaded yet), so
  such a manifest is accepted but inert, and the dependency registry refuses it
  because it is not complete.
- **Limits** (`CHUNK_SIZE` and `MAX_CHUNKS` are on `IContentStore`). 1 to 512
  chunks per file, which is 12,582,400 bytes (about 12.58 MB). The cap exists
  because Fusaka's EIP-7825 limits every transaction to 16,777,216 gas:
  registering a manifest at 512 chunks costs 11.8M gas including calldata and the
  21,000 base, so it fits with room for repricing (1,024 chunks would not). MIME
  type up to 64 bytes, lowercase `type/subtype` from `[a-z0-9+._-]`, no
  parameters.

**Encodings.** The value is part of the file ID, so it is permanent.

| Encoding | The stored bytes are |
| --- | --- |
| `Identity` | the media |
| `Gzip` | an RFC 1952 gzip stream of the media |
| `Base64` | RFC 4648 section 4 base64 text of the media (standard alphabet, `=` padding, no line breaks) |
| `GzipBase64` | that base64 text of a gzip stream |

The base64 encodings exist for inline rendering. Base64 encoding on-chain is what
dominates `tokenURI` gas, so a file stored as base64 lets the renderer
concatenate the stored bytes into a `data:<mime>;base64,` URI without encoding
anything. The price is that base64 text is a third larger (about 33% more to
upload). A media file that will be inlined should be stored as `Base64`; one that
is served by range reads can stay `Identity`. The declared SHA-256 is always the
hash of the **fully decoded** media (base64-decoded, then gunzipped, as the
encoding requires), whichever encoding is stored.

**File ID.** It is chain- and deployment-independent, so a package can commit to
it before anything is deployed or uploaded:

```
fileId = keccak256(abi.encode(bytes32[] chunkHashes, uint256 length, uint8 encoding,
                              string mimeType, bytes32 sha256))
```

It commits to the whole manifest, not only to the chunk list. The store is
permissionless, so a record keyed by chunk hashes alone would let anyone
front-run an artist's manifest with a wrong MIME type or digest. Here a
different claim about the same chunks is a different file, and nobody can
overwrite or block another registration. Chunks are shared by hash across files,
so one upload serves every manifest that lists them.

Two consequences follow, and the rest of the system must respect both.

- **The file ID names one exact encoded stream, forever.** It commits to the
  stored bytes (through the chunk hashes), not just to the media. A gzip or base64
  file can be rebuilt from the original media only if the encoder is
  deterministic, and gzip output depends on the compressor, its version and its
  settings. If nobody keeps the encoded bytes, nobody can reproduce the chunks
  later. So a work stored as `Gzip`, `Base64` or `GzipBase64` needs a locator
  (Arweave or IPFS) for the **encoded stream itself**, next to the locator for the
  decoded media. Uploader tooling must prove that the encoded bytes it publishes
  reproduce the chunk hashes, and that decoding them gives the declared SHA-256,
  before the artist signs the package.
- **The file ID is not a content-uniqueness key.** It binds the MIME type and the
  encoding, so the same media stored as `Identity` and as `Gzip` has two file IDs.
  Product uniqueness (ADR 0001 §3: one content hash per product) must key on the
  SHA-256 of the **decoded** media, not on the file ID. The curation lane owns
  that check.

### Upload flow

Uploads can happen at any time, in any order, by anyone. The mint does not wait
for them, and nobody needs permission to complete a work's on-chain copy.

1. **Encode and chunk the file** off-chain: apply the encoding (gzip, base64 or
   both), then cut the stored bytes into 24,575-byte pieces, the last one
   shorter. Compute each chunk's `keccak256`, the stored `length`, and the
   SHA-256 of the decoded media. Publish the encoded stream to Arweave or IPFS
   too (see the file ID notes above).
2. **Compute the file ID** with the formula above. The artist's package commits
   to it (the store itself needs nothing at this point).
3. **Register the manifest** with `registerManifest`. It is cheap (about 1.05M
   gas for 1 MB) and can be done by the artist, the platform or a collector.
4. **Find what is missing** with `missingChunks(fileId)`, which returns the
   indexes still to be uploaded, and `isComplete(fileId)` for the yes or no.
5. **Upload chunks** with `writeChunk(bytes)`, in any order and across as many
   transactions as needed. Because `writeChunk` does not depend on the caller,
   any batching tool works (for example Multicall3, to fit two full chunks, about
   49 KB, in one transaction, at about two thirds of the 16,777,216-gas transaction
   cap; three full chunks reach 97–99% of the cap and are not recommended). A collector, the designated payer in the product,
   finishes what the artist or platform started. Re-sending a chunk costs almost
   nothing.
6. **Done.** When `isComplete(fileId)` is true every chunk is stored with the
   length the layout requires, so `read(fileId, 0, length)` succeeds. On-chain
   bytes are permanent. Completion is derived, not recorded: there is no
   completion transaction and no event.

Steps 3 to 5 may be done in any order. Registering before uploading is how a
work is committed on-chain cheaply and completed later.

### Reads

| Function | Result |
| --- | --- |
| `fileInfo(fileId)` | declared SHA-256, stored length, chunk count, encoding, MIME type |
| `isComplete(fileId)`, `missingChunks(fileId)` | whether every chunk is present at its required length, and which are not |
| `chunkHash(fileId, i)`, `chunkPointer(hash)` | the manifest's hash for chunk `i`, and the contract storing a chunk |
| `readChunk(fileId, i)` | one chunk, verified against its hash |
| `read(fileId, offset, length)` | any byte range of the stored data |

**Reads fail closed.** A read never returns partial data. If a chunk the range
touches is missing, it reverts with `ContentChunkMissing(fileId, index, hash)`;
a range that avoids the missing chunk still succeeds. Unknown files, bad
indexes, out-of-range ranges and chunks of the wrong length each revert with
their own error (see `IContentStore.sol`). Every touched chunk is read in full
and checked against its keccak256, so the cost of a range is one chunk read per
chunk touched.

### Integrity: what is and is not checked on-chain

- **Per chunk: checked on every read** (keccak256 against the manifest's hash).
- **The declared SHA-256 is never recomputed on-chain.** Hashing a large file in
  memory costs quadratic gas, and chunk integrity already pins every byte. The
  SHA-256 is for off-chain verification and for records to bind a file to the
  media hash they committed to. It is the hash of the **fully decoded** media,
  the same value a work record lists as the media hash. `length` is the
  **stored** length that `read` returns.
- **Verify a file off-chain:** read all chunks, concatenate, base64-decode and
  gunzip as `encoding` requires, SHA-256, compare with
  `fileInfo(fileId).sha256Hash`. A manifest whose declared digest is wrong yields
  a different file ID from the honest one, so it cannot displace it.

### Base64 attestation

The store never looks at bytes while chunks are uploaded, so a file declared
`Base64` or `GzipBase64` is only a claim. A renderer that copies the stored text
verbatim into token JSON or a `data:` URI would let an artist inject JSON keys
with a quote or backslash. **Renderers must embed such a file only when
`isBase64Attested(fileId)` is true.** The view never reverts: it is false for an
unknown file and for any file not yet attested.

`attestBase64(fileId)` reads the chunks, checks them, and records the result for
good:

- **Who and when.** Anyone. A call reads the chunks it checks, so each must
  exist at its required length. A call that reaches the end of the file also
  reads the file's last one or two chunks to find the `=` padding, so the last
  call cannot succeed until the file is complete; earlier calls on a big file do
  not need the end, and can run while it is still being uploaded. A call on an
  attested file is a no-op that returns true, emits nothing and reads no chunk.
- **What is checked.** Every byte is in `[A-Za-z0-9+/]`, except that `=` may be
  the last one or two bytes of the whole file (a final `=` or `==`, which can
  straddle the last chunk boundary), and the file's length is a multiple of 4.
  `=` anywhere else, a byte of `0x80` or more, a control byte, a quote, a
  backslash, `%`, `#`, the URL-safe `-` and `_`, and whitespace are all rejected.
  Canonical padding bits are not checked: the point is that the text is inert,
  not that it is the one encoding of its bytes.
- **Failure is specific.** The first bad chunk reverts with
  `ContentBase64Invalid(fileId, index)`; a missing or wrong-length chunk with
  `ContentChunkMissing` or `ContentChunkLengthMismatch`; a file with another
  encoding with `ContentNotBase64`; a length that is not a multiple of 4 with
  `ContentBase64LengthInvalid`. Nothing is recorded on a revert.
- **Big files take several calls.** One call checks at most
  `ATTEST_CHUNKS_PER_CALL` (48) chunks and continues where the last call
  stopped, so a file of any size is attested by repeating the call until it
  returns true (`Base64Progress` is emitted in between, `Base64Attested` once at
  the end). A file of up to 48 chunks (about 1.18 MB, so a full 1 MiB) is one
  call, and the largest file the store accepts (512 chunks) is eleven. The limit
  keeps the worst call (48 cold chunks plus the last one, read for the padding) at about half of EIP-7825's
  16,777,216 gas cap.

The check is a word-at-a-time SWAR scan (`Base64Validator`): once every byte of a
32-byte word is below `0x80`, range tests on all 32 bytes run as a few additions
and subtractions with no carry between bytes. The tests cover every byte value in
every lane and every adjacent pair of bytes against a scalar oracle.

The attestation is about the stored text, so it is per file ID; the same bytes
under another MIME type are another file and are attested separately. Uploader
tooling should call `attestBase64` once a `Base64` or `GzipBase64` file is
complete, since the cost falls on whoever calls it.

### Gas

Measured by `forge test --match-contract Gas -vv` (Foundry 1.7.1, Solidity
0.8.37, optimizer 200 runs). Each figure is the gas the call itself uses, from a
**cold** start: the fixtures are built in a separate transaction, so the store,
its storage and the chunk contracts are all first touches, as in a fresh
`eth_call`. The 21,000 base and calldata are added only where a row says so.

| Operation | Gas |
| --- | --- |
| `writeChunk`, 24,575 bytes (new): execution | 5,020,000 |
| `writeChunk`, same, as a transaction (execution + 21,000 + 392,000 calldata at 16 gas per byte) | 5,434,000 |
| Upload per MB, as transactions | 231.8M, which is **about 0.23 ETH per MB per gwei** |
| `writeChunk`, bytes already stored | 16,000 |
| `registerManifest`, 100 KB / 1 MB (execution) | 212,000 / 1,055,000 |
| `registerManifest`, 512 chunks (the cap): execution / transaction | 11,521,000 / 11,806,000 (limit 16,777,216) |
| `isComplete`, 1 MB (43 chunks) | 353,000 |
| `readChunk`, one full chunk | 37,000 |
| `read`, 100 bytes inside one chunk | 30,000 |
| `read`, 100 KB (5 chunks) | 221,000 |
| `read`, 256 KB (11 chunks, the inline threshold) | 855,000 |
| `read`, 1 MB (43 chunks) | 9,678,000 |
| `attestBase64`, 256 KiB (11 chunks), as a transaction | 1,943,000 |
| `attestBase64`, 1 MiB (43 chunks), as a transaction | 7,565,000 |
| `attestBase64`, the worst call (48 distinct cold chunks, then the last chunk for the padding), as a transaction | 8,502,000 (limit 16,777,216) |

The figures are as measured on the toolchain above and drift with compiler and
optimizer changes, while the tests assert only loose ceilings, so re-measure with
the command above after changing either. Cold access costs dominate small
operations: each chunk touched adds a cold
`SLOAD` for its hash, one for its pointer, and a cold code access (about 6,800
gas); the same calls run warm cost much less (for example `isComplete` on 1 MB
is 67,000 warm).

`read` costs grow faster than linearly because Solidity memory does, and the
returned `bytes` is ABI-encoded into a second buffer, so the callee holds twice
the file size. On-chain callers that handle large files should read in ranges
(a few hundred KB) or chunk by chunk. The store releases each verified chunk
buffer after copying, so memory is the output size plus one chunk.

### DependencyRegistry

Generative works load pinned libraries by name and version. The registry maps
`(bytes32 name, bytes32 version)` to a store file:

- **Labels** are 1 to 32 bytes of lowercase ASCII from `[a-z0-9._-]`, left-aligned
  and zero-padded, so each name and version has one canonical spelling: `three`
  and `r170`, or `p5` and `1.9.0`.
- **`register(name, version, fileId)`** is restricted (AccessManager). The file
  must be registered and on-chain complete, so every registered version is
  readable for as long as the chain exists. A registered version can never be
  changed or removed: there is no function that rewrites an entry.
- **`deprecate(name, version)`** is restricted and sets a one-way flag. It
  deletes nothing, and the version stays resolvable and readable, so works that
  pin it keep rendering.
- **`resolve(name, version)`** returns the file ID, the deprecated flag and the
  manifest data. The encoding and MIME type come from the file's manifest.

**Governance TODO.** The registry only calls `restricted`. Granting `register`
and `deprecate` to a registrar role (from `src/governance/Roles.sol`, owned by
the governance lane, with a delay because a version is forever) is a
deployment-time `setTargetFunctionRole` call. The tests use a local role until
that file lands.

## Renderer

`Renderer.sol` implements [`IRenderer`](../interfaces/IRenderer.sol): `tokenURI`
and `fullTokenURI` for 6529 Stream works and 6529 Editions editions. It is
immutable and stateless, and supports ERC-165 for `IRenderer`. The tests are in
[`test/content/renderer/`](../../test/content/renderer).

| File | Role |
| --- | --- |
| `Renderer.sol` | The renderer. |
| `JsonScan.sol` | A strict RFC 8259 scanner that validates the record JSON and reports where values sit. |
| `DataUri.sol` | Percent-escapes `%` and `#` for a non-base64 `data:` URI. |
| `HtmlScript.sol` | Neutralizes `</script` and `<!--` in script text placed in an HTML page. |

### What it reads, and how it fails

`tokenURI(token, id)` reads the token it is asked about (6529 Stream, or 6529
Editions, which it recognises by ERC-165 and follows to the master through
`masterOf`), that Stream's `IWorkRecords` satellite, the content store it was
deployed with, and optionally the statement log's `latestDisputeOutcome`. Every
read is a `BoundedCall` with its own gas cap and return-size cap, and a read that
fails reverts with `RendererReadFailed(target, selector)`: a renderer never
returns plausible metadata for a token it cannot read. A hostile `token` can only
change what its own call returns, so there is no list of tokens.

**Records that are not open.** `openRecord` is permissionless and runs after the
auction starts, and every satellite view reverts until it has. So the renderer
asks `isOpen` first, and a work whose record is not open, or whose record file is
not completely uploaded yet, gets core-only metadata and never a revert: its name
from the collection and serial (`Spring #12`), and the traits Stream knows
(`Artist ID`, `Collection`, `Serial`, `Edition of`, the VRF seed, a dispute
statement). The `description` says the record is not open yet. The ARTIST seed is
stored when the record opens, so it appears only after.

### The record

A work's descriptive record is a JSON file in the content store, stored as
`Identity`, at most one chunk (24,575 bytes: `MAX_RECORD_BYTES`). The renderer
reads it, checks it as UTF-8 and with `JsonScan` (strings, escapes, numbers,
nesting up to 8 levels, no duplicate requested keys), and copies validated JSON
text, never decoded text:

| Record member | Metadata |
| --- | --- |
| `name` (required, a string) | `name` |
| `description` (a string) | `description` |
| `artists` (strings, at most 16) | one `Artist` trait each |
| `year` (a number) | the `Year` trait |
| `medium`, `dimensions` (strings) | the `Medium` and `Dimensions` traits |
| `attributes` (an array) | its elements, as they are, after the renderer's own traits |
| any other member (`dependencies`, `files`, ...) | validated and ignored |

The `attributes` array is copied without checking its elements, so a record keeps
the shape the tooling gives it. A wrong type, a missing `name`, a malformed
record, an invalid UTF-8 byte or too many artists reverts (`RendererRecordInvalid`,
`JsonScan.JsonInvalid`, `RendererInvalidUtf8`): the artist can fix the record
until finalize, and nothing is guessed. Because the whole file is percent-escaped
first, `%` and `#` inside it survive the URI.

### Output

`data:application/json;utf8,` followed by compact JSON. It is not base64: the
media is already base64 text, and encoding it twice would cost gas and a third
more size. Every string from the Stream, a locator or the store (a collection
name, a license identifier, a MIME type, a URL) is checked as UTF-8, escaped by
`JsonEscape` and percent-escaped by `DataUri`. The JSON carries `name`,
`description`, `image`, `animation_url`, `media_url`, `content_type`,
`content_hash` (the primary's decoded SHA-256), `license`, `license_url` (the SPDX
page; none for a `licenseref-` expression) and `attributes`.

### Media

| Primary file | `tokenURI` |
| --- | --- |
| complete, work on-chain complete, stored as `Base64`, at most the threshold | `data:<mime>;base64,` plus the stored text, concatenated as it is |
| the same, stored as `Identity`, at most an eighth of the threshold | base64-encoded on-chain |
| `text/javascript` or `application/javascript`, `Identity`, at most 16 KiB, UTF-8 | an HTML page that sets `window.works` and runs the script (below) |
| anything else: larger, incomplete, `Gzip` or `GzipBase64` | the preferred locator (and `media_url`) |

- **The threshold** is `inlineThreshold()`, in stored bytes, set at deployment
  (`DEFAULT_INLINE_THRESHOLD`, 262,144, which is 256 KiB, as the ADR targets). An
  `Identity` file counts eight times against it, because the renderer encodes it
  with OpenZeppelin's `Base64`, which costs about 80 gas a byte against 10 for
  copying text that is already base64. A 256 KiB `Base64` file fits 8M gas with
  room to spare; an `Identity` file fits only up to 32 KiB. **Store media that will
  be inlined as `Base64`.**
- **`Gzip` and `GzipBase64` are never inlined.** Their stored bytes are a
  compressed stream, not the media, so a `data:` URI of them would carry the wrong
  bytes under the media's MIME type. They are served by locator.
- **Complete** means the work is on-chain complete (`RecordInfo.onChainComplete`)
  and `isComplete` is true for the file in the store. A missing chunk falls back to
  the locator, and the same token switches to inline once the last chunk is
  uploaded.
- **Fields.** `image` is the primary when it is an image and inlined; otherwise the
  on-chain preview if the work lists a `PREVIEW` image that is complete and within
  `PREVIEW_LIMIT` (65,536, cost-weighted like the threshold), else the primary's
  locator for an image, else the preview's locator. `animation_url` is the primary
  when it is not an image (inline, or its locator). `media_url` is the primary's
  preferred locator whenever the primary is not inlined.
- **The preferred locator** is `IWorkRecords.preferredLocator`. When that is the
  implicit on-chain one (no URL), the first registered copy is used. Inline wins
  over the preference: a complete file under the threshold is inlined whatever the
  preferred kind.
- **`fullTokenURI`** raises the limit to 1 MiB (`MAX_INLINE_BYTES`) and reverts
  with `RendererNotInlineable` instead of falling back. It is an off-chain view with
  no 8M promise: 256 KiB of `Base64` costs 2.6M, 1 MiB costs 30M.
- **Memory.** Media is read one store chunk at a time, straight into the single
  output buffer, and each chunk buffer is released after it is copied, so there is
  no second copy of the file. An `Identity` file also needs its raw bytes and the
  encoded text as transient buffers.

### The page around a script

A JavaScript primary cannot be shown as a `data:` URI, so the renderer wraps it: a
fixed HTML page whose first script sets
`window.works={tokenId:<id>,seed:<"0x…" or null>};` and then runs the work's
script. `window.works` is the script's whole interface, so it is part of what a
finalized work pins. The script text is the only artist-controlled text placed
inside the renderer's own markup, so it goes through `HtmlScript.neutralize`:
`</script` (any case) and `<!--` each gain a backslash after the `<`, which keeps
their meaning inside JavaScript strings, template literals and comments. `<!--`
matters because it can start the HTML parser's "double escaped" state, after which
the next `</script>` no longer closes the element. `JsonEscape.scriptText` handles
only the first sequence, and costs about 300 gas a byte on text made of `<`, so
this library does both in one linear pass (about 170 gas a byte at worst, which
with the 16 KiB limit keeps the page under 4.4M gas for any script). A document
(`text/html`) is inlined as base64 and left as it is: it is never parsed together
with the renderer's markup, and rewriting it would break it.

### Gas

Measured by `forge test --match-contract RendererGas -vv` (Foundry 1.7.1, Solc
0.8.37, optimizer 200 runs): one call through a relay that behaves like Stream's
`tokenURI` (call, copy the string out, return it), cold, with pseudo-random file
bytes. The content store is the real one; the Stream, the satellite and the log are
mocks that answer from storage.

| Stored bytes of the primary file | `Base64` file | `Identity` file |
| --- | --- | --- |
| 32 KiB | 0.32M | 2.59M |
| 64 KiB | 0.46M | 5.12M |
| 128 KiB | 0.97M | 10.56M |
| 256 KiB (the default threshold) | 2.61M | not inlined (it would cost 22M) |

Other measurements: a file over the threshold with a locator, 0.18M; a maximal
record (24,575 bytes with 16 artists and 64 attributes), 1.5M; a 16 KiB script page,
1.6M, and 3.3M to 4.4M for scripts made only of `<`, `</`, `<!-` or `</scrip`; the
worst case (a non-image primary of 256 KiB `Base64`, an 8 KiB `Identity` preview, a
maximal record, a collection, a seed, a dispute and a license), 5.2M. The limit is
8M.
