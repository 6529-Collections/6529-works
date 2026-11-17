# ADR 0009: The second permanence pass

Status: Accepted by owner instruction, 16 November 2026. Recorded by the delivery owner
(Claude Code, acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md) (§7, §11,
§13, §16), [ADR 0002](0002-access-manager-hardening.md),
[ADR 0005](0005-stream-editions-auction.md), [ADR 0006](0006-work-powers-and-conventions.md),
[ADR 0007](0007-permanence.md) and [ADR 0008](0008-federation.md); each carries a dated
amendment note pointing here.

The behaviour is specified in the spec pages ([index](../spec/README.md)); this record is how it
was decided. Pre-audit: nothing here claims an audit, production readiness or correctness.

## Context

The first permanence build (ADR 0007, ADR 0008) leaned many open choices towards artists,
collectors and federated contracts and away from the network. On 16 November 2026 the owner
reviewed a 61-item list of those choices item by item and gave four general directions:

- **The authority is TDH.** In effect a multisig of thousands of holders on 6529chain, bridged
  to Ethereum by a zero-knowledge proof. The contracts are not designed around small human
  councils: no seat counts, no vetoes by several lanes, no machinery to recover governance itself.
- **Short, fixed timeframes.** Durations are compiled constants (the owner calls them
  invariants), not governed parameters with ranges.
- **An artist, and each collaborator, is a 6529 consolidated account.** Every wallet in the
  consolidation has the same rights. No wallet ranks above another.
- **Simplify.** When in doubt, remove machinery. Explain in plain English.

## Decision

### Governance

1. One address, `network`, holds ADMIN, NETWORK and the three setter roles. Delay classes are
   fixed: at once (NETWORK), 24 hours (PARAMETER_SETTER), 3 days (FUNDS_SETTER) and 7 days
   (SUCCESSOR_SETTER, ADMIN). Grants have no delay.
2. Guardians, seats, suspension, the escalated lane, dead-admin recovery, succession and the
   successor probe are removed. The network hands over in two steps: `transferNetwork` (7 days)
   and `acceptNetwork` by the new address, after which the old address holds nothing.
3. One optional brake address can delay a scheduled network action once, by a compiled 7 days
   (`brakeOnce`). No brake is installed at launch; the network can set one (7 days).
4. Until the TDH bridge exists, one 6529 Safe holds `network` (owner, 16 November 2026), then
   hands over. The earlier commitment that no 6529 entity holds a privileged role from
   1 January 2027 (D67, D98) stands beside this and is the owner's to reconcile.
5. The pauser stays an ordinary hot role. `unpause`, `resume` and `cancel` are the network's, at
   once. Operational keys are administered by the network, which grants and revokes them at once.

### Identity (C13 to C18)

6. An account is a consolidated account: its root, or any wallet the consolidation source says
   has a live two-way link with the root, with no minimum age. Signatures are proofs,
   `abi.encodePacked(wallet, signature)`, from any wallet of the account.
7. Fixed timers: an account's own change 2 days; a network replacement 14 days' notice; a
   contested replacement lapses after 90 days unless upheld by a vote recorded after the contest.
   Dormancy, standing, heartbeats and timers set by governance are removed.
8. The network can cancel its own pending replacement (C14) and an account's own pending change,
   and can freeze an account at once for a fixed 14 days (C17); a freeze also holds payouts. No
   payout-only redirect exists (C15).
9. Collaborators consent unanimously, counted by account (C6, C31).

### Revenue and works

10. The network can change its fee-receiving address (through the fee vault's destination and a
    resolver read at settlement) and lower its share on existing works alone; no path raises a
    share on existing works (R8, R9).
11. A royalty rate can rise when the artist and the network agree (R10). Renouncing the royalty
    or licence power needs the network (C7). The network repairs a finalized work's renderer
    alone unless the artist renounced the repin (C8).
12. The artist finalizes when they like; 14 days after a recorded notice following the sale,
    anyone can finalize the work as it stands (C9).
