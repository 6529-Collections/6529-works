# Convention reference tools

Reference implementations of the off-chain conventions in
[Declarations and conventions](../../docs/spec/declarations-and-conventions.md): the
structural validator for the convention JSON Schemas, the conservation-floor check, the promise
card and its grade, the control-proof verifier and the custody-attestation reader check. A front
end, a venue or the curation signer's tooling can copy them, or test its own implementation
against them.

Python 3.12, standard library only. The tools make no network call and hold no key: every chain
read and every fetched file is an input, gathered by the caller at the block it names. The one
exception is signature recovery, which shells out to Foundry's `cast` by default (see
[Signatures](#signatures)). Pre-audit software, like the contracts; the spec page is the
authority, and where a tool and the page disagree the page wins.

```bash
python -m tools.conventions validate declarations doc.json --canonical
python -m tools.conventions floor floor-input.json      # before the curation signer attests
python -m tools.conventions card card-input.json > card.json
python -m tools.conventions grade card.json
python -m tools.conventions control-proof digest proof.json
python -m tools.conventions control-proof verify proof.json --context context.json
python -m tools.conventions custody digest attestation.json
python -m tools.conventions custody check custody-input.json
```

Run from the repository root. Exit codes: `0` ok, `1` refused or invalid, `2` bad input. Each
command prints JSON.

## Modules

| Module | Does | Rules |
| --- | --- | --- |
| [`schema.py`](schema.py) | Validates a document against the committed schema in [`docs/spec/schemas/`](../../docs/spec/schemas/), interpreting the schema itself; raises, when the schemas load, on any keyword it does not implement anywhere in a schema; checks `format: uint256` values (0 to 2<sup>256</sup> − 1) | DCL-1, DCL-2 step 4 |
| [`jcs.py`](jcs.py) | RFC 8785 canonical JSON and a strict I-JSON parser | DCL-1, DCL-30 |
| [`floor.py`](floor.py) | `check_floor(package, policy, contents, observed)`: the signer's `CHECK_FLOOR`; `floor_result` turns a passing result into the published floor-result.v1 object; `dependency_label` is the bytes32 `DependencyRegistry` takes | DCL-3 to DCL-5, DCL-7, DCL-33 |
| [`card.py`](card.py) | `build_card(inputs)`: a promise card from the reads at one block | DCL-3, DCL-8, DCL-26 to DCL-29, DCL-33 |
| [`grade.py`](grade.py) | `grade(card)`: rubric 1, total over valid cards | DCL-30, DCL-31 |
| [`eip712.py`](eip712.py) | The two typed-data digests and `verify_signature`, as `SignatureVerifier` | DCL-19, DCL-20, DCL-23, DCL-24 step 3 |
| [`control_proof.py`](control_proof.py) | `issue_challenge` and `verify_response` | DCL-23 to DCL-25 |
| [`custody.py`](custody.py) | `evaluate_custody(declarations, attestations, now, work=...)` | DCL-20 to DCL-22 |

The exact input shapes are in each module's docstring.

## Commands

### `validate SCHEMA FILE [--canonical]`

`SCHEMA` is the short name (`declarations`, `promise-card`, `control-proof`, ...). Prints every
violation as a JSON pointer and a message. `--canonical` also requires the bytes to be RFC 8785
canonical, as DCL-1 requires of every convention document.

### `floor INPUT`

`CHECK_FLOOR` of DCL-5. `INPUT` holds `package` (the item, the ordered media list and
`ContentStore.fileInfo` per file, including the license text file), `policy` (the wave's
`requiresDeclarations`, `waivable`, `allowsTimeCapsule` and, optionally, `workPowers`; without
it the names are `ROYALTY_RATE` and `RELICENSE`, the `WorkPowers` names of DCL-8),
`contents` (the declarations bytes, `{"file": path}` or `{"hex": "0x…"}`) and `observed`: what the
signer's own tooling saw at each storage receipt (`{"file": path}` of the fetched bytes, which
the tool checks as the receipt's `form` says: a `stored` copy is `fileInfo.length` bytes whose
chunks reproduce the file ID (the committed chunk hashes) and that decode to the file's SHA-256, a
`decoded` copy hashes to it; or `{"sha256": "0x…"}` of the decoded media, which stands for a
`stored` copy only of an `Identity` file; or `null` when the fetch failed), the dimensions it
measured by decoding each image or video, the default renderer and its code hash, and each
dependency's resolution. The PRIMARY file's `fileInfo`, with its MIME type, is required: without
it whether the work is generative is unknown, and the check refuses.

