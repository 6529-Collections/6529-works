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

**1. The gas budgets are in Prague gas.**
- **Prague gas** is a whole transaction's gas (intrinsic, calldata and
  execution, before refunds) priced with Prague's schedule, state creation
  included at Prague's prices, with storage and accounts cold at the start as
  in a real transaction. CI measures it with Foundry.
- Every existing ceiling keeps its number, now as Prague gas:
  - a steady-state `start` and `startWithBid` in ETH, at most **350K**, for
    one artist and for the two-party variants (decision 6 covers ERC-20
    starts);
  - the first start in a new collection, and `settle`: 400K test ceilings;
  - `tokenURI`: 8M.
- Every other measured operation gets a **regression ceiling**: its Prague gas
  when this ADR was accepted, plus about 2%, rounded up to the thousand. A
  regression ceiling is not a budget. A change that crosses one says why in
  its pull request and moves it.

**2. Exact counts of new state per operation.** CI counts what each
transaction creates:
- **A new slot** is a storage slot that is zero before the transaction and
  non-zero after it, read from the state itself. A slot counts once however
  often it is written. A write that a revert or a halt undid does not count.
- **A new account** is an account that is empty before the transaction (no
  code, nonce zero, balance zero) and not empty after it: a contract creation,
  or ETH sent to an empty address.

Each measured operation asserts its exact counts, so a slot one change saves
cannot be spent again unnoticed. A steady-state `start` is also held to a
maximum of **6** new slots, and `startWithBid` to **7**, in ETH: for one or
two parties, and for VRF and edition-master works.
- When a change lowers a count, the same pull request lowers the test's
  figure, this ADR's table and the figure in `AGENTS.md`. Lowering needs no
  new ADR.
- Raising a count needs a stated reason in the pull request.
- Raising the `start` or `startWithBid` maximum needs an ADR.

**3. Publish the Glamsterdam totals next to the budgets.** The table below
gives each operation's Sepolia gas from the r2 rehearsal. Mainnet's Glamsterdam
parameters may differ. Every figure will be re-measured when they are final.

**4. Restate the per-transaction cap.** EIP-7825's limit of 16,777,216 gas
applies to regular gas.
- On Sepolia, transactions whose state-creation gas took them above it were
  accepted. The largest observed used 38.4M: a `writeChunk` of 24,572 bytes.
- That is an observation of Sepolia's behaviour, not a reading of the final
  EIP mechanics.
- CI keeps testing worst-case transactions against 16,777,216 in Prague gas,
  the measure Foundry has. Whether that matches the regular gas Glamsterdam
  counts against the cap will be checked when Foundry supports Amsterdam and
  against mainnet's final parameters.

**5. Assume that payees exist.** The network fee recipient, and any royalty
payee, is an existing account (a Safe, or an address with a balance or a
nonce).
- A payout to an empty address creates it, which on Sepolia costs about 184K
  more gas, paid by whoever settles or buys.
