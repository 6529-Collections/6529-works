# Content store uploader tooling

Off-chain tooling that lets an artist, a collector or the network stage a work's
bytes into the [content store](../../src/content/README.md) and then verify them
or rebuild them from the chain. It implements the upload flow of
[ADR 0001 section 8](../../docs/adr/0001-v1-scope.md#8-works-content-and-storage)
and has to agree with `ContentStore` byte for byte: a different chunk hash or
file ID is not a rounding error, it names a different file.

Python 3.12, standard library only. Nothing here signs or sends a transaction
and nothing handles a private key. Pre-audit software, like the contracts.

```bash
python -m tools.content plan art.png --mime image/png --encoding base64
python -m tools.content calls art.png.content.json --store 0xSTORE --schedule glamsterdam
python -m tools.content verify  --rpc "$ETH_RPC_URL" --store 0xSTORE 0xFILEID
python -m tools.content rebuild --rpc "$ETH_RPC_URL" --store 0xSTORE 0xFILEID -o art.png
python -m tools.content cid art.png                     # the ipfs:// locator (offline)
```

Use `--schedule glamsterdam` for Sepolia, which has priced state creation under
Glamsterdam since 6 October 2026; Prague limits run out of gas there (see
[Gas](#gas-schedules-the-cap-and-quotes)).

Run from the repository root. Exit codes: `0` success, `1` the file did not
verify (or is incomplete), `2` bad input or an unreachable endpoint.

## Commands

### `plan FILE --mime TYPE --encoding identity|gzip|base64|gzipbase64`

Produces the exact stream the store will hold, cuts it into chunks, and writes a
JSON manifest.

1. Applies the encoding (gzip with the [fixed profile](#gzip-profile), base64
   with the RFC 4648 section 4 alphabet, `=` padding and no line breaks).
2. **Proves the encoding reproduces:** the stored stream is decoded and the
   result encoded again, and the two streams must be identical, or no plan is
   made.
3. Cuts the stream into chunks of exactly `CHUNK_SIZE` (24,575) bytes, the last
   one shorter, and rejects a stream that is empty or needs more than
   `MAX_CHUNKS` (4,096) chunks. The input file size is checked first, so an
   oversize file is refused before it is read.
4. Hashes each chunk (`keccak256`), computes the SHA-256 of the **decoded**
   media, and computes the file ID exactly as `ContentStore.manifestId` does.
5. Validates the MIME type with the contract's rule (lowercase `type/subtype`
   from `[a-z0-9+._-]`, one slash, at most 64 bytes).
6. For `base64` and `gzipbase64`, checks the stored text against the
   [attestation rule](#base64-attestation) and refuses a stream that
   `attestBase64` would revert on, before any transaction pays for it.

Output: `<FILE>.content.json` (or `-o`) and, unless the stream is the input file
itself, `<manifest>.stored` beside it: the exact stored bytes. **For a gzip or
base64 encoding, publish that `.stored` stream (Arweave or IPFS) as a locator
next to the decoded media.** The file ID commits to those exact bytes, and gzip
output depends on the compressor, so nobody can promise to reproduce it later;
see [Works and storage](../../docs/spec/works-and-storage.md#concepts).

`plan` also prints a **cost quote** for putting the file on chain (registration,
one write per distinct chunk, and the attest calls of a base64 file) under each
gas schedule, as total gas and as ETH at `--gwei` per gas (default 1). This is
what a collector pays to make a work on-chain complete; see
[cost quotes](#cost-quotes). With `--part-size BYTES` it also quotes writing each
chunk as parts of that size joined by `linkChunk`, so whole chunks and parts can
be compared under both schedules.

`--already-encoded` takes a stream you already have (for example fetched from
Arweave) instead of media. It must decode cleanly; the media SHA-256 comes from
the decoded bytes, and the manifest records whether this tool's encoder would
have produced the same stream (`"reproducible": false` for a foreign but valid
gzip stream).

### `calls MANIFEST --store ADDRESS`

Emits the ordered transactions, **without broadcasting anything**:

- the registration (first by default; `--register last` puts it after the
  chunks): one `registerManifest` for a manifest of up to 16 chunks, otherwise
  the chunk-hash list as list chunks (`writeListChunk`, 767 hashes each, ordinary
  `writeChunk` calls) and one small `registerManifestList`, which registers the
  same file ID. `--manifest one|list` forces either; one call stores a slot per
  hash and stops fitting a transaction at a few hundred chunks, list chunks never
  do, and cost less from a few chunks up;
- one `writeChunk` per **distinct** chunk (a file that repeats a chunk needs it
  stored once), or, with `--part-size BYTES`, each chunk longer than BYTES as
  parts of that size (`writePart`, ordinary `writeChunk` calls) and one
  `linkChunk`, which stores the same chunk with the same hash. Parts keep every
  transaction small if code deposits are ever repriced or capped per transaction;
  today they cost about 6% more under Prague and about 3% more under Glamsterdam
  for 8,192-byte parts;
- for a `Base64` or `GzipBase64` file, `ceil(chunks / N)` calls to
  `attestBase64(fileId, N)` (`--attest-chunks N`, default 48) **last**, after the manifest is registered and every
  chunk is stored, because attestation reads the chunks (see
  [Base64 attestation](#base64-attestation); `--no-attest` leaves them out);
- ABI-encoded calldata in `<manifest>.calls/NNN-<name>.calldata`, a machine
  readable `calls.json` (per transaction: the gas estimate with its regular and
  state parts, and the recommended gas limit and where it came from; for the
  whole set: the schedule, the cost quotes and any warnings), and `send.sh`, a
  script of `cast send` lines that is also printed to stdout (`--json` prints
  `calls.json` instead).

Gas options (see [Gas](#gas-schedules-the-cap-and-quotes)):

- `--schedule prague|glamsterdam` prices every transaction and sets its gas
  limit. `prague` is the default. Use `glamsterdam` on a chain that runs it, such
  as Sepolia. With `--rpc` on Sepolia, `prague` is refused.
- `--gas-limits rpc` (needs `--rpc`) takes each gas limit from the node's
  `eth_estimateGas` plus 10 percent instead of from the model. A call the node
  cannot estimate keeps the model's limit, with a warning: the attest calls
  revert until every chunk is stored, and a node with the default 50M RPC gas
  cap refuses a larger call. The quotes always come from the model.
- `--block-gas GAS` is the target chain's block gas limit (default 60,000,000,
  a deliberately conservative assumption). Under `glamsterdam` no gas limit is
  set above it, and a transaction that would not fit a block is flagged.
- `--gwei PRICE` is the gas price for the cost quote (default 1).

Before emitting anything it re-proves that the stored stream is the one the
manifest commits to (length, every chunk hash, and the decoded media SHA-256),
and it refuses a manifest whose `fileId` is not the hash of its own fields.

`--only-missing --rpc URL` asks the chain and drops what it already has: a
registered manifest, any chunk the store already holds (whole or linked, found
with `firstMissing` over ranges of 256 chunks once the manifest is registered),
any part or list chunk already written, and the attest calls if
`isBase64Attested` is already true. That is how a stopped upload resumes, and how
a collector finishes an upload the artist started; its cost quote is what
finishing costs. Pass the same `--part-size` and `--manifest` as the first run.
(Against a store that has no `attestBase64` it warns and emits no attest
calls.)

Run `send.sh` yourself, with your own signer:

```bash
export ETH_RPC_URL=...                 # your endpoint
export SIGNER="--account my-keystore"  # or --ledger, --trezor, ...
bash art.png.content.calls/send.sh
```

`SIGNER` holds your `cast` signer flags. Never put a raw private key in it or in
shell history. Each line reads its calldata from a file because a full chunk is
about 49,000 hex characters. **On Windows, run `send.sh` from WSL, Linux or
macOS:** a native Windows process takes at most about 32,000 characters of
command line. Alternatively feed the calldata files, listed in `calls.json`, to
any other sender (ethers, viem, a Safe transaction builder).

### `verify --rpc URL --store ADDRESS FILEID`

Read-only (`eth_call` and `eth_getCode` only). Trusts neither the RPC nor the
contract:

- checks there is a contract at the address and that its `CHUNK_SIZE` and
  `MAX_CHUNKS` are the ones this tool hashes with;
- reads `fileInfo` and every `chunkHash`, **recomputes the file ID** from them
  and compares it with the one you asked for;
- asks `missingChunks` and **reports which chunks are missing**, then reads each
  present chunk with `readChunk` and re-hashes it;
- once complete, checks the length, decodes the stored bytes and compares the
  SHA-256 with the declared one, and reports whether this tool's encoder
  reproduces the stored stream (informational);
- for a `Base64` or `GzipBase64` file, **reports whether it is base64-attested**
  (`isBase64Attested`) and how many `attestBase64` calls it still needs, and
  checks the stored text against the attestation rule. A complete, correct file
  that is not attested yet still verifies (its bytes are fine), but renderers
  will not inline it; `--require-attested` makes that exit 1. If the store says
  a file is attested while its text fails the rule, that is a problem (wrong
  store, or an untrustworthy RPC).

`--json` prints a machine-readable report. Output never contains the RPC URL
(it usually carries an API key): errors name only scheme, host and port.
`--rpc` defaults to `$ETH_RPC_URL`.

### `rebuild --rpc URL --store ADDRESS FILEID -o OUT`

Runs the same verification and writes the decoded media only if every check
passed, atomically, and never over an existing file without `--force`.
`--stored` writes the stored (encoded) stream instead, which is what to re-publish to
Arweave or IPFS.

### `cid FILE`

Prints the IPFS CID of the file's exact bytes under the fixed profile of
[ADR 0001 section 8](../../docs/adr/0001-v1-scope.md#8-works-content-and-storage), and the
`ipfs://` locator `WorkRecords.addLocator` accepts for it. Offline: nothing is read but the
file, which is streamed one chunk at a time, so a file of any size works.

The profile is CIDv1, sha2-256, raw leaves, a fixed 262,144-byte chunker and the balanced
UnixFS layout with at most 174 links per node, in lowercase base32. A file of at most one chunk
is a single raw block (`bafkrei...`, the SHA-256 of the file); a larger file's root is a dag-pb
node (`bafybei...`). It is what kubo prints with its default import settings for

```bash
ipfs add --only-hash --quieter --cid-version=1 --raw-leaves --chunker=size-262144 FILE
```

so pin with the same settings: another chunker, layout (`--trickle`), CID version, hash or
`--inline` gives another CID for the same bytes, and a kubo configured with another
`Import.UnixFSFileMaxLinks` or `Import.UnixFSChunker` (for example the `unixfs-v1-2025`
profile's 1 MiB chunks) does too. Never use `ipfs add -w` (`--wrap-with-directory`) output: its
last line is the wrapping directory's CID, which names a directory, not the file, and a path
under it (`ipfs://<dir>/art.png`) is not a locator `WorkRecords` accepts. The command repeats
these warnings on stderr (`-q` silences them). For a gzip or base64 encoding the locator names
the stored stream, so run it on `plan`'s `.stored` file.

`--json` prints the CID, the locator, the size, the number of chunks, the root's kind and depth,
and whether the locator passes the `WorkRecords` rule.

How it is checked (`test_cid.py`): the published CIDs of an empty file and of `hello world`; the
root blocks of [IPIP-0499](https://specs.ipfs.tech/ipips/ipip-0499/)'s own test fixtures
(`golden/ipip-0499-blocks.json`), each authenticated by its CID and re-encoded byte for byte,
among them kubo's 174-link node and its rebalanced two-level root; an independent statement of
the balanced layout at small sizes; Python's base32; and kubo itself whenever `ipfs` is on the
`PATH`. `golden/cid-vectors.json` and the generated `test/content/tooling/CidGoldenData.sol`
carry the golden CIDs into Foundry, where `CidGolden.t.sol` adds each as a locator on the real
`WorkRecords` and re-derives the raw ones from their SHA-256.

## How it maps to the contract

| Rule | Contract | Here |
| --- | --- | --- |
| Chunk size | `CHUNK_SIZE = SSTORE2.MAX_CHUNK_LENGTH = 24_575` | `plan.CHUNK_SIZE` |
| Chunk count | 1 to `MAX_CHUNKS = 4096` | `plan.check_stored_length` |
| Parts of a linked chunk | 1 to `MAX_PARTS = 256`, any sizes | `plan.split_parts` |
| Hashes per list chunk | 767 (`CHUNK_SIZE // 32`) | `plan.list_chunks` |
| Layout | every chunk but the last is full | `plan.split_chunks` |
| Chunk hash | `keccak256(chunk)` | `keccak.keccak256` (pure Python, not `hashlib.sha3_256`) |
| File ID | `keccak256(abi.encode(bytes32[] chunkHashes, uint256 length, uint8 encoding, string mimeType, bytes32 sha256Hash))` | `plan.manifest_id` |
| `length` | the **stored** length | same |
| `sha256Hash` | SHA-256 of the **decoded** media | `plan.plan_from_media` |
| MIME type | `_requireMime` | `plan.validate_mime` |
| Calldata | `writeChunk(bytes)`, `registerManifest(...)` | `abi.encode_write_chunk`, `abi.encode_register_manifest` |

The file ID is not a content-uniqueness key: it also binds the MIME type and the
encoding. Uniqueness checks belong on `mediaSha256`, which is the same for every
encoding of the same media.

## Gzip profile

Fixed, so a stream is reproducible from its media with this tool:

- header `1f 8b 08 00 00000000 02 ff`: deflate, no flags (no file name, no extra
  field, no comment), **MTIME 0**, XFL 2, OS 255 (unknown), written by hand
  because zlib's own wrapper writes a platform-dependent OS byte;
- raw deflate from **zlib at level 9**, memLevel 8, window 15, default strategy;
- trailer: CRC-32 and size modulo 2^32.

Decoding is strict: exactly one gzip member, correct CRC and size, no trailing
bytes, bounded output (512 MiB), canonical base64 only. A foreign gzip stream is
still storable (`plan --already-encoded`); it is just not reproducible here.

Be honest about the limit: the deflate bytes depend on the zlib implementation.
Stock zlib has produced the same bytes for these settings across releases, but
zlib forks (zlib-ng and others) differ. That is why `plan` re-checks
reproduction on the machine it runs on, why the manifest records the zlib
version, and why the encoded stream itself must be kept and published.

## Base64 attestation

A renderer copies a `Base64` or `GzipBase64` file's stored text verbatim into
token JSON and `data:` URIs, and the store never looks at bytes while chunks are
uploaded, so such a file is only a claim until `ContentStore.attestBase64(fileId, count)`
has validated it. Anyone may call it, it is incremental (up to `count` chunks per
call, the caller's choice, repeat until it returns true) and
permanent, and `isBase64Attested(fileId)` is what the renderer checks.

The rule, which `base64_attestation_problem` in [`encoding.py`](encoding.py)
mirrors: the length is a multiple of 4, every byte is in `[A-Za-z0-9+/]`, and `=`
appears only as the last one or two bytes of the whole text (padding may
straddle the last chunk boundary). Canonical trailing bits are not checked.
Anything else, such as the URL-safe `-` and `_`, whitespace, a quote, a
backslash, a byte of `0x80` or more, or `=` in the middle, makes the call revert
with `ContentBase64Invalid(fileId, chunk)` (or `ContentBase64LengthInvalid`).

What the tooling does about it:

- **Before anything is emitted**, `plan --already-encoded` and `calls` run the
  rule on the stored text and refuse a stream that would fail on chain, naming the
  chunk the contract would report. (Text this tool encodes itself always passes.)
- **`calls`** appends the attest calls, `ceil(chunks / 48)` of them by default:
  1 up to 48 chunks (about 1.18 MB), 2 for 49 to 96, and 86 for the 4,096-chunk
  maximum. Each is the same 68 bytes of calldata, `attestBase64(fileId, 48)`, and each carries its
  own gas estimate. They come last because each call reads the chunks it
  validates and the call that reaches the end of the file also reads the last
  chunk to find the padding, so the final call cannot succeed before the manifest
  is registered and every chunk is stored. (Earlier calls on a big file do not
  need the end and could run while the upload is still going; the tool keeps one
  simple order.) Repeating a call on an attested file is a cheap no-op that
  returns true.
- **`verify`** reports the status (above).

Cost falls on whoever calls it: about 175,000 gas per chunk, so about 8.5M gas for
a full call of 48 distinct chunks (about half the Fusaka cap), and about 90M gas
for a 512-chunk file (about 720M for 4,096). Attestation only reads chunks, so Glamsterdam adds only the
new slot that records it: about 89,000 gas once per file.

## Manifest JSON

`schema` is `6529-works/content-plan/v1`. Deterministic (no timestamps), fixed key
order:

```json
{
  "schema": "6529-works/content-plan/v1",
  "fileId": "0x...",
  "mimeType": "image/png",
  "encoding": "base64",
  "encodingId": 2,
  "mediaSha256": "0x...",
  "mediaLength": 268,
  "storedLength": 360,
  "storedSha256": "0x...",
  "chunkSize": 24575,
  "chunkCount": 1,
  "chunkHashes": ["0x..."],
  "reproducible": true,
  "storedFile": "art.png.content.stored",
  "source": "art.png"
}
```

Gzip encodings add an `encoder` block with the profile and the zlib version.
`calls` re-derives the file ID from the fields and rejects a manifest where it
differs, so editing a manifest cannot change what gets sent. `storedFile` must
be a plain file name beside the manifest: a manifest from someone else cannot
point the tool at an arbitrary local file.

## Gas: schedules, the cap and quotes

`calls` prices every transaction with an offline model (`gas.py`) under one of
two schedules, and `plan` and `calls` quote both. Foundry 1.7.1 has no
Amsterdam EVM, so every `forge` gas figure in this repository is a Prague
figure; the Glamsterdam constants come from Sepolia receipts.

### Prague (the default)

[EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) caps every transaction at
16,777,216 gas. The model is execution plus 21,000 plus calldata, or the EIP-7623
floor if higher. `calls` refuses to emit any transaction above the cap, warns
above three quarters of it, and sets `--gas-limit` to the estimate plus 10
percent, never above the cap.

| Transaction | Model (execution) | Measured on `ContentStore` | As a transaction |
| --- | --- | --- | --- |
| `writeChunk`, new 24,575-byte chunk | 5,107,875 | 5,020,261 | about 5.5M (33% of the cap) |
| `registerManifest`, 512 chunks, `text/html` | 11,777,200 | 11,638,687 | about 12.1M (72%) |
| `writeChunk`, 8,192-byte part | 1,749,360 | 1,710,142 | about 1.86M (11%) |
| `linkChunk`, 3 parts, 24,575 bytes | 153,575 | 114,196 to 130,196 | about 0.15M (1%) |
| `registerManifestList`, 4,096 chunks in 6 list chunks, 64-byte MIME | 2,808,200 | 2,414,947 | about 2.4M (14%) |
| `attestBase64`, the worst call (48 cold chunks, then the last chunk for the padding) | 8,790,000 | about 8,500,000 | about 8.8M (53%) |

`writeChunk` is priced as a new chunk, the worst case; a chunk the store already
holds costs about 16,000. `attestBase64` is priced at 150,000 plus 180,000 per
chunk validated. The worst call is 48 checked chunks plus one read of the file's
last chunk for the padding (the call that reaches the end of the file does that;
earlier calls do not), measured at about 8.50M against the model's 8.79M. The
model constants (`gas.py`) are upper bounds fitted to measurements.
`UploaderGolden.t.sol` fuzzes `writeChunk` and `registerManifest` on a real
`ContentStore`, and `UploaderAttest.t.sol` measures `attestBase64` for 1, 11 and
48 chunks, the worst call (the first call of a 49-chunk file) and the second
call of that file, each asserting that measured gas never exceeds the model.

A whole 12.58 MB file is 513 transactions and about 2.84 billion gas, about 2.8
ETH at 1 gwei. Batching chunks (for example with Multicall3): three full chunks
in one transaction come to 97% to 99% of the cap, with no room for repricing;
two per transaction (about 49 KB) is about 66%.

### Glamsterdam

Glamsterdam reprices state creation. Sepolia has run it since 6 October 2026,
and the constants below were measured there on 11 and 12 October 2026
([`flows.md`](../../deployments/11155111/flows.md)). Mainnet parameters may
differ, so re-measure before relying on them there.

| State created | Prague | Sepolia (Glamsterdam) |
| --- | ---: | ---: |
| A byte of contract code (a chunk's bytes) | 200 | about 1,542 to 1,548 |
| A storage slot written from zero | 22,100 | about 111,000 |
| A contract creation, empty | about 53,000 | about 210,000 |

The model is the Prague model plus a state surcharge per new contract, per byte
of new code and per new slot. The surcharges are the measured increases over
Prague: `writeChunk` receipts for 191 to 24,572 bytes rise by 247,459 plus
1,330.2 per byte over their Prague replays, within 20 gas, and each chunk hash a
manifest stores costs 88,400 to 89,300 more. The model uses 1,331 per code byte,
89,400 per new slot and 157,000 per new contract, at or above every
measurement. Against the receipts:

| Transaction | Model | Sepolia |
| --- | ---: | ---: |
| `writeChunk`, 24,572 bytes | 38,474,847 | 38,364,370 |
| `writeChunk`, the 7,048-byte CC0 text | 11,277,679 | 11,238,006 |
| `writeChunk`, a full 24,575-byte chunk | 38,479,491 | about 38.4M |
| `registerManifest`, 1 chunk | 596,576 | 577,375 |
| `registerManifest`, 43 chunks (1 MiB) | 5,330,480 | 5,265,859 (estimate) |
| `registerManifest`, 256 chunks | 29,337,752 | 28,784,463 (simulated) |
| `registerManifest`, 512 chunks | 58,191,604 | about 57.6M |

`test_glamsterdam.py` holds these receipts and fails if the model drops below
any of them or drifts more than a few percent above.

**The transaction cap, as observed.** On Sepolia, EIP-7825's 16,777,216 cap
bounds a transaction's **regular** gas only: Sepolia accepts transactions above
the cap when the excess is state-creation gas. A full chunk costs about 38.4M
and a 512-chunk manifest about 57.6M. So under `glamsterdam` the model splits
each estimate in two:

- **regular gas**, bounded by the Prague estimate, which still counts state
  creation at its Prague price. That makes it an upper bound as far as Sepolia
  shows: reads and other execution cost there what they cost on Prague, or
  slightly less. It is an observation, not a reading of the final EIP
  mechanics, and mainnet must confirm it. `calls` refuses a
  transaction whose regular gas is above the cap and warns above three quarters
  of it. A full chunk is about 5.5M regular, and a 512-chunk manifest about
  11.9M;
- **state gas**, the surcharge, which the cap does not count.

The gas limit is the whole estimate plus 10 percent, **not** clamped to the cap
(a full chunk gets 42,328,000). It is never above the assumed block gas limit
(`--block-gas`, default 60M), unless the transaction could not fit a block
anyway.

**Batching.** Batch only while the regular gas still fits:
`gas.chunks_per_transaction` adds a chunk to a transaction only while the
batch's regular gas keeps the quarter reserve, and under Glamsterdam only while
the batch also stays within 50M and the block gas limit. That allows one full
chunk per transaction under Glamsterdam: two would be about 77M. The emitted
transactions are always one chunk each; `calls` prints the batching limit for
anyone who batches them with another tool.

**Warnings.** `calls` warns when a transaction needs more than 50,000,000 gas,
and when it needs more than the block gas assumption.

- **The 50M estimate cap.** The public Sepolia RPC caps estimates and
  simulations at 50M gas, and so do geth and reth by default (`--rpc.gascap`).
  Under Glamsterdam a one-call registration above about **439 chunks**
  (about 10.8 MB) costs more than that, so such a node cannot estimate it; the
  default registration from list chunks never does. Use the offline model's
  limit (the default, and the fallback of `--gas-limits rpc`) or a self-hosted
  node with a raised cap.
- **The block.** A transaction has to fit in one block. Sepolia's blocks were
  200M on 11 October 2026; the default assumption is 60M.

**`MAX_CHUNKS` is 4,096 (about 100.66 MB), and nothing grows with the file.**
One-call registration (about 22,800 gas per hash under Prague, about 111,000
under Glamsterdam) is what the tool sends for small manifests only; above 16
chunks it writes the hash list as list chunks (at most 767 hashes, about 5.4M
Prague or 38M Glamsterdam each) and registers with one `registerManifestList`
(about 2.8M Prague and 3.7M Glamsterdam at 4,096 chunks, modelled). A 512-chunk
manifest then costs about 4.2M Prague and 26.7M Glamsterdam in two transactions,
against 12.1M and 58.2M in one; 4,096 chunks cost about 32M and 209M in seven,
each inside the cap with its quarter reserve and under a 50M-capped node's
estimate. Chunks and parts are written one per transaction, so no transaction
ever needs more than one chunk's code. ADR 0004 (gas budgets under Glamsterdam)
records the repository's budgets.

### Cost quotes

`plan` and `calls` print the total gas of their transactions under each
schedule, and its price at `--gwei` per gas (default 1). `calls.json` carries
the same `quotes`. The figures are the offline model's upper bounds; at another
gas price, scale linearly. What a file costs on chain (upload, manifest and
attestation; the gas price includes the base fee):

| File | Prague | at 1 gwei | Glamsterdam | at 1 gwei |
| --- | ---: | ---: | ---: | ---: |
| 256 KiB as `Base64` (11 chunks) | 61M | 0.061 ETH | 415M | 0.41 ETH |
| 1 MiB as `Base64` (43 chunks) | 245M | 0.24 ETH | 1,655M | 1.65 ETH |
| 12.58 MB (512 chunks, no attestation) | 2,839M | 2.84 ETH | 19,759M | 19.8 ETH |

Storage is about 7 times dearer under Glamsterdam: about 1.65 ETH per MiB at 1
gwei, against about 0.24 ETH under Prague.

## Cross-language agreement

Keccak-256, the ABI encoding, the file ID formula and the chunk layout are all
re-implemented here, so they are checked against the contract, not against
themselves:

- **Golden vectors** in [`golden/vectors.json`](golden/vectors.json): one small
  sample file per encoding ([`golden/samples`](golden/samples), with the stored
  gzip streams), the layout edges (24,575 bytes, 24,576, 49,150) and multi-chunk
  files for every encoding, each with its file ID, chunk hashes, SHA-256 and
  `registerManifest` calldata. Large media is generated by
  `keccak256(abi.encode(seed, offset))`, the same generator as `ContentBase._data`
  in the Foundry tests. A second set of cases, in
  [`golden_attest.py`](golden_attest.py), lists base64 texts the store must
  accept and refuse (valid padding, every kind of bad byte, the bytes next to the
  alphabet's ranges, padding straddling chunks, a bad byte in the second and third
  chunk, wrong lengths), with the error and chunk each should give, plus two
  bitmaps that say which of the 256 byte values are accepted first and last.
- **Foundry:** [`UploaderGolden.t.sol`](../../test/content/tooling/UploaderGolden.t.sol)
  loads the same vectors (through the generated `UploaderGoldenData.sol`) and
  asserts, on a real `ContentStore`, the identical file IDs and chunk hashes, the
  identical SHA-256 of the media, byte-equal `abi.encodeCall` output for both
  functions, that the Python-built calldata registers and uploads files that read
  back complete, and the gas model. Solidity cannot gzip, so large gzip vectors
  are checked from their hashes and file ID only; the small ones from their
  committed stored bytes. [`UploaderAttest.t.sol`](../../test/content/tooling/UploaderAttest.t.sol)
  does the same for attestation: for every golden case, under both base64
  encodings, the store attests the text or reverts with the same error and chunk
  Python predicted, and for every byte value, first and last, the verdict equals
  the Python bitmap.
- **Python:** `test_*.py` here assert the same vectors, `cast`-derived keccak
  and ABI values, RFC 4648 and strict-decoder cases, the fake-store command line
  flows, and `test_anvil.py`, which sends the emitted calldata (with the
  recommended gas limits) to the compiled contract on a local Anvil node and
  verifies and rebuilds the files, runs the attest calls (including a file that
  needs two) and checks `isBase64Attested`, and confirms the contract refuses
  texts the tool refuses, with the error and chunk predicted.

- **Renderer oracles** in [`oracles.py`](oracles.py): differential vectors for
  the renderer's text checks, decided outside Solidity: CPython's strict `json`
  for `JsonScan`, its strict UTF-8 decoder for `Utf8`, a mirror of
  `HtmlScript.neutralize` whose every output a transcription of the WHATWG
  tokenizer's script-data states shows closing at the renderer's own
  `</script>`, and the trait-name rule. They are written from a fixed seed to
  [`test/fixtures/oracles/`](../../test/fixtures/oracles) and checked by
  [`RendererOracles.t.sol`](../../test/content/renderer/RendererOracles.t.sol),
  which reads them at test time (compiled into Solidity, they would take minutes
  to build). `python -m tools.content.oracles --write` regenerates them, and
  `test_oracles.py` fails if they are stale.

Regenerate after changing the vectors or the gas model, and commit the result:

```bash
python -m tools.content golden --write   # vectors.json, the stored gzip streams, UploaderGoldenData.sol
forge fmt test/content/tooling
python -m tools.content golden --check   # fails if anything committed is stale
```

New vectors go in `SPECS` in [`golden.py`](golden.py). If this machine's gzip no
longer reproduces a committed stream (`GzipReproductionTest`), the committed
stream is the truth, because the file ID commits to it.

## Tests

```bash
python -m unittest discover -s tools/content -t . -p "test_*.py"
```

`test_anvil.py` needs `anvil` on the `PATH` and `forge build` output; it is
skipped without them, and CI sets `CONTENT_E2E_REQUIRE=1` so a missing
prerequisite fails there instead. CI runs these in the Build and checks job, one of
the parts behind the required Contracts check.

## Performance and limits

- Pure-Python keccak costs about 25 ms per full chunk. A 512-chunk file
  (12.58 MB) takes about 14 seconds to plan and again to emit calls; the
  4,096-chunk maximum (100.66 MB) about eight times as long.
- `verify` and `rebuild` make about two RPC calls per chunk; the whole file
  and its decoded form are held in memory (at most 100.66 MB stored).
- Not covered: signing or sending (by design), batching through Multicall3 (the
  limit is printed, the batches are not built), and publishing to Arweave or
  IPFS. Gas estimation against live chain state is `--gas-limits rpc`.
