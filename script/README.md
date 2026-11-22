# script

Deployment, read-back and the operating procedures of 6529 Works on the plain core
([ADR 0010](../docs/adr/0010-plain-permanent-core.md); what the system is:
[overview](../docs/overview.md)). Deployments are to a local `anvil` node or Sepolia only; the
deploy script refuses every other chain. 6529 Works is pre-audit and not deployed on mainnet.

| File | What it is |
| --- | --- |
| [`DeployCore.sol`](DeployCore.sol) | The library: predicts every address, deploys, builds the governance configuration and the genesis wiring from the genesis JSON, installs it |
| [`CoreFactory.sol`](CoreFactory.sol) | The deployer's factory: creates each contract at its predicted address in one call only the deployer may make |
| [`DeployCore.s.sol`](DeployCore.s.sol) | The broadcast script (anvil or Sepolia). It deploys, installs, accepts on anvil, reads back, prints every address and writes `deployments/<chain>/core-<timestamp>.json` |
| [`VerifyCore.sol`](VerifyCore.sol), [`VerifyCore.s.sol`](VerifyCore.s.sol) | The read-back, as a library and as a read-only script over a deployment record: every contract's runtime code against a fresh deployment of the build, and the whole wiring |
| [`DeployGuards.sol`](DeployGuards.sol) | The off-anvil checks run before anything is broadcast |
| [`ScriptIO.sol`](ScriptIO.sol) | Everything the scripts read from outside the EVM: environment, files, chain ID, the deployment parameters |
| [`local/`](local/README.md) | The local walkthrough: one command, a full sale end to end on anvil |
| [`sepolia/`](sepolia/) | The Sepolia round tooling: genesis and manifest writers, deploy, flows, Sourcify |

## How a deployment is built

- **Addresses.** The deployer first creates its `CoreFactory`, at a CREATE2 address that depends
  on `DEPLOY_NAMESPACE` and the deployer. The factory creates every contract in one call that
  only the deployer may make: a one-use proxy at a CREATE2 address that depends only on the
  factory and the contract's name creates the contract in the same call. All addresses are known
  before anything is deployed, so the tokens and `StreamDirectory6529` take their genesis modules
  and minters as constructor arguments, and nobody else can put code at any of them. An address does
  not commit to code: `VerifyCore.s.sol` compares every contract's runtime code with a fresh
  deployment of the same build and reads the wiring back.
- **Order.** Governance, `ContentStore` (and the CC0 text), `StreamWorkFacts6529`,
  `StreamDirectory6529`, the two governed vaults, `SplitLedger`, `ClaimRouter`, `RevenueEscrow`,
  `Stream6529`, `StreamEditions6529` (the permanent part), then the replaceable modules,
  `SaleStarter` last.
- **Genesis.** One `configure` call installs every role, holder and governed selector of the
  genesis file and runs the genesis wiring (the package registry's Stream bind and entropy
  module, the edition auction's target, the ETH opening bid, the Independent Stream module's
  adapters, templates and entropy module, the epoch-0 manifest). The configurator then holds
  nothing.
- **The network** is one address (a 2-of-n Safe today) that holds every network role once it
  calls `acceptNetwork()` on the manager.

From a test (see [`test/deploy/DeployCore.t.sol`](../test/deploy/DeployCore.t.sol)):

```solidity
DeployCore.Deployment memory d = DeployCore.deploy(p, address(this)); // p.deployer = caller of install
GovernanceConfig.Config memory cfg = DeployCore.config(d, json);
GovernanceConfig.Call[] memory calls = DeployCore.wiring(d, json, manifest);
DeployCore.install(d, cfg, manifest, calls);
vm.prank(cfg.network);
d.manager.acceptNetwork();
VerifyCore.verify(p, d, cfg, true);
```

## Local

```bash
forge build
bash script/local/walkthrough.sh
```

It starts anvil, deploys with anvil's public test accounts, accepts, reads back and runs a full
sale ([details](local/README.md)). To deploy only:

