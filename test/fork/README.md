# fork

Tests against the real external systems v1 depends on, on a local fork of Ethereum mainnet or
Sepolia. Nothing is broadcast: a fork is a local copy of the chain, so a test may write to it
(register delegations, create a VRF subscription, deploy the whole system) without sending a
transaction.

They are opt-in. Without an RPC URL every test here is skipped and costs nothing, so the default
`forge test` (and CI) never touches the network.

| Variable | What it enables |
| --- | --- |
| `FORK_MAINNET_RPC` | The mainnet tests: the delegation contract and Permit2. |
| `FORK_SEPOLIA_RPC` | The Sepolia tests: the delegation contract, Permit2, the VRF coordinator and the deploy simulation. |
| `FORK_MAINNET_RPC_BLOCK`, `FORK_SEPOLIA_RPC_BLOCK` | Optional: the block to fork at (default: eight blocks behind the head, which every node behind a load-balanced public endpoint already serves). A pinned block lets Foundry cache the RPC reads between runs. |

```bash
export FORK_MAINNET_RPC=https://ethereum-rpc.publicnode.com
export FORK_SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
forge test --match-path "test/fork/*" -vv
```

PowerShell: `$env:FORK_SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"`, and the same
for `FORK_MAINNET_RPC`. Any archive-free RPC works; a public endpoint may rate-limit, so rerun a
test that fails with an RPC error before reading anything into it. The whole directory takes
about 20 seconds against the public endpoints.

## What runs

The system is deployed by the same deploy library as the integration tests
([`WorksForkBase.sol`](WorksForkBase.sol) overrides only the external systems), against:

| File | Real dependency | What is checked |
| --- | --- | --- |
| [`DelegationFork.t.sol`](DelegationFork.t.sol) | The 6529 delegation contract (mainnet `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, Sepolia `0x8f86c644f845A077999939C69Bc787662377d915`), read through the deployed `ConsolidationAdapter` | Its code hash is the pinned one; a two-way consolidation counts from the later registration and is established 30 days later; one-way, specific-collection and expired registrations do not count; revocation ends it; a full bounded scan fits the read stipend; the integration mock answers as the real contract for the same history; and a consolidated wallet signs a recovery the artist registry executes. |
| [`Permit2Fork.t.sol`](Permit2Fork.t.sol) | Canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) | Its EIP-712 domain; relayed, witness-bound intents signed with test keys for a fixed-price purchase, a Dutch purchase (exactly the current price is pulled) and an ERC-20 auction's start-with-bid and outbid; a replayed nonce (`InvalidNonce`), an intent for another recipient (`InvalidSigner`) and an expired one are refused. The digests are computed from the EIP-712 definitions, not from the integration mock. |
| [`VrfFork.t.sol`](VrfFork.t.sol) | Chainlink VRF v2.5 coordinator on Sepolia (`0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B`) | The code hash sepolia-r2 pinned; a new native-funded subscription with the entropy module as consumer; `requestSeed` reaches the coordinator, which logs the request with r2's gas lane, confirmations and callback gas; a simulated fulfilment (the real one needs the oracle's VRF proof) delivered within the callback gas lets the VRF work start and its seed render; nobody but the coordinator fulfils. |
| [`DeploySimulationFork.t.sol`](DeploySimulationFork.t.sol) | Everything `Deploy.s.sol` touches on Sepolia | The full deploy script with sepolia-r2's inputs (its holders on the committed policy, fee recipient, marketplace owner, VRF gas lane and limits, epoch-0 manifest; a new VRF subscription, as the runbook creates for each deployment) under a fresh namespace: every off-anvil guard passes against the live Safes and dependencies (the Safe singleton, module and guard checks included), and `Verify.s.sol` confirms the simulated deployment five days later, once the new entropy module is its subscription's only consumer. |

r2's own `config/sepolia-r2/genesis.json` predates later policy changes (the governed selectors
`Stream.releaseContent` and `EntropyModule.lowerCallbackGasLimit`, and the `manager` section), so
the committed-policy guard refuses it as it stands. The simulation therefore uses the committed
example with r2's holders, as a new rehearsal would; its holders alone are checked against the
live Safes by `test_TheR2HoldersPassTheHolderGuards`.
