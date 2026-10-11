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
- Governance: a genesis wiring phase. `GovernanceConfigurator.configure` executes the
  one-shot binds and admitted-minter grants as zero-delay admin before renouncing, and
  `config/genesis.example.json` commits the selector, role and delay map for every v1
  contract, checked by `test/governance/GenesisConfig.t.sol`.
- CI: the budget gate measures an explicit Foundry profile (`--profile`, default
  `default`) and fails cleanly on malformed `forge build --sizes` output.
- CI: a parallel **Static analysis** job runs Slither (hash-locked, pinned) and fails on
  any High or Medium finding without a row in `docs/security/slither-triage.md`.
