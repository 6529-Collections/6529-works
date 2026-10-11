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
| `peers` | Ungoverned addresses that wiring passes as arguments, including the manager itself, the epoch-0 manifest's subject. |
| `contracts` | `cfg.targets`, per contract. `artifact` is the compiled ABI the entries are checked against. `implementation` is the contract on `main`, or null while its lane is pending. `functions` lists the governed selectors, each with its role, delay class and delay. `genesisOnly` lists one-shot binds that stay unmapped (`ADMIN`) and are wired. `deferred` lists restricted functions that are neither mapped nor wired in v1. |
| `wiring` | The genesis calls `configure` executes as zero-delay admin before mapping any selector: the one-shot binds, the admitted minters, the sale targets and the epoch-0 governance manifest. |
| `initialInstalls` | Which initial settings are constructor arguments and which are wiring (below). |
| `pendingLanes` | Contracts whose implementations are not yet on `main`. |
| `unusedRoles` | Roles with no v1 selector: `MINTER` (adapters are admitted per token instead) and `KEEPER`. |

## Sources

The selector classes follow:
- [ADR 0002](../docs/adr/0002-access-manager-hardening.md) decision 7;
- [ADR 0003](../docs/adr/0003-build-time-decisions.md);
- the governance map in [docs/architecture.md](../docs/architecture.md);
- the interfaces and implementations on `main`.

**Two paths for creators and artists.** `openSale` and `closeSale` on the sale
adapters, and `addLocator` on WorkRecords, let the creator or the artist act directly.
`PLATFORM`'s path to the same functions goes through a manual `canCall` check in the
implementation, not through `restricted`, so the mapping here grants PLATFORM only.
The integration lane verifies both paths on the real contracts.

## Initial installs: constructor or wiring

The deploy script follows one rule:

- **Constructor arguments:** anything immutable, or installed once with a pinned code hash:
  - the curation verifier in the `PackageRegistry`;
  - the resolver and escrow in each sale adapter;
  - the consolidation source in the `ArtistRegistry`;
  - the artist resolver in the `StatementLog`;
  - the initial economics and default license in the `EconomicsResolver`.

  Changing any of them later goes through its governed setter and delay class.
- **Wiring (`wiring` in this file):** calls that connect contracts deployed independently:
  - the one-shot `bind*` calls;
  - the admitted-minter grants (`setAdmittedMinter`);
  - the sale adapters' targets (`setTarget`);
  - the epoch-0 governance manifest (`appendGovernanceManifest` on the statement log).

  Nothing else can be wired: `GovernanceConfig.isGenesisSelector` is an allow-list.

  `configure` executes them as zero-delay admin before mapping selectors.
- **Grants:** curation signers become active when they are granted `CURATION_SIGNER` in
  `holders`. The verifier keeps no signer list to wire.

`ArtistRegistry.bindFederationRegistry` is listed under `deferred` and is not wired.
The federation registry ships in v1.1, and binding it then is a 30-day `ADMIN` action.

## Checks

**[`test/governance/GenesisConfig.t.sol`](../test/governance/GenesisConfig.t.sol)** reads
this file (Foundry has read-only access to `./config`) and checks:
- **Compiled selectors:** every entry equals a compiled `Interface.f.selector` or
  `Contract.f.selector`, in both directions, so a renamed or re-typed function fails to
  compile.
- **Roles and classes:** the role table matches `Roles.sol`, and every delay matches its
  role's class.
- **Wiring:** every call uses a genesis selector, every genesis-only bind is wired, and no
  deferred entry is.
- **Guardians:** they hold only `GUARDIAN` and `PAUSER`.
- **Installation:** the whole configuration, wiring included, installs on a fresh manager
  and reads back with `verify`.
- **Gas:** the configuration plus the maximum wiring stays under 60% of the EIP-7825 cap.

**[`tools/check_genesis.py`](../tools/check_genesis.py)** runs in CI (standard library
only; unit tests in `tools/test_check_genesis.py`). It compares every entry with
`forge inspect <path:Contract> methodIdentifiers`, including overloads such as the
auction's two `pause` functions. It also requires every `restricted` function of every
concrete contract under `src/` to be mapped, genesis-only or deferred, so nothing silently
falls back to `ADMIN`.
- **Inherited functions:** a `restricted` function declared in an abstract base, such as
  `MintSaleBase`, counts for each concrete contract that inherits it. The abstract base is
  never required in the configuration itself.
- **Pending contracts:** a configured contract whose artifact source is not in the
  repository yet is reported as pending and passes. It is mapped ahead from its lane's
  branch, so its merge never turns `main` red, and it is checked in full once its source
  lands. Today these are Stream, WorkRecords and Editions.

Selectors and wiring calldata are generated from the build artifacts and `cast calldata`,
not typed by hand. When a lane merges, add its contract's `implementation` and its
implementation-only setters; the checker fails until they are listed.
