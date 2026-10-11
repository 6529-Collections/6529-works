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
- CI under 15 minutes.
- Starting an auction costs 300K gas or less; `tokenURI` costs 8M gas or less.

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
- Request CodeRabbit review (`@coderabbitai review`). Verify bot findings, fix
  the valid ones, and explain any you decline.
- Merge with green required checks and resolved threads.

## Security and secrets

- Never commit private keys, seed phrases, signer material, RPC credentials or
  API tokens.
- Do not discuss exploitable vulnerabilities publicly. See
  [SECURITY.md](SECURITY.md).
