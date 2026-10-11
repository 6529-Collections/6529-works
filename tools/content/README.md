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
python -m tools.content calls art.png.content.json --store 0xSTORE
python -m tools.content verify  --rpc "$ETH_RPC_URL" --store 0xSTORE 0xFILEID
python -m tools.content rebuild --rpc "$ETH_RPC_URL" --store 0xSTORE 0xFILEID -o art.png
```

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
   `MAX_CHUNKS` (512) chunks. The input file size is checked first, so an
   oversize file is refused before it is read.
4. Hashes each chunk (`keccak256`), computes the SHA-256 of the **decoded**
   media, and computes the file ID exactly as `ContentStore.manifestId` does.
5. Validates the MIME type with the contract's rule (lowercase `type/subtype`
   from `[a-z0-9+._-]`, one slash, at most 64 bytes).

Output: `<FILE>.content.json` (or `-o`) and, unless the stream is the input file
itself, `<manifest>.stored` beside it: the exact stored bytes. **For a gzip or
base64 encoding, publish that `.stored` stream (Arweave or IPFS) as a locator
next to the decoded media.** The file ID commits to those exact bytes, and gzip
output depends on the compressor, so nobody can promise to reproduce it later;
see the [content README](../../src/content/README.md#the-model).

`--already-encoded` takes a stream you already have (for example fetched from
Arweave) instead of media. It must decode cleanly; the media SHA-256 comes from
the decoded bytes, and the manifest records whether this tool's encoder would
have produced the same stream (`"reproducible": false` for a foreign but valid
gzip stream).

### `calls MANIFEST --store ADDRESS`

Emits the ordered transactions, **without broadcasting anything**:

- one `registerManifest` (first by default; `--register last` puts it after the
  chunks), then one `writeChunk` per **distinct** chunk (a file that repeats a
  chunk needs it stored once);
- ABI-encoded calldata in `<manifest>.calls/NNN-<name>.calldata`, a machine
  readable `calls.json` (gas estimate and recommended gas limit per
  transaction), and `send.sh`, a script of `cast send` lines that is also
  printed to stdout (`--json` prints `calls.json` instead).

Before emitting anything it re-proves that the stored stream is the one the
manifest commits to (length, every chunk hash, and the decoded media SHA-256),
and it refuses a manifest whose `fileId` is not the hash of its own fields.

`--only-missing --rpc URL` asks the chain and drops what it already has: a
registered manifest and any chunk the store already holds. That is how a
collector finishes an upload the artist started.

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
  reproduces the stored stream (informational).

`--json` prints a machine-readable report. Output never contains the RPC URL
(it usually carries an API key): errors name only scheme, host and port.
`--rpc` defaults to `$ETH_RPC_URL`.

### `rebuild --rpc URL --store ADDRESS FILEID -o OUT`

Runs the same verification and writes the decoded media only if every check
passed, atomically, and never over an existing file without `--force`.
`--stored` writes the stored (encoded) stream instead, which is what to re-publish to
Arweave or IPFS.

## How it maps to the contract

| Rule | Contract | Here |
| --- | --- | --- |
| Chunk size | `CHUNK_SIZE = SSTORE2.MAX_CHUNK_LENGTH = 24_575` | `plan.CHUNK_SIZE` |
| Chunk count | 1 to `MAX_CHUNKS = 512` | `plan.check_stored_length` |
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

## Gas and the Fusaka cap

[EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) caps every transaction at
16,777,216 gas. `calls` estimates each transaction with an offline model
(execution plus 21,000 plus calldata, or the EIP-7623 floor if higher), refuses
to emit any transaction above the cap, warns above three quarters of it, and sets
`--gas-limit` to the estimate plus 10 percent, never above the cap.

| Transaction | Model (execution) | Measured on `ContentStore` | As a transaction |
| --- | --- | --- | --- |
| `writeChunk`, new 24,575-byte chunk | 5,107,875 | 5,020,261 | about 5.5M (33% of the cap) |
| `registerManifest`, 512 chunks, `text/html` | 11,572,400 | 11,460,012 | about 11.9M (71%) |

`writeChunk` is priced as a new chunk, the worst case; a chunk the store already
holds costs about 16,000. The model constants (`gas.py`) are upper bounds fitted
to measurements, and `UploaderGolden.t.sol` fuzzes both functions on a real
`ContentStore` asserting that measured gas never exceeds the model.

A whole 12.58 MB file is 513 transactions and about 2.84 billion gas, about 2.8
ETH at 1 gwei. One more thing to know before batching chunks with Multicall3:
three full chunks in one transaction come to 97% to 99% of the cap, with no room
for repricing; two per transaction is about 66%.

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
  in the Foundry tests.
- **Foundry:** [`UploaderGolden.t.sol`](../../test/content/tooling/UploaderGolden.t.sol)
  loads the same vectors (through the generated `UploaderGoldenData.sol`) and
  asserts, on a real `ContentStore`, the identical file IDs and chunk hashes, the
  identical SHA-256 of the media, byte-equal `abi.encodeCall` output for both
  functions, that the Python-built calldata registers and uploads files that read
  back complete, and the gas model. Solidity cannot gzip, so large gzip vectors
  are checked from their hashes and file ID only; the small ones from their
  committed stored bytes.
- **Python:** `test_*.py` here assert the same vectors, `cast`-derived keccak
  and ABI values, RFC 4648 and strict-decoder cases, the fake-store command line
  flows, and `test_anvil.py`, which sends the emitted calldata (with the
  recommended gas limits) to the compiled contract on a local Anvil node and
  verifies and rebuilds the files.

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
prerequisite fails there instead. CI runs these in the Contracts job, next to
`forge test`.

## Performance and limits

- Pure-Python keccak costs about 25 ms per full chunk. A maximum-size file
  (512 chunks, 12.58 MB) takes about 14 seconds to plan and again to emit calls.
- `verify` and `rebuild` make about two RPC calls per chunk; the whole file
  and its decoded form are held in memory (at most 12.58 MB stored).
- Not covered: signing or sending (by design), batching through Multicall3,
  gas estimation against live chain state (`cast estimate` does that), and
  publishing to Arweave or IPFS.
