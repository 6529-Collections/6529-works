# Quickstart

From a fresh clone to a built, tested system running on a local node, with one work sold end to
end. Every command here is run from the repository root.

> Pre-audit. See the [project status](../README.md#status).

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`) | v1.7.1, as CI pins it | `foundryup --install 1.7.1`. Forge downloads solc 0.8.37 itself on the first build. |
| Python | 3.12 or later | The tools use the standard library only. The docs write `python`; where your system only has `python3`, use that. |
| Git | any recent | The OpenZeppelin and forge-std libraries are git submodules. |
| Bash | any | For the local walkthrough. On Windows, use Git Bash; the other commands work in PowerShell too. |

## 1. Clone and build

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
forge build
```

- If you cloned without submodules, run `git submodule update --init` first.
- The first build compiles about 520 files and runs solc as a single job: it took 5 to 6 minutes
  on a recent machine. Later builds compile only what changed.
- `forge build` also lints `src/` and `script/`. Three lints whose every hit was reviewed
  (`unsafe-typecast`, `incorrect-shift`, `block-timestamp`) are left out of the build output, with
  the reason for each in `foundry.toml`; `forge lint --only-lint unsafe-typecast incorrect-shift
  block-timestamp` lists their hits when you review a change to `src/`.

## 2. Test

```bash
forge test --no-match-test "^invariant"      # unit, fuzz and integration: about 1 minute
forge test                                    # everything: 15 to 18 minutes
```

- The full run is about 3,100 tests. Most of its time is the stateful invariant campaigns
  (256 runs of depth 128 each), which CI runs in three of its four parallel test jobs. Use the first command while
  you work and the full run before a pull request.
- The 44 fork tests are skipped unless you set an RPC URL ([fork tests](../test/fork/README.md)),
  and so is the keeper's fixture, which its own tests run.
- Running one file, one contract or one test, and every other layer of the suite, is described in
  [Testing](testing/README.md) and the [test map](../test/README.md).

## 3. Run the CI checks

```bash
forge fmt --check
python tools/check_budgets.py --profile default   # rebuilds with sizes; slow after a change
python tools/check_genesis.py                     # about 1 minute (one forge inspect per contract)
python tools/check_natspec.py
python tools/check_docs_facts.py --artifacts out  # after forge build
python tools/check_markdown_links.py
python tools/gen_role_matrix.py --check
```

What each gate checks, and the rest of what CI runs, is in
[Build, test and budgets](audit/build-and-test.md#running-the-ci-checks-locally).

## 4. Run the whole system locally

```bash
bash script/local/walkthrough.sh
```

It starts its own `anvil` node on port 8545 (stop any other node there first, or set
`WALKTHROUGH_PORT`), and in about a minute after the build:

1. deploys every contract with [`script/Deploy.s.sol`](../script/Deploy.s.sol), installs the
   genesis configuration with anvil's test accounts as the network and the role holders, and has
   the network accept (`ACCEPT_NETWORK=1`);
2. moves the clock five days and runs [`script/Verify.s.sol`](../script/Verify.s.sol);
3. walks one work through its life: content stored on-chain, a curated package registered and
   accepted by the artist, the 1/1 auction started with a bid, the edition auction opened beside
   it with two bids, a competing 1/1 bid, settlement, the work's record opened and finalized,
   `tokenURI`, the edition created and settled, copies claimed, and the proceeds released to the
   artist and the network.

Every account is one of anvil's default test accounts; no real key is used. What each phase does
and prints, and how to explore the node afterwards, is in [`script/local/`](../script/local/README.md).
To deploy by hand instead, step by step, follow the runbook's
[local dry run](../script/README.md#local-dry-run-anvil).

## Next

| To | Read |
| --- | --- |
| Learn how the protocol works | The [specification](spec/README.md), the [architecture overview](architecture.md) and the [glossary](glossary.md) |
| Integrate a marketplace, wallet, indexer or front end | The [integrator guide](integrators/README.md), the exported ABIs in [`abi/`](../abi/), runnable examples in [`examples/`](../examples/README.md), and a reference keeper in [`keeper/`](../keeper/README.md) (reference code, not production software) |
| Deploy to a testnet | The [runbook](../script/README.md#sepolia-runbook) |
| Contribute | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Review security | The [auditor pack](audit/README.md) |
