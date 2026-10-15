# Storage: content addresses, Arweave, IPFS and the uploader

This guide is for integrators, artists' tooling and indexers that need to fetch a work's bytes,
check that they are the committed bytes, or put them on chain. A 6529 Stream work's media can
live in three places: the on-chain content store, Arweave and IPFS. The work records satellite
(`WorkRecords`) lists the work's files, registers the off-chain copies (locators) and says which
copy to serve. The rules are in
[Works and storage](../spec/works-and-storage.md#rules-and-invariants), cited here by ID (`WS-n`);
this page is the practical side.

> Pre-audit. See the [project status](../../README.md#status).

Addresses are in [Addresses](addresses.md), ABIs in
[ABIs and interface IDs](abis-and-interface-ids.md). The shell examples use Foundry's `cast` with
`$RECORDS` (WorkRecords), `$STORE` (ContentStore) and `$ETH_RPC_URL` set.

## What to trust

- **Chunks are checked on every read** (WS-28). A read never returns partial or wrong bytes for a
  file ID; a read that touches a missing chunk reverts.
- **The declared SHA-256 is not checked** (WS-30). Hashing a large file on chain costs quadratic gas, so the
  SHA-256 of the decoded file is a declaration in the manifest, which you verify off chain. A
  manifest with a wrong digest is a different file ID (WS-25), so it cannot displace the honest one.
- **Locators are checked for shape, not content** (WS-18). `WorkRecords` never sees the bytes
  behind an Arweave or IPFS address. Hash what you fetch.
- **Your RPC node is not trusted either.** Recompute the file ID from the manifest fields and the
  SHA-256 from the bytes. The uploader's `verify` command does both.

## 1. Find a work's files

A work's per-token views revert with `RecordNotOpen` until anyone has called `openRecord` (WS-1).

```bash
cast call $RECORDS "isOpen(uint256)(bool)" $TOKEN_ID
cast call $RECORDS "mediaOf(uint256)((bytes32,bytes32,uint8)[])" $TOKEN_ID
cast call $RECORDS "record(uint256)((bytes32,bytes32,bytes32,uint32,bool,bool,address))" $TOKEN_ID
cast call $RECORDS "licenseOf(uint256)((string,bytes32))" $TOKEN_ID
```

- `mediaOf` returns the media list in approved order: `(fileId, sha256, role)`, with role `0`
  `PRIMARY` (always first), `1` `PREVIEW`, `2` `AUXILIARY`. The `sha256` is the SHA-256 of the
  decoded file. The `PRIMARY` file's is the work's content hash.
- `record` returns the record file ID, the media hash, the license key, the version, whether the
  work is finalized, whether it is on-chain complete, and the pinned renderer.
- `licenseOf` returns the SPDX identifier and the license text's file ID.

The record file and the license text are content-store files like the media, so everything
below applies to them too.

## 2. Read a file from the content store

```bash
cast call $STORE "fileInfo(bytes32)((bytes32,uint256,uint256,uint8,string))" $FILE_ID
cast call $STORE "missingChunks(bytes32)(uint256[])" $FILE_ID
cast call $STORE "readChunk(bytes32,uint256)(bytes)" $FILE_ID 0
```

1. Call `fileInfo(fileId)`. It returns the declared SHA-256 of the decoded file, the stored
   `length`, the `chunkCount`, the `encoding` (`0` `Identity`, `1` `Gzip`, `2` `Base64`, `3`
   `GzipBase64`) and the MIME type. It reverts with `ContentFileUnknown` if no manifest is
   registered under that ID.
2. Check `missingChunks(fileId)` (or `isComplete(fileId)`). An empty list means every chunk is
   stored at the length the layout rule requires.
3. Read chunks `0` to `chunkCount − 1` with `readChunk(fileId, i)` and concatenate them. Every
   chunk but the last is exactly 24,575 bytes (`CHUNK_SIZE`).
4. For a byte range, `read(fileId, offset, length)` works too, but every chunk it touches is read
   whole, and memory cost grows faster than linearly: reading 1 MB in one call costs about 9.7M
   gas in Prague terms ([content module](../../src/content/README.md#gas)). Prefer `readChunk`
   for whole files, or ranges of a few hundred KB.

A read that touches a missing chunk reverts with `ContentChunkMissing(fileId, index, hash)`.
Upload the chunk (any account may, WS-29) and read again.

## 3. Verify the bytes off chain

1. Check that the concatenated bytes are exactly `length` bytes long.
2. Optionally recompute each chunk's keccak256 and compare it with `chunkHash(fileId, i)`, and
   recompute the file ID:

   ```text
   fileId = keccak256(abi.encode(bytes32[] chunkHashes, uint256 length, uint8 encoding,
                                 string mimeType, bytes32 sha256))
   ```

   Python's `hashlib.sha3_256` is not keccak256; the uploader ships a pure-Python keccak
   ([`tools/content/keccak.py`](../../tools/content/keccak.py)).
3. Decode as the encoding requires: base64 first, then gunzip.
4. Compare the SHA-256 of the decoded bytes with `fileInfo(fileId).sha256Hash`, and with the
   media list's `sha256` for that file.

A standard-library sketch of steps 3 and 4:

```python
import base64, gzip, hashlib

IDENTITY, GZIP, BASE64, GZIP_BASE64 = 0, 1, 2, 3

def decode(stored: bytes, encoding: int) -> bytes:
    data = stored
    if encoding in (BASE64, GZIP_BASE64):
        data = base64.b64decode(data, validate=True)  # strict alphabet, padding at the end
    if encoding in (GZIP, GZIP_BASE64):
        data = gzip.decompress(data)
    return data

def verify(stored: bytes, length: int, encoding: int, declared_sha256: bytes) -> None:
    assert len(stored) == length
    assert hashlib.sha256(decode(stored, encoding)).digest() == declared_sha256
```

The uploader does all of this, trusting neither the RPC nor the contract, and is stricter than
the sketch (one gzip member, no trailing bytes, canonical base64):

```bash
python -m tools.content verify  --rpc "$ETH_RPC_URL" --store $STORE $FILE_ID
python -m tools.content rebuild --rpc "$ETH_RPC_URL" --store $STORE $FILE_ID -o art.png
```

`verify` exits `0` when the file verifies, `1` when it does not or is incomplete, and `2` for
bad input or an unreachable endpoint. `rebuild` writes the decoded media (or, with `--stored`,
the encoded stream) only if every check passed.

## 4. Locators: content addresses only

A [locator](../glossary.md#locator) is `(kind, uri)`: kind `1` `ARWEAVE` or `2` `IPFS`. Kind `0`
`NONE` is the unset value of a preference, and kind `3` `ONCHAIN` is the content store itself,
implicit and never registered. `WorkRecords.addLocator` accepts exactly these shapes (WS-18):

| Kind | URI | Length | Character rules |
| --- | --- | --- | --- |
| `ARWEAVE` | `ar://` then a transaction ID | 48 bytes (5 + 43) | The ID is the unpadded base64url text of 32 bytes: `A–Z a–z 0–9 - _`. Its last character carries two padding bits, which must be zero, so it is one of `AEIMQUYcgkosw048`. |
| `IPFS` | `ipfs://` then a CIDv1 | 66 bytes (7 + 59) | Multibase `b` (lowercase base32, `a–z 2–7`, no padding). It starts `bafkrei` (raw leaf, codec `0x55`) or `bafybei` (dag-pb, codec `0x70`), then a character in `a`–`h`, which is where the 32-byte sha2-256 multihash length shows. Its last character has two zero padding bits: one of `aeimquy4`. |

Nothing may follow the address: no path, query or fragment, so no `/`, `?`, `%` or `#`. Refused
examples, all from the tests
([`ContentReviewRegressions.t.sol`](../../test/integration/ContentReviewRegressions.t.sol),
[`WorkRecords.t.sol`](../../test/stream/WorkRecords.t.sol)):

- `https://...` of any kind;
- an ArNS name such as `ar://artist-name_6529`, or a transaction ID of 42 or 44 characters;
- `ipfs://<cid>/index.html`, `ipfs://<cid>?x=1`, `ipfs://<cid>#x`;
- CIDv0 (`ipfs://Qm...`), uppercase base32, an identity multihash (`bafkqaa...`) or a dag-cbor
  root (`bafyrei...`);
- a non-canonical last character (padding bits set), or an Arweave address under kind `IPFS`.

A content address names exact bytes, while what an HTTPS URL, a path, an ArNS name or an IPNS
link serves can change, so only bare content addresses are accepted
([ADR 0003](../adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8)).
One canonical spelling also makes the duplicate-URI check meaningful: a raw-leaf CID and a dag-pb
CID are different addresses, and both may be listed.

**Producing the addresses.** An Arweave transaction ID is the 43-character ID that gateways and
wallets print. For IPFS, add the file with CIDv1, raw leaves and sha2-256 (with Kubo,
`ipfs add --cid-version=1 --raw-leaves`; base32 is the CIDv1 default). A file that fits one
block gets a raw-leaf CID (`bafkrei...`); a larger one gets a dag-pb root (`bafybei...`).
ADR 0001 §8 fixes the chunker as part of the network's IPFS profile, so match the platform's
settings if you want the same CID it pins; the on-chain check does not see the chunker.

**Quick cross-check for raw-leaf CIDs.** A raw-leaf CID's digest is the SHA-256 of the block's
bytes. Base32-decode the 58 characters after `b`, drop the first 4 bytes
(`01 55 12 20`), and the remaining 32 bytes are that SHA-256. A dag-pb root hashes a DAG node,
not the file, and an Arweave transaction ID does not reveal the data's hash: for those, fetch
the bytes and hash them.

**Which bytes a locator holds.** For an `Identity` file the stored stream is the media, so a
copy is the media. For a `Gzip`, `Base64` or `GzipBase64` file, a file's locators may hold the
decoded media or the encoded stream: the uploader asks for the encoded stream to be published
too, because the file ID commits to its exact bytes and gzip output depends on the compressor.
Hash what you fetch. If its SHA-256 equals the declared SHA-256, it is the decoded media; if it
is `length` bytes and decodes to that, it is the stored stream.

## 5. Which copy to serve: the preferred locator

```bash
cast call $RECORDS "preferredLocator(uint256,bytes32)((uint8,string),uint256)" $TOKEN_ID $FILE_ID
cast call $RECORDS "locators(uint256,bytes32)((uint8,string)[])" $TOKEN_ID $FILE_ID
```

`preferredLocator` returns the [preferred locator](../glossary.md#preferred-locator), the copy
`tokenURI` serves, and its registration index. The most specific setting wins: the file's
preferred index (`setFilePreference`), then the collection's and the global preferred kind
(`setCollectionPreferredKind`, `setPreferredKind`), then the first registered copy (WS-21). Two
results carry the index `type(uint256).max`:

- kind `ONCHAIN`: the work is on-chain complete, and a preferred kind names `ONCHAIN` or no copy
  is registered; read it from the content store as in section 2;
- kind `NONE`: no copy is known.

`locators` returns every registered copy in registration order, so a client can fall back to the
next copy itself when the preferred one fails to verify. The renderer does not: it uses the
preferred locator as it is ([Rendering and tokenURI](../spec/rendering-and-tokenuri.md)).

**Who sets what.** The artist and the PLATFORM role each add up to 8 locators per file before
finalize; after it, only PLATFORM adds, up to 16 per file in all (WS-19). Locators are
append-only (WS-20). The STORAGE_OPERATOR role sets the file, collection and global preferences,
with no delay, and can only choose among registered copies or the on-chain bytes (WS-22). The
selectors and delays are in the [role matrix](../audit/roles.md).

**Off-chain monitoring.** Because locators are not verified on chain, the network runs an
off-chain health monitor that verifies copies and re-pins or re-uploads from a surviving copy
([ADR 0001 §8](../adr/0001-v1-scope.md#8-works-content-and-storage)), and the storage operator
serves only copies the monitor verified
([stream module](../../src/stream/README.md#records-satellite)). Monitoring results can be
published in the statement log under the kinds `STORAGE_COPY` and `FIXITY_CHECK`
([`StatementKinds.sol`](../../src/interfaces/types/StatementKinds.sol)); any role may write those
kinds, so read each entry's kind together with its signer's role
([Disputes and statements](../spec/disputes-and-statements.md)).

**Gateways.** Fetch `ar://<id>` through any Arweave gateway (for example
`https://arweave.net/<id>`) and `ipfs://<cid>` through any IPFS gateway (`https://<gateway>/ipfs/<cid>`)
or your own node. Gateways are not trusted: verify the bytes as in section 3.

**Events to index.** `LocatorAdded`, `FilePreferenceSet`, `CollectionPreferredKindSet`,
`PreferredKindSet` and `WorkOnChainComplete` ([WorkRecords](events-and-indexing.md#workrecords)),
plus Stream's ERC-4906 events ([Stream](events-and-indexing.md#stream)). A global or collection
change affects many tokens and arrives as `BatchMetadataUpdate` (WS-23).

## 6. Put a file on chain with the uploader

The uploader in [`tools/content`](../../tools/content/README.md) is Python 3.12 with the
standard library only. It stages a file into the content store and verifies or rebuilds it from
the chain. It never signs or sends a transaction and never handles a private key. Run it from
the repository root.

1. **Plan.** Encode, chunk and hash the file, and write a manifest:

   ```bash
   python -m tools.content plan art.png --mime image/png --encoding base64
   ```

   It writes `art.png.content.json` and, for an encoded file, `art.png.content.stored` (the
   exact bytes the store will hold), and prints the file ID and a cost quote under both gas
   schedules. Choose `base64` for media that should be inlined in `tokenURI` (up to the inline
   threshold, 256 KiB by default), `identity` for files served by range reads; `gzip` and
   `gzipbase64` are never inlined in v1
   ([Rendering and tokenURI](../spec/rendering-and-tokenuri.md)).
2. **Publish the stored stream** of a `gzip`, `base64` or `gzipbase64` file to Arweave or IPFS,
   next to the decoded media.
3. **Emit the transactions** (nothing is sent):

   ```bash
   python -m tools.content calls art.png.content.json --store $STORE --schedule glamsterdam
   ```

   This writes `art.png.content.calls/` with one `registerManifest`, one `writeChunk` per
   distinct chunk, and, for a base64 file, `ceil(chunks / 48)` `attestBase64` calls last, plus
   `calls.json` and `send.sh`. Use `--schedule glamsterdam` on Sepolia; Prague gas limits run out
   of gas there.
4. **Send them with your own signer:**

   ```bash
   export SIGNER="--account my-keystore"   # cast signer flags, never a raw key
   bash art.png.content.calls/send.sh
   ```

   On Windows, run `send.sh` from WSL, Linux or macOS (a full chunk's calldata exceeds the
   Windows command-line limit), or feed the calldata files in `calls.json` to another sender.
5. **Verify** on chain, requiring the attestation for a base64 file:

   ```bash
   python -m tools.content verify --rpc "$ETH_RPC_URL" --store $STORE $FILE_ID --require-attested
   ```

6. **Mark the work on-chain complete** once every media file of the work is complete. Anyone may
   call it; a large work may take several calls, each resuming where the last stopped:

   ```bash
   cast send $RECORDS "syncOnChain(uint256)" $TOKEN_ID $SIGNER
   ```

**Finishing someone else's upload.** Uploads can stop and resume in any order, by anyone. To
finish a work's file, get its stored stream (for example from its Arweave copy), plan it as
already encoded with the file's exact MIME type and encoding from `fileInfo`, check that the
printed file ID is the work's, and emit only what the chain lacks:

```bash
python -m tools.content plan stream.bin --mime image/png --encoding base64 --already-encoded
python -m tools.content calls stream.bin.content.json --store $STORE --schedule glamsterdam \
    --only-missing --rpc "$ETH_RPC_URL"
```

`--only-missing` drops a registered manifest, every chunk the store already holds, and the
attestation calls if the file is already attested. Its quote is what finishing costs.

**What the uploader proves before emitting anything:**

- the encoding reproduces: the stored stream decodes and re-encodes to the same bytes (for its
  own fixed gzip profile; a foreign gzip stream is accepted and marked not reproducible);
- the stored stream reproduces every chunk hash and the stored length, and decodes to the
  declared SHA-256;
- the manifest's `fileId` is the hash of its own fields, so editing a manifest cannot change what
  is sent;
- the MIME type passes the contract's rule, and base64 text passes the attestation rule that
  `attestBase64` applies, so no transaction pays for a file that can never be attested.

Its file IDs, chunk hashes, calldata and attestation verdicts are tested against the contract
(WS-33; [`UploaderGolden.t.sol`](../../test/content/tooling/UploaderGolden.t.sol),
[`UploaderAttest.t.sol`](../../test/content/tooling/UploaderAttest.t.sol)).

## 7. Costs

Glamsterdam, which Sepolia has run since 6 October 2026, prices every stored byte as new
contract code: about 1,548 gas per stored byte on Sepolia, so about 1.65 ETH per MiB at 1 gwei
([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#consequences),
[`flows.md`](../../deployments/11155111/flows.md#1-content)). Two limits follow:

- **One full chunk per transaction.** Two full chunks are more than a node with the default 50M
  RPC gas cap can estimate ([content module](../../src/content/README.md#upload-flow)).
- **Large manifests.** Registration grows with the chunk count; above about 440 chunks a node with
  a 50M estimate cap cannot estimate it, so use the uploader's offline model, which is the default
  ([uploader](../../tools/content/README.md#gas-schedules-the-cap-and-quotes)).

`plan` and `calls` print a quote for any file under both schedules
([cost quotes](../../tools/content/README.md#cost-quotes)). Mainnet's Glamsterdam parameters may
differ from Sepolia's; re-measure there. The full figures are in the
[content module](../../src/content/README.md#glamsterdam) and
[ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table).

## 8. Who pays, and when

- **Anyone can pay, at any time, in any order.** `writeChunk`, `registerManifest`,
  `attestBase64` and `syncOnChain` are permissionless, and the mint never waits for them. The
  store has no payable function: gas is the only cost (WS-17, WS-29).
- **The artist, the platform or a collector** may pay for any part. The approved record file
  should be complete before the work is shown (until then it renders core-only metadata marked
  `incomplete`), and the record file and license text must be complete before the artist can
  finalize, so the artist or the platform usually uploads those first. The default CC0 text is
  uploaded once by the deployment.
- **The collector is the designated payer for the on-chain upgrade** of the media
  ([ADR 0001 §8](../adr/0001-v1-scope.md#8-works-content-and-storage)): any collector can finish
  what the artist or platform started, with `calls --only-missing`.
- **The off-chain copies** (Arweave transactions, IPFS pins) are paid by whoever publishes them;
  the network pins with at least two independent providers plus a 6529 node (ADR 0001 §8).

On-chain bytes are permanent. Nothing in the protocol deletes a chunk or a manifest.

## 9. Dependencies of generative works

A work's record may list `dependencies` as `[{name, version}]`. The `DependencyRegistry` maps
each pair, as left-aligned lowercase `bytes32` labels, to one complete content-store file forever
(WS-34):

```bash
cast call $DEPS "resolve(bytes32,bytes32)(bytes32,bool,(bytes32,uint256,uint256,uint8,string))" \
    $(cast format-bytes32-string p5) $(cast format-bytes32-string 1.9.0)
```

It returns the file ID, whether the version is deprecated, and the file's manifest data. A
deprecated version still resolves and reads (WS-35). Read and verify the file as in sections 2 and 3.
In v1 the renderer does not bundle dependencies: a script whose record declares any is served by
locator ([Rendering and tokenURI](../spec/rendering-and-tokenuri.md)).

## See also

- [Works and storage](../spec/works-and-storage.md): the rules, invariants and failure modes.
- [Reading a work](reading-a-work.md) and [Events and indexing](events-and-indexing.md).
- [Content module README](../../src/content/README.md) and
  [uploader README](../../tools/content/README.md).
- [`deployments/11155111/flows.md`](../../deployments/11155111/flows.md): the Sepolia receipts.
