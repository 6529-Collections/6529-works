# script

Deployment and verification for 6529 Works v1, plus the Sepolia runbook. These scripts
implement the deploy assembly and the configuration readback from the
[§17 reuse plan](../docs/adr/0001-v1-scope.md#17-reuse-plan-from-rc1-and-pr-744) and the
[§13 evidence trail](../docs/adr/0001-v1-scope.md#13-governance) of
[ADR 0001](../docs/adr/0001-v1-scope.md).

Not built yet: a deployed-bytecode verifier that matches the chain against a reproducible
build. Verify recomputes every address from the recorded constructor parameters and compares
code hashes with the record, but it does not rebuild the bytecode.

6529 Works is pre-audit and not deployed on mainnet. A Sepolia run is a testnet rehearsal, not a
launch; the rehearsals so far are recorded in [`deployments/11155111/`](../deployments/11155111/README.md).
The library deploys every v1 contract: identity, curation, economics, content and the
renderer, the statement log, the optional entropy module, 6529 Stream and WorkRecords, 6529
Stream Editions, the English auction, and the edition auction of ADR 0005
(`UniformEditionAuction`, whose stateless lens is deployed first in its own transaction and
pinned by the auction's constructor; genesis admits it on Editions and lists Editions as its
target, and Verify checks the lens against the record). No stand-in
remains. A Sepolia run needs the owner's accounts and keys (steps 1 and 2), and the inputs
below.

| File | Purpose |
| --- | --- |
| [`DeployV1.sol`](DeployV1.sol) | Library shared by the script and the tests. Deploys every merged v1 contract with CREATE2, uploads the CC0 text, builds the genesis configuration and wiring from the genesis JSON, and installs it. `predict` recomputes every address from the same initcode. |
| [`DeployGuards.sol`](DeployGuards.sol) | The off-anvil checks of the genesis file and the deployment: the network a bare canonical Safe, reachable holders, the committed policy, nothing dropped. |
| [`VerifyV1.sol`](VerifyV1.sol) | Library: static readback of a deployment against its configuration, its predicted addresses and its default license. |
| [`Deploy.s.sol`](Deploy.s.sol) | Checks every input, deploys, configures, and records `deployments/<chainId>/<timestamp>.json`. |
| [`Verify.s.sol`](Verify.s.sol) | Confirms a recorded deployment against the chain: addresses, code, CC0 text, manifest, governance and events. |
| [`ScriptIO.sol`](ScriptIO.sol) | What the scripts read from outside the EVM (environment, files, the RPC's chain ID), one virtual function each, so the tests run the scripts with their own inputs. |

## Using the library from tests

```solidity
DeployV1.Deployment memory d = DeployV1.deploy(p);          // p.deployer = address(this)
GovernanceConfig.Config memory cfg = DeployV1.config(d, json);
GovernanceConfig.Call[] memory calls = DeployV1.wiring(d, json, manifest);
DeployV1.install(d, cfg, manifest, calls);                  // configure: proposes cfg.network
vm.prank(cfg.network);
d.manager.acceptNetwork();                                  // the network accepts: the system is live
vm.warp(block.timestamp + d.manager.minSetback());          // as Verify asks
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
  work priced in `CURRENCY_DEFAULT` auctioned from the genesis block, on the deployed system;
- [`test/deploy/DeployScript.t.sol`](../test/deploy/DeployScript.t.sol): the scripts.

## Local dry run (anvil)

To deploy, accept, verify and sell one work end to end with one command, run
`bash script/local/walkthrough.sh` ([`local/`](local/README.md)). The steps below do the
deployment by hand, with the committed example genesis.

```bash
anvil --port 8545
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# The example genesis names the placeholder network 0x...b001: impersonate it to accept.
# <WorksAccessManager> is the `manager` address the deploy prints; <timestamp> is in the
# `recorded deployments/31337/<timestamp>.json` line.
cast rpc anvil_impersonateAccount 0x000000000000000000000000000000000000b001 --rpc-url http://127.0.0.1:8545
cast rpc anvil_setBalance 0x000000000000000000000000000000000000b001 0xDE0B6B3A7640000 --rpc-url http://127.0.0.1:8545   # 1 ETH for gas
cast send --unlocked --from 0x000000000000000000000000000000000000b001 <WorksAccessManager> \
  "acceptNetwork()" --rpc-url http://127.0.0.1:8545
cast rpc evm_increaseTime 432000 --rpc-url http://127.0.0.1:8545   # minSetback: 5 days
cast rpc evm_mine --rpc-url http://127.0.0.1:8545
DEPLOYMENT=deployments/31337/<timestamp>.json \
  forge script script/Verify.s.sol --rpc-url http://127.0.0.1:8545
```

- **Placeholders.** Anvil runs on placeholders: the example genesis, the manifest, the fee
  recipient and the marketplace owner. The CC0 text is the real one, the committed fixture.
  A `DelegationManagementMock` is deployed first, because the canonical delegation address has
  no code. The record says `"placeholders": true` and marks the mock (`"delegationMock": true`).
  Its `standIns` list is empty.
- **The network accepts.** `configure` only proposes the genesis file's `network`; nothing is
  governed until that address calls `acceptNetwork()`. With `ACCEPT_NETWORK=1`, `Deploy.s.sol`
  broadcasts the acceptance from the network address itself, for a network account the operator
  holds; on anvil, impersonate the placeholder as above.
- **Use `--slow`.** Without it, anvil can pack a block until the next deploy transaction no
  longer fits. That transaction then waits for a block that automine never produces;
  `cast rpc evm_mine` frees it.
- **No key is handled.** The anvil node unlocks its own dev account.
- **The example's holders cannot sign.** The example genesis's holders are placeholders
  without keys, so no curation signer can sign. To run flows locally, deploy with a genesis
  file that names keys you hold, as the [walkthrough](local/README.md) does with anvil's test
  accounts (`GENESIS_CONFIG`, any file under `config/`, and `ACCEPT_NETWORK=1` when the network
  is one of them).
- **The record is local.** `deployments/31337/` is git-ignored; delete old records when you no
  longer need them.
- **Restart, don't reset.** Restart anvil rather than calling `anvil_reset`, which removes the
  CREATE2 deployer.
- **Verify after the acceptance and 5 days.** `Verify.s.sol` runs after the network accepted
  (else `NetworkNotAccepted`) and at least the manager's `minSetback` (5 days) after genesis.

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
- **Mainnet: use a private RPC and a private namespace.** Every address is predictable from
  public inputs. Someone who sees the configurator's creation in the public mempool can create
  the same initcode first. ContentStore takes no constructor arguments and ClaimRouter takes the
  split ledger, so their addresses depend on `DEPLOY_NAMESPACE` alone, and anyone who knows the
  namespace can create them in advance. That gains nothing, because the code is identical and
  the configurator still only obeys the operator, but the namespace is then spent: the next
  run stops with `ConfiguratorAddressTaken` or `AddressTaken` and needs a new
  `DEPLOY_NAMESPACE`. Off anvil the namespace has no default. Choose a fresh one, keep it
  private until the broadcast, and send through a private transaction endpoint.
- **Sepolia mirrors mainnet.** Use throwaway signers, but the mainnet structure and thresholds:
  - the network as a Safe with the mainnet threshold, and the same operational roles as below;
  - the entropy module with a real VRF subscription (step 7), not `NO_VRF`;
  - the official 6529 delegation contract (step 5).

  A rehearsal then exercises the same flows, a network handover included.

### 1. Accounts

| Account | Roles | Kind |
| --- | --- | --- |
| Deployer (operator) | None after genesis. It is the configurator's `deployer`, and signs every deploy transaction and `configure` | Keystore or Ledger EOA, funded with Sepolia ETH. Not an EIP-7702 delegated account: the script refuses one (`DelegatedDeployer`). On mainnet it may not be the network, a role holder, the museum, the marketplace owner or the network fee recipient (`HolderIsTheDeployer`, `RecipientIsTheDeployer`; Verify repeats both) |
| Network | Every network role: ADMIN, NETWORK, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER (the genesis file's `network`). It holds them once it calls `acceptNetwork()` | One Safe: a canonical Safe singleton, a threshold of at least 2, plain-key owners, no module and no guard ([step 2](#2-safe-pre-flight)) |
| Brake | None at launch. The network may name one later (`setBrake`, 7 days). The brake can delay one scheduled network action by 7 days, once | Any account, when named |
| Pauser keys 1 to 3 | PAUSER: the emergency pause and a 1/1's dispute pause | EOA |
| Curation signer keys 1 and 2 | CURATION_SIGNER (at least two off anvil). They sign approvals off-chain and never call a contract | EOA |
| Storage operator | STORAGE_OPERATOR | EOA |
| Platform | PLATFORM | EOA |
| Curator | CURATOR | EOA |
| Network fee recipient | No role (`NETWORK_FEE_RECIPIENT`); the fee vault's destination | An existing account: a Safe, or an EOA with a balance or a sent transaction ([below](#the-network-fee-recipient-must-exist)) |
| 6529 Network Museum | No role (`MUSEUM`). Receives every 6529 Stream work whose 1/1 sale ends unsold (D140), moved there by Stream (owner decision 17); FUNDS_SETTER can change it (`setMuseum`, 3 days) | An existing Safe or EOA that can hold ERC-721 tokens ([below](#the-museum-must-exist)) |
| Marketplace owner | No role (`MARKETPLACE_OWNER`). Stream's `owner()`: collection admin on marketplaces, no protocol power; FUNDS_SETTER can change it (`setOwner`, 3 days) | Safe or EOA, separate from the platform key, so a stolen platform key does not also hold the marketplace listing |
| VRF subscription owner | No role; owns the Chainlink subscription. It can cancel the subscription or remove the module at once, outside governance, so on mainnet it must be the network Safe (the deploy checks it before the broadcast, and Verify again) | Mainnet: the network Safe. Sepolia: EOA or Safe |
| Keeper | No role. Starts sales through `SaleStarter` and runs the edition steps ([keepers](#the-11-start-keeper)) | Any funded EOA |

Delays and responsibilities are in the [role table](../docs/spec/governance.md#roles).

**Pauses and the network.**
- **Pausing is immediate** (PAUSER); `unpause`, and a dispute's `resume` and `cancel`, are the
  network's at once (NETWORK, no delay). The adapters add no wait of their own.
- **The edition auction's pause stops new opens only.** Running edition sales keep taking
  bids, settle and pay out; a sale nobody opened before its close never sells copies, so lift a
  pause before the 1/1s that started under it close.
- **Deprecating an auction's currency** (`deprecateAsset`, the network, at once) freezes the
  live auctions in that currency: nothing settles, and their high bidders may withdraw. To keep
  them alive, re-admit the currency between day 3 and day 14 after the deprecation
  (`admitAsset` is in the 3-day class and executes no earlier than 3 days from the
  deprecation); the first `settle` after the re-admission reopens each auction for at least the
  governed duration. After day 14, anyone can end a frozen auction unsold: its standing bid is
  credited back to the bidder and a 6529 Stream work goes to the museum (any other token's to
  its artist).

#### The network fee recipient must exist

Sales pay the network fee by sending it to the fee recipient. If that address is empty (no
code, a zero balance and a zero nonce), the first payout creates the account. Under
Glamsterdam that costs whoever settles or buys about 184K more gas
([ADR 0004](../docs/adr/0004-gas-budgets-under-glamsterdam.md)).
- Off anvil the script refuses an empty `NETWORK_FEE_RECIPIENT` (`AccountDoesNotExist`).
  Name a Safe, or fund the address first.
- A later `EconomicsResolver.setFeeTerms` must also name an existing account, for the same
  reason. Nothing on-chain checks it.
- It must also accept ETH from a 100,000-gas call: works lock their fee recipient at mint.
  `setFeeTerms` refuses the protocol contracts it recognises (`InvalidFeeRecipient`), but not
  the content store, the statement log, the AccessManager, the renderer, the curation verifier
  or the entropy module. Check the address against the deployment record before scheduling.

#### The museum must exist

6529 Stream moves every work whose 1/1 sale ends unsold, unbid or by the 14-day currency
freeze, to the museum its current economics resolver names when the adapter settles the sale,
with no receiver callback (owner decision 17;
[AUC-24, AUC-33](../docs/spec/stream-and-auctions.md#rules-and-invariants)).
- Off anvil the script requires `MUSEUM` and refuses an empty one (`AccountDoesNotExist`), as
  for the fee recipient: an existing account is less likely to be a typo. On Sepolia a fresh
  test Safe or EOA is fine once it has a balance or has sent a transaction.
- Name a Safe or an EOA that can move ERC-721 tokens on. The move makes no
  `onERC721Received` call, so the museum needs no ERC-721 fallback handler, and nothing is ever
  pending for it.
- `setMuseum(expectedRevision, next)` refuses zero and the protocol contracts the fee-recipient
  rule refuses (`InvalidMuseum`), nothing more. Before scheduling it, check that `next` exists and is
  not a contract of the deployment, and remember that it redirects auctions already running.

### 2. Safe pre-flight

The configurator renounces its ADMIN record in the genesis transaction, and the network address
then holds every network role. A network that nobody can operate can never hand over, so off
anvil the script refuses the genesis file's `network` in these cases:
- it has no code;
- it is an EIP-7702 delegated EOA;
- it does not answer `getThreshold()` with a nonzero value, or `getOwners()` with a list;
- its threshold is below 2 (`ThresholdTooLow`);
- one of its owners has code: an EIP-7702 delegated EOA (`DelegatedOwner`), or a nested
  Safe, a passkey signer contract or any other contract (`NestedOwner`). Owners must be
  plain keys, so the script can compare them; passkey signer contracts are refused by
  design. Verify repeats this check, so a signer that later adds an EIP-7702 delegation
  makes Verify fail until the delegation is cleared;
- its proxy (storage slot 0) does not point to a canonical Safe singleton with that
  singleton's code hash (`NotACanonicalSafe`). The allowed singletons, from
  safe-global/safe-deployments, with code hashes read on mainnet and Sepolia:

  | Singleton | Address | Runtime code hash |
  | --- | --- | --- |
  | Safe 1.3.0 L1 | `0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552`, and the EIP-155 deployment `0x69f4D1788e39c87893C980c06EdF4b7f686e2938` | `0xbba688fb…6304b1c2e` |
  | Safe 1.3.0 L2 | `0x3E5c63644E683549055b9Be8653de26E0B4CD36E`, and the EIP-155 deployment `0xfb1bffC9d739B8D520DaF37dF666da4C687191EA` | `0x21842597…731023c0f` |
  | Safe 1.4.1 L1 | `0x41675C099F32341bf84BFc5382aF534df5C7461a` | `0x1fe2df85…6d0c5e1c4` |
  | Safe 1.4.1 L2 | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | `0xb1f92697…894f81ff` |

  The full hashes are in `script/DeployGuards.sol`;
- it has an enabled module (`getModulesPaginated(0x1, 1)` is not empty, `SafeHasModules`)
  or a transaction guard (`SafeHasGuard`): either can act for the Safe or block it without
  the owners' signatures. Disable both before the run, and keep them disabled: Verify
  repeats every check.

Off anvil the recorded genesis file names no brake (`BrakeAtLaunch`, checked by
`DeployGuards.checkNoBrake` in `Deploy.prepare` and again in Verify; a later epoch file may name
one). Every holder must be reachable (not a placeholder or a system address), and no holder may
name a network role (`NetworkRoleHolder`): those are the network's alone.

The script cannot check that the owners are the right people, so check the network Safe before
the run:

```bash
SAFE=<network>
cast code "$SAFE" --rpc-url "$SEPOLIA_RPC_URL" | head -c 12; echo   # not 0x
cast call "$SAFE" "getThreshold()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$SAFE" "getOwners()(address[])" --rpc-url "$SEPOLIA_RPC_URL"
```

- The Safe is on this chain, with the intended owners and threshold.
- At least one owner has signed a test transaction on it.

### 3. The genesis configuration

```bash
cp config/genesis.example.json config/genesis.sepolia.json
# Replace the network (0x...b001) and every holder (0x...b0xx) with the accounts from step 1.
# Leave the contract placeholders (0x...a0xx): the library substitutes deployed addresses by name.
python tools/check_genesis.py --config config/genesis.sepolia.json
```

For a new Sepolia rehearsal instance with an earlier instance's accounts,
`python script/sepolia/make_genesis.py <new> <previous>` (for example `r5 r4`) writes
`config/sepolia-<new>/genesis.json` from the committed policy. With new accounts, pass a public
accounts file instead (`make_genesis.py r5 config/sepolia-r5/accounts.json`: the network, the
holders by role, and the new Safe's owners for the manifest), as r5 did. For an instance from before the
single network address (r1 to r4), it names that instance's first ADMIN holder, the hot admin
Safe, as the network; run `check_genesis.py --config` on the result.

- **The policy is pinned.** A deployment's genesis file may differ from the committed
  `config/genesis.example.json` only in its network, its brake, its holders, its description and
  its address fields.
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
  - a holder that names a network role, or fewer than two curation signers;
  - on mainnet only (owner decision 18, `DeployGuards.checkRoleGroups`), the deployer EOA as the
    network or as any holder, the network address as a holder, or an account holding roles of
    two groups. The groups are the network (every network role), the pausers (PAUSER) and the
    curation signers (CURATION_SIGNER).

    Verify repeats this check ([mainnet governance](#mainnet-governance-owner-decision-18)).

Commit the Sepolia genesis file with the deployment record.

### 4. External contracts

Checked read-only on Sepolia on 11 October 2026. Check again before broadcasting.
`cast code` prints `0x` when an address has no code.

| Contract | Address | Sepolia | Used for |
| --- | --- | --- | --- |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | present | Every deploy (Foundry's default factory) |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | present | The sale adapters' Permit2 payments; required off anvil, canonical on mainnet |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | present | The entropy module (step 7) |
| 6529 delegation contract, mainnet address | `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` | absent | The artist registry's consolidation source on mainnet |
| 6529 delegation contract, official Sepolia deployment | `0x8f86c644f845A077999939C69Bc787662377d915` | present, same runtime code as mainnet | The consolidation source on Sepolia (step 5) |

```bash
cast codehash 0x8f86c644f845A077999939C69Bc787662377d915 --rpc-url "$SEPOLIA_RPC_URL"
# 0x28e32b740f699e25d2a1afac207a84e31197c0d4b87c1432c9c5c52c4c1e74e0, mainnet's
```

### 5. The delegation contract

`ConsolidationAdapter` reads consolidations from the 6529 delegation contract, and its
constructor requires code at that address. The `ArtistRegistry` pins the adapter's code hash.

The contract is `DelegationManagementContract` (`smart_contracts/DelegationManagement.sol` in
the public repository [6529-Collections/nftdelegation](https://github.com/6529-Collections/nftdelegation)).
Its runtime code hash is pinned in `DeployGuards.CANONICAL_DELEGATION_CODEHASH`:
`0x28e32b740f699e25d2a1afac207a84e31197c0d4b87c1432c9c5c52c4c1e74e0`, 20,766 bytes.

- **Mainnet:** the script accepts only `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`.
- **Sepolia:** use the official deployment `0x8f86c644f845A077999939C69Bc787662377d915`. It is
  listed in that repository's README, and its runtime code is byte-identical to mainnet's. It
  is the script's default on Sepolia, so `DELEGATION_CONTRACT` can stay unset.
- **Another chain with neither:** prefer deploying the same verified source rather than a
  mock. The owner does this, in a scratch directory outside the repository:

  ```bash
  forge clone 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d delegation-src \
    --etherscan-api-key "$ETHERSCAN_API_KEY"     # the verified mainnet source and settings
  cd delegation-src
  forge create <src>:DelegationManagementContract --rpc-url "$RPC_URL" \
    --account <deployer> --broadcast
  cast codehash <new address> --rpc-url "$RPC_URL"  # must equal the pinned hash
  ```

  If the hash does not match (a different compiler build), fall back to the mock
  (`test/mocks/identity/DelegationManagementMock.sol`). It is a faithful reduction of the same
  contract: the same storage, getters, and register and revoke semantics, permissionless like
  the original.

Pass any address other than the default as `DELEGATION_CONTRACT`. Off anvil the script refuses
an address without code. The record carries the contract's code hash (`delegationCodeHash`),
and marks it `"delegationMock": true` when that hash is not the canonical one. The official
Sepolia deployment is therefore not marked.

To consolidate two wallets, each one calls
`registerDelegationAddress(0x8888888888888888888888888888888888888888, <other wallet>, <expiry>, 999, true, 0)`:
use case 999, all collections, in both directions. The artist registry reads it live: a wallet
with a direct two-way consolidation with the account's root acts for the account at once, with no
minimum age ([identity](../docs/spec/identity-and-recovery.md)).

### 6. The CC0 license text

The default license for new works is CC0 1.0, and WorkRecords requires its text in the content
store. The file must be registered when WorkRecords is constructed, and complete before any
work finalizes. Genesis therefore stores it first, right after the content store. It passes
the file ID to the `EconomicsResolver` and to WorkRecords.

The text is the plain-text CC0 1.0 Universal legal code that Creative Commons publishes. It
is pinned in `DeployV1`:

| | |
| --- | --- |
| Source | <https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt> (`CC0_LEGALCODE_URL`) |
| Same file, Creative Commons' data repository | <https://raw.githubusercontent.com/creativecommons/cc-legal-tools-data/main/docs/publicdomain/zero/1.0/legalcode.txt> (`CC0_LEGALCODE_MIRROR`) |
| Size | 7,048 bytes, `text/plain` (`CC0_LEGALCODE_LENGTH`) |
| SHA-256 | `0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499` (`CC0_LEGALCODE_SHA256`) |

Both sources served the same bytes with this digest when it was pinned on 11 October 2026.
Off anvil both scripts refuse any other text.

For a run:
1. Nothing to fetch. The file is committed, byte for byte, at
   `test/fixtures/cc0-legalcode.txt`, which is the default `CC0_TEXT_PATH` on every chain.
   `test_TheCc0FixtureIsTheCanonicalLegalCode` checks its length and digest. To use another
   copy, put it under `config/` and set `CC0_TEXT_PATH`; it must have the same digest.
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

On Sepolia, set the module up as on mainnet; do not use `NO_VRF`.

1. In the Chainlink VRF app on Sepolia, create a **dedicated** subscription. Fund it with LINK,
   or with Sepolia ETH if `VRF_NATIVE_PAYMENT=1`. No app is needed: the coordinator's
   `createSubscription()` and `fundSubscriptionWithNative(subId)` can be called directly (r5).
   Fund it for the gas lane's maximum price, not today's: r1 and r2 (0.25 and 0.2 ETH) were
   fulfilled within five blocks, while r5's request on 0.02 ETH stayed pending (Sepolia's lane
   above is the 750 gwei one). A shared subscription does not work for Verify, which requires
   the module to be the only consumer, and the coordinator refuses to remove a consumer while
   any request on the subscription is pending (`PendingRequestExists`).
2. Set the variables:

   | Variable | Value | Bounds |
   | --- | --- | --- |
   | `VRF_COORDINATOR` | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | Must have code; its code hash is recorded. On mainnet it must be the canonical coordinator, `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`, with its pinned code hash (`DeployGuards`) |
   | `VRF_COORDINATOR_CODEHASH` | Optional off mainnet: the coordinator's expected runtime code hash (`cast codehash`) | Must match when set |
   | `VRF_SUBSCRIPTION_ID` | The subscription ID | Nonzero |
   | `VRF_KEY_HASH` | A Sepolia gas lane. 6529Stream's Sepolia instance used `0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae`; confirm it on Chainlink's supported-networks page | Nonzero |
   | `VRF_CALLBACK_GAS_LIMIT` | Default 200,000 | 100,000 to 2,500,000 |
   | `VRF_CONFIRMATIONS` | Default 3 | 3 to 200 |
   | `VRF_NATIVE_PAYMENT` | Default `0` (LINK); `1` for native | |
   | `VRF_RETRY_DELAY` | Default 3 days, in seconds | 3 to 30 days |

3. After the broadcast, add the module (`EntropyModule` in the record) as the subscription's
   only consumer. Requests fail until it is a consumer and the subscription is funded.
   Verify, off anvil, requires the module to be the only consumer. **On mainnet, add it before
   the broadcast:** the simulation reads the subscription after deploying the contracts and
   before `configure`, and stops with nothing broadcast unless the network Safe owns it and
   the module this run deploys is its only consumer. The first simulation stops with
   `ModuleNotAConsumer(subscriptionId, module)`, naming the module's address (CREATE2 under
   `DEPLOY_NAMESPACE`, so the broadcast deploys it there); the network Safe adds that
   address (`addConsumer` accepts an address without code), and the next simulation passes.
4. **On mainnet, the subscription owner is the network Safe.** Create the subscription from
   it, or transfer it (`requestSubscriptionOwnerTransfer`, then the Safe's
   `acceptSubscriptionOwnerTransfer`) before Verify; Verify reads `getSubscription` and
   requires the owner to be the network. The owner can cancel the subscription and take its
   balance, or remove the consumer, at once and outside governance; the module moves to a new
   subscription with `setConfig` (PARAMETER_SETTER, 24 hours). After a network handover the new
   network takes the subscription over the same way. Keep the balance small, and watch the
   coordinator's `SubscriptionCanceled`, `SubscriptionConsumerRemoved` and
   `SubscriptionOwnerTransferRequested` for the subscription ID.
5. Never use Chainlink's subscription `migrate`. The [entropy README](../src/entropy/README.md)
   describes the coordinator-change procedure.
6. **A coordinator change orphans every pending request**, including one whose fulfilment is
   already visible on the old coordinator: request IDs are scoped to their coordinator, so the
   old one can no longer deliver, and the content is drawn again through the new one
   ([coordinator change](../docs/spec/entropy.md#coordinator-change)). Execute `setCoordinator`
   only when every request has its delivery (no `SeedRequested` without a `SeedDelivered` for
   its content), or accept and publish the redraw of each pending content
   ([LIM-ENT-7](../docs/audit/known-limitations.md#entropy)).
7. **Federated VRF works are paid by the requester, never from this subscription.** A wallet of
   a listed federated artist calls `VrfEntropyModule.requestFederatedSeed(token, item)` with the
   VRF v2.5 wrapper's quoted price as `msg.value`; the module forwards it to Chainlink's wrapper.
   It is off at launch: federated requests are refused until the network sets the wrapper
   (`setWrapper(expected, next, codeHash)`, SUCCESSOR_SETTER, 7 days; zero turns it off again).

### 8. Default currencies

Genesis sets them. The wiring makes ETH (`address(0)`) the revision-0 default for
`PRODUCT_STREAM`, `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`. A `CURRENCY_DEFAULT` item can
therefore start in the genesis block:

- `EnglishAuction.start` reads the `PRODUCT_STREAM` default.
- Edition auctions take ETH only, whatever the `PRODUCT_EDITIONS` default.

Verify reads every default back at the revision genesis produced.

A later change is a FUNDS_SETTER action of the network, with a 3-day delay:
1. Allowlist the asset (it must be active).
2. Schedule `setDefaultCurrency(product, expectedRevision, asset)`. `expectedRevision` is the
   current revision, which is 1 after genesis.

### 9. The epoch-0 governance manifest

Write the epoch-0 governance manifest, save it under `config/`, and publish it before genesis.
Then set:
- `MANIFEST_PATH` to the file: the script hashes it, and Verify hashes it again;
- `MANIFEST_URI` to where it is published, for example `ar://...`.

Genesis appends it to the statement log as the manager's first governance statement.

For a Sepolia instance, `python script/sepolia/make_manifest.py` writes it in two passes from the
previous instance's manifest (its usage is in the file). Its `safes` section follows the new
genesis: the network address and each holder that is a Safe of the previous manifest, with that
Safe's owners, threshold and version. A network address that was no earlier Safe is written with
null details and a warning: fill them in before publishing.

### 10. Simulate, then broadcast

```bash
export SEPOLIA_RPC_URL=...                          # the operator's own endpoint
export GENESIS_CONFIG=config/genesis.sepolia.json
export NETWORK_FEE_RECIPIENT=0x... MARKETPLACE_OWNER=0x... MUSEUM=0x...
# DELEGATION_CONTRACT: unset on Sepolia (the official deployment, step 5)
# CC0_TEXT_PATH: unset (the committed legal code, step 6)
export VRF_COORDINATOR=... VRF_SUBSCRIPTION_ID=... VRF_KEY_HASH=...   # step 7
export MANIFEST_PATH=config/<manifest file> MANIFEST_URI=ar://...     # step 9

# Simulation: nothing leaves the machine. It runs every check and prints the addresses and
# the gas estimate.
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer>

# Owner only: broadcast, signing with the keystore or the Ledger.
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer> \
  --broadcast --slow --account <deployer>            # or --ledger

# On a chain that reprices state creation (Glamsterdam: Sepolia since 6 October 2026), add
# --skip-simulation, and optionally a lower priority fee:
forge script script/Deploy.s.sol --rpc-url "$SEPOLIA_RPC_URL" --sender <deployer> \
  --broadcast --slow --skip-simulation --priority-gas-price 0.05gwei --account <deployer>
```

- **Why `--skip-simulation` on Glamsterdam chains.** Sepolia activated Glamsterdam on
  6 October 2026, which reprices state creation. These are Sepolia r1's measurements
  (`eth_estimateGas`), with the Prague cost in brackets:
  - code deposit: about 1,542 gas per byte (200);
  - a new storage slot: about 111K gas (22.1K);
  - an empty `CREATE`: about 210K gas (53K);
  - a zero-value call to an empty account: 15,000 gas.

  Foundry 1.7.1 has no `amsterdam` EVM, so forge's own simulation prices the transactions
  with Prague costs. Its gas limits are then far too low: r1's first broadcast ran out of
  gas creating the configurator, whose limit was 6.96M when the node needed 33.8M.

  `--skip-simulation` skips only forge's replay of the collected transactions. The script
  itself, with every check below, still runs before anything is sent. With `--slow`, forge
  then takes each transaction's gas limit from the node's `eth_estimateGas` just before
  sending it. The simulation command above stays as it is: it runs the checks and prints the
  addresses.

- **Everything is checked before anything is sent.** Forge simulates the whole run first, so
  any failed check aborts it with nothing broadcast. The checks:
  - the RPC's `eth_chainId` is the chain the script runs on;
  - `--sender` was given and is the signer, and is not an EIP-7702 delegated EOA;
  - every input above (steps 2 to 9), and `DEPLOY_NAMESPACE`;
  - the configurator's CREATE2 address is free, and so is every other address that can be
    predicted before the broadcast (`AddressTaken`);
  - after the contracts are simulated and before `configure`: nothing the genesis names is
    missing, the policy is the committed one, and no holder is a contract of the deployment.
- **The sender is the deployer.** It becomes the configurator's `deployer`, the only account
  that can call `configure`.
- **The opening bid.** The committed policy wires the English auction's ETH opening bid at
  0.05 ETH (owner decision 19), on Sepolia as on mainnet: a rehearsal's first ETH bid on each
  1/1 must be at least 0.05 ETH, so fund the bidders for it. The allowlist bounds an opening
  bid only by its 96-bit field (`type(uint96).max`), not by a price cap (R19).
- **Addresses are predictable.** Most depend on the deployer and `DEPLOY_NAMESPACE`;
  ContentStore and ClaimRouter (which takes the split ledger) depend on `DEPLOY_NAMESPACE` alone. To repeat a
  rehearsal, use a new `DEPLOY_NAMESPACE`.
- **Resuming.** `--slow` waits for each receipt. If a broadcast stops partway, rerun the
  broadcast command with `--resume` added.
- **Gas.**
  - **On anvil, with Prague costs,** the whole system is 33 transactions and about 104M gas
    including the delegation mock (measured on 17 November 2026, after federation). The largest
    transaction is about 7.2M, within the 16,777,216-gas EIP-7825 cap.
  - **Each auction's lens is its own transaction** (the rc.2 review's GAS M-2). Created inside
    its auction's deployment, a lens put both contracts' code in one transaction: the edition
    auction's would have needed about 68.9M with Glamsterdam costs, over a 60M block and the
    50M `eth_estimateGas` cap of geth, reth and public RPCs. Deployed apart, the auctions and
    lenses stay under 40M. On Sepolia r4 (1 November 2026) the node's estimates were at most
    38.7M and the whole deploy used 496M gas over 26 transactions
    ([per transaction](../deployments/11155111/README.md#sepolia-r4-1-november-2026-superseded-by-r5)).
  - **WorkRecords now needs about 51M.** On Sepolia r5 (22 November 2026, `main` at `ca02473`)
    WorkRecords' creation used 50.8M gas (node estimate 51.2M), above the 50M estimate cap:
    `ethereum-sepolia-rpc.publicnode.com` answers its `eth_estimateGas` with an empty revert, and
    forge stops after Stream with `Failed to estimate gas`. Tenderly's public gateway
    (`https://sepolia.gateway.tenderly.co`) estimates it, and Sepolia's block limit is 200M. On
    r5, forge still failed to estimate through that gateway (`--resume` also reuses the RPC saved
    in its broadcast cache), so the remaining transactions were sent with forge's exact calldata
    from the cache, in order, with gas limits of 8 times forge's Prague simulation (the r5
    record says how). The whole deploy used 725M gas over 33 transactions
    ([per transaction](../deployments/11155111/README.md#sepolia-r5-22-november-2026-current)).
    Before a mainnet run, budget WorkRecords' creation against the private endpoint's estimate
    cap, or set its gas limit by hand.
  - [`sepolia/deploy.ps1`](sepolia/deploy.ps1) runs this step with an instance's public inputs
    (`config/sepolia-r5/deploy.env`; `-Rpc` overrides its RPC) and the operator's signer module;
    [`sepolia/`](sepolia/) also has the genesis and manifest writers, the per-transaction gas
    rows, Sourcify verification and the flow driver.
  - **On Sepolia r1, with Glamsterdam costs,** the deploy took 445M gas over 25 transactions,
    6.19 times the Prague estimate. That cost about 0.022 ETH at a 0.05 gwei priority fee.
    The per-transaction table is `deployments/11155111/README.md`, added in
    [PR #43](https://github.com/6529-Collections/6529-works/pull/43).
  - **The cap on Glamsterdam.** The cap applies to regular gas. Transactions whose
    state-creation gas takes them above 16,777,216 were accepted: r1's largest used 38.1M.
    That is an observation from r1, not a statement of the EIP rules; budget each chain from
    its own estimates.
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

The system is governed once the network accepts (`acceptNetwork`, from the network Safe, or
`ACCEPT_NETWORK=1` when the operator holds the network). Run Verify after the acceptance and at
least the manager's 5-day `minSetback` after genesis, as `Verify.s.sol` asks; until the
acceptance it fails with `NetworkNotAccepted`:

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
- on mainnet, the recorded VRF coordinator, the entropy module's live `coordinator()`,
  Permit2 and the delegation contract are the canonical contracts with their pinned code, and
  the delegation contract is no mock;
- off anvil, the genesis file still matches the committed policy and names nothing the
  deployment lacks;
- off anvil, the network and the holders still pass the deploy's guards against the chain as
  it is now: the network a bare canonical Safe with its current owners and threshold, and no
  contract of the deployment as a holder. A Safe change after genesis that the deploy would
  refuse fails the readback;
- the network accepted and is the configured one, the brake is the configured one, the
  configurator's own `verify` (roles, delays and selector map), no role left with the
  configurator, and every target's authority;
- every wired getter and default currency, the epoch-0 manifest, and PLATFORM's immediate
  path into `WorkRecords.addLocator`;
- off anvil, the entropy module is its VRF subscription's only consumer, read from its
  current coordinator; on mainnet the subscription's owner is the network. A read
  that fails (for example `InvalidSubscription`) fails the run; only off mainnet, a
  coordinator without `getSubscription` (an empty revert) is skipped;
- the `GovernanceConfigured` hashes match the configuration and wiring recomputed from the
  JSON;
- no other grant-delay or admin-delay change is pending;
- no account outside the configuration was granted a role;
- every selector remap, role-admin change, role-guardian change and target closure on the
  manager since genesis matches the configuration: a configured selector keeps its role, any
  other selector stays with ADMIN, every operational role's admin is NETWORK and any other
  role's ADMIN, every role's guardian stays ADMIN, and no target is closed. The configurator's readback
  sees only the configured selectors and roles, so this catches a genesis-only bind or the
  deferred `bindFederationRegistry` given a role, a mapping to a new role ID or the public
  role, and a change made and later undone;
- no operation scheduled on the manager since genesis is still pending. Each one fails the
  run with its ID, caller, target, selector and ready time. After reviewing them, set
  `ALLOW_PENDING_OPERATIONS=1` to log them instead.

Verify checks the genesis configuration. After a governance change, such as a
[network handover](#handing-the-network-over) or a key rotation, run it in epoch mode: set
`GOVERNANCE_CONFIG` to a copy of the genesis file with the current holders. The wiring
readback stays genesis readback, so a later default-currency change still fails it. Epoch
mode logs every grant it accepts for an account that no longer holds the role, and every
past remap, role-admin or role-guardian change or target closure it accepts because the
manager is back to the epoch configuration; a genesis selector mapping the epoch file drops
counts as such a change, so it passes only once the manager maps that selector to ADMIN. When the
epoch's governance manifest is given (`GOVERNANCE_MANIFEST_PATH`), Verify requires its
SHA-256 to be the content of a `GOVERNANCE_MANIFEST` statement on the manager's chain, and
its `governanceConfig.sha256` to be the SHA-256 of the `GOVERNANCE_CONFIG` file.

### 12. To do: test the state-gas reservoir (CALLS-3)

The NatSpec of the fixed-gas calls (`DELIVERY_GAS`, `PAYOUT_GAS`, `BoundedCall`,
`RevenuePayment`, `TokenTransfer`, `ClaimRouter`) says, from the EIP-8037 draft, that a state-gas
reservoir passes through a fixed-gas call, so a state-writing callee's outcome depends on the
caller's gas limit. Sepolia has so far shown only that transactions above 2^24 gas are accepted
([LIM-GAS-2](../docs/audit/known-limitations.md#gas-and-glamsterdam)). Not yet run:

1. Deploy a recipient whose `onERC721Received` writes three new storage slots.
2. Start and bid on two auctions with it as the recipient, and let both end.
3. Settle one with a gas limit of `2^24 - 1` (expected: `DeliveryPending`, the token stays a
   pending claim) and the other with `2^24 + 1,000,000` (expected: delivered).
4. Record both receipts in [`deployments/11155111/flows.md`](../deployments/11155111/flows.md),
   then update the NatSpec and LIM-GAS-2: confirmed, or corrected.

## Mainnet governance (owner decision 18)

One address holds every network role. Until the TDH bridge exists, that address is one 6529
Safe; it then hands over to the bridge's executor with `transferNetwork` (7 days) and
`acceptNetwork` (owner, 16 November 2026). Earlier commitments (D67, D98; owner decision 18,
1 November 2026) say no 6529 entity holds a privileged role from 2027-01-01; how the two dates
meet is an owner decision. This does not apply to Sepolia, whose rehearsals keep the owner's
keys ([accounts](#1-accounts)).

| Holder | Roles | Who |
| --- | --- | --- |
| Network | ADMIN, NETWORK, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER (at once, 24 hours, 3 days or 7 days by class) | One Safe; later the TDH bridge's executor |
| Pauser keys | PAUSER | Dedicated keys |
| Curation signers | CURATION_SIGNER | Dedicated keys that sign only the published TDH-vote result |

**Open before a mainnet genesis** (not decided yet): who holds PLATFORM, CURATOR and
STORAGE_OPERATOR on mainnet, consistent with D67 and D98, needs an owner decision. The network
grants and revokes those keys at once (it administers every operational role).

**The deploy-side guard.** On mainnet (chain 1), `Deploy.s.sol` and `Verify.s.sol` run
`DeployGuards.checkRoleGroups` on the genesis file. It refuses the deployer EOA as the network
or as any holder, the network address as a holder, and an account that holds roles of two groups
(the pausers' PAUSER, the curation signers' CURATION_SIGNER). The guard compares addresses
only: the same people behind different addresses pass it. The checklist below checks the
people.

### Mainnet genesis checklist

Before the mainnet broadcast, besides the [Sepolia runbook](#sepolia-runbook) steps:

1. The network Safe exists with the intended signers and threshold; check its owners by hand
   ([Safe pre-flight](#2-safe-pre-flight)).
2. The genesis configuration names it as `network`, names no brake (refused off anvil:
   `BrakeAtLaunch`), and gives only operational roles to holders.
3. The curation signer keys are dedicated to signing the published TDH-vote result.
4. The owner has decided who holds the operational keys (the open item above), and the genesis
   configuration names them.
5. The deploy's mainnet guard (`DeployGuards.checkRoleGroups`, above) passes, and Verify reads
   every role holder back ([step 11](#11-verify-after-5-days)).
6. The VRF subscription owner is the network Safe, and it has added the module's address as the
   only consumer ([step 7](#7-chainlink-vrf-the-entropy-module)). The deploy checks both before
   the broadcast, and Verify again.
7. The museum, the marketplace owner and the network fee recipient are not the deployer (the
   deploy and Verify refuse the deployer for each).
8. After the broadcast, the network Safe calls `acceptNetwork()`; then run Verify.

## Operating procedures

The contracts do not enforce these procedures; they describe the network's current practice.
A reference implementation of the keeper steps below, tested on a local anvil chain, is in
[`keeper/`](../keeper/README.md).
The rules themselves are in the [governance spec](../docs/spec/governance.md).

### Scheduled network actions

- **Classes.** A network action runs at once (NETWORK) or after its class: 24 hours
  (PARAMETER_SETTER), 3 days (FUNDS_SETTER) or 7 days (ADMIN, SUCCESSOR_SETTER). A delayed one
  is scheduled on the manager first; the network or the scheduler can cancel it
  ([cancellation rules](../docs/spec/governance.md#cancellation-rules)). The brake, when one is
  set, can delay a scheduled action once by 7 days (`brakeOnce`).
- **Watching.** The pending set is every `OperationScheduled` not followed by
  `OperationExecuted` or `OperationCanceled` with the same operation ID and nonce, and not yet
  past its expiry; Verify fails while any is pending on the manager, unless
  `ALLOW_PENDING_OPERATIONS=1`. On mainnet, also watch the VRF coordinator's
  `SubscriptionCanceled`, `SubscriptionConsumerRemoved` and `SubscriptionOwnerTransferRequested`
  for the subscription ID ([step 7](#7-chainlink-vrf-the-entropy-module)).
- **Operation expiry.** An operation must execute within `expiration()` of becoming ready: 14
  days (one week plus the brake delay, so a braked operation keeps a week to run: the brake
  always moves it to its ready time plus 7 days, whenever it acts, so a brake placed after
  that point delays nothing). After that
  `execute` reverts with `AccessManagerExpired`, and the operation must be scheduled again with
  the full delay.

### Emergencies

- **Pausing** is immediate (PAUSER); unpausing is the network's, at once.
- **Pausing the edition auction pauses the English auction's starts too** (LC-2). While the
  edition auction is paused it refuses `open`, and an edition master whose 1/1 starts and closes
  in that time can never get an edition sale from it (LIM-EA-11). Pause `EnglishAuction` with it
  (its `pause()` stops `start` and `startWithBid`; running 1/1s are unaffected) and unpause both
  together.
- **A dispute on a live 1/1.** A pauser's `pause(saleId, disputeRef)` holds the auction for at
  most 3 days, once per auction (`MAX_PAUSE`, C30). The network's `resume` and
  `cancel(saleId, outcomeRef)` take no wait and may land at any moment of the pause.
  `cancel` needs `outcomeRef` to be the token's latest `DISPUTE_OUTCOME` statement recorded
  after the pause (`OutcomeNotRecorded` otherwise): record the final outcome first, then cancel.
  Edition bids cannot be withdrawn meanwhile (R21).
- **A compromised operational key.** The network revokes it at once (`revokeRole(role, key)`:
  the network administers every operational role, with no delay) and grants a replacement key
  the same way. Pause the affected targets as well where they have a pause. If the same key is
  also the marketplace owner, schedule `setOwner` on Stream and Editions as well (FUNDS_SETTER,
  3 days).
- **A compromised curation signer.** The network calls the curation verifier's one-way
  `disableSigner(key)` and `PackageRegistry.killSignerApprovals(key)` in one Safe batch, both at
  once; the kill stops the key's approvals not yet minted (C32). A kill alone leaves attestations
  signed before it registrable, and a disable alone leaves registered packages live. Re-enabling a signer is a 7-day
  SUCCESSOR_SETTER action and starts a new curation signer epoch, and so does every new grant
  of the role (`grantCount`), so no earlier approval counts again.
- **An artist account.** The network can freeze an account at once for 14 days (`freeze`,
  `unfreeze`, C17); while frozen, no wallet acts for it and its payouts are held.
  The network's monitor watches `ArtistRegistered` for wallets consolidated with a frozen or
  delisted root and freezes (at once) or delists (24 hours) such a new account (LIM-ID-23).
- **A contested replacement.** The network holds PLATFORM itself and sends the
  `DISPUTE_OUTCOME` write and the execution of the scheduled `resolveContested` in one batch: a
  newer outcome appended in between makes the resolution revert (`OutcomeNotRecorded`,
  LIM-GV-29).

### Handing the network over

1. The network schedules `transferNetwork(next)` (ADMIN, 7 days; the brake can delay it once)
   and executes it: `next` is now pending (`pendingNetwork`). Zero withdraws a proposal.
2. `next` calls `acceptNetwork()`. From then on the old address holds no network role, and its
   scheduled operations can no longer run
   ([handing the network over](../docs/spec/governance.md#handing-the-network-over)).
   Acceptance does not touch operational roles: if the old address was granted any (PLATFORM,
   for example, under the contested-replacement procedure above), the new network revokes each
   with `revokeRole(role, old)` at once (the network administers operational roles with no
   delay). Check `RoleGranted` and `RoleRevoked` for the old address before step 4.
3. On mainnet, move the VRF subscription to the new network
   ([step 7](#7-chainlink-vrf-the-entropy-module)).
4. Re-run Verify in epoch mode with `GOVERNANCE_CONFIG` naming the new network
   ([step 11](#11-verify-after-5-days)) and publish the change as a governance manifest.

Only the current network can propose a handover, and nothing in the contracts recovers a
network address whose keys are lost, so the network Safe's signers and threshold are chosen so
that it cannot be lost.

### Onboarding a target after genesis

Deploy the target with `authority` set to the manager, then:

1. schedule one `setTargetFunctionRole` per selector, each a 7-day ADMIN operation;
2. execute them, for example in one `multicall`, where each call consumes its own schedule;
3. read the manager back with the target added to the configuration
   (`GovernanceConfigurator.verify`, `test_OnboardATargetAfterGenesis`).

### The 1/1 start keeper

The network's keeper (a funded hot wallet with no role) starts every 1/1 through
`SaleStarter` ([`src/sales/SaleStarter.sol`](../src/sales/SaleStarter.sol)), never by calling the
English auction directly:

- `SaleStarter.start(auction, stream, mintData, media)` (or `startWithBid`, PERMIT2 payments
  only) starts the auction, deploys the work's seller vault (`createWallet(item.payees, 0)`,
  checked against the seller the work's terms name) and, with a nonzero fee share, its royalty
  vault (`createWallet(Splits.royaltyPayees(seller, feeRecipient, feeShare), 0)`), and opens the
  record (`WorkRecords.openRecord(tokenId, item, media)`) in one transaction. If any step fails,
  nothing happens: no token, no sale, no vault. The helper is stateless, holds nothing and has
  no roles.
- This is the keeper's rule, not the chain's: `EnglishAuction.start` stays permissionless, and
  anyone holding the artist's signed move can still start a sale directly, leaving the vaults
  and the record to later permissionless calls (LIM-CNT-19, LIM-ECO-7).
- A direct `EnglishAuction.start` with the same mint data makes `SaleStarter.start` revert. The
  keeper then calls `createWallet` (seller, and royalty when the share is above zero) and
  `openRecord` itself; both are permissionless and fully determined.
- `startWithBid` refuses the helper itself as the payer (`HelperAsPayer`): the bid is paid by
  the keeper or another account through Permit2.
- **Claims through the `ClaimRouter`.** In a batch, leave out the network's own index for any
  wallet and asset whose payee is also released in the batch: the R11 push already paid the
  network, so that item releases zero and fails (atomic mode reverts the batch).

### The edition auction keeper

Every step of an edition sale is permissionless. The network currently runs a keeper (any
funded EOA, no role) that batches them so that nothing waits, and anyone else may make the same
calls ([ADR 0005](../docs/adr/0005-stream-editions-auction.md)):

1. **Open the edition auction right after every edition-master start** (owner decision 7):
   `UniformEditionAuction.open(editions, tokenId, abi.encode(item, packageRoot, proof))`, the
   master's EDITION_MASTER package item with the package root it was approved in and its Merkle
   proof (C23: a revoked package, or one whose curation signer was disabled, opens no sale), in
   the same batch as the keeper's own starts, and for starts by anyone else as soon as the English
   auction's `SaleStarted` for an `EDITION_MASTER` work appears. `open` also binds the edition to
   the adapter. An auction nobody opens before the 1/1's end plus 15 minutes can never be opened
   by this adapter (LIM-EA-11); a later admitted adapter of the edition's kind still can.
2. **Create the edition once the 1/1 settles:** `Editions.createEdition(tokenId, item)`. A sale
   with winners settles only once the edition exists (`EditionNotCreated`; LIM-EA-12). If it was
   missed, `abandon(saleId, abi.encode(item))` creates it from 21 days after the sale's close,
   for any completed 1/1, including one that ended with no bid (R16; owner, 17 November 2026).
3. **Settle after the edition close:** call `settle(saleId, order)` until it returns `true`,
   with `order` the keeper's own rest, `settlementOrderFor(saleId, keeper)` (on the adapter or
   its lens), cut to one chunk (16 entries in the call that clears, 96 after) to keep calldata
   small. Each call stays within 350,000 execution gas; a typical sale settles in one. With
   thousands of departures at the cut step, page the order instead:
   `settlementOrderFor(saleId, keeper, fromPosition, max)` with `max` 96 returns the next chunk
   from `fromPosition` on (one past the last position the keeper got), about 21.9M gas a page at
   10,000 departures, where the whole-log views no longer fit a 50M `eth_call` (LIM-EA-17). Each
   settler sweeps on its own: a keeper that sent a wrong order strands only its own progress
   (`sweepOf`), and settles from another address. A call after the sale settled returns
   `true`.
   **Settle directly, or through the keeper's own contract, never through a shared public
   relayer** such as Multicall3: the sweep slot belongs to `msg.sender`, so every caller of a
   shared relayer shares one slot, and one caller's wrong order strands the sweep for all of
   them. A keeper's own batching contract is its own settler.
4. **Optionally push claims** with `claimBidFor(saleId, bidId)`: copies go to the bidder and the
   refund is credited to it.
5. **Sweep stale credits to the network:** a credit (an outbid refund, a pushed claim's refund, a
   payout credited after a failed ERC-20 push) not claimed within 180 days of when it last went
   from zero (later credits do not move that clock) may be sent to the network's fee recipient
   with `expireCredit(account, currency)` on either auction (`creditExpiresAt` tells when). Push unclaimed edition bids with
   `claimBidFor` first: their refunds then become credits.

### Replacing one of Stream's dependencies

`Stream.setDependency(kind, expected, next)` (SUCCESSOR_SETTER, 7 days, owner decision 16)
replaces Stream's package registry, artist registry, economics resolver or entropy module.
Stream, 6529 Stream Editions and `WorkRecords` follow at once; existing tokens do not change
(`test_ReplacingEachDependencyLeavesExistingTokensUnchanged`): ownership, the terms and royalty
receivers locked at mint through Stream's immutable split factory, finalized renderer pins, and
VRF seeds, which always come from the module a work minted under
([ENT-18](../docs/spec/entropy.md#rules-and-invariants)). Other contracts hold their own wiring
to the same dependencies and do not follow, so each replacement is a set, deployed against the
existing Stream and Editions and switched in one governance batch: schedule every operation of
the set together, execute them in one `multicall`, and onboard each new contract first
([above](#onboarding-a-target-after-genesis)).

Before any switch:
- **Open every pending edition sale on the old adapters** when the set replaces the English
  auction or the edition auction. A master started on the old English auction whose edition
  sale is not open yet can never be opened afterwards: the old edition auction is no longer
  admitted, and the new one reads only the new English auction (`NoOneOfOneAuction`).
- **Settle edition sales with winners, and create their editions, before a package-registry
  switch.** A sale still OPEN or SETTLING across the switch, or one whose edition does not exist
  yet, depends on the successor. An open sale settles only after its close, so new 1/1 starts must stop (pausing
  `EnglishAuction`, as in [Emergencies](#emergencies)) early enough for every running sale to
  close and settle before the switch executes. A successor that cannot create an earlier master's edition leaves such a sale on
  `EditionNotCreated`, its bidders unable to claim until the network reverses the switch
  (another 7 days).

| Replaced | Who else holds it | The replacement set | Without a Stream redeploy? |
| --- | --- | --- | --- |
| Entropy module | Nobody: the renderer and `WorkRecords` ask Stream | A new `VrfEntropyModule` pinned to Stream's current package registry, added as a consumer of a funded subscription ([step 7](#7-chainlink-vrf-the-entropy-module)) and, when federated VRF is on, given the wrapper (`setWrapper`); then `setDependency("ENTROPY_MODULE")`. A successor entropy module keeps the seeds its predecessor delivered for content not yet minted only if it answers `isDeliveredContent`, `seedOfContent` and `seedOf` with the predecessor's seed and refuses a new draw for it. Today's `VrfEntropyModule` reads no predecessor, so the network's current practice is to schedule a replacement only when no unminted VRF content has a seed delivered or requested on the old module, or to publish that each such content is redrawn. List those contents before scheduling: every content hash in the old module's `SeedLinked` events whose `PackageRegistry.consumedItemOf` reads zero (a content a dispute released reads zero again, so it stays on the list). A delivered content is drawn again by the new module; a pending one is drawn there too, while the old module may still deliver its request. Rebuild the list immediately before executing, since anyone can request a seed and the old coordinator can deliver one during the 7-day delay, and cancel the switch, or publish the redraw, for each content not already disclosed ([LIM-ENT-7](../docs/audit/known-limitations.md#entropy)). Keep the old module deployed: the works minted under it read their seeds from it. | Yes |
| Economics resolver | `EnglishAuction` (immutable: the federated fee recipient and the asset allowlist; since owner decision 17 Stream, not the auction, reads the museum) and `UniformEditionAuction` (it holds no resolver: a sale pays exactly the terms `Editions.bindMinter` locks and returns, one source of truth since ADR 0005 §12; but it reads the 1/1's clock from its immutable English auction, so it is replaced with it) | A new resolver whose `splitFactory()` is Stream's (Stream derives sellers with its own immutable factory and Editions with the resolver's; `setDependency` does not check it), a new `EnglishAuction` and a new edition auction on it; then `setDependency("ECONOMICS")`, `Stream.setAdmittedMinter` (the new auction in, the old out: one adapter per kind, ADR 0005) and the same on Editions. Sales running on the old adapters finish there: their fees follow the terms locked at mint or at open, while an unsold 1/1 goes to the NEW resolver's museum, since Stream reads `museum()` from its current resolver when it settles (owner decision 17). | Yes |
| Package registry | `VrfEntropyModule` (pinned registry), `ArtistRegistry` (its only `register` caller: `setPackageRegistry`, SUCCESSOR_SETTER, 7 days) | A successor registry pinned to the current artist registry, bound to the existing Stream and Editions (`bindStream`, `bindEditions`: one-shot per instance, so a new instance binds), plus a new entropy module pinned to it, with the same seed question as in the row above; then, in one batch, `setDependency("PACKAGE_REGISTRY")`, `ArtistRegistry.setPackageRegistry(old, successor)`, so new artists register through the successor (`test_AReplacementPackageRegistryRegistersNewArtists`), and `setDependency("ENTROPY_MODULE")`. For earlier packages and releases to stay usable, the successor reads its predecessor's state: approved packages and releases (without them `releaseContent` refuses every work burned before); Stream calls it through `consume`'s ABI (LIM-GV-17). Today's `PackageRegistry` reads none of it: such a successor is new code. | Yes, with new code |
| Artist registry | 6529 Stream (an immutable with no setter: `setDependency("ARTIST_REGISTRY")` reverts, AUC-39), 6529 Stream Editions (cached at deployment), `SplitLedger` (the payout resolver, an immutable without a code-hash pin), `PackageRegistry` (pinned), `StatementLog` (`setArtistResolver`, 7 days) | None: the artist registry is permanent ([ADR 0007](../docs/adr/0007-permanence.md)). | **No.** It is never replaced; its replaceable parts are its consolidation source (`setConsolidationSource`), its package registry (`setPackageRegistry`) and its federation-registry pointer (`setFederationRegistry`), each SUCCESSOR_SETTER, 7 days. Its timers are compiled. |

One limit follows ([LIM-GV-16](../docs/audit/known-limitations.md#trust-and-governance)): the
genesis artist registry is permanent for Stream's payouts. A replacement package registry does
onboard new artists: the artist registry's one `register` caller is replaced with it, in the
same batch (`ArtistRegistry.setPackageRegistry`).

### Replacing the federation registry

The federation registry is replaceable ([ADR 0008](../docs/adr/0008-federation.md) §8);
nothing migrates, because entries are composed from the permanent directory: a successor
inherits every listing, and no artist signs anything (C3). A successor that
does not yet serve the predecessor's set when the artist registry's pointer moves freezes out
every running federated sale (refunds)
(`test_Replacement_SwappedBeforeItsApprovalsFreezesRunningSales`):

1. Deploy the successor (the artist registry, the economics resolver and the canonical content
   store as constructor arguments) and onboard it ([above](#onboarding-a-target-after-genesis)).
2. On the successor, approve every template version the predecessor approves, each bound to
   the same deployer (`approveTemplate(codeHash, deployer, version, form)`), carrying over any
   SUSPENDED or REVOKED status, and admit the same adapters (`setAdapter`). These wait their
   class (24 hours for the template actions, 7 days for `setAdapter`), so schedule them first.
3. Before scheduling the switch, check the successor answers as the predecessor: for each
   approved code hash, `templateOf` matches (`VerifyV1.checkTemplate` against the successor
   reproduces genesis's template check), and `isAdmittedAdapter` matches for each adapter.
4. Immediately before executing the switch, repeat the comparison with the verify script's
   `successorParity()` entry point (`VerifyV1.checkSuccessorParity`): the predecessor is the
   registry the recorded artist registry names now, and the lists are every code hash the
   predecessor has approved, suspended or revoked and every adapter either has admitted
   (comma-separated, no spaces; an empty list is refused):

   ```bash
   DEPLOYMENT=deployments/<chainId>/<timestamp>.json    SUCCESSOR_FEDERATION_REGISTRY=<successor>    FEDERATION_CODE_HASHES=<hash>,<hash> FEDERATION_ADAPTERS=<adapter>,<adapter>      forge script script/Verify.s.sol --sig "successorParity()" --rpc-url "$RPC_URL"
   ```

   It prints the counts compared and fails with `FederationMismatch("templateOf")` or
   `("isAdmittedAdapter")` on the first difference. The switch's setters check only the expected pointer and ERC-165, and a
   revocation, suspension or adapter change on the predecessor during the 7-day delay would
   otherwise go unnoticed; once the switch lands, the successor answers every read. Do not
   execute the switch while the check fails: mirror the change on the successor first.
5. Then, in one batch, `ArtistRegistry.setFederationRegistry(old, successor)` and
   `EnglishAuction.setFederationRegistry(old, successor)`. The predecessor answers as the
   successor from then on (FED-69), so the order inside the batch does not matter.

### Publishing a configuration epoch

Schedule `StatementLog.appendGovernanceManifest` (SUCCESSOR_SETTER, 7 days) with the epoch's
other operations, so the manifest's hash is public before they take effect. Once they have
executed, run Verify in epoch mode with `GOVERNANCE_CONFIG` and `GOVERNANCE_MANIFEST_PATH`
([step 11](#11-verify-after-5-days)).

## Environment reference

Unset and empty are the same. Numbers are checked against their type (`SafeCast`).

| Variable | Anvil default | Off anvil |
| --- | --- | --- |
| `GENESIS_CONFIG` | `config/genesis.example.json` | Required; the committed policy with reachable holders (step 3) |
| `DEPLOY_NAMESPACE` | `keccak256("6529-works/v1")` | Required; changes every address. Use a fresh one, kept private until the broadcast |
| `NETWORK_FEE_RECIPIENT` | Placeholder `0xC001` | Required; must exist: code, a balance or a nonce |
| `MARKETPLACE_OWNER` | Placeholder `0xC002` | Required |
| `MUSEUM` | Placeholder `0xC003` | Required; must exist: code, a balance or a nonce. A Safe or an EOA |
| `DELEGATION_CONTRACT` | Canonical address; a mock is deployed when it has no code | Must have code; canonical on mainnet. Default on Sepolia: the official deployment |
| `CC0_TEXT_PATH` | `test/fixtures/cc0-legalcode.txt` | Same default; must hash to the pinned digest |
| `MANIFEST_PATH` | Placeholder digest | Required, under `config/` |
| `MANIFEST_URI` | `ar://placeholder-epoch-0` | Required |
| `ETH_INCREMENT_FLOOR` | 0.001 ether, in wei | Optional: ETH's minimum bid increment |
| `PERMIT2` | The canonical address | Must have code; canonical on mainnet. On anvil, without code, the auction runs without Permit2 |
| `AUCTION_DURATION` | 24 hours, in seconds | Optional |
| `AUCTION_EXTENSION_WINDOW` | 15 minutes, in seconds | Optional |
| `AUCTION_INCREMENT_SHARE` | 5,000 (5% of 100,000) | Optional |
| `VRF_COORDINATOR`, `VRF_SUBSCRIPTION_ID`, `VRF_KEY_HASH` | Unset: no entropy module | Required unless `NO_VRF=1` (step 7) |
| `VRF_CALLBACK_GAS_LIMIT`, `VRF_CONFIRMATIONS`, `VRF_NATIVE_PAYMENT`, `VRF_RETRY_DELAY` | Defaults in step 7 | Optional |
| `VRF_COORDINATOR_CODEHASH` | Unset | Optional off mainnet; must match the coordinator's code. On mainnet the canonical coordinator and its code hash are pinned |
| `NO_VRF` | `0` | `1` declines the entropy module explicitly |
| `ACCEPT_NETWORK` | `0` | `1` also broadcasts `acceptNetwork()` from the genesis file's network address, for a network account the operator holds |
| `DEPLOYMENT` | (Verify) | The record to verify |
| `GOVERNANCE_CONFIG` | (Verify) unset: the genesis file | Epoch mode: a copy of the genesis file with the current holders, for readback after a governance change |
| `GOVERNANCE_MANIFEST_PATH` | (Verify) unset | Epoch mode: the epoch's manifest file; it must be recorded on chain and name the `GOVERNANCE_CONFIG` file's SHA-256 |
| `ALLOW_PENDING_OPERATIONS` | (Verify) `0` | `1` logs pending manager operations instead of failing on the first |
| `MANIFEST_PATH` | (Verify) the recorded path | The manifest file to hash again |