- Off anvil, the deploy refuses a `NETWORK_FEE_RECIPIENT` that does not exist.
  The runbook asks the same of a later `setFeeTerms`
  ([script README](../../script/README.md#the-network-fee-recipient-must-exist)).
- A new payee configuration's split wallet still costs one account creation
  on its first payout. This happens once per configuration, and the table
  shows it.

**6. The start budget is for ETH, Stream's launch currency.** The 350K Prague
budget and the 6 and 7 slot maxima apply to starts in ETH. ADR 0001 §5 says
Stream launches with ETH and makes ERC-20 payment a governed configuration. It
also lets a package's sale terms name any currency on the asset allowlist.
- An ERC-20 start paid by Permit2 is a supported path, not the default. It has
  a Prague regression ceiling (388,000) and exact counts (7 new slots, no new
  account), but no budget.
- The allowlist is global, so ERC-20 Stream starts can happen without any
  change to the default currency.
- Admitting the first ERC-20 to the allowlist, or curation approving a Stream
  package that names an ERC-20, must be accompanied by a re-measurement of the
  ERC-20 start's cost, in Prague gas and on the target chain, and by its
  publication.

### The table

Prague gas, counts and ceilings are from `test/integration/GasReport.t.sol`
(`forge test --match-test test_Gas_Table -vv`) at the head of this ADR's pull
request. Prague figures move by a few dozen gas whenever a source file changes:
metadata hashes change CREATE2 addresses, and with them the calldata. Sepolia
gas is the r2 receipt ([flows](../../deployments/11155111/flows.md)). "—" means
no ceiling, or not run on Sepolia.

| Operation | Prague gas | Prague ceiling | New slots | New accounts | Sepolia gas |
| --- | ---: | ---: | ---: | ---: | ---: |
| `start`, steady state | 291,808 | 350,000 | **6** | 0 | 846,963 |
| `startWithBid`, steady state | 333,883 | 350,000 | **7** | 0 | 982,312 |
| `start`, two-party work | 300,037 | 350,000 | **6** | 0 | — |
| `startWithBid`, two-party work | 342,121 | 350,000 | **7** | 0 | — |
| `start`, VRF work | 299,486 | 350,000 | **6** | 0 | 852,868 |
| `start`, edition master | 292,448 | 350,000 | **6** | 0 | 847,598 |
| `startWithBid`, ERC-20 by relayed Permit2 | 378,977 | 388,000 (regression) | 7 | 0 | — |
| `start`, first work in a new collection | 291,802 | 400,000 | 6 | 0 | 846,977 |
| `start`, first work ever (one-time) | 440,880 | 452,000 (regression) | 13 | 0 | 1,604,862 |
| `startWithBid`, first bid under new sale terms (one-time) | 404,032 | 413,000 (regression) | 10 | 0 | — |
| `bid` that outbids | 73,464 | 75,000 (regression) | 1 | 0 | 168,932 |
| `settle`, first payout to a seller wallet | 168,063 | 400,000 | 1 | 1 | 441,363 |
| `settle`, with a bid | 143,063 | 400,000 | 1 | 0 | 257,763 |
| `consume`, as Stream calls it | 96,456 | 99,000 (regression) | 1 | 0 | part of `start` |
| `createEdition` | 314,734 | 331,000 (regression) | 9 | 0 | 1,118,699 |
| `openSale` (one public phase) | 292,853 | 293,000 (regression) | 8 | 0 | 993,668 |
| `purchase`, the first copy, new holder | 193,971 | 195,000 (regression) | 3 | 0 | 468,086 |
| `purchase`, a later copy, new holder | 176,871 | 177,000 (regression) | 2 | 0 | 370,142 |
| `refreshStanding`, a first wallet | 129,708 | 131,000 (regression) | 2 | 0 | 299,112 (r1) |
| `refreshStanding`, a further wallet | 159,105 | 161,000 (regression) | 1 | 0 | 247,970 |
| `royaltyInfo` (view) | 41,325 | 50,000 of execution | 0 | 0 | 40,667 |
| `tokenURI` (view, the size matrix) | at most 2,733,567 | 8,000,000 | 0 | 0 | unchanged |
| `createWallet`, a seller wallet (one artist payee) | 1,236,339 | 1,262,000 (regression) | 4 | 1 | — |
| `release`, the artist's first ETH release | 93,368 | 96,000 (regression) | 2 | 0 | — |
| `claimSigned`, the artist's first signed release | 141,370 | 145,000 (regression) | 3 | 0 | — |
| `claimSigned`, a later signed release (next nonce) | 90,074 | 92,000 (regression) | 0 | 0 | — |

- **Re-measured after the review of 14 October 2026.** The split-wallet rows
  were added then, on the same harness; a wallet's deployment is mostly code
  (about 5,350 bytes, which Glamsterdam prices at about 1,542 gas each on
  Sepolia). Split wallets also got a constant init code, so predicting a
  wallet's address no longer hashes its creation code: the `start`,
  `startWithBid`, `createEdition` and `royaltyInfo` rows are re-measured with
  it (about 4,500 less per start, 9,000 per `createEdition`, 4,500 per
  `royaltyInfo`). The `refreshStanding` rows were re-measured with the
  identity fixes; the other rows are as accepted, and moved by a few dozen gas
  at most. The Sepolia column and the replay comparison below are the r2
  deployment, which predates the change.
- **The VRF start row** also includes, since the same review, the read of
  the item's content link in `isDelivered` (DEPS-1, about 2,200 gas).
- **Re-measured again with the restrained authority (IDENTITY-1, ADR 0003
  owner decision 6).** Every path that resolves the artist's creator or signer
  now reads its pending-change slot: about 2.4K more per creator read
  (`settle`, `openSale`, `purchase`) and about 2.8K per `start`, which reads it
  twice. Re-checking the consolidation source's pinned code hash (DEPS-6) adds
  about 2.2K to each `refreshStanding`. Slot and account counts are unchanged;
  the `consume` regression ceiling moved from 96,000 to 99,000.
- **The two-party `startWithBid` is the tightest:** 341,251, about 8.7K under
  350K.
- **An ERC-20 `startWithBid` paid by Permit2 costs 377,833**, about 45K more
  than in ETH, because of the Permit2 transfer path. That path adds:
  - the signed permit and its witness in the calldata;
  - Permit2's signature check and nonce update;
  - the token transfer, with the balance checks around it;
  - two more accounts, Permit2 and the token.

  It is not the launch currency, so the row has a regression ceiling, not the
  350K budget (decision 6). The row uses the test suite's reproduction of
  Permit2, not the canonical deployment.
- **A rule of thumb on Sepolia's parameters:** a transaction's Glamsterdam gas
  is about its Prague gas, plus about 89,000 per new slot, plus about 184,000
  per new account. It is not a gate.
- **Where a steady-state start's 6 slots go:**
  - Stream's three-word token record and the ERC-721 owner;
  - the package registry's consumed-content record;
  - the auction's sale.

  `startWithBid` adds the bid.

### CI against the Sepolia replays

The same operations, as CI measures them and as the r2 receipts replay with
Prague costs (`cast run --evm-version prague`):

| Operation | CI | Sepolia r2 at Prague | CI minus Sepolia |
| --- | ---: | ---: | ---: |
| `start`, steady state | 293,230 | 293,243 | −13 |
| `startWithBid`, steady state | 334,584 | 334,572 | +12 |
| `start`, VRF work | 298,736 | 298,748 | −12 |
| `start`, edition master | 293,890 | 293,878 | +12 |
| `start`, first work in a new collection | 293,244 | 293,257 | −13 |
| `start`, first work ever | 442,314 | 442,302 | +12 |
| `bid` that outbids | 73,348 | 73,312 | +36 |
| `createEdition` | 323,833 | 323,819 | +14 |
| `openSale` | 286,584 | 286,608 | −24 |
| `refreshStanding`, a further wallet | 157,132 | 157,250 | −118 |
| `settle`, first payout to a seller wallet | 158,414 | 164,743 | −6,329 |
| `settle`, with a bid | 133,414 | 139,743 | −6,329 |
| `purchase`, the first copy | 190,597 | 196,926 | −6,329 |
| `purchase`, a later copy | 173,497 | 179,802 | −6,305 |

- **The starts, `bid` and the Editions calls agree within 40 gas, and
  `refreshStanding` within 120.** The inputs differ: the packages' calldata,
  and the consolidations a refresh walks.
- **The four payout rows differ by about 6,300.** On Sepolia the network fee
  recipient is the hot admin Safe, and ETH paid to a Safe runs its receive
  code. CI's fee recipient is a plain funded account.

## Consequences

**What CI checks.**
- `test/integration/GasReport.t.sol` measures every row above on the real,
  wired contracts.
  - It gates the Prague budgets and ceilings.
  - It asserts the exact counts of new slots and accounts, and the `start`
    maxima.
  - It also checks that `tokenURI` creates no state.
- `test/helpers/StateGrowth.sol` does the counting. It takes each candidate
  slot and account from the state-diff recording, and reads its value before
  and after the call from the state itself. Its tests on a toy contract cover:
  - overwrites, zero to zero and non-zero to zero;
  - reverted writes, and writes in frames that ran out of gas or hit
    `INVALID`;
  - re-entrancy, a parent writing between two child calls, `delegatecall` and
    transient storage;
  - `CREATE`, and ETH sent to a fresh account or an empty precompile.
- Module gas tests, such as `EnglishAuctionGas.t.sol`, keep their Prague gates.

**How CI measures Prague gas.** Foundry 1.7.1 does not model a transaction's
cold start fully. The harness works around three quirks:
- **`vm.cool` cools storage but not accounts.** The harness probes which
  accounts the test had already touched before each measurement. It then adds
  2,500 gas (EIP-2929: 2,600 cold against 100 warm) for each of those that a
  real transaction would reach cold. Without this, a steady-state start read
  about 17,500 low.
- **Recording a state diff warms what it reads.**
- **After a recording, nothing in that test is cold again**, even after a
  state revert.

So each row is probed and measured first, and recorded last, all from one
snapshot. A probe fails any measurement whose cooling did not work, and another
check fails if a measured call reached storage the harness does not cool.

`test/integration/GasHarness.t.sol` checks the correction against the truth.
A steady-state `start` measured at the very start of a test, where every
account and slot is cold, must equal the corrected figure measured after the
test has warmed every account the call reaches. Today they are both 292,455,
against 274,955 uncorrected: seven accounts at 2,500 each.

**What CI cannot check.**
- **Glamsterdam totals.** The Sepolia column is measured by hand on a
  deployment. CI gates the count of new slots and accounts, which is the part
  of the Glamsterdam cost it can see. It does not see the price of code bytes
  in a contract creation, beyond counting the account.
- **Receive code of real payees.** A Safe or a contract payee costs more to pay
  than the plain accounts CI uses (about 6,300 for a Safe, above).

**What happens next.**
- **Re-measure on mainnet.** When mainnet's Glamsterdam parameters are final,
  re-measure the Sepolia column on a deployment that uses them. Do the same
  for the per-byte storage costs.
- **When Foundry supports Amsterdam,** consider gating Glamsterdam gas
  directly. `vm.lastCallGas` already declares a `gasStateUsed` field that
  Foundry 1.7.1 does not return.
- **Content storage costs** about 1,548 gas per byte on Sepolia, against 218 on
  Prague: about 1.65 ETH per MiB at 1 gwei. The
  [content module](../../src/content/README.md#glamsterdam) restates its
  guidance; this ADR only records the measurement.

## Security impact

Fixed gas allowances inside the protocol now absorb Glamsterdam's state
pricing.
- **`DELIVERY_GAS` (300K).** `settle` forwards it to the token's
  `safeTransferFrom`. Delivering to a new holder writes that holder's balance
  slot from zero; on Sepolia those deliveries succeeded. A recipient contract
  whose `onERC721Received` also writes new state has less room than on Prague
  and may run out. The token then stays as a pending claim: nothing is lost,
  but the winner claims it later and pays for that.
- **`PAYOUT_GAS` (100K).** A seller or fee wallet gets this much for an ETH
  payout. A wallet whose receive code writes new state may need more under
  Glamsterdam; its payout is then refused and goes to the escrow, to be
  flushed later. Split wallets receive with an empty `receive` and are
  unaffected.
- **The auction's ERC-20 payout frame (1,000,000).** Each ERC-20 settlement
  payout runs in its own call frame with this allowance (MONEY-1), and the
  settler must be able to forward it in full: an ERC-20 `settle` needs a call
  gas limit of about 1.11M although it uses about 140K (an ETH `settle` about
  460K). If a payout fails in the frame, it is credited to its wallet, to be
  paid with `claimFor`. Under Glamsterdam, if a token burns the whole frame,
  the credit's new storage slot (about 111K of state gas) may not fit in what
  remains: the settlement then reverts and is retried with a higher limit.
- **Settlement reads the currency's status** (MARKET-2: a deprecated currency
  freezes the auction), about 7K more Prague gas per `settle` than before.
- **The VRF callback** used about 62% of its 200,000-gas limit on Sepolia (one
  new slot). Raising the limit is a PARAMETER_SETTER operation (48 hours);
  lowering it, never below the floor, a SUCCESSOR_SETTER one (30 days). The
  callback now creates no slot (the seed overwrites the request
  ID, DEPS-2): about 34,000 under Glamsterdam, about a third of the 100,000
  floor.
- **The claim router's continue-mode minimums** (200,000 per plain item,
  450,000 per signed item) are Prague-sized floors. A first release needs more
  under Glamsterdam: new slots, and possibly the payee's account (about 716,000
  for a first signed release on Sepolia). While an item is offered less than
  `SHORTFALL_REVERT_CEILING` (1,500,000), continue mode reverts when it fails
  after spending its share, so gas estimation raises the limit until it is
  paid; an item that fails despite the ceiling is skipped. Re-check the ceiling
  (about twice the Sepolia figure) and the batch sizes: a full batch of first
  releases may not fit one transaction, and then reverts for the caller to
  split.

Re-check each of these allowances against mainnet's Glamsterdam parameters before
mainnet.

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
  - The exact counts make any such saving visible and keep it.
- **C: a redesign for minimal state.** This is rejected. Any design keeps the
  essential records: the owner, the consumed content and the sale. A redesign
  could remove little more than B does, and it would reopen modules that have
  been reviewed and integrated.

## Superseded or amended

- **ADR 0001.** The 300K start budget (Intended behavior) was already amended
  to 350K by ADR 0003. It is now Prague gas plus the slot maximum. The storage
  figures in §8 (0.23 ETH per MB per gwei, 72 KB per transaction) predate
  Glamsterdam.
- **ADR 0003.** The 350K steady-state start gate and its measured table are
  Prague gas. The "two full chunks per transaction" figure predates
  Glamsterdam: one full chunk per transaction under Glamsterdam (content
  module README).
