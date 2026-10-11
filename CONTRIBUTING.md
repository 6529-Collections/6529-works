# Contributing

6529 Works is pre-audit and under active construction. Before you start:

1. Read [ADR 0001](docs/adr/0001-v1-scope.md) for the scope, and the
   [delivery plan](ops/DELIVERY_PLAN.md) for current priorities.
2. Open an issue before large changes. Changes outside the ADR scope need a new
   ADR.
3. Keep PRs small and focused. Each PR states:
   - what changed and why;
   - the validation you ran;
   - the security impact.
4. Tests come with the code:
   - unit tests with specific revert selectors;
   - invariants for anything that moves money;
   - gas checks where the budgets apply.
5. `forge build` and `forge test` must pass, and the CI budgets must hold.
6. Static analysis must stay clean: Slither runs in CI, and a High or Medium finding
   needs a reviewed row in [docs/security/slither-triage.md](docs/security/slither-triage.md)
   (or a fix). Run it locally with `python tools/check_slither.py` after
   `python -m pip install -r requirements-tools.in`, which installs the same pinned Slither
   on any platform; CI installs the Linux hash lock, `requirements-tools.lock`.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md),
never in public issues or PRs.
