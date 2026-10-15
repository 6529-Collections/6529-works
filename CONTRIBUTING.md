# Contributing

6529 Works is pre-audit and under active construction. Before you start:

1. Read [ADR 0001](docs/adr/0001-v1-scope.md) for the scope, and the
   [delivery plan](ops/DELIVERY_PLAN.md) for current priorities.
2. Read the [specification](docs/spec/README.md) page for the area you are changing. It states
   the rules, with their IDs and the tests that prove them; a change that alters a rule updates
   the page in the same PR. Terms are in the [glossary](docs/glossary.md). The README in each
   `src/` folder is a code map of that module: its files, entry points, storage and bytecode
   notes, and the tests to run.
3. Read [Build, test and budgets](docs/audit/build-and-test.md) for the CI gates and the gas
   and state-growth rules, and [Testing](docs/testing/README.md) for the layers of the suite,
   coverage floors, mutation testing and the Halmos proofs.
4. Open an issue before large changes. Changes outside the ADR scope need a new
   ADR.
5. Keep PRs small and focused. Each PR states:
   - what changed and why;
   - the validation you ran;
   - the security impact.
6. Tests come with the code:
   - unit tests with specific revert selectors;
   - invariants for anything that moves money;
   - gas checks where the budgets apply.
7. `forge build` and `forge test` must pass, and the CI budgets must hold.
8. A new or changed `restricted` function is mapped in
   [`config/genesis.example.json`](config/genesis.example.json) in the same PR
   (`tools/check_genesis.py` fails otherwise). Then regenerate the
   [role and permission matrix](docs/audit/roles.md) with `python tools/gen_role_matrix.py`;
   CI checks it with `--check`.
9. Static analysis must stay clean: Slither runs in CI, and a High or Medium finding
   needs a reviewed row in [docs/security/slither-triage.md](docs/security/slither-triage.md)
   (or a fix). Run it locally with `python tools/check_slither.py` after
   `python -m pip install -r requirements-tools.in`, which installs the same pinned Slither
   on any platform; CI installs the Linux hash lock, `requirements-tools.lock`.
10. Documentation must stay true. Each fact has one owner, and other pages link to it
    ([where each fact lives](docs/README.md#where-each-fact-lives)): update the owner, not a
    copy. Run `python tools/check_markdown_links.py` and
    `python tools/check_docs_facts.py --artifacts out` (after `forge build`); the second also
    refreshes the audit scope's figures with `--update`.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md),
never in public issues or PRs.
