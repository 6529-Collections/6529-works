# fork

Tests against the real external systems the plain-core stack depends on, on a local fork of
Ethereum mainnet or Sepolia. Nothing is broadcast: a fork is a local copy of the chain, so a test
may write to it (create Safes, register delegations, create a VRF subscription, deploy the whole
system) without sending a transaction.

They are opt-in. Without an RPC URL every suite skips in `setUp` (one skipped `setUp` per suite)
and costs nothing, so the default `forge test` (and CI) never touches the network.

| Variable | What it enables |
| --- | --- |
| `FORK_MAINNET_RPC` | The Safe suites and the delegation suite on mainnet. |
| `FORK_SEPOLIA_RPC` | The delegation suite on Sepolia, the VRF suite and the deploy simulation. |
| `FORK_SEPOLIA_LOGS_RPC` | The read-back log suite. It needs a Sepolia endpoint that still serves the logs of r8's genesis (an archive endpoint such as `https://sepolia.gateway.tenderly.co`); an endpoint that has dropped old logs answers an empty list, not an error. |
| `FORK_MAINNET_RPC_BLOCK`, `FORK_SEPOLIA_RPC_BLOCK` | Optional: the block to fork at (default: eight blocks behind the head, which every node behind a load-balanced public endpoint already serves). |

```bash
export FORK_MAINNET_RPC=https://ethereum-rpc.publicnode.com
export FORK_SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
forge test --match-path "test/fork/*" -vv
```

PowerShell: `$env:FORK_SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"`, and the same
for `FORK_MAINNET_RPC`. Never commit an RPC URL. publicnode serves no archive state, so do not
pin an old block: a `_BLOCK` pin must be within about 128 blocks of the head on its first run
(Foundry's RPC cache serves later runs). Any archive-free RPC works; a public endpoint may
rate-limit, so rerun a test that fails with an RPC error before reading anything into it. The
whole directory takes about 15 seconds against the public endpoints, after compilation.

## What runs

Every suite but the deploy simulation deploys the system with the integration base
([`../integration/CoreIntegrationBase.sol`](../integration/CoreIntegrationBase.sol): `DeployCore.deploy`,
the committed genesis policy, `VerifyCore`); [`StreamForkBase.sol`](StreamForkBase.sol)
(`CoreForkBase`) selects the fork, swaps the delegation mock for the chain's real contract and
lets a suite put external accounts in place before the deployment.

| File | Real dependency | What is checked |
| --- | --- | --- |
| [`SafeNetwork.t.sol`](SafeNetwork.t.sol) (base [`SafeForkBase.sol`](SafeForkBase.sol)) | Safe v1.4.1 singleton, proxy factory, `MultiSendCallOnly`, `CompatibilityFallbackHandler` at their canonical addresses, code-hash pinned | The network as a 2-of-3 Safe governing the deployed stack by Safe transactions: it proposes a module and anyone activates it once `moduleDelay()` has passed; it removes the English auction as a minter at once and rescues the unsold work it held once `rescueDelay()` has passed; it changes three settings in one MultiSend batch, and a batch with one failing call changes nothing; it schedules and executes a 3-day setter through the manager; it hands the network to a second Safe, which accepts by a Safe transaction. Planted faults: one signature of three ("GS020") and an owner key calling the core directly are refused. The proxy the 1.4.1 factory creates has the runtime code hash the deploy guards pin; both Safe 1.3.0 factories answer the pinned 1.3.0 proxy code and a 1.3.0 Safe passes the guards; a Safe's transaction hash equals the EIP-712 digest computed from its fields, as the Sepolia flow driver computes it. |
| [`SafeAccounts.t.sol`](SafeAccounts.t.sol) | The same Safe contracts | A Safe as an artist's account signing ERC-1271 proofs: package acceptance (which creates the account), the move that starts the work, and consent to a royalty-rate change the network Safe executes through the manager; a proof below the threshold or by non-owners is refused. The artist Safe releases its share by a Safe transaction (nobody else can) and by a relayed signed release, which stops verifying after an owner swap. A Safe bids, is credited when outbid, claims, wins and receives the 721 within the auction's delivery gas. The fee and museum vaults forward ETH and an unbid work to their Safes. |
| [`SafeCoreNetwork.t.sol`](SafeCoreNetwork.t.sol) | Safe v1.4.1 singleton, proxy factory and fallback handler | `CoreNetworkFlows` (the permanent contracts with stand-in modules, `test/deploy/CoreDeployFixture.sol`) with a 2-of-3 Safe as the network: the module, minter, rescue, rebind and unclaimed-period waits read from the contracts. The same flows run without a fork in `test/governance/CoreNetwork.t.sol`. |
| [`DelegationFork.t.sol`](DelegationFork.t.sol) | The 6529 delegation contract (mainnet `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, Sepolia `0x8f86c644f845A077999939C69Bc787662377d915`), read through the deployed `ConsolidationAdapter` and `Accounts` | Its code hash is the pinned one; a two-way, all-collections consolidation counts at once; one-way, specific-collection and expired registrations do not; revocation ends it; the read stops after `MAX_REGISTRATIONS_READ` registrations per direction; the integration mock answers as the real contract for the same history; a consolidated wallet signs the artist's move and moves the account's root to itself. |
| [`VrfFork.t.sol`](VrfFork.t.sol) | Chainlink VRF v2.5 coordinator on Sepolia (`0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B`) | The code hash sepolia-r3 pinned; a new native-funded subscription with the deployed entropy module as its only consumer; `requestSeed` reaches the coordinator, which logs it with the Sepolia gas lane, confirmations and callback gas; a simulated fulfilment (the real one needs the oracle's VRF proof) within the callback gas lets the VRF work start, and the work carries and renders its seed; nobody but the coordinator fulfils. |
| [`ReadbackLogsFork.t.sol`](ReadbackLogsFork.t.sol) | An archive Sepolia endpoint's `eth_getLogs` (`FORK_SEPOLIA_LOGS_RPC`), through `script/VerifyCore.s.sol` | The logs of Sepolia r8's manager and configurator over the blocks of its genesis are the same whatever `LOG_BLOCK_RANGE` the read-back asks them in (5,000, 13, 7 and 2 blocks per request): one `GovernanceConfigured` log and the eight genesis holders each time, so no log is lost or repeated where one request ends and the next begins. |
| [`DeploySimulationFork.t.sol`](DeploySimulationFork.t.sol) | Everything `script/DeployCore.s.sol` touches on Sepolia | The deploy script run with sepolia-r5's public inputs (its live network Safe and holder keys on the committed policy, fee recipient, marketplace owner, museum, the VRF gas lane, the epoch-0 manifest; a new VRF subscription) under a fresh namespace: every off-anvil guard passes against the live accounts (the RPC's chain ID, the network a bare canonical Safe, the holders, the committed policy, no holder a deployment contract) and the readback passes; the committed example is refused off anvil; once the entropy module is its subscription's only consumer the subscription guard passes, and once r5's Safe accepts the whole governance configuration reads back. |

The genesis acceptance in the Safe suites is the integration base's (`acceptNetwork` from the
Safe's address); the handover test shows an acceptance by a Safe transaction. The deploy
simulation's acceptance is a prank of r5's Safe, whose keys the test does not hold.
