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
  ([ADR 0004](docs/adr/0004-gas-budgets-under-glamsterdam.md)). An ERC-20 start paid by
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

## Workflow

```bash
git fetch origin main
forge build
forge test
```

- One focused change per PR, branched from `origin/main`. Describe the summary,
  the validation you ran, and the security impact.
- A change of behavior updates its page in [docs/spec/](docs/spec/README.md) in the
  same PR. A change to `config/genesis.example.json` regenerates the role matrix
  (`python tools/gen_role_matrix.py`). A source change that moves nSLOC or bytecode sizes
  refreshes the docs with `python tools/check_docs_facts.py --artifacts out --update`. CI
  checks all three.
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