```bash
python script/local/make_genesis.py
GENESIS_CONFIG=config/local/genesis.core.anvil.json ACCEPT_NETWORK=1 \
  forge script script/DeployCore.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

## Sepolia

The operator holds every key; nothing in the repository reads, prints or stores one. Signing
goes through a PowerShell module kept outside the repository (`-SignerModule`, exporting
`Invoke-Signed` and `Invoke-Tool`). RPC URLs with credentials stay in the operator's shell.
Forge's `broadcast/` output is not committed; the deployment record is.

### 1. Accounts and inputs

| Account | What it does |
| --- | --- |
| Deployer | Sends every deploy transaction and `configure`; holds nothing afterwards |
| Network | A Safe: canonical singleton, threshold at least 2, plain-key owners, no module, no guard. It calls `acceptNetwork()` after the deploy |
| Pausers (3), curation signers (2), storage operator, platform, curator | The genesis file's holders. Curation signers sign off-chain only |
| Network fee recipient, museum, marketplace owner | No role. Existing accounts, named in `deploy.env` |
| Keeper | No role. Runs the permissionless steps ([`keeper/`](../keeper/README.md)) |

A round's public inputs live in `config/sepolia-<round>/`: `accounts.json` (holders and the
network Safe), `genesis.json`, `deploy.env` and `manifest-epoch0.json`. Round r6 reuses r5's
network Safe and holders.

### 2. Genesis and manifest

```bash
python script/sepolia/make_genesis.py r6 r5        # the committed policy with r5's holders
python tools/check_genesis.py --config config/sepolia-r6/genesis.json
python script/sepolia/make_manifest.py r6 r5 <commit>            # first pass: no addresses
./script/sepolia/deploy.ps1 -SignerModule <path> -EnvFile config/sepolia-r6/deploy.env -Log sim.txt
python script/sepolia/make_manifest.py r6 r5 <commit> sim.txt    # second pass: the addresses
```

Simulate again after the second pass: no address may move (the manifest's hash is not an
input to any address).

### 3. Simulate, then broadcast

`deploy.ps1` without `-Broadcast` simulates: it runs every check of `DeployGuards` (the
network is a bare Safe, every holder reachable and none a contract of the deployment, the
policy is the committed one, no brake) and prints every address. r6's simulation needed 37
transactions (the factory, one per contract, the install) and forge estimated 143,847,103 gas in
total (Prague pricing, with forge's 1.3 multiplier).

Sepolia reprices state creation, which forge cannot simulate: the broadcast skips forge's
replay and takes each limit from the node's `eth_estimateGas` (`--skip-simulation --slow`).
The largest creation measured on Sepolia was the Renderer's, 38,217,377 gas by publicnode's
`eth_estimateGas` (with the deployer's factory supplied as a state override, since it does not
exist before the broadcast); several creations cannot be estimated before the contracts they read exist,
so broadcast through an endpoint with a higher estimate cap:

```powershell
./script/sepolia/deploy.ps1 -SignerModule <path> -EnvFile config/sepolia-r6/deploy.env `
  -Broadcast -Rpc https://sepolia.gateway.tenderly.co -Log run.txt
```

A broadcast that stops partway resumes with `-Resume`.

### 4. After the broadcast

1. **The network accepts.** The Safe calls `acceptNetwork()` on the manager
   (`flows.ps1 -Step safeCall -Safe <network> -To <manager> -Data 0xa503fb3e -Label acceptNetwork`).
2. **Read back.** `DEPLOYMENT=deployments/11155111/core-<timestamp>.json` plus the `deploy.env`
   variables, then `forge script script/VerifyCore.s.sol --rpc-url <rpc>`, after the network has
   accepted (it refuses before, off anvil). It checks the permanent wiring, the genesis modules
   and minters (and that nothing else of the deployment mints), the four settings at their
   launch values, every module's manager and wiring, the effect of every genesis wiring call and
   the governance configuration; then it deploys the same build again in memory from the
   record's `forkBlock` and compares every contract's address and runtime code with the chain's.
   The endpoint must serve the state of `forkBlock` (an archive endpoint such as
   `https://sepolia.gateway.tenderly.co`, or run it soon after the deploy).
3. **VRF.** The subscription owner adds the entropy module as a consumer and funds the
   subscription.
4. **Sourcify.** `./script/sepolia/sourcify.ps1 -Record <record> -Out sourcify.json`, from the
   deployed commit after `forge build`.
5. **Gas table.** `python script/sepolia/deploy_gas.py deploy-gas.json <record>`.
6. **Flows.** `./script/sepolia/flows.ps1 -SignerModule <path> -State <state.json> -Record <record> -Step <step>`
   (steps and examples are in the script's header; `-Step prague` replays each transaction at
   Prague prices).

## Operating procedures

The contracts do not enforce these procedures; they are the network's current practice. The
rules are in the [governance spec](../docs/spec/governance.md); who may call what is in the
[role matrix](../docs/audit/roles.md).

### Modules and minters

`Stream6529`, `StreamEditions6529`, `StreamDirectory6529` and every Independent Stream token hold
their rules in replaceable modules, in named slots: `RENDERER`, `TERMS` and `RECORDS` on the tokens;
`ACCOUNTS`, `INDEPENDENT_STREAM`, `INDEPENDENT_TERMS` and `INDEPENDENT_RECORDS` on
`StreamDirectory6529`. Sale contracts are minters.

| Step | Call | Who | When |
| --- | --- | --- | --- |
| Announce a module | `proposeModule(slot, module)` | The network | Any time; the module must have code. It becomes ready `moduleDelay` later. A new proposal for the same slot replaces the pending one |
| Activate it | `activateModule(slot)` | Anyone | From the ready time |
| Withdraw an announcement | `cancelModule(slot)` | The network | At once, before the module takes effect; the installed module stays |
| Remove a module | `removeModule(slot)` | The network | At once; it also clears a pending proposal |
| Add a minter | `addMinter(minter)` | The network | Active `moduleDelay` later |
| Remove a minter | `removeMinter(minter)` | The network | At once. It still finishes the sales it started |
| Rescue a token | `Stream6529.rescue(tokenId, to)` | The network | `rescueDelay` after its minter was removed, for a token with no outcome |
| Rebind an edition | `StreamEditions6529.rebind(editionId, minter)` | The network | `rebindDelay` after its minter was removed, for an edition with no copies and no seal |

