# Changelog

## Unreleased

- Repository created for the 6529 network's art protocol: 6529 Stream, 6529
  Editions and 6529 Stream Federated.
- ADR 0001 records the accepted v1 scope (originally 6529Stream ADR 0055).
- ADR 0003 records the build-time decisions for v1: ABI package hashing, the Stream
  core and records split, the 350K start-gas budget, pull-only artist payouts,
  sticky identity standing, base64 attestation for inline media, and more.
- ADR 0002 records how the AccessManager hardening in ADR 0001 §13 is implemented:
  a guardian-cancellable subclassed manager, guardian rules, a cold recovery admin
  and the selector delay classes decided during the build.
- Governance: `WorksAccessManager` (guardians cancel any scheduled operation;
  nobody cancels their own revocation), the canonical role and delay-class table
  (`Roles.sol`), a one-shot configurator that owns its manager and reads it back,
  and `BoundedParameter` for raise-only parameters.
- Governance: a genesis wiring phase. `GovernanceConfigurator.configure` executes an
  allow-list of genesis calls (one-shot binds, admitted minters, sale targets and the
  epoch-0 manifest) as zero-delay admin before renouncing. `config/genesis.example.json`
  commits the selector, role and delay map for every v1 contract, checked against the
  compiled selectors by `test/governance/GenesisConfig.t.sol` and against `forge inspect`
  and every `restricted` function in `src/` by `tools/check_genesis.py` in CI.
- Identity: `ArtistRegistry` and `ConsolidationAdapter` (ADR 0001 §11). The
  registry has 7-day STANDARD changes and 180-day two-sided overrides, a sticky
  recovery-standing snapshot (young consolidations recorded as pending, a 30-day
  public grace for missing wallets), a payout freeze while a change would move
  the payout, payout validation, and one-shot bindings. The adapter reads 6529
  consolidations with age and expiry. `IArtistRegistry` gains the standing
  surface, `FederatedListFull` and `AcceptanceUsed`; `IConsolidationSource`
  gains `consolidations` and `effectiveAt`; `OVERRIDE_ACCEPTANCE` is nonce-free
  and consumed once by digest.
- Identity: contested overrides (ADR 0003 owner decision 1). A captured wallet's
  cancel during the notice turns a 180-day override into a contest that a TDH
  vote decides through the governed `resolveContested`, which cites the vote's
  DISPUTE_OUTCOME statement, recorded after the contest.
  The payout stays frozen meanwhile, the guardian may veto, and an unresolved
  contest lapses after a year (`expireContest`). `bindStatementLog` is a new
  genesis wiring call.
- Deployment: `script/` deploys the merged v1 contracts with CREATE2 (`DeployV1`),
  installs the genesis configuration, records the deployment, and confirms it against the
  chain (`Verify.s.sol`), which recomputes every address from the recorded constructor
  parameters. Off anvil, the deploy script refuses the following: placeholder or unreachable
  holders (ADMIN and GUARDIAN must be Safes), a genesis that departs from the committed
  policy, a CC0 text other than the pinned canonical one, a missing entropy-module choice,
  non-canonical dependencies on mainnet, and anything the genesis names but the deployment
  lacks. Each product's first default currency is genesis wiring. `script/README.md` is the
  Sepolia runbook. The canonical CC0 legal code is pinned by digest. The deploy covers every
  v1 contract, the renderer and 6529 Editions included, with no stand-in.
- Deployment, owner decisions: off anvil, at least two admin Safes (hot and cold) and three
  guardian Safes, and no signer shared between admin Safes or between an admin and a
  guardian Safe. The runbook adds an admin-recovery procedure and guardian practice. Sepolia
  mirrors mainnet: throwaway signers, a real VRF subscription, and the official 6529
  delegation deployment. That deployment is the default there, and the canonical code hash is
  pinned. Artists refresh their own recovery standing; a network keeper is optional. The CC0
  legal code is committed as a byte-exact test fixture and is the deploy's default text.
- CI: the budget gate measures an explicit Foundry profile (`--profile`, default
  `default`) and fails cleanly on malformed `forge build --sizes` output.
- CI: a parallel **Static analysis** job runs Slither (hash-locked, pinned) and fails on
  any High or Medium finding without a row in `docs/security/slither-triage.md`.
