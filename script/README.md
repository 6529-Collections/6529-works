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
| [`DeployGuards.sol`](DeployGuards.sol) | The off-anvil checks of the genesis file and the deployment: reachable holders, the committed policy, nothing dropped. |
| [`VerifyV1.sol`](VerifyV1.sol) | Library: static readback of a deployment against its configuration, its predicted addresses and its default license. |
| [`Deploy.s.sol`](Deploy.s.sol) | Checks every input, deploys, configures, and records `deployments/<chainId>/<timestamp>.json`. |
| [`Verify.s.sol`](Verify.s.sol) | Confirms a recorded deployment against the chain: addresses, code, CC0 text, manifest, governance and events. |
| [`ScriptIO.sol`](ScriptIO.sol) | What the scripts read from outside the EVM (environment, files, the RPC's chain ID), one virtual function each, so the tests run the scripts with their own inputs. |

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
  work priced in `CURRENCY_DEFAULT` auctioned from the genesis block, on the deployed system;
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

- **Placeholders.** Anvil runs on placeholders: the example genesis, the manifest, the fee
  recipient and the marketplace owner. The CC0 text is the real one, the committed fixture.
  A `DelegationManagementMock` is deployed first, because the canonical delegation address has
  no code. The record says `"placeholders": true` and marks the mock (`"delegationMock": true`).
  Its `standIns` and `pendingLanes` are empty.
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
- **Mainnet: use a private RPC and a private namespace.** Every address is predictable from
  public inputs. Someone who sees the configurator's creation in the public mempool can create
  the same initcode first. ContentStore, ReleaseVerifier and ClaimRouter take no constructor
  arguments, so their addresses depend on `DEPLOY_NAMESPACE` alone, and anyone who knows the
  namespace can create them in advance. That gains nothing, because the code is identical and
  the configurator still only obeys the operator, but the namespace is then spent: the next
  run stops with `ConfiguratorAddressTaken` or `AddressTaken` and needs a new
  `DEPLOY_NAMESPACE`. Off anvil the namespace has no default. Choose a fresh one, keep it
  private until the broadcast, and send through a private transaction endpoint.
- **Sepolia mirrors mainnet.** Use throwaway signers, but the mainnet structure and thresholds:
  - the same Safes, roles and thresholds as below;
  - the entropy module with a real VRF subscription (step 7), not `NO_VRF`;
  - the official 6529 delegation contract (step 5).

  A rehearsal then exercises the same flows, admin recovery included.

### 1. Accounts

| Account | Roles | Kind |
| --- | --- | --- |
| Deployer (operator) | None after genesis. It is the configurator's `deployer`, and signs every deploy transaction and `configure` | Keystore or Ledger EOA, funded with Sepolia ETH. Not an EIP-7702 delegated account: the script refuses one (`DelegatedDeployer`) |
| Hot admin Safe | ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER | Safe |
| Cold recovery admin Safe | ADMIN only. It acts only for [admin recovery](#admin-recovery) | Safe, 3-of-5 recommended. Its signers differ from the hot admin's and the guardians', on hardware wallets kept in separate places |
| Guardian Safes 1, 2 and 3 | GUARDIAN, PAUSER (at least three off anvil) | Safe, 2-of-3 each |
| Curation signer keys 1 and 2 | CURATION_SIGNER (at least two off anvil). They sign approvals off-chain and never call a contract | EOA |
| Storage operator | STORAGE_OPERATOR | EOA |
| Platform | PLATFORM | EOA |
| Curator | CURATOR | EOA |
| Network fee recipient | No role (`NETWORK_FEE_RECIPIENT`) | An existing account: a Safe, or an EOA with a balance or a sent transaction ([below](#the-network-fee-recipient-must-exist)) |
| 6529 Network Museum | No role (`MUSEUM`). Receives every 6529 Stream work whose 1/1 sale ends unsold (D140), moved there by Stream (owner decision 17); FUNDS_SETTER can change it (`setMuseum`, 14 days) | An existing Safe or EOA that can hold ERC-721 tokens ([below](#the-museum-must-exist)) |
| Marketplace owner | No role (`MARKETPLACE_OWNER`). Stream's `owner()`: collection admin on marketplaces, no protocol power; FUNDS_SETTER can change it (`setOwner`, 14 days) | Safe or EOA, separate from the platform key, so a stolen platform key does not also hold the marketplace listing |
| VRF subscription owner | No role; owns the Chainlink subscription. It can cancel the subscription or remove the module at once, outside governance, so on mainnet it must be the hot admin Safe (Verify checks it) | Mainnet: the hot admin Safe. Sepolia: EOA or Safe |
| Keeper | No role (`refreshStanding` is permissionless) | Any funded EOA |

Delays and responsibilities are in the [role table](../docs/spec/governance.md#roles).

**Guardians.** They veto any scheduled operation and pause in an emergency, so they must be
independent of the admins they check:
- **Signers.** Use signers independent of the admin Safes and of the other guardian Safes; the
  script refuses a signer shared between any two admin or guardian Safes. Mix team and community members across the three Safes.
- **Operations.** Monitoring, emergencies, suspensions and rotations are under
  [Operating procedures](#operating-procedures).
- **Separate pause and unpause.** The guardians hold PAUSER and the hot admin holds UNPAUSER;
  the configuration refuses one account holding both. A pause by a guardian is undone only by
  the admins, and no earlier than 48 hours after it (`unpause`, `resume` and `cancel` count
  the delay from the pause; re-admitting a deprecated currency waits 14 days from the
  deprecation).
- **The edition auction's pause stops new opens only.** Running edition sales keep taking
  bids, settle and pay out; a sale nobody opened before its close never sells copies, so lift a
  pause before the 1/1s that started under it close.
- **Deprecating an auction's currency.** A deprecation freezes the live auctions in that
  currency: nothing settles, and their high bidders may withdraw. To keep them alive,
  re-admit the currency between day 14 and day 30 after the deprecation (`admitAsset` is in
  the 14-day class and executes no earlier than 14 days from the deprecation); the first
  `settle` after the re-admission reopens each auction for at least the governed duration.
  After day 30, anyone can end a frozen auction unsold: its standing bid is credited back to
  the bidder and a 6529 Stream work goes to the museum (any other token's to its artist).

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

6529 Stream moves every work whose 1/1 sale ends unsold, unbid or by the 30-day currency
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

The configurator renounces ADMIN in the genesis transaction. An admin or guardian that nobody
can operate is therefore permanent. Off anvil, the script refuses an ADMIN or GUARDIAN holder
in these cases:
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

It also requires at least two admin Safes, the hot and the cold, and refuses a signer that any
two of the admin and guardian Safes share: two admin Safes, an admin and a guardian Safe, or
two guardian Safes (owner decision 3: independent guardians).

The script cannot check that the owners are the right people, so check every Safe before the
run:

```bash
for SAFE in <hot> <cold> <guardian1> <guardian2> <guardian3>; do
  cast code "$SAFE" --rpc-url "$SEPOLIA_RPC_URL" | head -c 12; echo   # not 0x
  cast call "$SAFE" "getThreshold()(uint256)" --rpc-url "$SEPOLIA_RPC_URL"
  cast call "$SAFE" "getOwners()(address[])" --rpc-url "$SEPOLIA_RPC_URL"
done
```

- Each Safe is on this chain, with the intended owners and threshold.
- The hot and cold admin Safes share no signer.
- Each guardian Safe is separate from the admins and from the other guardians.
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
  - fewer than three guardians or two curation signers;
  - on mainnet only (owner decision 18), an account holding roles of two groups, or a group
    role held by the deployer EOA (`DeployGuards.checkRoleGroups`). The groups are:
    - the community council: ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER and
      SUCCESSOR_SETTER;
    - the security council: GUARDIAN and PAUSER;
    - the curation signers: CURATION_SIGNER.

    Verify repeats this check.

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
use case 999, all collections, in both directions. Then refresh the artist's standing
(step 12).

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
   or with Sepolia ETH if `VRF_NATIVE_PAYMENT=1`.
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
   Verify, off anvil, requires the module to be the only consumer.
4. **On mainnet, the subscription owner is the hot admin Safe.** This is an accepted
   trade-off: if the hot admin is compromised, VRF works stop for about 64 days or more. The
   hot Safe can cancel the subscription at once. The cold admin removes it (30 days), then
   appoints a new hot Safe (30 days, then PARAMETER_SETTER's 48-hour grant delay), which
   moves the module to a new subscription (`setConfig`, 48 hours). A guardian acting with
   the hot Safe adds another 30 days ([admin recovery](#admin-recovery)). Create the subscription
   from it, or transfer it (`requestSubscriptionOwnerTransfer`, then the Safe's
   `acceptSubscriptionOwnerTransfer`) before Verify. The owner can cancel the subscription
   and take its balance, or remove the consumer, at once and outside governance; the
   module's recovery is a 48-hour `setConfig`. Verify reads `getSubscription` and requires
   the owner to hold ADMIN and PARAMETER_SETTER. Keep the balance small, and alert the
   guardians on the coordinator's `SubscriptionCanceled`, `SubscriptionConsumerRemoved` and
   `SubscriptionOwnerTransferRequested` for the subscription ID.
5. Never use Chainlink's subscription `migrate`. The [entropy README](../src/entropy/README.md)
   describes the coordinator-change procedure.

### 8. Default currencies

Genesis sets them. The wiring makes ETH (`address(0)`) the revision-0 default for
`PRODUCT_STREAM`, `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`. A `CURRENCY_DEFAULT` item can
therefore start in the genesis block:

- `EnglishAuction.start` reads the `PRODUCT_STREAM` default.
- Edition auctions take ETH only, whatever the `PRODUCT_EDITIONS` default.

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
  1/1 must be at least 0.05 ETH, so fund the bidders for it. `ETH_INCREMENT_FLOOR` must stay at
  least 0.00005 ETH, or the wired bid is above the auction's ceiling (1,000 floors) and
  `configure` reverts.
- **Addresses are predictable.** Most depend on the deployer and `DEPLOY_NAMESPACE`;
  ContentStore, ReleaseVerifier and ClaimRouter depend on `DEPLOY_NAMESPACE` alone. To repeat a
  rehearsal, use a new `DEPLOY_NAMESPACE`.
- **Resuming.** `--slow` waits for each receipt. If a broadcast stops partway, rerun the
  broadcast command with `--resume` added.
- **Gas.**
  - **On anvil, with Prague costs,** the whole system is 26 transactions and about 71.7M gas,
    including the delegation mock. The largest transaction is the edition auction's creation,
    at about 5.5M, within the 16,777,216-gas EIP-7825 cap.
  - **Each auction's lens is its own transaction** (the rc.2 review's GAS M-2). Created inside
    its auction's deployment, a lens put both contracts' code in one transaction: the edition
    auction's would have needed about 68.9M with Glamsterdam costs, over a 60M block and the
    50M `eth_estimateGas` cap of geth, reth and public RPCs. Deployed apart, every deploy
    transaction is at most about 39.9M with Sepolia's measured Glamsterdam costs (the edition
    auction; its lens about 30.7M, the English auction about 37.8M and its lens about 10.4M),
    so no gas limit needs setting by hand: `--slow` takes each from `eth_estimateGas`.
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
- on mainnet, the recorded VRF coordinator, the entropy module's live `coordinator()`,
  Permit2 and the delegation contract are the canonical contracts with their pinned code, and
  the delegation contract is no mock;
- off anvil, the genesis file still matches the committed policy and names nothing the
  deployment lacks;
- off anvil, the holders still pass the deploy's holder guards against the chain as it is
  now: admin and guardian Safes with their current owners and thresholds, no shared signer,
  and no contract of the deployment as a holder. A Safe owner change after genesis that the
  deploy would refuse fails the readback;
- the configurator's own `verify` (roles, delays and selector map), no role left with the
  configurator, and every target's authority;
- every wired getter and default currency, the epoch-0 manifest, and PLATFORM's immediate
  path into `WorkRecords.addLocator`;
- off anvil, the entropy module is its VRF subscription's only consumer, read from its
  current coordinator; on mainnet the subscription's owner is the hot admin Safe. A read
  that fails (for example `InvalidSubscription`) fails the run; only off mainnet, a
  coordinator without `getSubscription` (an empty revert) is skipped;
- the `GovernanceConfigured` hashes match the configuration and wiring recomputed from the
  JSON;
- no other grant-delay or admin-delay change is pending;
- no account outside the configuration was granted a role;
- no operation scheduled on the manager since genesis is still pending. Each one fails the
  run with its ID, caller, target, selector and ready time. After reviewing them, set
  `ALLOW_PENDING_OPERATIONS=1` to log them instead.

Verify checks the genesis configuration. After a governance change, such as an
[admin recovery](#admin-recovery) or a key rotation, run it in epoch mode: set
`GOVERNANCE_CONFIG` to a copy of the genesis file with the current holders. The wiring
readback stays genesis readback, so a later default-currency change still fails it. Epoch
mode logs every grant it accepts for an account that no longer holds the role. When the
epoch's governance manifest is given (`GOVERNANCE_MANIFEST_PATH`), Verify requires its
SHA-256 to be the content of a `GOVERNANCE_MANIFEST` statement on the manager's chain, and
its `governanceConfig.sha256` to be the SHA-256 of the `GOVERNANCE_CONFIG` file.

### 12. Standing refresh: `refreshStanding`

`ArtistRegistry.refreshStanding(artistId)` is permissionless and does not count as artist
activity. One refresh any time after a consolidation records the wallet; a consolidation
younger than 30 days is recorded as pending. The worst case was measured at about 4.7M gas
with Prague costs. A refresh writes new storage slots, which Glamsterdam reprices, so
re-measure it on Sepolia before relying on that figure.

- **Artists pay (owner decision).** Right after an artist links a wallet (a two-way
  use-case-999 consolidation), 6529.io prompts the artist to call `refreshStanding` from their
  own wallet. The artist pays the gas, and their recovery standing is current from then on.
- **A network keeper is optional.** It is a later safety net, not part of the launch. Such a
  keeper watches the delegation contract for use-case-999 registrations involving a
  registered artist's wallets, and refreshes that artist.
- **On Sepolia,** call it by hand, as the artist would:

  ```bash
  cast send <ArtistRegistry> "refreshStanding(uint256)" <artistId> \
    --rpc-url "$SEPOLIA_RPC_URL" --account <artist>
  ```

- **If the consolidation source cannot read** (a call reverts with
  `DelegationReadFailed`, for example after a gas repricing): staging, heartbeats and
  `refreshStanding` revert until it is fixed. Registrations and executions go ahead and skip
  their standing refresh, emitting `StandingRefreshSkipped(artistId)`; nobody loses standing.
  1. Confirm the failure with a direct read of the adapter (`effectiveAt`) and of the
     delegation contract.
  2. If the adapter needs replacing, deploy and review a new one and schedule
     `setConsolidationSource` (SUCCESSOR_SETTER, 30 days).
  3. Once reads work, call `refreshStanding` for every artist ID in a `StandingRefreshSkipped`
     event since the outage began.

### 13. To do: test the state-gas reservoir (CALLS-3)

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

D67 and D98 say no 6529 entity holds a privileged role from 2027-01-01, and a role handover
takes 60, 44 or 32 days (the 30-day grant operation plus the role's grant delay), so the owner
decided on 1 November 2026 that mainnet roles are network-held from day one. This does not apply to Sepolia,
whose rehearsals keep the owner's keys ([accounts](#1-accounts)).

| Holder | Roles | Who |
| --- | --- | --- |
| Community council multisig | The delayed roles: ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER (the hot admin Safe's roles, with execution delays of 48 hours to 30 days) | A Safe of about 5 of 9 independent signers, none from 6529 |
| Security council multisig | The immediate roles: PAUSER and GUARDIAN | A smaller Safe of independent signers |
| Curation signer | CURATION_SIGNER | A dedicated key that signs only the published TDH-vote result |

Later, on-chain TDH governance takes the roles over through ordinary role grants (and the
revocation of the councils' roles), each in its class's delay.

**Open before a mainnet genesis** (not decided yet):
- **The operational keys and the cold recovery admin have no named holders.** Decision 18 does
  not cover PLATFORM, CURATOR, STORAGE_OPERATOR or the cold recovery admin (the second ADMIN
  Safe, which acts only for [admin recovery](#admin-recovery)). Who holds them on mainnet,
  consistent with D67 and D98, needs an owner decision.
- **Three guardian Safes.** Off anvil the deploy requires at least three GUARDIAN Safes whose
  signers are disjoint from each other's and from the admin Safes' (`DeployGuards`), while
  decision 18 names one security-council multisig. How the security council fills those seats
  is not decided.
- **No deploy-side guard for decision 18 exists yet.** Nothing in the scripts refuses a mainnet
  configuration that breaks it; until one is built, the checklist below is the only check.

### Mainnet genesis checklist

Before the mainnet broadcast, besides the [Sepolia runbook](#sepolia-runbook) steps:

1. The community council and the security council Safes exist, with the signers and thresholds
   above, and none of their signers is a 6529 entity or key; check each Safe's owners by hand
   ([Safe pre-flight](#2-safe-pre-flight)).
2. The genesis configuration gives ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER and
   SUCCESSOR_SETTER to the community council, and PAUSER and GUARDIAN to the security council,
   in as many Safes as the deploy requires (the open item above).
3. The curation signer keys are dedicated to signing the published TDH-vote result, and are
   held outside 6529.
4. The owner has decided who holds the operational keys and the cold recovery admin (the open
   item above), and the genesis configuration names them.
5. Every holder is checked against decision 18 by hand, or by a deploy-side guard once one
   exists, and Verify reads every role holder back ([step 11](#11-verify-after-5-days)).
6. The VRF subscription owner is the community council (it must hold ADMIN and
   PARAMETER_SETTER; Verify checks it).

## Operating procedures

The contracts do not enforce these procedures; they make the enforced rules effective. The
rules themselves, including the cancellation Rules 1 to 3 cited below, are in the
[governance spec](../docs/spec/governance.md#cancellation-rules).

### Guardian liveness and monitoring

- **Two honest guardians online at all times.** A guardian cannot cancel its own removal
  (Rule 2), so one may be the target of a hostile revocation while another cancels it. With one
  guardian online, a compromised admin removes it in 30 days, and nothing then stops a target
  takeover (`test_Residual_LivenessNeedsTwoHonestGuardiansOnline`). The code floor is two
  guardians (`GovernanceConfig.MIN_GUARDIANS`); off anvil the deploy requires three
  (`DeployGuards.MIN_GUARDIANS`), 2-of-3 each (ADR 0003, owner decision 3).
- **Monitoring.** Alert every guardian on the manager's `OperationScheduled`, `RoleGranted`,
  `RoleGrantDelayChanged`, `TargetAdminDelayUpdated` and `RoleSuspended` events. A hostile
  admin operation waits at least its delay class (up to 30 days), and a guardian cancels it in
  that window. The pending set is every `OperationScheduled` not followed by
  `OperationExecuted` or `OperationCanceled` with the same operation ID and nonce, and not yet
  one week past its ready time; Verify fails while any is pending on the manager, unless
  `ALLOW_PENDING_OPERATIONS=1`. On mainnet, also alert on the VRF coordinator's
  `SubscriptionCanceled`, `SubscriptionConsumerRemoved` and `SubscriptionOwnerTransferRequested`
  for the subscription ID ([step 7](#7-chainlink-vrf-the-entropy-module)).
- **Operation expiry.** An operation must execute within one week of becoming ready
  (`expiration()`). After that `execute` reverts with `AccessManagerExpired`, and the operation
  must be scheduled again with the full delay.

### Emergencies

- **Pausing** is immediate (PAUSER). Unpausing is a 48-hour UNPAUSER operation that any
  guardian can cancel. The adapters and the auction also refuse an unpause, a `resume` or a
  dispute `cancel` until 48 hours after the pause they end (review finding GOV-5), so one
  scheduled before the pause cannot land inside it.
- **Pausing the edition auction pauses the English auction's starts too** (LC-2). While the
  edition auction is paused (at least 48 hours) it refuses `open`, and an edition master whose
  1/1 starts and closes in that time can never get an edition sale from it (LIM-EA-11). Pause
  `EnglishAuction` with it (its `pause()` stops `start` and `startWithBid`; running 1/1s are
  unaffected) and unpause both together.
- **A dispute cancel cites the latest outcome.** `EnglishAuction.cancel(saleId, outcomeRef)`
  needs `outcomeRef` to be the token's latest `DISPUTE_OUTCOME` statement recorded after the
  pause (`OutcomeNotRecorded` otherwise). A correction recorded after the cancel is scheduled
  makes the scheduled call revert, and rescheduling takes another 48 hours, which can pass the
  pause's 7-day lapse (`MAX_PAUSE`), after which the auction resumes. Record the final outcome
  first, then schedule the cancel early in the window.
- **A compromised operational key.** Any guardian Safe calls `manager.suspend(role, key)` for a
  PLATFORM, CURATOR or STORAGE_OPERATOR key; the key stops in the same block. Pause the affected
  targets as well where they have a pause. The hot admin then schedules `revokeRole(role, key)`
  and the grant of a replacement key (30 days, then the role's grant delay). If the same key is
  also the marketplace owner, schedule `setOwner` on Stream and Editions as well (FUNDS_SETTER,
  14 days).
- **A compromised curation signer.** Signers cannot be suspended. A guardian calls the curation
  verifier's one-way `disableSigner(key)`, which cuts the key off at once. Re-enabling it is a
  30-day SUCCESSOR_SETTER action and starts a new curation signer epoch, so no earlier approval
  counts again.
- **Suspensions last.** No guardian can lift a suspension, and nobody can cancel one. It ends
  when a 30-day ADMIN `grantRole` of that role to that account executes (the key acts again), or
  a `revokeRole` (the key loses the role), or when the key renounces the role itself. Plan for
  30 days after a mistaken suspension, about 60 days if a dishonest guardian suspends keys (it
  cancels each lift until its own removal executes), and about 90 days if it acts with a
  compromised hot admin.

### Rotating a guardian

- **Cooperative: grant the replacement first, then revoke.**
  1. Schedule `grantRole(GUARDIAN, new, 0)` and `grantRole(PAUSER, new, 0)`.
  2. Once both are active (30 days to execute, then GUARDIAN's 30-day grant delay), schedule
     `revokeRole(GUARDIAN, old)` and `revokeRole(PAUSER, old)`.

  The departing guardian cannot cancel its own removal; the others can. The guardian count
  never drops below the configured number.
- **Compromised: revoke first.** Only the other guardians, or the admin that scheduled it, can
  cancel the revocation (Rules 2 and 3). While still active, the guardian can cancel a grant to
  its replacement (`test_GuardianCanCancelGrantOfAReplacement`), so schedule the grant once the
  revocation has executed. Suspensions it made outlast its removal until an admin lifts them.

### Rotating the hot admin Safe

For a cooperative rotation; a compromised hot admin is removed by
[admin recovery](#admin-recovery) instead.

1. The old admin schedules grants of ADMIN, UNPAUSER and the three setter roles to the new
   Safe, each at its class delay (`Roles.executionDelay`).
2. Guardians, the old admin or the cold admin cancel every other pending operation of the old
   admin (the pending set under [Monitoring](#guardian-liveness-and-monitoring)). A revocation
   the old admin scheduled can be cancelled only by itself or a guardian (Rule 3).
3. Execute the grants after 30 days and wait for the grant delays: 48 hours for UNPAUSER and
   PARAMETER_SETTER, 14 days for FUNDS_SETTER, 30 days for SUCCESSOR_SETTER and ADMIN.
4. The old admin renounces every role, which is immediate. Its remaining scheduled operations
   can no longer execute.
5. On mainnet, transfer the VRF subscription to the new Safe (Verify requires its owner to hold
   ADMIN and PARAMETER_SETTER). Re-run Verify in epoch mode ([step 11](#11-verify-after-5-days))
   and publish the change as a governance manifest.

### Onboarding a target after genesis

Deploy the target with `authority` set to the manager, then:

1. schedule `setTargetAdminDelay(newTarget, 30 days)` and one `setTargetFunctionRole` per
   selector, each a 30-day admin operation the guardians can cancel;
2. execute them, for example in one `multicall`, where each call consumes its own schedule;
3. wait `minSetback()` (5 days);
4. read the manager back with the target added to the configuration
   (`GovernanceConfigurator.verify`, `test_OnboardATargetAfterGenesis`).

### The edition auction keeper

Every step of an edition sale is permissionless; a keeper (any funded EOA, no role) batches
them so that nothing waits ([ADR 0005](../docs/adr/0005-stream-editions-auction.md)):

1. **Open the edition auction right after every edition-master start** (owner decision 7):
   `UniformEditionAuction.open(editions, tokenId, abi.encode(item))`, the master's
   EDITION_MASTER package item, in the same batch as the keeper's own starts, and for starts by
   anyone else as soon as the English auction's `SaleStarted` for an `EDITION_MASTER` work
   appears. `open` also binds the edition to the adapter. An auction nobody
   opens before the 1/1's end plus the close offset can never be opened by this adapter
   (LIM-EA-11); a later admitted adapter of the edition's kind still can.
2. **Create the edition once the 1/1 settles:** `Editions.createEdition(tokenId, item,
   packageRoot, proof)`. A sale with winners settles only once the edition exists
   (`EditionNotCreated`; LIM-EA-12).
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

### Replacing one of Stream's dependencies

`Stream.setDependency(kind, expected, next)` (SUCCESSOR_SETTER, 30 days, owner decision 16)
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
- **No edition sale with winners may be OPEN or SETTLING across a package-registry switch**, and
  every edition such a sale needs must exist: settle those sales and create their editions
  first. An open sale settles only after its close, so new 1/1 starts must stop (pausing
  `EnglishAuction`, as in [Emergencies](#emergencies)) early enough for every running sale to
  close and settle before the switch executes. A successor that cannot create an earlier master's edition leaves such a sale on
  `EditionNotCreated`, its bidders unable to withdraw or claim until governance reverses the
  switch (another 30 days).

| Replaced | Who else holds it | The replacement set | Without a Stream redeploy? |
| --- | --- | --- | --- |
| Entropy module | Nobody: the renderer and `WorkRecords` ask Stream | A new `VrfEntropyModule` pinned to Stream's current package registry, added as a consumer of a funded subscription ([step 7](#7-chainlink-vrf-the-entropy-module)); then `setDependency("ENTROPY_MODULE")`. Seeds requested from the old module but not yet started are requested again from the new one. Keep the old module deployed: the works minted under it read their seeds from it. | Yes |
| Economics resolver | `EnglishAuction` (immutable: the federated fee recipient and the asset allowlist; since owner decision 17 Stream, not the auction, reads the museum) and `UniformEditionAuction` (it holds no resolver: a sale pays exactly the terms `Editions.bindMinter` locks and returns, one source of truth since ADR 0005 §12; but it reads the 1/1's clock from its immutable English auction, so it is replaced with it) | A new resolver whose `splitFactory()` is Stream's (Stream derives sellers with its own immutable factory and Editions with the resolver's; `setDependency` does not check it), a new `EnglishAuction` and a new edition auction on it; then `setDependency("ECONOMICS")`, `Stream.setAdmittedMinter` (the new auction in, the old out: one adapter per kind, ADR 0005) and the same on Editions. Sales running on the old adapters finish there: their fees follow the terms locked at mint or at open, while an unsold 1/1 goes to the NEW resolver's museum, since Stream reads `museum()` from its current resolver when it settles (owner decision 17). | Yes |
| Package registry | `VrfEntropyModule` (pinned registry), `ArtistRegistry` (its only `register` caller: `setPackageRegistry`, SUCCESSOR_SETTER, 30 days) | A successor registry pinned to the current artist registry, bound to the existing Stream and Editions (`bindStream`, `bindEditions`: one-shot per instance, so a new instance binds), plus a new entropy module pinned to it; then, in one batch, `setDependency("PACKAGE_REGISTRY")`, `ArtistRegistry.setPackageRegistry(old, successor)`, so new artists register through the successor (`test_AReplacementPackageRegistryRegistersNewArtists`), and `setDependency("ENTROPY_MODULE")`. The successor MUST read its predecessor's state: approved packages, consumed content (or content minted before would mint again), edition claims (or `createEdition` refuses every master minted before) and releases (or `releaseContent` refuses every work burned before); it must also keep `consume`'s ABI, which Stream calls (LIM-GV-17). Today's `PackageRegistry` reads none of it: the successor is new code. | Yes, with new code |
| Artist registry | `SplitFactory` and every `SplitWallet` (the payout resolver, pinned by code hash), `PackageRegistry` (pinned), `StatementLog` (`setArtistResolver`, 30 days) | A registry carrying every identity, authority, pending change and recovery; a successor package registry pinned to it (row above); `StatementLog.setArtistResolver`; the new registry's one-shot binds. | **No, not completely.** Stream's split factory is immutable, so every Stream work, existing or future, resolves its artist payouts through the genesis artist registry: a replacement moves authority (creator, records consent, statements) but never payouts, and an artist known only to the replacement cannot release Stream proceeds. The genesis registry would have to be kept in step for every identity change, by hand. |

One limit follows ([LIM-GV-16](../docs/audit/known-limitations.md#trust-and-governance)): the
genesis artist registry is permanent for Stream's payouts. A replacement package registry does
onboard new artists: the artist registry's one `register` caller is replaced with it, in the
same batch (`ArtistRegistry.setPackageRegistry`).

### Publishing a configuration epoch

Schedule `StatementLog.appendGovernanceManifest` (SUCCESSOR_SETTER, 30 days) with the epoch's
other operations, so the manifest's hash is public before they take effect. Once they have
executed, run Verify in epoch mode with `GOVERNANCE_CONFIG` and `GOVERNANCE_MANIFEST_PATH`
([step 11](#11-verify-after-5-days)).

## Admin recovery

The cold recovery admin Safe holds ADMIN only and stays offline. It acts in one case: the hot
admin Safe is lost or compromised (owner decision 2).

1. **Pause and suspend if needed.** A guardian pauses the affected contracts while the
   recovery runs, and suspends any operational key the hot Safe could have reached
   (`manager.suspend`).
2. **Schedule the removal.** The cold Safe schedules `revokeRole(role, hotSafe)` on the
   manager for each of the hot Safe's roles: ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER and
   SUCCESSOR_SETTER. In the Safe transaction builder, each is
   `manager.schedule(manager, revokeRole(role, hotSafe), 0)`. ADMIN's 30-day execution delay
   applies to each. Schedule nothing else yet.
   - **The hot Safe cannot cancel its own removal.** `WorksAccessManager` lets no one but the
     scheduler cancel the revocation of their own role, and no admin cancel another
     account's revocation (Rules 2 and 3).
   - **The guardians can cancel any operation.** They must know of the recovery and let these
     through, and keep cancelling anything the compromised hot Safe schedules.
3. **If a guardian cancels the removal,** treat that guardian as compromised too. The cold
   Safe schedules `revokeRole(GUARDIAN, guardian)` and `revokeRole(PAUSER, guardian)`. Only
   the other guardians may cancel those. After 30 days it executes them, then schedules the
   hot Safe's revocations again (step 2).
4. **Execute after 30 days.** The cold Safe calls `manager.execute` for each revocation. The old
   hot Safe loses its roles at once.
5. **Only then appoint the new hot Safe.** Schedule
   `grantRole(role, newHotSafe, Roles.executionDelay(role))` for the same five roles, and
   execute them after 30 days. Revocations go first: a hot Safe that still holds ADMIN can
   cancel any grant scheduled before its removal executes. The new Safe holds each role after
   that role's grant delay: 48 hours for UNPAUSER and PARAMETER_SETTER, 14 days for
   FUNDS_SETTER, and 30 days for SUCCESSOR_SETTER and ADMIN.
6. **Move the VRF subscription.** On mainnet the hot Safe owns it ([step 7](#7-chainlink-vrf-the-entropy-module)),
   and governance cannot take it over. Create a subscription owned by the new hot Safe, fund
   it, add the module as its only consumer, and have the new Safe schedule the module's
   `setConfig` to it (PARAMETER_SETTER, 48 hours).
7. **Re-verify in epoch mode.** Copy the genesis file, replace the old hot Safe's entries with
   the new one, and run Verify with `GOVERNANCE_CONFIG` set to the copy, after the last grant
   delay:

   ```bash
   DEPLOYMENT=deployments/<chainId>/<timestamp>.json GOVERNANCE_CONFIG=config/<epoch file> \
     forge script script/Verify.s.sol --rpc-url "$RPC_URL"
   ```

   The current-state checks use the copy. The genesis event checks keep the recorded genesis
   file, and every genesis holder the copy drops must hold no record any more. Publish the
   change as a governance manifest (`appendGovernanceManifest`).

**Rehearse this once on Sepolia** with the throwaway Safes, end to end, before mainnet.

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
| `DEPLOYMENT` | (Verify) | The record to verify |
| `GOVERNANCE_CONFIG` | (Verify) unset: the genesis file | Epoch mode: a copy of the genesis file with the current holders, for readback after a governance change |
| `GOVERNANCE_MANIFEST_PATH` | (Verify) unset | Epoch mode: the epoch's manifest file; it must be recorded on chain and name the `GOVERNANCE_CONFIG` file's SHA-256 |
| `ALLOW_PENDING_OPERATIONS` | (Verify) `0` | `1` logs pending manager operations instead of failing on the first |
| `MANIFEST_PATH` | (Verify) the recorded path | The manifest file to hash again |
