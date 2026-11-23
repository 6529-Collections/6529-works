# Agent operating guide

Instructions for automated coding agents working in this repository. Human contributors read
[CONTRIBUTING.md](CONTRIBUTING.md); the system itself is described in the
[three-page overview](docs/overview.md).

## Scope

- Scope is [ADR 0001](docs/adr/0001-v1-scope.md) as amended, most recently by
  [ADR 0010](docs/adr/0010-plain-permanent-core.md) (the plain permanent core). Anything
  outside it needs a new ADR first.
- Maturity: pre-audit. Never claim an audit, beta or production readiness.
- Deployments: Sepolia only, with throwaway keys. Never mainnet.

## Permanent code (`src/core/`, the split ledger and vaults, the escrow, the content store)

- Holds only token ownership and the collection address, the facts of a finished work, and
  money already owed. Every rule lives in a replaceable module.
- Plain: OpenZeppelin style, one struct per thing, no assembly, no hand-packed words, no hash
  tables, no `try`/`catch`, no gas numbers, no `delegatecall`; `pragma solidity 0.8.37;`;
  custom errors; an event for every state change, sufficient to rebuild the state from that
  contract's logs alone.
- No fixed waiting periods. Every wait is a network setting: a stored value with a launch
  value, changed by the network at once (no floor, zero allowed), with an event carrying old
  and new. Tests read the setting; they never assume the number. Limits on the work of one
  transaction (payees, chunks, name lengths) stay compiled.
- Every contract under `src/core/` keeps at least 3,000 bytes of EIP-170 margin; every other
  contract at least 512 (`tools/size-margins.json`).

## Comments

NatSpec is plain English and complete (`python tools/check_natspec.py`). A comment states what
the code does and what it guarantees, never its history. A comment may cite only:

- a rule ID of the specification that exists today (`AUC-3`, `WS-17`, `ED-30`);
- an invariant or property ID of [docs/audit/invariants.md](docs/audit/invariants.md);
- an ADR by number (`ADR 0010`), an EIP or ERC by number, or a limitation ID
  (`LIM-SAL-9`) of [known limitations](docs/audit/known-limitations.md);
- a file, contract, function or error in this repository.

It may not cite owner decisions by number, review or finding labels, pass or lane names,
pull request numbers or any other code a reader cannot look up here.
`python tools/check_comment_codes.py` lists every remaining code.

## Engineering rules

- At most 17,000 non-comment lines of Solidity under `src/`; at most 5 linked libraries; no
  delegatecall and no proxies; no unreviewed High or Medium Slither finding
  ([triage](docs/security/slither-triage.md)).
- Every start row of the English auction costs at most 370,000 Prague gas and writes at most 8
  new storage slots, with or without a bid ([ADR 0004](docs/adr/0004-gas-budgets-under-glamsterdam.md)
  as amended by ADR 0010); `tokenURI` at most 8M Prague gas.
- Pull payments with exact balance checks; storage-backed replay protection; `abi.encode` for
  structured hashing; fail closed (no read that returns a plausible default); no `tx.origin`.
- Tests: forge-std assertions; `vm.expectRevert` with specific selectors; stateful invariants
  (256 runs, depth 128) for anything that moves money; hostile-module tests for every side of
  the seam (a module that lies, reverts, burns all gas or re-enters: no token moves, no fact or
  balance changes, transfers still work).

## Documentation: one owner per fact

| Fact | Owner |
| --- | --- |
| What the system is | [Overview](docs/overview.md) |
| Rules, by rule ID | The [specification](docs/spec/README.md) page of the area |
| Events and topic0 values | [Events and indexing](docs/integrators/events-and-indexing.md) |
| Selector, role, delay | The generated [role matrix](docs/audit/roles.md) (from `config/genesis.core.example.json`) |
| Gas budgets and measured gas | [ADR 0004's table](docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) |
| Accepted risks and known gaps | [Known limitations](docs/audit/known-limitations.md) |
| Sizes and nSLOC | [Audit scope](docs/audit/scope.md), refreshed by `check_docs_facts.py --update` |

- Write for the owner and for outside readers: plain English, short sentences, no internal
  codes, no wording that frames the network as a risk. Never call a waiting period a guarantee.
- ADRs are history: never rewrite one; add a dated amendment note. ADR 0004's table is kept
  current.
- Module READMEs under `src/` are code maps of at most about 800 words.

## Workflow

```bash
forge build
forge test --no-match-test "^invariant"
python tools/check_markdown_links.py
```

- One focused change per PR, branched from `origin/main`; state the summary, the validation
  run and the security impact.
- A behaviour change updates its specification page in the same PR. A change to the genesis
  configuration regenerates the role matrix (`python tools/gen_role_matrix.py`). A change that
  moves sizes runs `python tools/check_docs_facts.py --artifacts out --update`.
- Use `python`, not `python3`. Read and write text as UTF-8.
- Request CodeRabbit review (`@coderabbitai review`); verify bot findings before acting.

## Security and secrets

Never commit private keys, seed phrases, signer material, RPC credentials or API tokens. Do not
discuss exploitable vulnerabilities publicly ([SECURITY.md](SECURITY.md)).