An Independent Stream token's own `RENDERER` slot is its artist's. A finalized work keeps the
renderer it pinned whatever the slot holds later.

### The four settings

Each is a value stored in a permanent contract. The network changes it at once, to any value
including zero; every change emits an event with the old and the new value. A pending module
keeps the ready time it was given.

| Setting | Contract | Setter | Launch value |
| --- | --- | --- | --- |
| `moduleDelay` | `Stream6529`, `StreamEditions6529`, `StreamDirectory6529` (each its own) | `setModuleDelay` | 604,800 s (7 days) |
| `rescueDelay` | `Stream6529` | `setRescueDelay` | 1,209,600 s (14 days) |
| `rebindDelay` | `StreamEditions6529` | `setRebindDelay` | 1,209,600 s (14 days) |
| `unclaimedPeriod` | `StreamDirectory6529` (read by the escrow, the split ledger and both auctions) | `setUnclaimedPeriod` | 15,552,000 s (180 days) |

The launch values are in `config/genesis.core.example.json` (`settings`) and read back by
`VerifyCore`. On Sepolia every network call goes through the Safe (`flows.ps1 -Step safeCall`).

### Points of care

- **Independent Stream tokens.** Their `rescue`, `setRescueDelay`, `rebind` and `setRebindDelay`
  pass only for a role member calling directly with no delay (the token asks the manager whether the
  caller may call the matching `StreamDirectory6529` function immediately). Keep those
  `StreamDirectory6529` roles at no delay: adding one would lock these functions, scheduled calls
  included.
- **Editions.** A sale contract can close a work's edition for good by sealing it at zero
  (`StreamEditions6529.seal(editionId, 0)` with no copies minted). Add only sale contracts that seal
  at the count sold.
- **Replacing modules.** A replacement accounts module must carry the existing artists over
  (IDs, wallets, payout addresses). A replacement mint policy starts with no content releases
  and no barred items: a burned work's content stays unmintable until the network releases it
  again there. A new instance needs its role-map entries. The checklist is in
  [Replacing a module](../docs/operations/replacing-modules.md).
- **Media locations.** A finalized work's content hashes are permanent in `StreamWorkFacts6529`;
  where its off-chain copies are served from comes from the replaceable delivery module
  (`WorkRules.setDelivery`).
- **Unclaimed shares.** An artist payee who cannot release (a frozen account, or one whose payout
  address does not resolve) can still be marked, and the share forfeited to the network after
  `unclaimedPeriod`.

### Pauses and disputes

- A pauser pauses at once; the network unpauses at once.
- A pauser pauses one 1/1 sale for a dispute (`pause(saleId, disputeRef)`), once per sale, at
  most `MAX_PAUSE` (3 days). The network resumes it, or cancels it citing the latest dispute
  outcome the platform recorded in the statement log.

### Keepers

Every keeper step is permissionless. The reference keeper ([`keeper/`](../keeper/README.md))
starts 1/1s through `SaleStarter` (auction, vaults and record in one transaction), opens the
edition auction beside every edition master, settles both auctions, finalizes records after the
notice, deploys missing vaults, and sends credits that waited `unclaimedPeriod` to the network.

## Environment reference

| Variable | On anvil | Off anvil (Sepolia) |
| --- | --- | --- |
| `GENESIS_CONFIG` | `config/genesis.core.example.json` | Required |
| `DEPLOY_NAMESPACE` | `keccak256("6529-works/core")` | Required |
| `NETWORK_FEE_RECIPIENT`, `MUSEUM`, `MARKETPLACE_OWNER` | Placeholders | Required |
| `MANIFEST_PATH` or `MANIFEST_DIGEST`, `MANIFEST_URI` | A placeholder digest | Required (`MANIFEST_PATH` is hashed with SHA-256) |
| `AUCTION_DURATION` | 24 hours | Optional; a testnet round may shorten the 1/1 auction to 1 hour |
| `ACCEPT_NETWORK` | `1` accepts in the same run | Unused: the Safe accepts |
| `VRF_COORDINATOR`, `VRF_SUBSCRIPTION_ID`, `VRF_KEY_HASH`, `VRF_NATIVE_PAYMENT`, `VRF_CALLBACK_GAS_LIMIT` (200,000), `VRF_CONFIRMATIONS` (3), `VRF_RETRY_DELAY` (3 days) | Unset: no entropy module | The round's subscription |
| `DELEGATION_CONTRACT` | A mock is deployed | Unused: the official Sepolia deployment |
| `DEPLOYMENT` | (`VerifyCore.s.sol`) the record to read back | Same |
