# script

Deployment and verification for 6529 Works v1, plus the Sepolia runbook. These scripts
implement the deploy assembly and the configuration readback from the
[§17 reuse plan](../docs/adr/0001-v1-scope.md#17-reuse-plan-from-rc1-and-pr-744) and the
[§13 evidence trail](../docs/adr/0001-v1-scope.md#13-governance) of
[ADR 0001](../docs/adr/0001-v1-scope.md).

Not built yet: a deployed-bytecode verifier that matches the chain against a reproducible
build. Verify checks code hashes against the deployment record only.

6529 Works is pre-audit and not deployed. A Sepolia run is a testnet rehearsal, not a
launch, and it is **not runnable yet**. Off anvil, the deploy refuses to proceed until the
Renderer (#20) merges (`RendererPending`). Editions (#14) joins the deploy when it merges.
The library already deploys identity (#16), Stream and WorkRecords (#22).

| File | Purpose |
| --- | --- |
| [`DeployV1.sol`](DeployV1.sol) | Library shared by the script and the tests. Deploys every merged v1 contract with CREATE2, uploads the CC0 text, builds the genesis configuration and wiring from the genesis JSON, and installs it. |
| [`VerifyV1.sol`](VerifyV1.sol) | Library: static readback of a deployment against its configuration. |
| [`Deploy.s.sol`](Deploy.s.sol) | Deploys, configures, and records `deployments/<chainId>/<timestamp>.json`. |
| [`Verify.s.sol`](Verify.s.sol) | Reads back a recorded deployment, and checks its events over RPC. |
| [`standins/RendererStandIn.sol`](standins/RendererStandIn.sol) | Anvil-only stand-in for the renderer until #20 merges. 6529 Stream pins its default renderer at construction. |

## Using the library from tests

```solidity
DeployV1.Deployment memory d = DeployV1.deploy(p);          // p.deployer = address(this)
GovernanceConfig.Config memory cfg = DeployV1.config(d, json);
GovernanceConfig.Call[] memory calls = DeployV1.wiring(d, json, manifest);
DeployV1.install(d, cfg, manifest, calls);                  // configure: the system is live
vm.warp(block.timestamp + d.manager.minSetback());          // the genesis delays take effect
VerifyV1.check(d, cfg, calls);
```

- `json` is the genesis configuration, for example `vm.readFile("config/genesis.example.json")`.
- `p.delegation` must have code. Tests pass a `DelegationManagementMock`
  (`test/mocks/identity/`). `p.marketOwner` is Stream's marketplace `owner()`.
- `p.deployer` must be the account that calls `install`; only that account can run `configure`.
- A test can add calls to `calls` before `install`, such as listing a mock token with
  `setTarget`, if each call is on the genesis allow-list
  (`GovernanceConfig.isGenesisSelector`).

[`test/deploy/DeployV1.t.sol`](../test/deploy/DeployV1.t.sol) has worked examples.

## Local dry run (anvil)

```bash
anvil --port 8545
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
cast rpc evm_increaseTime 432000 --rpc-url http://127.0.0.1:8545   # minSetback: 5 days
cast rpc evm_mine --rpc-url http://127.0.0.1:8545
DEPLOYMENT=deployments/31337/<timestamp>.json \
  forge script script/Verify.s.sol --rpc-url http://127.0.0.1:8545
```

- **Placeholders.** Anvil runs on placeholders and stand-ins. The placeholders are the example
  genesis, the CC0 text, the manifest, the fee recipient and the marketplace owner. The
  stand-ins are the renderer, and a `DelegationManagementMock` deployed first because the
  canonical delegation address has no code. The record says `"placeholders": true` and lists
  the stand-ins.
- **Use `--slow`.** Without it, anvil can pack a block until the next deploy transaction no
  longer fits. That transaction then waits for a block that automine never produces;
  `cast rpc evm_mine` frees it.
- **No key is handled.** The anvil node unlocks its own dev account.
- **Restart, don't reset.** Restart anvil rather than calling `anvil_reset`, which removes the
  CREATE2 deployer.
- **Verify needs the 5 days.** Before the warp, Verify fails with `RoleMismatch`. The grant
  delays and target admin delays that genesis sets take effect only after the manager's
  `minSetback`. Every role works from genesis.

## Sepolia runbook

The owner holds every key and approves the broadcast. Nothing in this repository reads, prints
or stores a key:

- **Signing.** Sign with Foundry's `--account` (an encrypted keystore made by
  `cast wallet import`) or `--ledger`. Never pass `--private-key` or put a key in `.env`.
- **Credentials.** RPC URLs that carry an API key, and any Etherscan key, stay in the
  operator's shell. They never go into a committed file.
- **Broadcast caches.** Do not commit forge's `broadcast/` output for Sepolia; `.gitignore`
  only covers anvil's. The deployment record is the committed evidence.

### 1. Accounts

| Account | Roles | Kind |
| --- | --- | --- |
| Deployer (operator) | None after genesis. It is the configurator's `deployer`, and signs every deploy transaction and `configure` | Keystore or Ledger EOA, funded with Sepolia ETH |
| Hot admin Safe | ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER | Safe |
| Cold recovery admin Safe | ADMIN only | Safe, with signers distinct from the hot Safe |
| Guardian Safes 1, 2 and 3 | GUARDIAN, PAUSER (at least two Safes) | Safe |
| Curation signer keys 1 and 2 | CURATION_SIGNER. It signs approvals off-chain and never calls a contract | EOA |
| Storage operator | STORAGE_OPERATOR | EOA |
| Platform | PLATFORM | EOA |
| Curator | CURATOR | EOA |
| Network fee recipient | No role (`NETWORK_FEE_RECIPIENT`) | Any address |
| Marketplace owner | No role (`MARKETPLACE_OWNER`). Stream's `owner()`: collection admin on marketplaces, no protocol power; FUNDS_SETTER can change it | Safe or EOA |
| VRF subscription owner | No role; owns the Chainlink subscription (only with the entropy module) | EOA or Safe |
| Keeper | No role (`refreshStanding` is permissionless) | Any funded EOA |

Delays and responsibilities are in the [role table](../src/governance/README.md). Use Safes
where the table says Safe, as on mainnet, so the rehearsal exercises the Safe flows.

### 2. The genesis configuration

```bash
cp config/genesis.example.json config/genesis.sepolia.json
# Replace every holder (0x...b0xx) with the account from step 1.
# Leave the contract placeholders (0x...a0xx): the library substitutes deployed addresses by name.
python tools/check_genesis.py --config config/genesis.sepolia.json
```

Off anvil, `Deploy.s.sol` requires `GENESIS_CONFIG`. It refuses
`config/genesis.example.json` and any holder at or below `0xFFFF`, which covers the
placeholder range and the precompiles. The configurator renounces ADMIN in the genesis
transaction, so a wrong holder cannot be fixed afterwards. Commit the Sepolia genesis file
with the deployment record.

### 3. External contracts

Checked read-only on Sepolia on 11 October 2026. Check again before broadcasting.
`cast code` prints `0x` when an address has no code.

| Contract | Address | Sepolia | Used for |
| --- | --- | --- | --- |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | present | Every deploy (Foundry's default factory) |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | present | The sale adapters' Permit2 payments |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | present | The optional entropy module (step 6) |
| 6529 delegation contract | `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` | **absent** | The artist registry's consolidation source (step 4) |

```bash
cast code 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d --rpc-url "$SEPOLIA_RPC_URL"
```

### 4. The delegation contract

`ConsolidationAdapter` reads consolidations from the 6529 delegation contract, and its
constructor requires code at that address. The `ArtistRegistry` pins the adapter's code hash. The canonical contract is
absent on Sepolia, so the rehearsal uses `DelegationManagementMock`
(`test/mocks/identity/DelegationManagementMock.sol`). The mock is a faithful reduction of the
6529 contract: the same storage, getters, and register and revoke semantics, and permissionless
like the original.

1. If `cast code` above prints code, use the canonical address and skip step 2.
2. Deploy the mock. The owner runs this command:

   ```bash
   forge create test/mocks/identity/DelegationManagementMock.sol:DelegationManagementMock \
     --rpc-url "$SEPOLIA_RPC_URL" --account <deployer> --broadcast
   ```

3. Pass the address as `DELEGATION_CONTRACT`. Off anvil, the script refuses an address
   without code. On mainnet it refuses anything but the canonical contract. The record
   lists the mock as a stand-in.

To consolidate two wallets on the mock, each one calls
`registerDelegationAddress(0x8888888888888888888888888888888888888888, <other wallet>, <expiry>, 999, true, 0)`:
use case 999, all collections, in both directions. Then run the keeper (step 11).

### 5. The CC0 license text

The default license for new works is CC0 1.0, and WorkRecords requires its text in the content
store. The file must be registered when WorkRecords is constructed, and complete before any
work finalizes. Genesis therefore stores it first, right after the content store
(`DeployV1._content`), and passes the file ID to the `EconomicsResolver` and to WorkRecords.

1. Save the plain-text CC0 1.0 Universal legal code, as published by Creative Commons
   (<https://creativecommons.org/publicdomain/zero/1.0/legalcode>), under `config/`. The
   script can read only `./config`. The file is not committed.
2. Set `CC0_TEXT_PATH=config/<file>` and `CC0_TEXT_SHA256=0x$(sha256sum config/<file> | cut -c1-64)`.
   The script refuses a file that does not match the digest. Record the digest with the
   deployment.
3. After the broadcast, check the stored copy against the chain. The record carries the
   `ContentStore` address and `cc0TextFileId`:

   ```bash
   python -m tools.content verify --rpc "$SEPOLIA_RPC_URL" --store <ContentStore> <cc0TextFileId>
   ```

### 6. Chainlink VRF (optional entropy module)

The entropy module is deployed only when `VRF_COORDINATOR` is set. Without it, works draw no
VRF seed.

1. In the Chainlink VRF app on Sepolia, create a **dedicated** subscription. Fund it with LINK,
   or with Sepolia ETH if `VRF_NATIVE_PAYMENT=true`.
2. Set the variables:

   | Variable | Value | Bounds |
   | --- | --- | --- |
   | `VRF_COORDINATOR` | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | Must have code; its code hash is pinned |
   | `VRF_SUBSCRIPTION_ID` | The subscription ID | Nonzero |
   | `VRF_KEY_HASH` | A Sepolia gas lane. 6529Stream's Sepolia instance used `0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae`; confirm it on Chainlink's supported-networks page | Nonzero |
   | `VRF_CALLBACK_GAS_LIMIT` | Default 200,000 | 100,000 to 2,500,000 |
   | `VRF_CONFIRMATIONS` | Default 3 | 3 to 200 |
   | `VRF_NATIVE_PAYMENT` | Default `false` (LINK) | |
   | `VRF_RETRY_DELAY` | Default 3 days | 3 to 30 days |

3. After the broadcast, add the module (`EntropyModule` in the record) as the subscription's
   only consumer. Requests fail until it is a consumer and the subscription is funded.
4. Never use Chainlink's subscription `migrate`. The [entropy README](../src/entropy/README.md)
   describes the coordinator-change procedure.

### 7. Default currencies

Genesis sets them. The wiring makes ETH (`address(0)`) the revision-0 default for
`PRODUCT_STREAM`, `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`. A `CURRENCY_DEFAULT` item can
therefore start in the genesis block:

- `EnglishAuction.start` reads the `PRODUCT_STREAM` default.
- The fixed-price and Dutch sales resolve the default through
  `EconomicsResolver.resolveCurrency`.

Verify reads every default back.

A later change is a FUNDS_SETTER action from the hot admin Safe, with a 14-day delay:
1. Allowlist the asset (it must be active).
2. Schedule `setDefaultCurrency(product, expectedRevision, asset)`. `expectedRevision` is the
   current revision, which is 1 after genesis.

### 8. The epoch-0 governance manifest

Publish the epoch-0 governance manifest before genesis, then set:
- `MANIFEST_SHA256` to its SHA-256;
- `MANIFEST_URI` to where it lives, for example `ar://...`.

Genesis appends it to the statement log as the manager's first governance statement.

### 9. Simulate, then broadcast

```bash
export SEPOLIA_RPC_URL=...                          # the operator's own endpoint
export GENESIS_CONFIG=config/genesis.sepolia.json
export NETWORK_FEE_RECIPIENT=0x... MARKETPLACE_OWNER=0x...
export CC0_TEXT_PATH=config/<file> CC0_TEXT_SHA256=0x...
export MANIFEST_SHA256=0x... MANIFEST_URI=ar://...
export DELEGATION_CONTRACT=0x...                    # step 4: the mock on Sepolia
# export VRF_COORDINATOR=... VRF_SUBSCRIPTION_ID=... VRF_KEY_HASH=...   # step 6, optional

# Simulation: nothing leaves the machine. It prints the addresses and the gas estimate.
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer>

# Owner only: broadcast, signing with the keystore or the Ledger.
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer> \
  --broadcast --slow --account <deployer>            # or --ledger
```

- **The sender is the deployer.** `--sender` must be the signing account. It becomes the
  configurator's `deployer`, the only account that can call `configure`.
- **Addresses are predictable.** They depend on the deployer and `DEPLOY_NAMESPACE`. To repeat
  a rehearsal from the same deployer, use a new `DEPLOY_NAMESPACE`; otherwise the CREATE2
  addresses are already taken.
- **Resuming.** `--slow` waits for each receipt. If a broadcast stops partway, rerun the
  broadcast command with `--resume` added.
- **Gas.** On anvil, today's set is 24 transactions and about 53.1M gas, including the
  delegation mock and the renderer stand-in. The largest transaction is 5.1M, under the 16.8M
  EIP-7825 cap. The renderer and Editions add more, so use the simulation's estimate.
- **The record.** The run writes `deployments/11155111/<timestamp>.json`, which holds addresses
  and hashes only. Commit it with the Sepolia genesis file.

### 10. Verify after 5 days

The system is live from genesis, but the delays genesis sets take effect after the manager's
5-day `minSetback`. During those days, the guardians watch `OperationScheduled` on the manager
and cancel anything unexpected. Then run Verify:

```bash
DEPLOYMENT=deployments/11155111/<timestamp>.json \
  forge script script/Verify.s.sol --rpc-url "$SEPOLIA_RPC_URL"
```

It checks:
- the configurator's own `verify`: roles, delays and selector map;
- that the configurator holds no role;
- that every target's authority is the manager;
- every wired getter and default currency, the epoch-0 manifest, and PLATFORM's immediate
  path into the sale adapters;
- that the `GovernanceConfigured` hashes match the configuration and wiring recomputed from
  the JSON;
- that no other grant-delay or admin-delay change is pending;
- that no account outside the configuration was granted a role;
- every recorded code hash.

### 11. Keeper: `refreshStanding`

`ArtistRegistry.refreshStanding(artistId)` is permissionless and does not count as artist
activity.
- **When.** Call it after consolidation events that involve an artist's wallets. One refresh
  any time after a consolidation records the wallet. A consolidation younger than 30 days is
  recorded as pending.
- **Gas.** The worst case is about 6.8M gas, under the EIP-7825 cap.
- **On Sepolia.** A manual call from any funded key is enough:

  ```bash
  cast send <ArtistRegistry> "refreshStanding(uint256)" <artistId> \
    --rpc-url "$SEPOLIA_RPC_URL" --account <keeper>
  ```

- **A bot.** It watches the delegation contract for use-case-999 registrations involving a
  registered artist's wallets, and refreshes that artist.

## Environment reference

| Variable | Anvil default | Off anvil |
| --- | --- | --- |
| `GENESIS_CONFIG` | `config/genesis.example.json` | Required; not the example; no placeholder holder |
| `DEPLOY_NAMESPACE` | `keccak256("6529-works/v1")` | Optional; changes every address |
| `NETWORK_FEE_RECIPIENT` | Placeholder `0xC001` | Required |
| `MARKETPLACE_OWNER` | Placeholder `0xC002` | Required |
| `DELEGATION_CONTRACT` | Canonical address; a mock is deployed when it has no code | Must have code; canonical on mainnet |
| `CC0_TEXT_PATH` | Placeholder text | Required, under `config/` |
| `CC0_TEXT_SHA256` | Unchecked | Recommended |
| `MANIFEST_SHA256` | Placeholder | Required |
| `MANIFEST_URI` | `ar://placeholder-epoch-0` | Required |
| `ETH_INCREMENT_FLOOR` | 0.001 ether | Optional: ETH's minimum bid increment |
| `PERMIT2` | The canonical address | Optional; the auction runs without Permit2 where there is no code |
| `AUCTION_DURATION` | 24 hours | Optional |
| `AUCTION_EXTENSION_WINDOW` | 15 minutes | Optional |
| `AUCTION_INCREMENT_SHARE` | 5,000 (5% of 100,000) | Optional |
| `VRF_*` | Unset: no entropy module | Step 6 |
| `DEPLOYMENT` | (Verify) | The record to verify |