13. Every release from a split vault also pays the network its share (R11). Sale rounding goes to
    the network (R18); a split vault keeps at most one unit per payee of dust (sweeping it at
    once is unsound). Unclaimed shares, escrow credits and sale credits go to the network after
    a fixed 180 days (R12; in a split vault the 180 days run from a mark anyone can place).
14. The network can move its own parked escrow credits (C19), change a network vault's
    destination (C20), add storage locations and mark dead ones (C21), and sets a default
    file-location order for all files (C33).
15. Price caps are removed (R19): the edition base price and the 1/1 opening bid are bounded only
    by their storage widths.
16. The rescue wait after an adapter is removed is a fixed 14 days (C12).

### Sales

17. Every edition sale closes exactly 15 minutes after its 1/1 (R20). Edition bids are firm,
    including during a dispute; they are returned only if the dispute is upheld (R21).
18. An edition sale may be abandoned 21 days after its close; if the master's sale settled, the
    call creates the edition (R16).
19. A dispute pause on a live 1/1 lasts at most a fixed 3 days; the network can cancel or resume
    at any moment of it (C30). The federated refusal exit opens 2 days after the sale's end; the
    currency-freeze exit and the delivery redirect wait 14 days each.
20. EIP-2612 permit payments are removed; payments are direct or Permit2.
21. The network's keeper starts sales only through `SaleStarter`, which also deploys the payout
    vaults and opens the record in one transaction. This is the keeper's rule; `start` stays
    permissionless.
22. Cancelling an approval stops any edition whose sale has not opened (C23); disabling a signer
    kills its unminted approvals (C32).

### Federation

23. Leaving the federation is removed entirely (R1 to R5, C4). Delisting is per account, a
    network decision at the 24-hour class, and blocks new contracts from that account (C5,
    C25); a delisted contract cannot mint or sell through network adapters (C1).
24. A replacement registry inherits existing listings without artist signatures (C3). The
    network can reverse a template revocation; a suspension also stops new sales (C26).
25. Federated templates take collaborators and VRF. Federated VRF is paid by the requester to
    the provider with the call (price read from the provider); the network does not pay. It is
    off until the network sets a wrapper. Overpayment goes to the provider.
26. Federated royalties may be 0% and the artist may lower them alone (R6, R7).

### Documents and tools

27. The grade tool is removed (O1). The promise card becomes a neutral fact sheet per work with
    no warnings (O2). Documents describe the network's duties as current practice (O3), carry no
    rules that bind future governance (O4), use neutral wording (O5) and match the code (O6).
    Declarations no longer carry intended renunciations (confirmed by the owner, 17 November 2026).

### Fixed values (compiled constants)

| Value | Number |
| --- | --- |
| Network action delays | at once / 24 hours / 3 days / 7 days |
| Brake, once per action | 7 days |
| Account's own change | 2 days |
| Network replacement notice | 14 days |
| A contested replacement lapses | 90 days |
| Account freeze | 14 days |
| Rescue wait after an adapter is removed | 14 days |
| Anyone may finalize | 14 days after a recorded notice |
| Dispute pause on a live 1/1 | 3 days |
| Federated refusal exit | 2 days after the end |
| Currency-freeze exit; delivery redirect | 14 days each |
| Edition close | 15 minutes after its 1/1 |
| Edition abandon | 21 days after its close |
| Unclaimed credits and shares go to the network | 180 days |
| Source-line budget | 17,000 |
| Start-gas margin | 3,000 under the 350,000 ceiling |

**Compiled durations in permanent contracts are intended.** ADR 0007's permanent-contract rule 5
("no compiled durations unless the number is itself the guarantee") gives way to the owner's
direction: each constant's NatSpec says the number is the guarantee. ADR 0007's rule 1 likewise
gives way for one live read: a permanent account's wallets other than the root are answered by
the replaceable consolidation source (LIM-ID-20).

## Consequences

- Before the bridge everything governed depends on one Safe. A compromised operational key is
  revoked by the network at once; there is no separate suspension.
- Any class can be shortened by a 7-day remap (stock AccessManager); the 7 days, the brake and
  public logs are what bound it.
- A start whose move a non-root wallet signed reads the delegation contract and costs about
  47,000 gas more (314,199 at steady state); it has its own regression ceiling (LIM-ID-21).
