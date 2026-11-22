# fork

Tests against the real external systems v1 depends on, on a local fork of Ethereum mainnet or
Sepolia. Nothing is broadcast: a fork is a local copy of the chain, so a test may write to it
(register delegations, create a VRF subscription, deploy the whole system) without sending a
transaction.

They are opt-in. Without an RPC URL every test here is skipped and costs nothing, so the default
`forge test` (and CI) never touches the network.

| Variable | What it enables |
| --- | --- |
| `FORK_MAINNET_RPC` | The mainnet tests: the delegation contract, Permit2 and the Safe tests. |
| `FORK_SEPOLIA_RPC` | The Sepolia tests: the delegation contract, Permit2, the VRF coordinator and the deploy simulation. |
| `FORK_MAINNET_RPC_BLOCK`, `FORK_SEPOLIA_RPC_BLOCK` | Optional: the block to fork at (default: eight blocks behind the head, which every node behind a load-balanced public endpoint already serves). A pinned block lets Foundry cache the RPC reads between runs. |

```bash
export FORK_MAINNET_RPC=https://ethereum-rpc.publicnode.com
export FORK_SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
forge test --match-path "test/fork/*" -vv
```

PowerShell: `$env:FORK_SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"`, and the same
for `FORK_MAINNET_RPC`. publicnode serves no archive state, so a `_BLOCK` pin must be within about
128 blocks of the head on its first run (Foundry's RPC cache serves later runs). Any archive-free RPC works; a public endpoint may rate-limit, so rerun a
test that fails with an RPC error before reading anything into it. The whole directory takes
about 20 seconds against the public endpoints.

## What runs

The system is deployed by the same deploy library as the integration tests
([`WorksForkBase.sol`](WorksForkBase.sol) overrides only the external systems), against:

| File | Real dependency | What is checked |
| --- | --- | --- |
| [`DelegationFork.t.sol`](DelegationFork.t.sol) | The 6529 delegation contract (mainnet `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, Sepolia `0x8f86c644f845A077999939C69Bc787662377d915`), read through the deployed `ConsolidationAdapter` | Its code hash is the pinned one; a two-way consolidation counts from the later registration and is established 30 days later; one-way, specific-collection and expired registrations do not count; revocation ends it; a full bounded scan fits the read stipend; the integration mock answers as the real contract for the same history; and a consolidated wallet signs a recovery the artist registry executes. |
| [`SafeCoreNetwork.t.sol`](SafeCoreNetwork.t.sol) | Safe v1.4.1 singleton, proxy factory and fallback handler | The plain core with a 2-of-3 Safe as the network: a module waits `moduleDelay()` read from the contract and anyone activates it; a changed delay applies to later proposals while a pending one keeps its time; a minter is removed at once; `rescue` and `rebind` wait `rescueDelay()` and `rebindDelay()` since the removal, and a changed value decides; `Directory.unclaimedPeriod` is set at once. The same flows run without a fork in `test/governance/CoreNetwork.t.sol`. |
| [`VrfFork.t.sol`](VrfFork.t.sol) | Chainlink VRF v2.5 coordinator on Sepolia (`0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B`) | The code hash sepolia-r3 pinned; a new native-funded subscription with the entropy module as consumer; `requestSeed` reaches the coordinator, which logs the request with r3's gas lane, confirmations and callback gas; a simulated fulfilment (the real one needs the oracle's VRF proof) delivered within the callback gas lets the VRF work start and its seed render; nobody but the coordinator fulfils. |
| [`DeploySimulationFork.t.sol`](DeploySimulationFork.t.sol) | Everything `Deploy.s.sol` touches on Sepolia | The full deploy script with sepolia-r3's inputs (its accounts on the committed policy, fee recipient, marketplace owner, VRF gas lane and limits, epoch-0 manifest; r3's fee Safe as the museum, which r3 predates; a new VRF subscription, as the runbook creates for each deployment) under a fresh namespace: every off-anvil guard passes against the live Safes and dependencies (the Safe singleton, module and guard checks included), and `Verify.s.sol` confirms the simulated deployment five days later, once the new entropy module is its subscription's only consumer. |
| [`SafeNetwork.t.sol`](SafeNetwork.t.sol), [`SafeAccounts.t.sol`](SafeAccounts.t.sol) (base [`SafeForkBase.sol`](SafeForkBase.sol)) | Safe v1.4.1 (singleton, proxy factory, `MultiSendCallOnly`, `CompatibilityFallbackHandler`), code-hash pinned | The network as a 2-of-3 Safe: genesis acceptance by a Safe transaction, delayed setters scheduled and executed through the manager in MultiSend batches, a stale revision reverting the whole batch, the no-delay signer kill, unpause, the brake, handover to a second Safe. A Safe as an artist wallet signing wallet-prefixed ERC-1271 proofs (acceptance, move, royalty consent), a relayed statement and a signed release, invalidated by an owner swap. A Safe as payee, bidder and 721/1155 receiver, museum and fee destination. |

The Sepolia inputs are those of r3 (r4, deployed on 1 November 2026, now supersedes it; r4 shares
r3's holders)
([deployment record](../../deployments/11155111/README.md#sepolia-r3-15-october-2026-superseded-by-r4)).
The simulation uses the committed example with r3's accounts, as a new rehearsal would (r3's
hot admin Safe as the network, its guardian Safes as the pausers, its keys), so it follows the
committed policy as it changes; the proposed network accepts before Verify runs. r3's own
`config/sepolia-r3/genesis.json` predates the single network address and is no longer a valid
genesis; `test_TheR3SafesPassTheHolderGuards` checks r3's live Safes through the example.