The result lists every failure with the fact it belongs to, and each fact's state: `met`,
`waived` (with its reason), `unmet`, `not_applicable` or `failed`. `ok` is false on any refusal;
the signer does not attest then. For a passing result, `floor.floor_result(result, itemHash)` is
the floor-result.v1 object DCL-33 puts into the curation evidence.

### `card INPUT [--notes]`

Builds a promise card that validates against `promise-card.v1`, or fails. `INPUT` holds `reads`,
one answer per function the spec cites, made at one block, and the documents a reader holds: a
declarations copy fetched from a locator, the published floor result (a floor-result.v1 object;
the card uses it only when it names the work's item hash and declarations file, DCL-33),
custody attestations (counted only when they are about this work, DCL-20), the winning display
change, and the `roles` rows, required, that the caller composes from the
[role matrix](../../docs/audit/roles.md), to which the tool applies DCL-27's row rules. A read
the chain returns as a bool must be a JSON boolean. The full shape is in [`card.py`](card.py).

The tool does not make the reads itself. The chain tooling in this repository reaches a node
over JSON-RPC with `urllib` ([`tools/content/rpc.py`](../content/rpc.py)) rather than by
shelling out to `cast call`, and the card needs reads from several contracts at one block, so
fetching is left to the caller, who must pin every `eth_call` to the same block hash.

`IWorkPowers` is optional, for a deployment whose `WorkRecords` does not report it: absent, the
card says `"available": false` and every intended renunciation is `unknown`. Present, it is
`renouncedMask`, the `renouncedPowers(tokenId)` read. The names default to `ROYALTY_RATE`
(bit 0) and `RELICENSE` (bit 1), and the covered rows to `royalty_rate` and `license` (DCL-8,
DCL-27); `powers` and `covers` may be given explicitly, but the card schema accepts only the
`WorkPowers` names.

`--notes` also prints why the declarations and custody states were chosen.

### `grade CARD`

Rubric 1 of DCL-30. The example card in `docs/spec/schemas/examples/` grades 90, A, byte for byte
the example grade. A new rubric is a new function and a new version number, never an edit
(DCL-31).

### `control-proof digest FILE` and `control-proof verify FILE --context CONTEXT`

`digest` prints the EIP-712 digest of a control-proof document. `verify` runs DCL-24 steps 2 to 6
and DCL-25: the response must equal a challenge the venue issued, and the digest is built from
that challenge with the venue's own chain ID. `CONTEXT` holds the venue's identity and clock, the
challenges it issued and has not spent (`challenges`: control-proof.v1 challenge documents), the
official token addresses of the chain, block `B` and the head, and the reads at `B`: the signer's
code,
`ownerOf` (or the edition balance, or the auction's pending-delivery buyer) and the
consolidation source's `isEstablished` and `effectiveAt`. The command recovers ECDSA signatures
with `cast` and cannot make the ERC-1271 call a contract signer needs; a program that keeps state,
or must accept contract signers, calls `control_proof.verify_response` with its own store of
issued challenges and `erc1271` callable. The store has one operation, `claim(nonce)`, which must
be atomic: it returns the outstanding challenge at most once and marks it used, and the verifier
calls it before any other check (DCL-24 steps 2 and 6).

### `custody digest FILE` and `custody check INPUT`

`digest` prints the EIP-712 digest of a custody attestation. `check` applies DCL-20 to DCL-22 to a
list of attestations about the work `INPUT` names (`work`: `{chainId, contract, tokenId}`; an
attestation about another work is discarded): which counts for each object and custodian, whether
the custodian is recognized, and whether it is stale. An attestation without `signatureValid` is checked with
`cast` against the custodian, as an account without code unless `custodianCode` is given.

## Signatures

`eip712.verify_signature` follows `SignatureVerifier.isValid`: low-s ECDSA for an account without
code; for an EIP-7702 delegated account, ECDSA against the account first, then ERC-1271;
ERC-1271 otherwise. The checks before recovery (length, `v`, `r`, low `s`, ERC-2098 unpacking)
are done here. The repository has no pure-Python secp256k1, so recovery itself is a pluggable
`ecdsa(signer, digest, signature65) -> bool`. The default runs
`cast wallet verify --no-hash`. The ERC-1271 call is always the caller's
`erc1271(signer, digest, signature) -> bool`, made at the reader's block.

## Tests

```bash
python -m unittest discover -s tools/conventions -t . -p "test_*.py"
```

Every example file under `docs/spec/schemas/examples/` is exercised. The type hashes and the
two example digests are checked against the values the spec prints. When `cast` is installed,
the example signatures are recovered to the public Anvil test account 0; set
`CONVENTIONS_CAST_REQUIRE=1` to fail rather than skip when it is not. Each test docstring names
the rules it covers.
