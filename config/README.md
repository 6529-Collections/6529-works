# config

Deployment configuration for the 6529 Works `WorksAccessManager`
([src/governance](../src/governance/README.md)).

`genesis.example.json` is the committed genesis configuration. **Every address in it is a
placeholder**: `0x…a0xx` stands for a contract and `0x…b0xx` for a holder.

A real deployment copies it and replaces the holders with its Safes and keys.
[`script/Deploy.s.sol`](../script/README.md) substitutes the deployed contracts by name and
passes the result to `GovernanceConfigurator.configure(cfg, manifestHash, wiring)`.

**This file is the policy.** A deployment's copy may differ only in its holders, its
description and its address fields:
- `python tools/check_genesis.py --config <copy>` compares the copy with this file;
- off anvil, the deploy script refuses a copy whose governed targets or wiring differ from
  what this file produces (`DeployGuards.checkPolicy`).

A change to a role, a delay class or a wiring call is a change to this file, made by PR.

| Key | Contents |
| --- | --- |
| `roles` | Every role in `Roles.sol`, with its ID, execution delay and grant delay, and whether a guardian may suspend its holders (`suspendable`, `Roles.isSuspendable`). |
| `holders` | `cfg.grants`: hot and cold admin Safes (the cold one ADMIN only, 3-of-5 recommended, with signers distinct from the hot admin's and the guardians'), three guardian Safes (`GUARDIAN` and `PAUSER` only, 2-of-3 each), two curation signers, and one key each for storage, platform and curator. Off anvil the deploy script requires at least two admin Safes and three guardian Safes, each with a threshold of at least 2, owners that are plain keys, a canonical Safe 1.3.0 or 1.4.1 singleton, no module and no guard, and no signer shared between any two of the admin and guardian Safes. |
| `peers` | Ungoverned addresses that wiring passes as arguments, including the manager itself, the epoch-0 manifest's subject. |
| `manager` | The manager's own functions beyond its OpenZeppelin base, which check the caller's role themselves: the guardians' `suspend`, and the `isSuspended` view. `tools/check_genesis.py` requires every added function to be listed. |
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

**Two paths for artists.** `addLocator` on WorkRecords lets the artist act directly.
`PLATFORM`'s path to the same function goes through a manual `canCall` check in the
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
  - each product's first default currency (`setDefaultCurrency`, ETH for `PRODUCT_STREAM`,
    `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`): `EnglishAuction.start` reads it, and the
    setter is otherwise a 14-day FUNDS_SETTER action;
  - the English auction's ETH opening bid of 0.05 ETH (`setOpeningBid`, owner decision 19),
    later a 48-hour PARAMETER_SETTER action;
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
falls back to `ADMIN`. With `--config`, it also checks that copy against this committed file
(the policy above).
- **Inherited functions:** a `restricted` function declared in an abstract base counts for
  each concrete contract that inherits it. The abstract base is
  never required in the configuration itself.
- **Pending contracts:** a configured contract whose artifact source is not in the
  repository yet is reported as pending and passes. It is mapped ahead from its lane's
  branch, so its merge never turns `main` red, and it is checked in full once its source
  lands. Every configured contract is on `main` today, so none is pending. (The JSON's
  `status` and `pendingLanes` fields are descriptive only; the checker ignores them.)

Selectors and wiring calldata are generated from the build artifacts and `cast calldata`,
not typed by hand. When a lane merges, add its contract's `implementation` and its
implementation-only setters; the checker fails until they are listed.

**[`tools/gen_role_matrix.py`](../tools/gen_role_matrix.py)** renders this file as the
[role and permission matrix](../docs/audit/roles.md): every mapped selector with its role, delay
class and whether a guardian can cancel it. After any change here, run
`python tools/gen_role_matrix.py` and commit the result; CI's Docs job runs it with `--check`
and fails if the matrix is stale. It also checks that every selector is the keccak-256 of its
signature and that every delay matches its role.
