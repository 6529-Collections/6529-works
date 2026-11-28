# Contributing

6529 Stream is pre-audit and under active construction. Before you start:

1. Read the [three-page overview](docs/overview.md), then [ADR 0001](docs/adr/0001-v1-scope.md)
   for the scope and [ADR 0010](docs/adr/0010-plain-permanent-core.md) for what is permanent.
2. Read the [specification](docs/spec/README.md) page for the area you are changing. It states
   the rules, with their IDs and the tests that prove them; a change that alters a rule updates
   the page in the same PR. Terms are in the [glossary](docs/glossary.md). The README in each
   `src/` folder is a code map of that module: its files, entry points, storage and bytecode
   notes, and the tests to run.
3. Read the engineering rules in [AGENTS.md](AGENTS.md) and
   [Testing](docs/testing/README.md) for the layers of the suite, coverage floors, mutation
   testing and the Halmos proofs.
4. Open an issue before large changes. Changes outside the ADR scope need a new
   ADR.
5. Keep PRs small and focused. Each PR states what changed and why, how it was checked and
   the security consequence.
6. Permanent code is plain ([ADR 0010](docs/adr/0010-plain-permanent-core.md)): no gas
   number, no assembly, no `try`/`catch`, no fixed waiting period (every wait is a network
   setting). Comments cite only what a reader can look up here ([AGENTS.md](AGENTS.md#comments)).
7. Tests come with the code:
   - unit tests with specific revert selectors;
   - invariants for anything that moves money;
   - gas checks where the budgets apply.
8. `forge build` and `forge test` must pass and the CI budgets must hold; a PR merges only
   with the `Contracts` and `Static analysis` checks green. The
   [quickstart](docs/quickstart.md) has the commands and a local end-to-end run.
9. A new or changed `restricted` function is mapped in
   [`config/genesis.core.example.json`](config/genesis.core.example.json) in the same PR
   (`tools/check_genesis.py` fails otherwise). Then regenerate the
   [role and permission matrix](docs/audit/roles.md) with `python tools/gen_role_matrix.py`;
   CI checks it with `--check`.
10. Static analysis must stay clean: Slither runs in CI, and a High or Medium finding
    needs a reviewed row in [docs/security/slither-triage.md](docs/security/slither-triage.md)
    (or a fix). Run it locally with `python tools/check_slither.py` after
    `python -m pip install -r requirements-tools.in`, which installs the same pinned Slither
    on any platform; CI installs the Linux hash lock, `requirements-tools.lock`.
11. Each fact has one owner, and other pages link to it
    ([where each fact lives](docs/README.md#where-each-fact-lives)): update the owner, not a
    copy. Run `python tools/check_markdown_links.py` and
    `python tools/check_docs_facts.py --artifacts out` (after `forge build`); the second also
    refreshes the audit scope's figures with `--update`.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md),
never in public issues or PRs.
