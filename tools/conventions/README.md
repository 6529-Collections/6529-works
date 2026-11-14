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
| [`schema.py`](schema.py) | Validates a document against the committed schema in [`docs/spec/schemas/`](../../docs/spec/schemas/), interpreting the schema itself; raises on any keyword it does not implement | DCL-1, DCL-2 step 4 |
| [`jcs.py`](jcs.py) | RFC 8785 canonical JSON and a strict I-JSON parser | DCL-1, DCL-30 |
| [`floor.py`](floor.py) | `check_floor(package, policy, contents, observed)`: the signer's `CHECK_FLOOR` | DCL-3 to DCL-5, DCL-7 |
| [`card.py`](card.py) | `build_card(inputs)`: a promise card from the reads at one block | DCL-3, DCL-8, DCL-26 to DCL-29 |
| [`grade.py`](grade.py) | `grade(card)`: rubric 1, total over valid cards | DCL-30, DCL-31 |
| [`eip712.py`](eip712.py) | The two typed-data digests and `verify_signature`, as `SignatureVerifier` | DCL-19, DCL-20, DCL-23, DCL-24 step 3 |
| [`control_proof.py`](control_proof.py) | `issue_challenge` and `verify_response` | DCL-23 to DCL-25 |
| [`custody.py`](custody.py) | `evaluate_custody(declarations, attestations, now)` | DCL-20 to DCL-22 |

The exact input shapes are in each module's docstring.

## Commands

### `validate SCHEMA FILE [--canonical]`

`SCHEMA` is the short name (`declarations`, `promise-card`, `control-proof`, ...). Prints every
violation as a JSON pointer and a message. `--canonical` also requires the bytes to be RFC 8785
canonical, as DCL-1 requires of every convention document.

### `floor INPUT`

`CHECK_FLOOR` of DCL-5. `INPUT` holds `package` (the item, the ordered media list and
`ContentStore.fileInfo` per file, including the license text file), `policy` (the wave's
`requiresDeclarations`, `waivable`, `allowsTimeCapsule` and the `IWorkPowers` power names),
`contents` (the declarations bytes, `{"file": path}` or `{"hex": "0x…"}`) and `observed`: what the
signer's own tooling saw at each storage receipt (`{"file": path}` of the fetched stored bytes,
which the tool decodes and hashes, or `{"sha256": "0x…"}` of the decoded bytes, or `null` when
the fetch failed), the dimensions it measured by decoding each image or video, the default
renderer and its code hash, and each dependency's resolution.

The result lists every failure with the fact it belongs to, and each fact's state: `met`,
`waived` (with its reason), `unmet`, `not_applicable` or `failed`. `ok` is false on any refusal;
the signer does not attest then. The result is what DCL-5 puts into the curation evidence.

### `card INPUT [--notes]`

Builds a promise card that validates against `promise-card.v1`, or fails. `INPUT` holds `reads`,
one answer per function the spec cites, made at one block, and the documents a reader holds: a
declarations copy fetched from a locator, the published floor result, custody attestations, the
winning display change, and the `changeable` rows taken from the
[role matrix](../../docs/audit/roles.md). The full shape is in [`card.py`](card.py).

The tool does not make the reads itself. The chain tooling in this repository reaches a node
over JSON-RPC with `urllib` ([`tools/content/rpc.py`](../content/rpc.py)) rather than by
shelling out to `cast call`, and the card needs reads from several contracts at one block, so
fetching is left to the caller, who must pin every `eth_call` to the same block hash.

`IWorkPowers` (added by ADR 0006) is optional: absent, the card says `"available": false` and
every intended renunciation is `unknown`. Present, it is the renounced-powers mask with the
view's power names in bit order, and `covers`, which maps each power to the `changeable` rows it
covers.

`--notes` also prints why the declarations and custody states were chosen.

### `grade CARD`

Rubric 1 of DCL-30. The example card in `docs/spec/schemas/examples/` grades 90, A, byte for byte
the example grade. A new rubric is a new function and a new version number, never an edit
(DCL-31).

### `control-proof digest FILE` and `control-proof verify FILE --context CONTEXT`

`digest` prints the EIP-712 digest of a control-proof document. `verify` runs DCL-24 steps 2 to 6
and DCL-25. `CONTEXT` holds the venue's identity and clock, its outstanding nonces, the official
token addresses of the chain, block `B` and the head, and the reads at `B`: the signer's code,
`ownerOf` (or the edition balance, or the auction's pending-delivery buyer) and the
consolidation source's `isEstablished` and `effectiveAt`. The command recovers ECDSA signatures
with `cast` and cannot make the ERC-1271 call a contract signer needs; a program that keeps state,
or must accept contract signers, calls `control_proof.verify_response` with its own nonce store
and `erc1271` callable.

### `custody digest FILE` and `custody check INPUT`

`digest` prints the EIP-712 digest of a custody attestation. `check` applies DCL-20 to DCL-22 to a
list of attestations: which counts for each object and custodian, whether the custodian is
recognized, and whether it is stale. An attestation without `signatureValid` is checked with
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
