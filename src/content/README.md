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
  chunks per file, which is 12,582,400 bytes (about 12.58 MB). MIME type up to 64
  bytes, lowercase `type/subtype` from `[a-z0-9+._-]`, no parameters.
- **Why 512 chunks.** Fusaka's EIP-7825 limits every transaction to 16,777,216
  gas. Under Prague, registering a manifest at 512 chunks costs 11.8M gas
  including calldata and the 21,000 base, so it fits with room for repricing
  (1,024 chunks would not). Glamsterdam reprices state creation, and on Sepolia
  the cap bounds only a transaction's regular gas, as observed: the
  registration's regular part still fits, but the whole transaction is about
  57.6M gas. `MAX_CHUNKS` stays 512 as the protocol limit. The largest manifests
  need a chain whose blocks hold them (Sepolia's blocks were 200M on 11 October
  2026), and a gas limit from the offline model or from a node whose RPC gas cap
  is above 50M. See [Gas](#gas) below.

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
3. **Register the manifest** with `registerManifest`. It is cheap next to the
   upload (for 1 MiB, 43 chunks, about 1.1M gas under Prague and 5.3M under
   Glamsterdam) and can be done by the artist, the platform or a collector.
4. **Find what is missing** with `missingChunks(fileId)`, which returns the
   indexes still to be uploaded, and `isComplete(fileId)` for the yes or no.
5. **Upload chunks** with `writeChunk(bytes)`, in any order and across as many
   transactions as needed. A collector, the designated payer in the product,
   finishes what the artist or platform started. Re-sending a chunk costs almost
   nothing. Because `writeChunk` does not depend on the caller, any batching tool
   works (for example Multicall3), but batch only while the batch's regular gas
   still fits the cap:
   - **Glamsterdam:** one full chunk (24,575 bytes) per transaction. A full chunk
     costs about 38.4M gas, so two would be about 77M: more than a node with the
     default 50M RPC gas cap can estimate, and more than many blocks hold.
   - **Prague:** two full chunks (about 49 KB) per transaction, at about two
     thirds of the 16,777,216-gas cap; three reach 97–99% of the cap and are not
     recommended.
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

Two pricing schedules matter. Foundry 1.7.1 has no Amsterdam EVM, so the
`forge` figures below are **Prague** costs. Glamsterdam, which Sepolia has run
since 6 October 2026, reprices state creation: the content store pays for every
stored byte as contract code. Its figures were measured on Sepolia on 11 and 12
October 2026 and are in [Glamsterdam](#glamsterdam) below; mainnet parameters
may differ.

**Prague.** Measured by `forge test --match-contract Gas -vv` (Foundry 1.7.1,
Solidity 0.8.37, optimizer 200 runs). Each figure is the gas the call itself
uses, from a **cold** start: the fixtures are built in a separate transaction, so
the store, its storage and the chunk contracts are all first touches, as in a
fresh `eth_call`. The 21,000 base and calldata are added only where a row says
so.

| Operation | Gas |
| --- | --- |
| `writeChunk`, 24,575 bytes (new): execution | 5,020,000 |
| `writeChunk`, same, as a transaction (execution + 21,000 + 392,000 calldata at 16 gas per byte) | 5,434,000 |
| Upload per MB, as transactions | 231.8M, which is **about 0.23 ETH per MB per gwei under Prague** |
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

#### Glamsterdam

Measured on Sepolia
([`deployments/11155111/flows.md`](../../deployments/11155111/flows.md)): each
transaction's receipt, next to the same transaction replayed with Prague costs.

| Operation | Sepolia (Glamsterdam) | Prague |
| --- | ---: | ---: |
| `writeChunk`, 24,572 bytes (new), as a transaction | 38,364,370 | 5,431,552 |
| `writeChunk`, per stored byte | about 1,548 | about 218 |
| `writeChunk`, the 7,048-byte CC0 legal code | 11,238,006 | |
| `registerManifest`, 1 chunk | 577,375 | 143,475 |
| `registerManifest`, 43 chunks (1 MiB; `eth_estimateGas`) | 5,265,859 | |
| `registerManifest`, 256 chunks (simulated) | 28,784,463 | |
| `registerManifest`, 512 chunks (the cap; extrapolated) | about 57.6M | about 11.8M |
| `attestBase64`, one 24,572-byte chunk | 325,172 | 242,152 |
| A 256 KiB `Base64` work on chain: upload, manifest and attestation | about 413M, **0.41 ETH at 1 gwei** | about 60M, 0.06 ETH |
| A 1 MiB `Base64` work on chain | about 1,650M, **1.65 ETH at 1 gwei** | about 241M, 0.24 ETH |

- **About 7 times dearer.** A new slot costs about 111,000 gas (Prague 22,100), a
  byte of contract code about 1,542 to 1,548 (Prague 200), and an empty contract
  creation about 210,000 (Prague about 53,000). A full 24,575-byte chunk costs
  about 38.4M gas, and storage about 1.65 ETH per MiB at 1 gwei. Reads are not
  repriced (`tokenURI` measured within about 3% of Prague), so the 256 KiB inline
  threshold stands.
- **The transaction cap, as observed.** Sepolia accepts transactions above
  EIP-7825's 16,777,216 when the excess is state-creation gas: the cap bounds only
  the regular gas. The uploader's model bounds a full chunk's regular gas at
  about 5.5M and the largest manifest's at about 11.9M, both within the cap.
- **Estimation.** The public Sepolia RPC caps `eth_estimateGas` and simulations at
  50M gas, as geth and reth do by default. A manifest above about 440 chunks costs
  more, so such a node cannot estimate it: use the
  [uploader's](../../tools/content/README.md#gas-schedules-the-cap-and-quotes)
  offline model (`--schedule glamsterdam`) or a self-hosted node with a raised
  cap.

The uploader prints a cost quote under both schedules for any file. ADR 0004
(gas budgets under Glamsterdam) records the repository's budgets.

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
fails reverts with `RendererReadFailed(target, selector)`: a renderer never returns
plausible metadata for a token it cannot read, and that includes the preferred
locator, where a failure would otherwise silently drop the media. A hostile `token`
can only change what its own call returns, so there is no list of tokens. The gas
caps are 300,000 for most reads and 1,000,000 for the media list, which the satellite
builds with a content-store read per file: 195,000 gas fully cold at 32 files, so a
repricing of cold reads leaves room (a finalized work pins its renderer).

**Records that are not usable.** `openRecord` is permissionless and runs after the
auction starts, and every satellite view reverts until it has. So the renderer
asks `isOpen` first. A work whose record is not open, whose record file is not
completely uploaded yet, or whose record is not acceptable (next section) gets
core-only metadata and never a revert: its name from the collection and serial
(`Spring #12`), the traits Stream knows (`Artist ID`, `Collection`, `Serial`,
`Edition of`, the VRF seed, a dispute statement), the description "The work record
is not available." and a field that says why:

| `record_status` | Meaning |
| --- | --- |
| `not_open` | `openRecord` has not run |
| `incomplete` | the record file is not completely in the content store |
| `invalid` | the record breaks a rule below |

The ARTIST seed is stored when the record opens, so it appears only after.
`fullTokenURI` reverts with `RendererNotInlineable` for such a work: there is
nothing to inline. Reads that fail still revert (above): that is a broken
dependency, not a broken record. So does a work whose media list does not start
with a `PRIMARY` file, and an edition whose content hash is not its master's
primary file's (`RendererRecordInvalid`): the satellite and Editions are meant to
make both impossible, and a renderer should not paper over a broken invariant.

### The record

A work's descriptive record is a JSON file in the content store, stored as
`Identity`, at most 12,288 bytes (12 KiB: `Limits.MAX_RECORD_BYTES`, shared with
`WorkRecords`, which enforces it when a record is set; half a chunk, so one chunk
always holds it). The renderer reads it, checks it as UTF-8 and with `JsonScan`,
and copies validated JSON text, never decoded text:

| Record member | Metadata |
| --- | --- |
| `name` (required, a non-empty string) | `name` |
| `description` (a string) | `description` |
| `artists` (non-empty strings, at most 16) | one `Artist` trait each |
| `year` (an integer, at most six digits) | the `Year` trait |
| `medium`, `dimensions` (strings) | the `Medium` and `Dimensions` traits |
| `attributes` (at most 32 objects, each with only the keys `trait_type`, `value`, `display_type` and `max_value`, each at most once, a printable ASCII `trait_type` without a backslash or two spaces in a row, and a string or number `value`) | its elements, as they are, after the renderer's own traits |
| `dependencies` | validated; a script whose record declares any is not wrapped in the page. Anything but exactly `[]` counts as declaring one (so `[ ]` with a space is read as having dependencies): that fails safe, the script is served by locator |
| any other member (`files`, ...) | validated and ignored |

Write the record as RFC 8785 canonical JSON, as the tooling does: non-ASCII text
stays as UTF-8, and only quotes, backslashes and control characters are escaped.
Text written as `\uXXXX` escapes (what `json.dumps` does by default) is valid, but
each escape counts against the budget below.

**What makes a record invalid** (core-only metadata with `"record_status":
"invalid"`, never a revert: the artist can fix the record until finalize, and
nothing is guessed):

- not `Identity`, over 12,288 bytes, or not well-formed UTF-8;
- not an RFC 8259 object, or one of the scanner's extra rules:
  - a key containing a backslash (so `name` can never be a second `name`);
  - an escape that is `\u0000`, a lone surrogate (`\uD800` to `\uDFFF` outside a
    high-low pair) or has a character that is not a hex digit;
  - a number of more than 24 bytes or with an exponent of more than two digits
    (every number is a finite binary64; parsers read `1e400` differently);
  - more than 1,024 units (`JsonScan.MAX_VALUES`). A unit is a value (a string,
    number, literal, array or object below the top level), a key (two at the top
    level, where it is also hashed and matched) or a backslash escape (a surrogate
    pair is two). A top-level member is three units, a member of a nested object
    two, an element of an array one, an attribute with its four members nine;
  - nesting deeper than 8 levels, or a duplicate of a member the renderer reads;
- a missing or empty `name`, a member of the wrong type, an empty artist, more than
  16 artists, a `year` that is not an integer of at most six digits (so no `1e400`
  and no `2026.5`);
- more than 32 attributes, an attribute that is not an object with a string
  `trait_type` and a string or number `value`, an attribute with a key other than
  `trait_type`, `value`, `display_type` and `max_value` (the keys OpenSea documents,
  so an attribute has at most four members) or with the same key twice (so
  `display_type` cannot be said twice and read two ways), or a `trait_type` that is
  not printable ASCII, has a backslash or two spaces in a row, or is one of the names
  the renderer writes itself (`Artist`, `Artist ID`, `Year`, `Medium`, `Dimensions`,
  `Collection`, `Serial`, `Edition of`, `Seed`, `Dispute statement`) in any case and
  with or without spaces (`SEED`, `Serial `, `ArtistID` included). Those traits are
  the only ones the renderer vouches for, so a record may not show a look-alike:
  - an escape could spell any name, so no backslash;
  - a letter of another script (a Cyrillic `е`), an invisible character (U+200B) or
    a no-break space displays like Latin text, so names are printable ASCII (values
    may be any UTF-8);
  - what is left is case and spacing, which the comparison ignores, and displays
    collapse runs of spaces, so two in a row are refused. ASCII letters that only
    some fonts draw alike (`l` and `I`, `0` and `O`) remain: the renderer's own
    traits come first in the list, and the record is the artist's own;
- more than 512 `%` and `#` characters (`MAX_ESCAPES`).

**Why these bounds.** The cost of a record has to be bounded whatever its bytes,
with the costliest media next to it, under 8M gas. Each kind of byte and each kind
of unit costs differently, and the cost of a record is the sum of what it holds, so
every cap has to be low enough that all of them together stay under the budget.
Measured on a record of 12 KiB of one kind of byte (the bytes, not the media):

| What the record is full of | Gas (about) | Bounded by |
| --- | --- | --- |
| plain ASCII inside strings | 3 a byte | the size |
| white space | 80 a byte (170 inside the attributes, which are walked twice), 12 KiB of it in the attributes 2.1M | the size |
| 2-byte UTF-8 (Cyrillic, accents) | 190 per character, 1.1M | the size |
| 3-byte UTF-8 (CJK) | 330 per character, 1.4M | the size |
| 4-byte UTF-8 (emoji) | 410 per character, 1.3M | the size |
| ASCII and multi-byte text alternating (the validator changes path at each step) | at most 140 a byte, 1.7M | the size |
| a unit (value, key or escape), top-level members dearest | 1,000 to 1,500 | 1,024 together |
| a `%` or `#` | 470 | 512 |
| an attribute (its nine units, and a second walk over it) | 27,000 | 32 |
| a byte of an attribute name (read a word at a time; a name of at most 33 bytes is also read byte by byte to compare it, about 100 gas a byte) | 3 | the size |

A record is validated once, and the pieces the renderer needs are found by walking
it again without checking. The caps are chosen together, not one at a time: a
record at every cap at once (32 attributes of four members, 512 `%`, the rest of
the units as top-level members, an array or a nested object, and the rest of its
12 KiB the costliest mix of UTF-8, or white space in the attributes) costs at most
7.8M gas with 256 KiB of attested `Base64` next to it and 6.4M with the dearest
script; those are the rows of `RendererGasBudgetTest`, the record matrix, and the
dearest of them are measured again on the real stack, with every other cap at once,
by the budget proof (see Gas). Because the whole file is
percent-escaped first, `%` and `#` inside it survive the URI.

### Output

`data:application/json;utf8,` followed by compact JSON. It is not base64: the
media is already base64 text, and encoding it twice would cost gas and a third
more size. Every string from the Stream, a locator or the store (a collection
name, a license identifier, a MIME type, a URL) is checked as UTF-8, escaped by
`JsonEscape` and percent-escaped by `DataUri`. The JSON carries `name`,
`description`, `image`, `animation_url`, `media_url`, `content_type`,
`content_hash` (the primary's decoded SHA-256), the license fields and
`attributes`:

- `license` is the SPDX identifier as stored, in its original case.
- `license_url` is its page on spdx.org (whose URLs are case sensitive, so the
  original case) only for an identifier made of `A-Z a-z 0-9 . + -` that is not a
  `LicenseRef-` expression in any case. For any other license it is a locator of
  the license text file (Arweave or IPFS, the work's preferred one), if the work
  lists that file among its media; otherwise it is left out.
- `license_text_file` is the license text file's ID (0x-prefixed hex), whenever the
  license has one.

### Media

| Primary file | `tokenURI` |
| --- | --- |
| complete, work on-chain complete, stored as `Base64` and attested, at most the threshold | `data:<mime>;base64,` plus the stored text, concatenated as it is |
| the same, stored as `Identity`, at most an eighth of the threshold | base64-encoded on-chain |
| `text/javascript` or `application/javascript`, `Identity`, at most 8 KiB (`fullTokenURI`: 128 KiB), UTF-8, at most 1,024 `<`, no declared `dependencies` | an HTML page that sets `window.works` (version 1) and runs the script (below) |
| anything else: larger, incomplete, unattested `Base64`, `Gzip` or `GzipBase64`, a script with dependencies | the preferred locator (and `media_url`) |

- **The threshold** is `inlineThreshold()`, in stored bytes, set at deployment
  (`DEFAULT_INLINE_THRESHOLD`, 262,144, which is 256 KiB, as the ADR targets). An
  `Identity` file counts eight times against it, because the renderer encodes it
  with OpenZeppelin's `Base64`, which costs about 80 gas a byte against 10 for
  copying text that is already base64. A 256 KiB `Base64` file fits 8M gas with
  room to spare; an `Identity` file fits only up to 32 KiB. **Store media that will
  be inlined as `Base64`.**
- **`Base64` needs an attestation.** The stored text is concatenated into a JSON
  string inside a `data:` URI without a look at it, so it has to be exactly
  base64: nothing else could be allowed to hide a `"` or a `#` there. The content
  store provides a permissionless, one-time, strict check, `attestBase64(fileId)`
  (every chunk is read once; only the standard alphabet with `=` padding at the
  very end; a pass is final), and `isBase64Attested(fileId)`. The renderer inlines a
  `Base64` file, primary or preview, only if it is attested, and otherwise serves
  the locator (and `fullTokenURI` reverts), so anyone can switch a token to inline
  by attesting its file. **Curation tooling must decode base64 strictly** (reject
  whitespace, `-_`, bad padding, trailing bytes): a lenient decoder drops what the
  attestation refuses, and the SHA-256 check would pass a file that can never be
  attested. An attested `GzipBase64` file is still never inlined.
- **`Gzip` and `GzipBase64` are never inlined.** Their stored bytes are a
  compressed stream, not the media, so a `data:` URI of them would carry the wrong
  bytes under the media's MIME type. They are served by locator.
- **Complete** means the work is on-chain complete (`RecordInfo.onChainComplete`)
  and `isComplete` is true for the file in the store. A missing chunk falls back to
  the locator, and the same token switches to inline once the last chunk is
  uploaded.
- **Fields.** `image` is the primary when it is an image and inlined; otherwise the
  on-chain preview if the work lists a `PREVIEW` image that is complete, attested if
  `Base64`, and within `PREVIEW_LIMIT` (65,536, cost-weighted like the threshold),
  else the primary's locator for an image, else the preview's locator. A 6529 Stream
  work's previews are smaller still: `WorkRecords.openRecord` refuses a `PREVIEW` file
  over `Limits.MAX_PREVIEW_BYTES` (16 KiB stored, an `Identity` file counting four
  times, so 4 KiB of `Identity` or 16 KiB of `Base64` text), which keeps the budget
  below.
  `animation_url` is the primary when it is not an image (inline, or its locator).
  `media_url` is the primary's preferred locator whenever the primary is not
  inlined.
- **The preferred locator** is `IWorkRecords.preferredLocator`, used as the
  satellite answers it: a file without a copy, or whose preferred copy is on-chain,
  has no URL (kind NONE or ONCHAIN) and the field is left out; the renderer does not
  look through the list for another copy. Inline wins over the preference: a
  complete file under the threshold is inlined whatever the preferred kind.
- **`fullTokenURI`** raises the limit to 1 MiB (`MAX_INLINE_BYTES`), cost-weighted
  (a `Base64` file up to 1 MiB, an `Identity` file up to 128 KiB), and reverts with
  `RendererNotInlineable` instead of falling back: for a record that is not open,
  incomplete or invalid, and for a primary that is not on-chain complete, not
  complete, too large, an unattested `Base64`, a script with dependencies, or not
  `Identity` or `Base64`. It is an off-chain view with no 8M promise: 256 KiB of
  `Base64` costs 2.6M, 512 KiB 8.4M and 1 MiB 30M (memory expansion makes it
  quadratic), so it is for `eth_call`, where nodes allow tens of millions of gas.
- **Memory.** Media is read one store chunk at a time, straight into the single
  output buffer, and each chunk buffer is released after it is copied, so there is
  no second copy of the file. An `Identity` file also needs its raw bytes and the
  encoded text as transient buffers.

### The page around a script

A JavaScript primary cannot be shown as a `data:` URI, so the renderer wraps it: a
fixed HTML page (`<html lang="en">`) with two scripts. The first sets

```js
window.works = { v: 1, tokenId: <id>, seed: <"0x…" hex string, or null> };
```

and the second is the work's script, which therefore cannot see or change how the
object was written. `seed` is null when the work has no seed. **This object is a
public, stable API.** A finalized work pins its renderer, so scripts in the field
depend on it exactly as it is: the `window.works` of version 1 never changes
meaning, and any change to its fields needs a new `v` (and so a new renderer).
Scripts should check `window.works.v`.

The script text is the only artist-controlled text placed inside the renderer's own
markup, so it goes through `HtmlScript.neutralize`: `</script` (any case) and
`<!--` each gain a backslash after the `<`, which keeps their meaning inside
JavaScript strings, template literals and comments. `<!--` matters because it can
start the HTML parser's "double escaped" state, after which the next `</script>`
no longer closes the element. `JsonEscape.scriptText` handles only the first
sequence, and costs about 300 gas a byte on text made of `<`, so this library does
both in one pass, a word at a time, jumping from `<` to `<`: a script costs about 5
gas a byte plus about 450 gas for each `<`. A script of nothing but `<` would cost
3.7M gas at 8 KiB, so a script with more than 1,024 `<` (`MAX_SCRIPT_LT`; real
scripts have tens or hundreds) is not wrapped but served by locator, and the
dearest page that is wrapped costs 1.5M gas (2.7M for the script that costs most to
validate as UTF-8). A script is wrapped up to 8 KiB (`SCRIPT_LIMIT`) by `tokenURI`,
which has the 8M promise; larger scripts are served by locator there, and
`fullTokenURI`, which has no such promise, wraps them whole. A document (`text/html`) is inlined
as base64 and left as it is: it is never parsed together with the renderer's
markup, and rewriting it would break it.

**What the rewrite changes, for artists.** It is exact where the sequences can
occur in well-formed JavaScript: strings, template literals and comments. Outside
them it changes the program. The page uses a classic script, in which `<!--` starts
a single-line comment, so `a<!--b` is a comment to the browser and a syntax error
after the rewrite; and `x</script/i.test(s)` (a comparison with a regular
expression) becomes a different expression. Split the sequence in code that needs
it (`"<" + "/script"`) and it passes through unchanged.

### Gas

Measured by `forge test --match-path 'test/content/renderer/RendererGas*' -vv`
(Foundry 1.7.1, Solc 0.8.37, optimizer 200 runs): one call through a relay that
behaves like Stream's `tokenURI` (call, copy the string out, return it), cold (the
fixtures are built in `setUp`, a separate transaction, and each test measures one
work), with pseudo-random file bytes. The content store is the real one; the Stream,
the satellite and the log are mocks that answer from storage.

| Stored bytes of the primary file | `Base64` file | `Identity` file |
| --- | --- | --- |
| 32 KiB | 0.32M | 2.59M |
| 64 KiB | 0.46M | 5.12M |
| 128 KiB | 0.97M | 10.57M |
| 256 KiB (the default threshold) | 2.63M | not inlined (it would cost 22M) |

A file over the threshold with a locator costs 0.18M. A script page (at most 8 KiB
of `Identity`, UTF-8, at most 1,024 `<`) costs 0.9M for plain code, at most 1.5M for
the dearest to neutralize (1,024 `</script`), and 2.7M, with its record and every
read, for the dearest to validate (8 KiB of ASCII and U+0800 alternating). A script
over the size or the `<` cap is served by locator by `tokenURI` (0.6M); `fullTokenURI`
wraps a script up to 128 KiB (its limit is the size check of the full form).

**The budget proof** is `test/integration/TokenUriBudget.t.sol`, on the real stack
(Stream, WorkRecords, the content store, the statement log and this renderer, as
deployed): every cap a work can reach at once, measured cold through
`Stream.tokenURI` and `Editions.uri`. The dearest records of the matrix below (white
space in all the room the attributes leave, before each or after every token, with
top-level members or an array of zeros, and the dearest UTF-8 fill), next to 256 KiB
of attested `Base64` `text/html` (inlined), a `PREVIEW` image at the WorkRecords cap
(4 KiB of `Identity` or 16 KiB of attested `Base64`, inlined), 32 media files, a
64-byte `LicenseRef` license whose text file is served by locator, 16 locators on it
(the longest, 66 bytes, served last), a collection name of 256 `%`, an ARTIST seed
and a dispute statement:

| Row | Gas |
| --- | --- |
| white space before each attribute, an array of zeros (the dearest) | 7.69M |
| the same, rendered as the edition of its master (`Editions.uri`) | 7.70M |
| the same, the preview as 16 KiB of `Base64` | 7.60M |
| white space after every token, an array of zeros | 7.67M |
| white space before each attribute, top-level members | 7.66M |
| `aa` and a 2-byte sequence, an array of zeros | 7.33M |

The WorkRecords caps are what make it hold. Without them the same work cost up to
9.8M: a locator could be 2 KiB of `%` (each escaped at about 470 gas), and a preview
up to the renderer's own limit (8 KiB of `Identity` or 64 KiB of `Base64`, up to 1.2M
more).

**The record matrix.** A record at every cap at once, with the dearest media: a
non-image primary of 256 KiB attested `Base64`, the script of `</script` with the most
`<`, or a script of ASCII and U+0800, an 8 KiB `Identity` preview (the renderer's own
limit, above what WorkRecords lets a work have), a collection whose
name is all `%`, a seed, a dispute and a `LicenseRef` license with a text file and a
locator. The record is 12 KiB with 32 attributes of four members (the most each may
have), 512 `%` and the rest of the 1,024 units as top-level members, an array of zeros
or members of a nested object, and the rest of its bytes one fill. All are accepted,
cold, and asserted under 8M by `RendererGasBudgetTest`, with the mocks:

| The fill of the rest of the record (top-level members) | 256 KiB `Base64` | script of `a` and U+0800 |
| --- | --- | --- |
| ASCII | 6.4M | - |
| 2-byte UTF-8 | 7.1M | - |
| 4-byte UTF-8 | 7.2M | - |
| U+0800 (E0), U+D000 (ED) | 7.3M | - |
| `a` and U+0800 alternating | 7.3M | 6.1M |
| `a` and a 4-byte sequence alternating | 7.2M | 6.0M |
| `aa` and a 2-byte sequence alternating (the dearest) | 7.4M | 6.2M |

With an array of zeros or nested members instead of top-level members the numbers
are the same within 0.1M (7.4M the dearest, with `aa` and a 2-byte sequence), and
with the script of `</script` 5.7M to 5.8M.

White space in the attributes is the dearest byte there is, because the attributes
are walked twice (the check, and the walk that finds their members): 170 gas a byte
against 130 for the dearest UTF-8. The rows put it before every attribute, or after
every one of the 17 tokens of each, in half of the room the attributes leave or in
all of it (nothing else but the minimum of fill), with the other caps all at their
limit: 7.6M for half, **7.8M for all of it, the worst row** (7.7M after every
token), and 6.4M with the script of `a` and U+0800. The cost rises with the number
of attributes (measured with all the room as white space for 1, 2, 4, 8, 12, 16, 24
and 32), so the most is the worst case.

**Each class of byte and each limit on its own**, at the full 12 KiB, each with 256
KiB of `Base64` or the script of `</script` (asserted at most 8M by
`RendererGasAdversarialTest`):

| Record | with `Base64` | with the script |
| --- | --- | --- |
| 1,024 units, in an array of zeros | 4.8M | 3.5M |
| 340 top-level members | 4.7M | 3.5M |
| 32 attributes of four members and 727 more units | 5.6M | 4.3M |
| 32 attributes with 132-byte names | 4.7M | 3.3M |
| the same, 16 `%` in each name | 5.0M | 3.6M |
| 512 `%`, one every sixth byte | 4.7M | 3.2M |
| 1,018 `\\` escapes in 12 KiB of text | 4.8M | 3.3M |
| 1,018 `\u00e9` escapes in 12 KiB of text | 5.6M | 4.1M |
| 509 surrogate pairs in 12 KiB of text | 5.4M | 4.0M |
| 12 KiB of 2-byte, 3-byte, 4-byte UTF-8 | 5.5M, 5.6M, 5.5M | 4.0M, 4.1M, 4.1M |
| 12 KiB of white space / pretty-printed values | 5.0M / 5.5M | 3.8M / 4.2M |

and refused records stay cheap, since the scan stops at the first fault: 12 KiB of
escapes (over the budget) 1.2M to 2.0M, of `\u0000` 0.6M, of `%` past the cap 0.6M,
arrays of zeros or `[]` 1.5M to 1.7M, empty or tiny members 1.5M to 1.6M, 33
attributes 0.9M, attribute names with a backslash 1.1M, names of 2-byte UTF-8 (not
ASCII) 1.6M, or with 16 `%` each as well 1.8M, and an attribute with a
fifth key found only at the last of 32 (the check, then the walk to the end, with the
record full of white space) 2.6M. Every figure includes
the mocks' own reads.

### Known gaps in v1

- **No gzip page.** `Gzip` and `GzipBase64` files are served by locator only. A
  later renderer can add a decompression page (renderers are pinned per work).
- **No dependency bundling.** Libraries from the dependency registry are not
  inlined into the script page; a script page is one self-contained file, and a
  script whose record declares `dependencies` is served by locator.
- **Scripts only up to 8 KiB** and with at most 1,024 `<` go through the page in
  `tokenURI` (up to 128 KiB in `fullTokenURI`), and `Identity` media only up to an
  eighth of the threshold (32 KiB at the default); bigger files go by locator, or
  should be stored as `Base64` (or, for an HTML artwork, as `text/html`).
- **Core-only metadata** (a record that is not usable) has no ARTIST seed, because
  that seed is stored when the record opens.
- **Records are bounded**: 12 KiB, 1,024 units (values, keys and escapes), 32
  attributes with only the four OpenSea keys and printable ASCII names, 512 `%` or
  `#`, numbers of 24 bytes. A work
  whose record needs more should keep the rest in the files the record points to,
  and write non-ASCII text as UTF-8 rather than `\uXXXX` escapes.
