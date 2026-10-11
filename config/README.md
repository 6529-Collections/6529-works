# config

Deployment configuration for the 6529 Works `WorksAccessManager`
([src/governance](../src/governance/README.md)).

`genesis.example.json` is the committed genesis configuration. **Every address in it is a
placeholder**: `0x…a0xx` stands for a contract and `0x…b0xx` for a holder. A real deployment
copies it, substitutes the deployed and Safe addresses, and passes the result to
`GovernanceConfigurator.configure(cfg, manifestHash, wiring)`.

| Key | Contents |
| --- | --- |
| `roles` | Every role in `Roles.sol`, with its ID, execution delay and grant delay. |
| `holders` | `cfg.grants`: hot and cold admin Safes, three guardian Safes (`GUARDIAN` and `PAUSER` only), two curation signers, and one key each for storage, platform and curator. |
| `contracts` | `cfg.targets`: each v1 contract's governed selectors, each with its signature, role, delay class and delay. `genesisOnly` lists one-shot binds that stay unmapped (`ADMIN`) and run once in the wiring. |
| `wiring` | The genesis calls `configure` executes as zero-delay admin before mapping any selector: the one-shot binds, the admitted minters and the sale adapters' targets. |
| `pendingLanes` | Contracts whose implementation-only setters, or initial installs, are not yet on `main`. |
| `unusedRoles` | Roles with no v1 selector: `MINTER` (adapters are admitted per token instead) and `KEEPER`. |

## Sources

The selector classes follow:
- [ADR 0002](../docs/adr/0002-access-manager-hardening.md) decision 7;
- the governance map in [docs/architecture.md](../docs/architecture.md);
- the NatSpec of the interfaces in [src/interfaces](../src/interfaces).

Where those disagree, the accepted ADR wins. The architecture map lists
`AssetAllowlist.admitAsset` and `setDefaultCurrency` under `PARAMETER_SETTER`, while ADR 0002
and the economics lane put them in the 14-day funds class, as this file does.

## Checks

[`test/governance/GenesisConfig.t.sol`](../test/governance/GenesisConfig.t.sol) reads this file
(Foundry has read-only access to `./config`) and checks:
- **Roles:** the role table matches `Roles.sol`.
- **Selectors:** every selector matches its signature, and every delay matches its role's class.
- **Wiring:** each call's calldata matches its signature and names its peer's placeholder.
- **Guardians:** they hold only `GUARDIAN` and `PAUSER`.
- **Installation:** the whole configuration, wiring included, installs on a fresh manager and
  reads back with `verify`.
- **Gas:** the configuration plus the maximum wiring stays under 60% of the EIP-7825
  transaction gas cap.

Selectors and wiring calldata were generated from the build artifacts and `cast calldata`, not
typed by hand. If an interface changes, regenerate the affected entries; the test catches any
selector that no longer matches its signature.
