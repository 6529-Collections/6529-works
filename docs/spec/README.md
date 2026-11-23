# Protocol specification

How 6529 Works v1 behaves, one page per area. Each page names its contracts (permanent or
module), says how the area works, lists the settings and fixed numbers, and gives the rules with
the tests that check them. Start with the [overview](../overview.md) if you are new.

> Pre-audit. See the [project status](../../README.md#status).

Where an ADR and a page differ, the page follows the code. [ADR 0010](../adr/0010-plain-permanent-core.md)
is the current design: a small plain permanent core and replaceable modules.

## Pages

| Page | Prefix | Covers |
| --- | --- | --- |
| [Stream and auctions](stream-and-auctions.md) | `AUC` | The permanent ERC-721, the seam with its modules, rescue, and the English auction from start to settlement |
| [Works and storage](works-and-storage.md) | `WS` | A work's facts (`StreamWorkFacts6529`, permanent) and rules (`WorkRules`, module); locators; the content store |
| [Editions and sales](editions-and-sales.md) | `ED`, `EA` | The permanent ERC-1155, rebind, and the uniform-price edition auction |
| [Curation](curation.md) | `CUR` | Package items and roots, approval, consent, the move signature, consume-once, content release |
| [Rendering and tokenURI](rendering-and-tokenuri.md) | `RND` | Which renderer draws a token, the metadata format, inline media |
| [Economics and payouts](economics-and-payouts.md) | `ECO` | Terms, split vaults, the escrow, releases, the unclaimed period |
| [Identity and recovery](identity-and-recovery.md) | `ID` | The accounts module: wallets, changes, contests, freezes, payouts |
| [Independent Stream](independent-stream.md) | `IND` | The Independent Stream token pair and the Independent Stream module |
| [Disputes and statements](disputes-and-statements.md) | `DSP` | The dispute pause, outcomes, content release, the statement log |
| [Entropy](entropy.md) | `ENT` | Optional VRF seeds |
| [Declarations and conventions](declarations-and-conventions.md) | `DCL` | Off-chain conventions for readers and tools |
| [Governance](governance.md) | `GV` | The network address, roles, settings and genesis |

Terms are in the [glossary](../glossary.md). Every governed function, with its role, is in the
generated [role matrix](../audit/roles.md).

## A work from end to end

| Step | Page |
| --- | --- |
| Upload content, build and approve the package | [Works and storage](works-and-storage.md), [Curation](curation.md) |
| Seed a VRF work | [Entropy](entropy.md) |
| Start, bid, settle; royalties | [Stream and auctions](stream-and-auctions.md) |
| Pay the seller, the network and the payees | [Economics and payouts](economics-and-payouts.md) |
| Pause and cancel on an upheld dispute | [Disputes and statements](disputes-and-statements.md) |
| Open the record, amend it, finalize | [Works and storage](works-and-storage.md) |
| Draw the metadata | [Rendering and tokenURI](rendering-and-tokenuri.md) |
| Sell editions beside the 1/1 | [Editions and sales](editions-and-sales.md) |
| Change an account's wallets | [Identity and recovery](identity-and-recovery.md) |

## Conventions

- **Permanent** contracts are deployed once and never replaced. **Modules** are replaceable;
  the network adds one after `moduleDelay` and removes one at once.
- **Waiting periods in permanent contracts are the network's settings**, with launch values,
  changed at once (zero allowed): `moduleDelay` 7 days, `rescueDelay` 14 days, `rebindDelay` 14
  days, `unclaimedPeriod` 180 days. Numbers inside modules (auction timers, the accounts
  module's notices, the 14-day finalize notice) are compiled or governed values of those
  modules. No period is a guarantee.
- **Rates and shares** are out of 100,000, so the 6.529% royalty is exactly 6,529.
- **ETH only** for sales. The split ledger and the escrow also hold ERC-20 royalties.
- **Gas** is Prague gas unless a figure says otherwise ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md)).
- **"Anyone"** means a permissionless function.
- **Rule IDs** are each page's own. A retired ID is kept with "Retired" and never reused.

## Differences from the ADRs

[ADR 0010](../adr/0010-plain-permanent-core.md) amends ADRs 0001, 0004, 0007, 0008 and 0009:
what is permanent, the start budget (370,000 Prague gas and 8 new slots; 395,000 and 9 for a start
with a bid of a VRF work), the Independent Stream templates and the waits in permanent contracts,
which are now the network's settings. The pages follow ADR 0010 and the code. The earlier register
of smaller differences is in the history of this file.

## Reporting a mismatch

If the code and a page disagree, the code is what runs. Open an issue naming the page, the rule
ID and the code. If the mismatch is exploitable, report it privately as
[SECURITY.md](../../SECURITY.md) describes.
