## Summary

<!-- What changed and why. One focused change per PR. -->

## ADR 0001 sections touched

<!-- e.g. §5 Sales and auctions, §7 Economics. "None" for tooling or docs only.
     Anything outside ADR 0001 needs a new ADR first. -->

## Validation

```text
forge fmt --check
forge build
forge test
python tools/check_budgets.py --profile default
# paste the results here: test counts and the budget gate output
```

- [ ] Tests added or updated: specific revert selectors, event assertions, fuzz and invariants where value moves.
- [ ] EIP-170 holds: largest contract size is stated above.

## Security notes

<!-- External calls, value flows, signatures and replay, governed setters (compare-and-set),
     roles and admin paths, storage layout. Write "none" if not applicable.
     Do not describe an exploitable vulnerability here: see SECURITY.md. -->

- [ ] No private keys, seed phrases, RPC credentials, tokens or unredacted broadcasts.
- [ ] No claim of audit, beta or production readiness.

## Known gaps

<!-- What is deliberately left out, open questions, follow-ups. -->
