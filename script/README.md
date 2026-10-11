# script

Deployment and verification for 6529 Works v1, plus the Sepolia runbook. These scripts
implement the deploy assembly and the configuration readback from the
[§17 reuse plan](../docs/adr/0001-v1-scope.md#17-reuse-plan-from-rc1-and-pr-744) and the
[§13 evidence trail](../docs/adr/0001-v1-scope.md#13-governance) of
[ADR 0001](../docs/adr/0001-v1-scope.md).

Not built yet: a deployed-bytecode verifier that matches the chain against a reproducible
build. Verify recomputes every address from the recorded constructor parameters and compares
code hashes with the record, but it does not rebuild the bytecode.

6529 Works is pre-audit and not deployed. A Sepolia run is a testnet rehearsal, not a launch,
and it is **not runnable yet**. Off anvil, the deploy refuses to proceed until:
- the Renderer (#20) merges (`RendererPending`);
- Editions (#14) merges (`EditionsPending`);
- a maintainer pins the canonical CC0 digest (`Cc0DigestNotPinned`, step 6).

The library already deploys identity (#16), Stream and WorkRecords (#22).

| File | Purpose |
| --- | --- |
| [`DeployV1.sol`](DeployV1.sol) | Library shared by the script and the tests. Deploys every merged v1 contract with CREATE2, uploads the CC0 text, builds the genesis configuration and wiring from the genesis JSON, and installs it. `predict` recomputes every address from the same initcode. |
| [`DeployGuards.sol`](DeployGuards.sol) | The off-anvil checks of the genesis file and the deployment: reachable holders, the committed policy, nothing dropped. |
| [`VerifyV1.sol`](VerifyV1.sol) | Library: static readback of a deployment against its configuration, its predicted addresses and its default license. |
| [`Deploy.s.sol`](Deploy.s.sol) | Checks every input, deploys, configures, and records `deployments/<chainId>/<timestamp>.json`. |
| [`Verify.s.sol`](Verify.s.sol) | Confirms a recorded deployment against the chain: addresses, code, CC0 text, manifest, governance and events. |
| [`ScriptIO.sol`](ScriptIO.sol) | What the scripts read from outside the EVM (environment, files, the RPC's chain ID), one virtual function each, so the tests run the scripts with their own inputs. |
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
- `DeployV1.predict(p, d.cc0TextFileId, address(this))` returns the same addresses as `d`.

Worked examples:
- [`test/deploy/DeployV1.t.sol`](../test/deploy/DeployV1.t.sol): the library;
- [`test/deploy/GenesisFlows.t.sol`](../test/deploy/GenesisFlows.t.sol): a curated 6529 Stream
  work auctioned on the deployed system;
- [`test/deploy/DeployScript.t.sol`](../test/deploy/DeployScript.t.sol): the scripts.

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

- **Placeholders.** Anvil runs on placeholders and stand-ins:
  - the placeholders are the example genesis, the CC0 text, the manifest, the fee recipient and
    the marketplace owner;
  - the stand-ins are the renderer, and a `DelegationManagementMock` deployed first because the
    canonical delegation address has no code.

  The record says `"placeholders": true`, lists the renderer under `standIns`, and marks the
  delegation mock (`"delegationMock": true`).
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
  `cast wallet import`) or `--ledger`, and pass the same account as `--sender`. Never pass
  `--private-key` or put a key in `.env`.
- **Credentials.** RPC URLs that carry an API key, and any Etherscan key, stay in the
  operator's shell. They never go into a committed file.
- **Broadcast caches.** Do not commit forge's `broadcast/` output for Sepolia; `.gitignore`
  only covers anvil's. The deployment record is the committed evidence.
- **Mainnet: use a private RPC.** Every address is predictable from public inputs. Someone who
  sees the configurator's creation in the public mempool can create the same initcode first.
  That gains them nothing, because the configurator still only obeys the operator, but the
  namespace is then spent. The next run stops with `ConfiguratorAddressTaken` and needs a new
  `DEPLOY_NAMESPACE`. A private transaction endpoint avoids the denial of service.

### 1. Accounts

| Account | Roles | Kind |
| --- | --- | --- |
| Deployer (operator) | None after genesis. It is the configurator's `deployer`, and signs every deploy transaction and `configure` | Keystore or Ledger EOA, funded with Sepolia ETH |
| Hot admin Safe | ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER | Safe |
| Cold recovery admin Safe | ADMIN only | Safe, with signers distinct from the hot Safe |
| Guardian Safes 1, 2 and 3 | GUARDIAN, PAUSER (at least three off anvil) | Safe |
| Curation signer keys 1 and 2 | CURATION_SIGNER (at least two off anvil). They sign approvals off-chain and never call a contract | EOA |
| Storage operator | STORAGE_OPERATOR | EOA |
| Platform | PLATFORM | EOA |
| Curator | CURATOR | EOA |
| Network fee recipient | No role (`NETWORK_FEE_RECIPIENT`) | Any address |
| Marketplace owner | No role (`MARKETPLACE_OWNER`). Stream's `owner()`: collection admin on marketplaces, no protocol power; FUNDS_SETTER can change it | Safe or EOA |
| VRF subscription owner | No role; owns the Chainlink subscription | EOA or Safe |
| Keeper | No role (`refreshStanding` is permissionless) | Any funded EOA |

Delays and responsibilities are in the [role table](../src/governance/README.md).

### 2. Safe pre-flight

The configurator renounces ADMIN in the genesis transaction. An admin or guardian that nobody
can operate is therefore permanent. Off anvil, the script refuses an ADMIN or GUARDIAN holder
in these cases:
- it has no code;
- it is an EIP-7702 delegated EOA;
- it does not answer `getThreshold()` with a nonzero value.

The script cannot check who the owners are, so check every Safe before the run:

```bash
for SAFE in <hot> <cold> <guardian1> <guardian2> <guardian3>; do
  cast code "$SAFE" --rpc-url "$SEPOLIA_RPC_URL" | head -c 12; echo   # not 0x
  cast call "$SAFE" "getThreshold()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
  cast call "$SAFE" "getOwners()(address[])" --rpc-url "$SEPOLIA_RPC_URL"
done
```

- Each Safe is on this chain, with the intended owners and threshold.
- The hot and cold admin Safes share no signer.
- Each guardian Safe is separate from the admins.
- At least one owner of each Safe has signed a test transaction on it.

### 3. The genesis configuration

```bash
cp config/genesis.example.json config/genesis.sepolia.json
# Replace every holder (0x...b0xx) with the account from step 1.
# Leave the contract placeholders (0x...a0xx): the library substitutes deployed addresses by name.
python tools/check_genesis.py --config config/genesis.sepolia.json
```

- **The policy is pinned.** A deployment's genesis file may differ from the committed
  `config/genesis.example.json` only in its holders, its description and its address fields.
  Both tools enforce this:
  - `tools/check_genesis.py --config` compares the file with the committed one;
  - off anvil, `Deploy.s.sol` (`DeployGuards.checkPolicy`) checks that the file's governed
    targets and wiring equal what the committed file produces for the same deployment.

  Changing a selector's role, a delay or a wiring call is a change to the committed policy,
  made by PR.
- **Holders off anvil.** `Deploy.s.sol` requires `GENESIS_CONFIG` and refuses the following:
  - the example file, under any path or as a copy;
  - any holder at or below `0xFFFF` (the placeholder range and the precompiles);
  - a system contract, the CREATE2 deployer, Permit2 or the delegation contract;
  - a contract of the deployment itself;
  - fewer than three guardians or two curation signers.

Commit the Sepolia genesis file with the deployment record.

### 4. External contracts

Checked read-only on Sepolia on 11 October 2026. Check again before broadcasting.
`cast code` prints `0x` when an address has no code.

| Contract | Address | Sepolia | Used for |
| --- | --- | --- | --- |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | present | Every deploy (Foundry's default factory) |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | present | The sale adapters' Permit2 payments; required off anvil, canonical on mainnet |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | present | The entropy module (step 7) |
| 6529 delegation contract | `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` | **absent** | The artist registry's consolidation source (step 5) |

```bash
cast code 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d --rpc-url "$SEPOLIA_RPC_URL"
```

### 5. The delegation contract

`ConsolidationAdapter` reads consolidations from the 6529 delegation contract, and its
constructor requires code at that address. The `ArtistRegistry` pins the adapter's code hash.

The canonical contract is absent on Sepolia, so the rehearsal uses `DelegationManagementMock`
(`test/mocks/identity/DelegationManagementMock.sol`). The mock is a faithful reduction of the
6529 contract: the same storage, getters, and register and revoke semantics, and
permissionless like the original.

1. If `cast code` above prints code, use the canonical address and skip step 2.
2. Deploy the mock. The owner runs this command:

   ```bash
   forge create test/mocks/identity/DelegationManagementMock.sol:DelegationManagementMock \
     --rpc-url "$SEPOLIA_RPC_URL" --account <deployer> --broadcast
   ```

3. Pass the address as `DELEGATION_CONTRACT`. Off anvil, the script refuses an address
   without code. On mainnet it refuses anything but the canonical contract. The record marks
   the mock (`"delegationMock": true`).

To consolidate two wallets on the mock, each one calls
`registerDelegationAddress(0x8888888888888888888888888888888888888888, <other wallet>, <expiry>, 999, true, 0)`:
use case 999, all collections, in both directions. Then run the keeper (step 12).

### 6. The CC0 license text

The default license for new works is CC0 1.0, and WorkRecords requires its text in the content
store. The file must be registered when WorkRecords is constructed, and complete before any
work finalizes. Genesis therefore stores it first, right after the content store. It passes
the file ID to the `EconomicsResolver` and to WorkRecords.

The text is the plain-text legal code that Creative Commons publishes at
<https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt>
(`DeployV1.CC0_LEGALCODE_URL`). Its SHA-256 is pinned in `DeployV1.CC0_LEGALCODE_SHA256`, and
off anvil both scripts refuse any other text.

**The digest is not pinned yet.** It could not be verified from the build environment, so the
constant is zero and every off-anvil run stops with `Cc0DigestNotPinned`. To pin it, a
maintainer does the following, by PR:
1. Fetches the file.
2. Checks it against an independent copy.
3. Sets the constant to `0x` followed by the output of `sha256sum legalcode.txt`.
4. Updates `test_TheCommittedCc0DigestIsNotPinnedYet`.

For a run:
1. Save the file under `config/` (the script can read only `./config`; the file is not
   committed) and set `CC0_TEXT_PATH=config/<file>`.
2. After the broadcast, Verify checks the stored copy:
   - WorkRecords and every product's default license name the recorded file;
   - the file is complete;
   - it hashes to the pinned digest.

   The uploader can check it too:

   ```bash
   python -m tools.content verify --rpc "$SEPOLIA_RPC_URL" --store <ContentStore> <cc0TextFileId>
   ```

### 7. Chainlink VRF (the entropy module)

6529 Stream pins its entropy module at construction, so leaving it out is permanent for that
deployment. Off anvil, the script therefore requires `VRF_COORDINATOR`, unless `NO_VRF=1`
declines the module explicitly. The record says which (`"entropy": "vrf"` or `"none"`).

1. In the Chainlink VRF app on Sepolia, create a **dedicated** subscription. Fund it with LINK,
   or with Sepolia ETH if `VRF_NATIVE_PAYMENT=1`.
2. Set the variables:

   | Variable | Value | Bounds |
   | --- | --- | --- |
   | `VRF_COORDINATOR` | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | Must have code; its code hash is pinned |
   | `VRF_SUBSCRIPTION_ID` | The subscription ID | Nonzero |
   | `VRF_KEY_HASH` | A Sepolia gas lane. 6529Stream's Sepolia instance used `0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae`; confirm it on Chainlink's supported-networks page | Nonzero |
   | `VRF_CALLBACK_GAS_LIMIT` | Default 200,000 | 100,000 to 2,500,000 |
   | `VRF_CONFIRMATIONS` | Default 3 | 3 to 200 |
   | `VRF_NATIVE_PAYMENT` | Default `0` (LINK); `1` for native | |
   | `VRF_RETRY_DELAY` | Default 3 days, in seconds | 3 to 30 days |

3. After the broadcast, add the module (`EntropyModule` in the record) as the subscription's
   only consumer. Requests fail until it is a consumer and the subscription is funded.
4. Never use Chainlink's subscription `migrate`. The [entropy README](../src/entropy/README.md)
   describes the coordinator-change procedure.

### 8. Default currencies

Genesis sets them. The wiring makes ETH (`address(0)`) the revision-0 default for
`PRODUCT_STREAM`, `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`. A `CURRENCY_DEFAULT` item can
therefore start in the genesis block:

- `EnglishAuction.start` reads the `PRODUCT_STREAM` default.
- The fixed-price and Dutch sales resolve the default through
  `EconomicsResolver.resolveCurrency`.

Verify reads every default back at the revision genesis produced.

A later change is a FUNDS_SETTER action from the hot admin Safe, with a 14-day delay:
1. Allowlist the asset (it must be active).
2. Schedule `setDefaultCurrency(product, expectedRevision, asset)`. `expectedRevision` is the
   current revision, which is 1 after genesis.

### 9. The epoch-0 governance manifest

Write the epoch-0 governance manifest, save it under `config/`, and publish it before genesis.
Then set:
- `MANIFEST_PATH` to the file: the script hashes it, and Verify hashes it again;
- `MANIFEST_URI` to where it is published, for example `ar://...`.

Genesis appends it to the statement log as the manager's first governance statement.

### 10. Simulate, then broadcast

```bash
export SEPOLIA_RPC_URL=...                          # the operator's own endpoint
export GENESIS_CONFIG=config/genesis.sepolia.json
export NETWORK_FEE_RECIPIENT=0x... MARKETPLACE_OWNER=0x...
export DELEGATION_CONTRACT=0x...                    # step 5: the mock on Sepolia
export CC0_TEXT_PATH=config/<legalcode file>        # step 6
export VRF_COORDINATOR=... VRF_SUBSCRIPTION_ID=... VRF_KEY_HASH=...   # step 7 (or NO_VRF=1)
export MANIFEST_PATH=config/<manifest file> MANIFEST_URI=ar://...     # step 9

# Simulation: nothing leaves the machine. It runs every check and prints the addresses and
# the gas estimate.
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer>

# Owner only: broadcast, signing with the keystore or the Ledger.
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer> \
  --broadcast --slow --account <deployer>            # or --ledger
```

- **Everything is checked before anything is sent.** Forge simulates the whole run first, so
  any failed check aborts it with nothing broadcast. The checks:
  - the RPC's `eth_chainId` is the chain the script runs on;
  - `--sender` was given and is the signer;
  - every input above (steps 2 to 9);
  - the configurator's CREATE2 address is free;
  - after the contracts are simulated and before `configure`: nothing the genesis names is
    missing, the policy is the committed one, and no holder is a contract of the deployment.
- **The sender is the deployer.** It becomes the configurator's `deployer`, the only account
  that can call `configure`.
- **Addresses are predictable.** They depend on the deployer and `DEPLOY_NAMESPACE`. To repeat
  a rehearsal from the same deployer, use a new `DEPLOY_NAMESPACE`.
- **Resuming.** `--slow` waits for each receipt. If a broadcast stops partway, rerun the
  broadcast command with `--resume` added.
- **Gas.** On anvil, today's set is 24 transactions and about 53M gas, including the
  delegation mock and the renderer stand-in. The largest transaction is about 5.1M, under the
  16.8M EIP-7825 cap. The renderer and Editions add more, so use the simulation's estimate.
- **The record.** The run writes `deployments/11155111/<timestamp>.json`. It holds:
  - every address and code hash;
  - every constructor parameter (`params`), including the CREATE2 deployer;
  - the CC0 file ID and digest;
  - the manifest digest, URI and path;
  - the entropy choice.

  The record is written from the simulation, before the transactions are confirmed, and
  says so (`"confirmed": false`). Verify confirms it against the chain. Commit it with the
  Sepolia genesis file.

### 11. Verify after 5 days

The system is live from genesis, but the delays genesis sets take effect after the manager's
5-day `minSetback`. During those days, the guardians watch `OperationScheduled` on the manager
and cancel anything unexpected. Then run Verify:

```bash
DEPLOYMENT=deployments/11155111/<timestamp>.json MANIFEST_PATH=config/<manifest file> \
  forge script script/Verify.s.sol --rpc-url "$SEPOLIA_RPC_URL"
```

The record is only an index; each check is made against the chain or the committed inputs:
- the RPC is on the recorded chain, and off anvil the record has no placeholder or stand-in;
- every recorded address is where CREATE2 puts that contract, given the recorded parameters
  and CREATE2 deployer. Each pinned code hash is read from the chain, so a substituted
  dependency moves every later address. Every recorded code hash is on chain;
- the CC0 text: WorkRecords and every product's default name the recorded file, which is
  complete and hashes to the pinned canonical digest;
- the manifest file hashes to the recorded digest;
- off anvil, the genesis file still matches the committed policy and names nothing the
  deployment lacks;
- the configurator's own `verify` (roles, delays and selector map), no role left with the
  configurator, and every target's authority;
- every wired getter and default currency, the epoch-0 manifest, and PLATFORM's immediate
  path into the sale adapters;
- the `GovernanceConfigured` hashes match the configuration and wiring recomputed from the
  JSON;
- no other grant-delay or admin-delay change is pending;
- no account outside the configuration was granted a role.

### 12. Keeper: `refreshStanding`

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

Unset and empty are the same. Numbers are checked against their type (`SafeCast`).

| Variable | Anvil default | Off anvil |
| --- | --- | --- |
| `GENESIS_CONFIG` | `config/genesis.example.json` | Required; the committed policy with reachable holders (step 3) |
| `DEPLOY_NAMESPACE` | `keccak256("6529-works/v1")` | Optional; changes every address |
| `NETWORK_FEE_RECIPIENT` | Placeholder `0xC001` | Required |
| `MARKETPLACE_OWNER` | Placeholder `0xC002` | Required |
| `DELEGATION_CONTRACT` | Canonical address; a mock is deployed when it has no code | Must have code; canonical on mainnet |
| `CC0_TEXT_PATH` | Placeholder text | Required, under `config/`; must hash to the pinned digest |
| `MANIFEST_PATH` | Placeholder digest | Required, under `config/` |
| `MANIFEST_URI` | `ar://placeholder-epoch-0` | Required |
| `ETH_INCREMENT_FLOOR` | 0.001 ether, in wei | Optional: ETH's minimum bid increment |
| `PERMIT2` | The canonical address | Must have code; canonical on mainnet. On anvil, without code, the auction runs without Permit2 |
| `AUCTION_DURATION` | 24 hours, in seconds | Optional |
| `AUCTION_EXTENSION_WINDOW` | 15 minutes, in seconds | Optional |
| `AUCTION_INCREMENT_SHARE` | 5,000 (5% of 100,000) | Optional |
| `VRF_COORDINATOR`, `VRF_SUBSCRIPTION_ID`, `VRF_KEY_HASH` | Unset: no entropy module | Required unless `NO_VRF=1` (step 7) |
| `VRF_CALLBACK_GAS_LIMIT`, `VRF_CONFIRMATIONS`, `VRF_NATIVE_PAYMENT`, `VRF_RETRY_DELAY` | Defaults in step 7 | Optional |
| `NO_VRF` | `0` | `1` declines the entropy module explicitly |
| `DEPLOYMENT` | (Verify) | The record to verify |
| `MANIFEST_PATH` | (Verify) the recorded path | The manifest file to hash again |
