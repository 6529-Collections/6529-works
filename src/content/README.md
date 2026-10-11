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
| `IContentStore.sol`, `ContentStore.sol` | Permissionless, content-addressed file storage: chunks, manifests, completeness, verified range reads. No owner, no governance, no payable function. |
| `IDependencyRegistry.sol`, `DependencyRegistry.sol` | Governed `(name, version)` to store-file map for shared libraries (p5.js, three.js). Immutable versions, deprecation as a flag. |

Other contracts should depend on the interfaces. Tests are in
[`test/content/`](../../test/content).

### The model

- **Chunk.** Up to 24,575 bytes (EIP-170's 24,576 minus the STOP byte), stored
  as the code of a CREATE2 contract by `src/libraries/SSTORE2.sol`. Its identity
  is `keccak256(bytes)`. Writing bytes that are already stored is a no-op that
  returns the same pointer and emits nothing.
- **Manifest.** An ordered list of chunk hashes, the total stored `length`, a
  MIME type, an `encoding` (`Identity` or `Gzip`) and a declared SHA-256. It can
  be registered before, during or after the upload of its chunks.
- **Layout rule.** Every chunk except the last is exactly 24,575 bytes. An
  offset maps to a chunk by division, one canonical chunking exists for any
  bytes, and a manifest that breaks the rule never completes and never reads.
- **Limits.** 1 to 1,024 chunks (about 25 MB) per file; MIME type 3 to 64 bytes,
  lowercase `type/subtype` from `[a-z0-9+._-]`, no parameters.

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

### Upload flow

Uploads can happen at any time, in any order, by anyone. The mint does not wait
for them, and nobody needs permission to complete a work's on-chain copy.

1. **Chunk the file** off-chain into 24,575-byte pieces (the last one shorter),
   gzipping text first if it should be stored compressed. Compute each chunk's
   `keccak256`, the stored `length`, and the SHA-256 of the decoded file.
2. **Compute the file ID** with the formula above. The artist's package commits
   to it (the store itself needs nothing at this point).
3. **Register the manifest** with `registerManifest`. It is cheap (about 1.05M
   gas for 1 MB) and can be done by the artist, the platform or a collector.
4. **Find what is missing** with `missingChunks(fileId)`, which returns the
   indexes still to be uploaded, and `isComplete(fileId)` for the yes or no.
5. **Upload chunks** with `writeChunk(bytes)`, in any order and across as many
   transactions as needed. Because `writeChunk` does not depend on the caller,
   any batching tool works (for example Multicall3, to fit about three chunks, 72
   KB, in one transaction). A collector, the designated payer in the product,
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
  media hash they committed to. It is the hash of the **decoded** file (after
  gunzip for `Gzip`), the same value a work record lists as the media hash.
  `length` is the **stored** length that `read` returns.
- **Verify a file off-chain:** read all chunks, concatenate, gunzip if
  `encoding` is `Gzip`, SHA-256, compare with `fileInfo(fileId).sha256Hash`. A
  manifest whose declared digest is wrong yields a different file ID from the
  honest one, so it cannot displace it.

### Gas

Measured by `forge test --match-contract Gas -vv` (Foundry 1.7.1, Solidity
0.8.37, optimizer 200 runs), gas used by the call:

| Operation | Gas |
| --- | --- |
| `writeChunk`, 24,575 bytes (new) | 5,020,000 (about 204 gas per byte, 0.21 ETH per MB at 1 gwei) |
| `writeChunk`, bytes already stored | under 20,000 |
| `registerManifest`, 100 KB / 1 MB / 1,024 chunks | 212,000 / 1,055,000 / 22.8M |
| `isComplete`, 1 MB (43 chunks) | 67,000 |
| `readChunk`, one full chunk | 24,000 |
| `read`, 100 bytes inside one chunk | 17,000 |
| `read`, 100 KB (5 chunks) | 182,000 |
| `read`, 256 KB (11 chunks, the inline threshold) | 777,000 |
| `read`, 1 MB (43 chunks) | 9,392,000 |

`read` costs grow faster than linearly because Solidity memory does, and the
returned `bytes` is ABI-encoded into a second buffer, so the callee holds twice
the file size. On-chain callers that handle large files should read in ranges
(a few hundred KB) or chunk by chunk. The store releases each verified chunk
buffer after copying, so memory is the output size plus one chunk.

### DependencyRegistry

Generative works load pinned libraries by name and version. The registry maps
`(bytes32 name, bytes32 version)` to a store file:

- **Labels** are 1 to 32 ASCII bytes from `[A-Za-z0-9._+-]`, for example
  `three` and `r170`, or `p5` and `1.9.0`.
- **`register(name, version, fileId)`** is restricted (AccessManager). The file
  must be registered and on-chain complete, so every registered version is
  readable for as long as the chain exists. A registered version can never be
  changed or removed: there is no function that rewrites an entry.
- **`deprecate(name, version)`** is restricted and sets a one-way flag. It
  deletes nothing, and the version stays resolvable and readable, so works that
  pin it keep rendering.
- **`resolve(name, version)`** returns the file ID, the deprecated flag and the
  manifest data. The gzip flag and MIME type come from the file's manifest.

**Governance TODO.** The registry only calls `restricted`. Granting `register`
and `deprecate` to a registrar role (from `src/governance/Roles.sol`, owned by
the governance lane, with a delay because a version is forever) is a
deployment-time `setTargetFunctionRole` call. The tests use a local role until
that file lands.