- Lowering a share moves the royalty receiver to a vault that may not be deployed yet; the
  network deploys it in the same batch.

## Tests deleted with the behaviour

Whole files: `test/governance/BoundedVeto.t.sol`, `ContractSeat.t.sol`, `DeadAdminRecovery.t.sol`,
`GuardianCancel.t.sol`, `Hardening.t.sol`, `PermanenceFixture.sol`, `PermanenceInvariant.t.sol`,
`SeatsAndParameters.t.sol`, `Succession.t.sol`, `Suspension.t.sol`;
`test/identity/ArtistRegistry.invariant.t.sol`, `ArtistRegistryHandler.sol`,
`ArtistRegistryStanding.t.sol`, `ConsolidationTrust.t.sol`, `ContestedOverrides.t.sol`,
`RecoveryRobustness.t.sol`, `RefreshGasRule.t.sol`, `RegistryTimers.t.sol`,
`RestrainedFlag.t.sol`; `test/integration/GovernanceHandover.t.sol`,
`GovernanceRecovery.t.sol`, `RecoveryRestraint.t.sol`;
`test/sales/edition/UniformEditionAuctionFixA.t.sol`; `test/mocks/governance/SuccessionMocks.sol`,
`test/mocks/identity/RepricedDelegationMock.sol`; `tools/conventions/grade.py`, `test_grade.py`.

Tests removed inside kept files, as the lanes reported them: the federated exit tests
(`test_Exit_*` and the leave parts of the pair, permanence, provenance and governance tests);
the rescue-delay setter tests (`setRescueDelay`, lane 4); the guardian-rationale tests of the
currency freeze (RFX-SAL-2, L-4); the edition withdrawal tests (R21); the PERMIT payment tests,
now refusal tests; the two `refreshStanding` gas rows; the lower-only royalty tests, now rise
tests; the identity standing, timer, override and restraint tests (lane 1); the fact-sheet
residual-risk and intended-renunciation tests and the grade schema cases (lane 7); the old
`VerifyGenesisState` and `DeployV1` checks of seats, recovery and succession (lane 2). The
invariants these covered are listed in [Invariants](../audit/invariants.md).

## Review fixes (17 November 2026)

An independent review of the pass led to these changes before release:

- Escrow and sale credits start their 180-day clock only when they go from zero; later credits,
  by anyone, do not move it.
- A due finalize by someone other than the artist finalizes the record exactly as it stands.
- `ChangeContested` carries `priorOutcome`; `resolveContested` accepts only a later outcome.
- `killSignerApprovals` is a network action with no delay; stopping a signer is
  `disableSigner` and `killSignerApprovals` in one batch.
- On a curated work the lead artist's account is never a fixed payee, so a freeze holds its
  payout.
- `FederatedEditions.createEdition` needs a SOLD master or a bound edition sale; an editions
  contract mints only while its partner's template is approved.
- `propagateRevocation` is removed: a revocation acts through `isActive` and `canMint`.
- Curated and federated VRF draws have separate seed maps and tenures.
- Deploy and Verify refuse a brake in the genesis file off anvil; `SaleStarter` refuses itself
  as payer; the deployment record no longer has `pendingLanes`.
- Documented, not built: a wallet of a frozen or delisted account can open a new account
  (LIM-ID-23); a newer dispute outcome can void a scheduled resolution (LIM-GV-29); the English
  auction reads its own economics resolver (LIM-SAL-21).

Decided by the owner on 17 November 2026: an edition is created for any completed 1/1,
including one that ended with no bid (R16, through the edition sale's `abandon`); collaborator
consent has no expiry (LIM-ID-24); declarations carry no intended renunciations.

## Alternatives considered

- Keeping guardians as a brake with seats: rejected by the owner ("once we go to network TDH
  guardians go away"); one optional brake that can delay once replaces them.
- Governed ranges for each timer: rejected for compiled values.
- Network-paid federated VRF: rejected; permissionless artists could spend the network's balance.

## Open items

- Whether `abandon` should also settle in the same call.
- The interim authority against D67/D98, for the owner.
