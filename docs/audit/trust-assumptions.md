# Trust assumptions

What the network can do, to whom, and how fast; what each key and outside dependency is
trusted with; and what nobody can do. The plain-language summary is the
[overview](../overview.md); the selector-by-selector map is the [role matrix](roles.md).

> Pre-audit. See the [project status](../../README.md#status).

## The model in brief

- **The network is the authority.** One address holds every network role: one 6529 Safe today,
  the TDH-governed account once the bridge exists. It chooses the modules, the sale contracts,
  the settings and every governed parameter. That is the design, not a risk to be reduced.
- **The permanent contracts limit every authority, the network included.** Nobody can move,
  freeze or burn a token a collector holds; nobody can change a minted work's facts, its media,
  its finalized record or a CC0 license; nobody can take money already owed in a split vault or
  the escrow, except unclaimed money after the unclaimed period, to the network, as the ledger
  and escrow rules allow.
- **Waiting periods are the network's settings.** The permanent contracts hold four
  (`moduleDelay` 7 days, `rescueDelay` 14 days, `rebindDelay` 14 days, `unclaimedPeriod` 180
  days at launch), which the network changes at once, zero allowed. The AccessManager's role
  delays (none, 24 hours, 3 days, 7 days at genesis) are also the network's: one 7-day action can
  remap a function or change a class. None of these is a guarantee; each is public notice while
  it is in force.
- **Modules are replaceable and trusted while installed.** A module can do what the seam lets
  it do and no more (below).

## Governance roles

### What the network can do

| Power | To whom | How fast (at genesis) |
| --- | --- | --- |
| Announce a module or add a sale contract to a permanent contract | Everyone, for new mints, new sales and unfinalized works | Usable after `moduleDelay` |
| Remove a module or a sale contract | The same | At once |
| Change `moduleDelay`, `rescueDelay`, `rebindDelay`, `unclaimedPeriod` | Additions announced later; rescues, rebinds, forfeits and expiries attempted later | At once |
| `rescue` a token a removed sale contract still holds unsold | That unsold token only; never a collector's | Once `rescueDelay` has passed since the removal |
| `rebind` an edition with no copies and no seal to another sale contract | That edition only | Once `rebindDelay` has passed since its sale contract's removal |
| Create collections, set the marketplace owner and contract URI | Marketplace presentation | Per the role matrix |
| Governed parameters of modules (fees for new works, auction timing within bounds, museum, recipients) | New sales and new works | 24 hours, 3 days or 7 days, per the role matrix |
| Freeze an artist account, cancel a replacement, revoke a package, disable a signer, cancel a dispute-paused sale | The account, package, signer or sale named | At once |
| Remap any function to another class, or change a class | Every governed function | 7 days |
| Hand the network to another address | Everything | 7 days, then the new address accepts |

What no power reaches: a held token, a minted work's facts and media, a finalized record, a CC0
license, a locked royalty rate, a sealed edition's maximum, and money owed in a vault or the
escrow before the unclaimed period.

### The network Safe and the brake

The network is a canonical Safe with a threshold of at least 2, plain-key owners, no module and
no guard (checked by the deploy and every readback). A brake, if the network sets one (none at
launch), can delay a scheduled network action once by 7 days and do nothing else.

### Operational keys

Ordinary keys the network grants and revokes at once.

| Key | Trusted to | Worst case if compromised | Recovery |
| --- | --- | --- | --- |
| Pauser | Pause new starts; pause a disputed 1/1 auction once, for at most 3 days | Pause each live auction once | The network unpauses or resumes at once and revokes the key |
| Curation signers (at least two) | Sign approvals only for packages curation approved | Approve any package until disabled; a start still needs every party's signature | The network disables the signer at once and kills its approvals |
| Curator | Append curation evidence statements | Misleading evidence, which a later entry supersedes | Revoke at once |
| Platform | Collections, locators, dispute outcomes, TDH votes | False dispute outcomes or junk locators | Revoke at once; a new outcome supersedes |
| Storage operator | Choose the preferred copy among registered copies | Point works at a missing copy until switched back | Revoke at once |

## Admitted sale adapters

The sale contracts are each token's minters. A minter can mint, record a sale's outcome once
and burn a token it still holds unsold. It cannot reach a token after the outcome is recorded,
or any token it does not hold. A removed minter mints nothing new; it still finishes what it
started, and the network can `rescue` what it leaves unsold. A federated token's minters are
the federation module's answer.

## Resolvers and renderer pins

| Module | If it is missing, fails or is hostile |
| --- | --- |
| TERMS | A hostile one can change the receiver and an unlocked rate of future royalties; never royalties already paid, never a locked rate |
| RENDERER | `tokenURI` of an unfinalized work reverts; a finalized work is drawn only by its pinned renderer, which `tokenURI` checks by code hash |
| RECORDS | Can change an unfinalized record and license within `WorkFacts`' rules; never media, never a finalized record, never away from CC0, never past a lock |
| ACCOUNTS | Names artists' payout addresses; a missing or failing one makes releases revert, and the money stays in the vault |
| FEDERATION | Decides which sale contracts mint for federated tokens; cannot move, burn or re-record a sold token |
| Mint policy, economics resolver | Decide what new works may be minted and on what terms; nothing about existing tokens |

## Actors

Artists, collaborators and collectors are trusted only with their own works, signatures and
money. A copier who mints someone else's content is handled by the dispute flow: a pause, an
upheld outcome and a cancel that burns the unsold token. Keepers and relayers are trusted only
for liveness: every upkeep call is permissionless, so anyone else can make it.

## External dependencies

| Dependency | Trusted to | If it fails |
| --- | --- | --- |
| 6529 delegation contract, through the consolidation adapter | Report consolidations of an artist's wallets | Only the account's root acts until it is fixed or the adapter replaced |
| Chainlink VRF v2.5 | Deliver an unbiased seed | A VRF work cannot start without its seed; repeat after the backoff or change coordinator |
| Safe wallets | Execute only what a threshold signs | The network's powers, as above |
| Arweave, IPFS and the storage monitor | Keep the bytes each locator names | Missing media in wallets; hashes and records do not change; put the work on-chain |
| 6529 waves and the TDH vote (off-chain) | Decide approvals, disputes and contested replacements | The chain sees only the signed or recorded result |
| The CC0 1.0 legal text | Be the official legal code | Fixed per deployment; deploy and readback refuse any other text |

The contracts assume Prague bytecode (transient storage, EIP-7702 detection) and the EIP-7825
transaction gas cap.

## References

[Governance](../spec/governance.md), [role matrix](roles.md),
[known limitations](known-limitations.md), [ADR 0010](../adr/0010-plain-permanent-core.md).
