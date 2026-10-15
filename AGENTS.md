# Agent operating guide

Instructions for automated coding agents working in this repository.

## Scope and ownership

- **Scope** is [ADR 0001](docs/adr/0001-v1-scope.md). Anything outside it needs a
  new ADR first.
- **Delivery state** lives in [ops/DELIVERY_PLAN.md](ops/DELIVERY_PLAN.md).
- **Delivery owner:** Claude Code is the integrator, acting for the repository
  owner. Builder agents work on independent lanes in their own worktrees and hand
  over small, green PRs.
- **Maturity:** pre-audit. Never claim audit, beta or production readiness
  without merged evidence.

## Engineering rules

**Budgets** (CI-enforced)
- 8–12K non-comment lines of Solidity under `src/`.
- At most 5 linked libraries.
- No delegatecall and no proxies.
- EIP-170 respected, measured on the explicit `--profile default` build.
- No unreviewed High or Medium Slither finding (`docs/security/slither-triage.md`).
- CI under 15 minutes.
- Starting an auction in ETH, Stream's launch currency, at steady state costs at most 350K
  Prague gas and writes at most 6 new storage slots, 7 with a bid
  ([ADR 0004](docs/adr/0004-gas-budgets-under-glamsterdam.md)); the artist's later works,
  which reuse Stream's shared terms word, write 5 and 6. An artist's first start under new
  terms writes one more on a hashed-position collision, which a curated artist can force by
  grinding an address; first starts are measured and gated separately, and such a collision
  can push one over 350K (an accepted limitation). The binding row, an artist's first start
  of a two-party work with a bid, and its margin are in ADR 0004's table. An ERC-20 start paid by
  Permit2 is a supported, non-default path: it has a regression ceiling and exact counts, not
  a budget. Admitting the first ERC-20, or approving a Stream package that names one, must be
  accompanied by a re-measurement and publication of its start cost, in Prague gas and on the
  target chain. `tokenURI` costs at most 8M Prague gas.
- Every operation in `test/integration/GasReport.t.sol` asserts its exact count of new storage
  slots and new accounts, and a Prague gas ceiling. When a change lowers a count, the same PR
  lowers the test's figure, ADR 0004's table and the figures here; that needs no new ADR.
  Raising a count needs a stated reason, and raising the `start` or `startWithBid` maximum
  needs an ADR.
- Every transaction's regular gas fits the 16,777,216 cap (EIP-7825) for worst-case bounded
  inputs.

**Solidity:** the pinned 0.8.x compiler in `foundry.toml`, OpenZeppelin 5, and
custom errors.
- Use events for every important state change.
- Use storage-backed replay protection.
- Use `abi.encode` for structured hashing.
- Use pull payments, with exact balance-delta checks on token transfers.
- Fail closed: no soft-failing reads that return plausible defaults.
- No `tx.origin`, and no unbounded loops over user-controlled data.

**Tests:**
- forge-std assertions, and `vm.expectRevert` with specific selectors.
- Every contract that moves money gets stateful invariants (≥256 runs × depth
  128) and adversarial mocks.
- Security-sensitive changes need happy-path, negative, regression and event
  tests.

**Reuse.** Port from the ADR 0001 §17 keep list by rewriting within the budgets.
Never copy 6529Stream PR #744 code wholesale.

## Documentation: one source of truth per fact

Each fact has one owner; every other page links to it instead of repeating it
([where each fact lives](docs/README.md#where-each-fact-lives)):

| Fact | Owner |
| --- | --- |
| Rules, state machines, parameters | The [specification](docs/spec/README.md) page of the area, by rule ID (`AUC-3`, `WS-17`, ...) |
| Where the code departs from an ADR | The [register](docs/spec/README.md#differences-from-the-adrs) in the specification index |
| Events and topic0 values | [Events and indexing](docs/integrators/events-and-indexing.md) |
| Selector, role, delay | The generated [role matrix](docs/audit/roles.md) (from `config/genesis.example.json`) |
| Gas budgets and measured gas | [ADR 0004's table](docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) |
| Accepted risks and known gaps | [Known limitations](docs/audit/known-limitations.md) |
| Sizes and nSLOC | [Audit scope](docs/audit/scope.md) and the README's module table, refreshed by `check_docs_facts.py --update` |

- **Module READMEs under `src/` are code maps:** what the module is for, its files, entry
  points with rule IDs, developer notes (storage layout, bytecode headroom, gotchas, tests)
  and links. Keep each under about 800 words and put rules, events, roles, gas figures and
  risks on their owning page, not in the README.
- **ADRs are history.** Never rewrite one; record a later correction as a dated amendment
  note, and the current behavior in the specification and its ADR register. The exception is
  ADR 0004's table, which its decision 2 keeps current.
- Testing guidance (coverage, mutation testing, Halmos proofs) is coming in
  [PR #58](https://github.com/6529-Collections/6529-works/pull/58) as `docs/testing/`;
  until then, [Build, test and budgets](docs/audit/build-and-test.md) covers the CI gates.

## Workflow

```bash
git fetch origin main
forge build
forge test
```

- One focused change per PR, branched from `origin/main`. Describe the summary,
  the validation you ran, and the security impact.
- A change of behavior updates its page in [docs/spec/](docs/spec/README.md) in the
  same PR, and the module README if a file, entry point or developer note changed. A
  change to `config/genesis.example.json` regenerates the role matrix
  (`python tools/gen_role_matrix.py`). A source change that moves nSLOC or bytecode sizes
  refreshes the docs: run `forge build`, then
  `python tools/check_docs_facts.py --artifacts out --update`, and commit what it rewrote.
  CI checks all three: the Docs job runs `gen_role_matrix.py --check`, `check_docs_facts.py`
  and `check_markdown_links.py`, and the required Contracts job runs
  `check_docs_facts.py --artifacts out`.
- Keep the **Static analysis** job green. Fix a new High or Medium Slither finding; only
  disposition a real false positive or an accepted risk, with a reason, in
  [docs/security/slither-triage.md](docs/security/slither-triage.md).
- Request CodeRabbit review (`@coderabbitai review`). Verify bot findings, fix
  the valid ones, and explain any you decline.
- Merge with green required checks and resolved threads.

## Security and secrets

- Never commit private keys, seed phrases, signer material, RPC credentials or
  API tokens.
- Do not discuss exploitable vulnerabilities publicly. See
  [SECURITY.md](SECURITY.md).
