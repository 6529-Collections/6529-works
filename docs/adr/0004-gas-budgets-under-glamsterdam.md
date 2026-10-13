# ADR 0004: Gas budgets under Glamsterdam

Status: Accepted by the owner, 13 October 2026. Amends the gas budgets of
[ADR 0001](0001-v1-scope.md) and [ADR 0003](0003-build-time-decisions.md).

## Problem

Every gas budget in ADR 0001, ADR 0003 and the tests was set in Prague gas,
because that is what Foundry measures. Sepolia activated Glamsterdam on
6 October 2026, and Glamsterdam reprices state creation. Measured on Sepolia
([deployments README](../../deployments/11155111/README.md#glamsterdam-gas-on-sepolia),
[flows](../../deployments/11155111/flows.md)):

| Operation | Prague | Sepolia (Glamsterdam) |
| --- | ---: | ---: |
| New storage slot (`SSTORE` from zero) | 22,100 | about 111,000 |
| Contract code, per byte | 200 | about 1,542 |
| Contract creation (`CREATE`), empty | about 53,000 | about 210,000 |
| ETH transfer to a fresh account, as a transaction | 21,000 | about 205,000 |

The start budget breaks.
- **Measured.** On the r2 rehearsal, a steady-state `start` costs **846,963**
  gas and `startWithBid` **982,312**. Replayed with Prague costs, the same
  transactions cost 293,243 and 334,572.
- **Where the difference goes.** A steady-state start writes 6 new slots, and
  `startWithBid` writes 7. At about 89,000 more per slot than on Prague, those
  slots are most of the difference.
- **350K is out of reach.** Any `start` that mints writes at least 3 new slots:
  the owner, the consumed-content record and the sale. That is about 333,000
  gas before any execution.

Foundry 1.7.1 has no Amsterdam EVM, so CI cannot measure Glamsterdam gas at
all.

## Decision

**1. The gas budgets are execution gas at Prague costs.**
- "Execution gas at Prague costs", or Prague gas, is the whole transaction
  (intrinsic, calldata and execution) priced with Prague's schedule, state
  creation included at Prague's prices. It is what Foundry and CI measure.
- Every existing ceiling keeps its number, now labelled as Prague gas.
- A steady-state `start` and `startWithBid` stay at **350K or less**, for one
  artist and for the two-party variants.
- The other ceilings also stay:
  - the first start in a new collection, 400K;
  - `settle`, 400K;
  - `tokenURI`, 8M.

**2. A hard cap on new state per operation.** CI counts what each
transaction creates, from the state diff of the call:
- **A new slot** is a storage slot that is zero before the transaction and
  non-zero after it. A slot counts once however often it is written. A write
  that a revert undid does not count.
- **A new account** is an account that is empty before the transaction (no
  code, nonce zero, balance zero) and not empty after it: a contract creation,
  or ETH sent to a fresh address.

A steady-state `start` may write at most **6** new slots and `startWithBid` at
most **7**, for one or two parties. Every other measured operation is capped at
the count it had when this ADR was accepted, as a regression gate.
- A change that saves a slot lowers its cap in the same pull request.
- Raising a regression cap needs a stated reason in the pull request.
- Raising a start cap needs an ADR.

**3. Publish the Glamsterdam totals next to the budgets.** The table below
gives each operation's Sepolia gas from the r2 rehearsal. Mainnet's Glamsterdam
parameters may differ. Every figure will be re-measured when they are final.

**4. Restate the per-transaction cap.** EIP-7825's limit of 16,777,216 gas
applies to regular (execution) gas.
- On Sepolia, transactions whose state-creation gas took them above it were
  accepted. The largest observed used 38.4M: a `writeChunk` of 24,572 bytes.
- That is an observation of Sepolia's behaviour, not a reading of the final
  EIP mechanics.
- CI keeps testing worst-case transactions against 16,777,216 in Prague gas,
  the measure Foundry has. Whether that matches the regular gas Glamsterdam
  counts against the cap will be checked when Foundry supports Amsterdam and
  against mainnet's final parameters.

### The caps

Prague gas is from `test/integration/GasReport.t.sol` on `main` at `6889306`.
Sepolia gas is the r2 rehearsal
([flows](../../deployments/11155111/flows.md)); rows marked "simulated" were
run with `eth_simulateV1` on the live state. "—" means no ceiling, or not run
on Sepolia.

| Operation | Prague gas | Prague ceiling | New slots, at most | New accounts, at most | Sepolia gas |
| --- | ---: | ---: | ---: | ---: | ---: |
| `start`, steady state | 275,738 | 350,000 | **6** | 0 | 846,963 |
| `startWithBid`, steady state | 317,092 | 350,000 | **7** | 0 | 982,312 |
| `start`, two-party work | 284,038 | 350,000 | **6** | 0 | — |
| `startWithBid`, two-party work | 325,401 | 350,000 | **7** | 0 | — |
| `start`, first work in a new collection | 275,764 | 400,000 | 6 | 0 | 846,977 |
| `start`, first work ever (one-time) | 437,310 | — | 13 | 0 | 1,604,862 |
| `startWithBid`, first bid under new sale terms (one-time) | 387,241 | — | 10 | 0 | — |
| `bid` that outbids | 70,848 | — | 1 | 0 | 168,932 |
| `settle`, first payout to a seller wallet | 150,914 | 400,000 | 1 | 1 | 441,363 (simulated) |
| `settle`, with a bid | 120,914 | 400,000 | 1 | 0 | 257,763 (simulated) |
| `consume`, as Stream calls it | 89,029 | — | 1 | 0 | part of `start` |
| `createEdition` | 313,833 | — | 9 | 0 | 1,118,699 (simulated) |
| `openSale` (one public phase) | 274,084 | — | 8 | 0 | 993,668 (simulated) |
| `purchase`, the first copy, new holder | 178,097 | — | 3 | 0 | 468,086 (simulated) |
| `purchase`, a later copy, new holder | 160,997 | — | 2 | 0 | 370,142 (simulated) |
| `refreshStanding`, a first wallet | 125,320 | — | 2 | 0 | 299,112 (r1) |
| `refreshStanding`, a further wallet | 152,132 | — | 1 | 0 | 247,970 |
| `royaltyInfo` (view) | 43,353 | 50,000 of execution | 0 | 0 | 40,667 |
| `tokenURI` (view, the size matrix) | at most 2.7M | 8,000,000 | 0 | 0 | unchanged |

- **A rule of thumb on Sepolia's parameters:** a transaction's Glamsterdam gas
  is about its Prague gas, plus about 89,000 per new slot, plus about 184,000
  per new account. It is not a gate.
- **Where a steady-state start's 6 slots go:**
  - Stream's three-word token record and the ERC-721 owner;
  - the package registry's consumed-content record;
  - the auction's sale.

  `startWithBid` adds the bid.
- **The first payout to a payee configuration** sends ETH to its split wallet's
  predicted address, which creates that account. This happens once per
  configuration.

## Consequences

**What CI checks.**
- `test/integration/GasReport.t.sol` measures every row above on the real,
  wired contracts.
  - It gates the Prague ceilings and the slot and account caps.
  - It also checks that `tokenURI` creates no state.
  - `forge test --match-test test_Gas_Table -vv` prints the table.
- `test/helpers/StateGrowth.sol` does the counting. Its tests cover the edge
  cases on a toy contract: an overwrite, zero to zero, non-zero to zero, a
  reverted write, a `CREATE` and ETH sent to a fresh address.
- Module gas tests, such as `EnglishAuctionGas.t.sol`, keep their Prague gates.

**What CI cannot check.**
- **Glamsterdam totals.** The Sepolia column is measured by hand on a
  deployment. CI gates the count of new slots and accounts, which is the part
  of the Glamsterdam cost it can see. It does not see the price of code bytes
  in a contract creation, beyond counting the account.
- **Cold accounts.** Foundry 1.7.1's `vm.cool` cools storage but not accounts.
  The report therefore prices each account a call reaches, besides its target,
  about 2,500 gas below a real transaction.
  - A steady-state start reaches seven, so its 275,738 compares with 293,243
    when the real Sepolia start is replayed with Prague costs.
  - Both replays, 293,243 for `start` and 334,572 for `startWithBid`, are
    within 350K.
- **Two Foundry quirks shape the harness.**
  - Recording a state diff warms what it reads.
  - Once a recording has run in a test, `vm.cool` stops cooling storage for the
    rest of that test.

  So every row runs twice from one snapshot: measured first, then recorded. A
  probe fails any measurement whose cooling did not work.

**What happens next.**
- **Re-measure on mainnet.** When mainnet's Glamsterdam parameters are final,
  re-measure the Sepolia column on a deployment that uses them. Do the same
  for the per-byte storage costs.
- **When Foundry supports Amsterdam,** consider gating Glamsterdam gas
  directly. `vm.lastCallGas` already declares a `gasStateUsed` field that
  Foundry 1.7.1 does not return.
- **Content storage costs** about 1,548 gas per byte on Sepolia, against 218 on
  Prague: about 1.65 ETH per MiB at 1 gwei. The content module and its tooling
  restate their guidance separately. This ADR only records the measurement.

## Alternatives considered

- **A: keep 350K as a Glamsterdam total.** This is unreachable, because any
  minting start writes at least 3 new slots.
- **B: a slot diet.** This is deferred, not rejected: it is an optimisation
  candidate.
  - Stream's per-token words could go from four to three, by storing the
    economics fields as a deduplicated terms ID, as the auction already does.
    A steady-state start would then cost about 760K on Sepolia.
  - The Editions record and the fixed-price listing with its phase (8 new
    slots each) could be halved, saving about 350K each on `createEdition` and
    `openSale`.
  - The slot caps make any such saving visible and keep it.
- **C: a redesign for minimal state.** This is rejected. Any design keeps
  the essential records: the owner, the consumed content and the sale. A
  redesign could remove little more than B does, and it would reopen modules
  that have been reviewed and integrated.

## Superseded or amended

- **ADR 0001.** The 300K start budget (Intended behavior) was already amended
  to 350K by ADR 0003. It is now Prague gas plus the slot cap. The storage
  figures in §8 (0.23 ETH per MB per gwei, 72 KB per transaction) predate
  Glamsterdam.
- **ADR 0003.** The 350K steady-state start gate and its measured table are
  Prague gas. The "two full chunks per transaction" figure predates
  Glamsterdam.
