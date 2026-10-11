"""Off-chain tooling for the 6529 Works content store (ADR 0001 section 8).

Plans a file's chunks and manifest, emits the transactions that stage them, and verifies or
rebuilds a stored file from the chain. Standard library only. Every hash, ID and byte layout here
must agree with `src/content/ContentStore.sol`; `test/content/tooling/UploaderGolden.t.sol` and the
golden vectors in `golden/` keep the two in step. Run `python -m tools.content --help`.
"""
