# Replacing a module

A checklist for the network when it replaces a module of `Stream6529`, `StreamEditions6529`,
`StreamDirectory6529` or an Independent Stream token. The calls and their timing are in the
[runbook](../../script/README.md#modules-and-minters); the rules are in the
[governance spec](../spec/governance.md). The contracts do not enforce this checklist.

Tokens, the facts of finished works and money already owed do not depend on any module, so a
replacement never changes them. What a replacement does change is listed below, per module.

## Every module

1. **Deploy the new instance** with the same constructor arguments as the one it replaces,
   unless a change is the point of the replacement.
2. **Map its roles before it takes effect.** A new instance is a new address, so the role map
   has no entries for it. Until the network maps them, each of its restricted functions
   belongs to `ADMIN` (the network, 7 days). For each restricted function call
   `setTargetFunctionRole(newInstance, selectors, role)` on the manager with the role the
   [role matrix](../audit/roles.md) gives the instance it replaces.
3. **Carry state over** where the module holds any (below).
4. **Announce it**: `proposeModule(slot, newInstance)`. It becomes ready `moduleDelay` later.
   `cancelModule(slot)` withdraws an announcement before it takes effect.
5. **Activate it**: anyone calls `activateModule(slot)` from the ready time.
6. **Read it back**: the slot names the new instance, and the checks below pass.

## Accounts (`ACCOUNTS` on `StreamDirectory6529`)

A new instance of the current `Accounts` code starts empty. It has no read-through to the one
it replaces and no import function, so:

- An artist the new module does not know has no wallets and no payout address there. A release
  of that artist's vault share reverts, and the money stays in the vault until the artist is
  registered in the new module. Fixed payees are not affected.
- A freeze or a pending replacement recorded in the old module is not in the new one. Place it
  again in the new module if it is still wanted.
- Tokens and vaults name artists by ID, so each artist needs the same ID in the new module.
  In the current `Accounts` code an ID is the address the artist first registered with:
  registering that address again gives the same ID. An artist whose account has moved to
  another address since cannot get the old ID through `register`; a replacement that must
  serve such artists needs its own way to take them over, written into the new module.

Before announcing a new accounts module:

1. **It must serve every existing account under its existing ID**, by reading through to the
   module it replaces or by importing its accounts: the same wallets, payout address, pending
   changes and freezes, including for an artist whose account has moved to another address.
   Reading through is safer than a copy, because the old module keeps changing during the
   wait. A module that cannot do this must not be activated while any artist has money
   waiting or a work that can still be edited.
2. **Prove it with a test before the announcement.** Run the new module on the deployed stack
   against a moved account, as
   [`AccountsSuccessor.t.sol`](../../test/integration/AccountsSuccessor.t.sol) does with a
   read-through test module: after the directory activates it, the moved account's payout
   address, wallet check and freeze are answered under the old ID, money owed before and after
   the replacement is released to the moved payout address, and the moved account's signatures
   verify.
3. **Bind the package registry** as the new module's `register` caller, so new artists can
   still accept a package.

After it takes effect, check `payoutAddress` for a sample of artists with money waiting,
including every artist whose account has moved.

## Mint policy (`PackageRegistry`)

A new mint policy starts with no content releases and no barred items. Content uniqueness
still holds through `Stream6529.tokenOfContent`, so the content of a burned work stays unmintable
until the network releases it again in the new policy (`releaseContent`), which bars the
burned item there too. A release made in the old policy and not yet used must be made again.

## Independent Stream module (`IndependentStreamRegistry`)

Replace it with `proposeModule` and `activateModule`; do not empty the slot with `removeModule`.
The module holds the record of removed sale contracts, and the permanent tokens ask it. A
successor reads through to the module it replaces, so removals carry over. While the slot is
empty, nothing new happens on an Independent Stream token: no token is minted, no edition is
created and none is sealed (the editions contract reads every sale contract as removed), and
`rescue` and `rebind` are refused. An edition sale that is open then is voided with full
refunds, and its edition stays without a seal; once a module is in the slot again, the network
can rebind such an edition after removing its sale contract. Transfers, and the minting of an
edition that was sealed before, do not depend on the slot.

**Retire the replaced module as a writer.** The replaced module keeps its storage and still
answers calls. An artist can still list a contract in it (`register` needs no role), and the
successor serves that listing by reading through. A listing or template version that the
successor has written once is its own copy from then, and no longer follows the replaced module
([LIM-IND-10](../audit/known-limitations.md#independent-stream)). So:

1. **Write nothing in the successor before it is active.** A listing copied early (`setStatus`,
   `lowerFeeShare`, a registration of its partner) misses what the current module records for
   it during the wait.
2. **Once the successor is active, stop the replaced module from listing.** `register` needs
   an approved version, so no version may stay approved or be resumed in the replaced module.
   For each template version, in one batch, first give the successor its own copy with two
   calls that leave the version's status as it was, then close the version in the replaced
   module. Which calls depends on the status the version has:

   | The version is | In the successor | In the replaced module |
   | --- | --- | --- |
   | approved | `suspendTemplate(deployer)`, then `resumeTemplate(deployer)` | `revokeTemplate(deployer)` |
   | suspended | `resumeTemplate(deployer)`, then `suspendTemplate(deployer)` | `revokeTemplate(deployer)` |
   | revoked | `reinstateTemplate(deployer)`, then `revokeTemplate(deployer)` | nothing: it is revoked there already |

   The replaced module then lists nothing more. The successor's versions keep their statuses
   and its listings are served as before
   ([`test_OnePair_ARetiredModuleTakesNoMoreListings`](../../test/integration/IndependentOnePair.t.sol),
   `test_OnePair_RetiringKeepsASuspendedAndARevokedVersionAsTheyWere`).
3. **Remove its setter rights.** Close the replaced module in the manager
   (`setTargetClosed(replacedModule, true)`), so no later call changes a status, a share or a
   sale contract there by mistake. From then every change is made in the successor.
4. **Read it back.** For every editions contract the successor serves,
   `entry(entry(editions).partner).partner` is that editions contract.

What the edition auction enforces whether or not these steps were taken: it opens a sale only
for the editions contract that its master's entry names
([IND-78](../spec/independent-stream.md#rules-and-invariants)). A second editions contract
listed for a master through the replaced module opens no sale and is never minted by the
auction. A later sale contract for editions needs the same check.

## Two settings that follow a replaced module

Two contracts keep their own pointer to a module instead of reading it at each use. The network
updates them as part of the replacement:

- **`StatementLog.setArtistResolver(expected, next, codeHash)`** (7-day class). The statement
  log asks its artist resolver who is an artist of a work, pins that resolver's code hash and
  records the resolver in every ARTIST statement. When the contract that answers changes (for
  example a new accounts module), set the new one here; statements already written keep the
  resolver that vouched for them.
- **The edition auction's lens names the package registry it was deployed with**
  (`UniformEditionAuctionLens.packageRegistry()`, fixed in the lens). It asks that registry
  whether a master's item is still approved when an edition sale is opened. A new mint policy
  therefore comes with a new edition auction and lens, added as a minter of
  `StreamEditions6529`; the old auction keeps settling the sales it opened.

## Sale contracts (minters)

**Before a sale contract is admitted** (`addMinter`, or `setAdapter` for Independent Stream
tokens), check in its code that:

- it mints every token to itself, never straight to a buyer: only the minter that holds a token
  can record the token's outcome or burn it;
- it records the outcome (`recordPrimarySale`) before any transfer of the token out of its
  custody, on every path: a sale, an unsold work sent to the museum, a refund;
- it closes a sale whose work the network rescued with refunds, reading the outcome the token
  recorded, as the English auction does
  ([AUC-36, AUC-56](../spec/stream-and-auctions.md#rules-and-invariants)).

`rescue` reaches any token that a removed minter holds with no outcome recorded, and the token
contract keeps no custody history. A token that left its sale contract with no outcome would
stay within reach at any address with code that is later added and removed as a minter
([LIM-SAL-14](../audit/known-limitations.md#sales-and-auctions)). The English auction keeps these
rules ([AUC-57](../spec/stream-and-auctions.md#rules-and-invariants)).

- A removed sale contract still finishes the sales it started.
- A token left in a removed sale contract with no outcome can be rescued after `rescueDelay`
  (`Stream6529.rescue`); an edition with no seal can be rebound after `rebindDelay`
  (`StreamEditions6529.rebind`), then opened with `adopt` or closed with `closeEdition` on the new
  edition auction.
- A rescue ends the work's sale, and two calls close it. Once the sale in the removed English
  auction has reached its end, anyone calls `settle` on it: the standing bid is credited back
  and the sale reads cancelled. If an edition sale followed that 1/1, anyone then calls
  `settle` on the edition auction for it: that call voids it, and its bidders claim their
  refunds (`claimBid`). Until each call is made, the bids of that sale stay where they are.
- Name a rescue recipient other than the sale contract. A rescued work that is in the English
  auction when its sale is settled is sent to the museum; one that reaches the auction after
  its sale closed is sent there by anyone with `sendRescuedToMuseum(saleId)`.
- For Independent Stream tokens, the Independent Stream module's
  `setAdapter(adapter, form, admitted)` admits a sale contract for one token form (ERC-721 or
  ERC-1155).

## Delivery (`WorkRules.setDelivery`)

A finalized work's content hashes are permanent in `StreamWorkFacts6529`. Where its off-chain copies
are served from is the delivery module's answer, so a new delivery module needs the locators of
existing works set again.

## Renderer (`RENDERER`)

A finalized work keeps the renderer it pinned. Works not yet finalized render with the new one
from its activation.
