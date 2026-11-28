# Replacing a module

A checklist for the network when it replaces a module of `Stream6529`, `StreamEditions6529`,
`StreamDirectory6529` or an Independent Stream token. The calls and their timing are in the
[runbook](../../script/README.md#modules-and-minters); the rules are in the
[governance spec](../spec/governance.md). The contracts do not enforce this checklist.

Tokens, the facts of finished works and money already owed do not depend on any module, so a
replacement never changes them. What a replacement does change is listed below, per module.

## Every module

1. **Deploy the new instance** with the same constructor arguments as the one it replaces,
   unless a change is the point of the replacement. The accounts module and the mint policy
   take one more argument, `previous`: the instance being replaced (zero only for the first
   one of a deployment). What each inherits through it is below.
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

Tokens and vaults name artists by ID, and an ID is the address the artist first registered
with. A module that knew nothing of an artist would treat that first address as the account,
even after the account had moved to another address. So a new `Accounts` is deployed naming
the module it replaces (`Wiring.previous`), and:

- **One module writes.** Every function that creates or changes an account works only in
  the module the directory names (`NotModule` otherwise). A module that is announced and
  not yet activated changes nothing and copies nothing: it only reads the module in force,
  so a freeze, a replacement or an account's own change made during the wait is what it
  serves at activation. A module that has been replaced changes no more, for the network
  and for every wallet, so the record its successor reads stands still. During the wait,
  act in the module in force; after activation, act in the new one.
- **What it inherits.** For an account it has not recorded, the new module answers from the
  record of the module it replaces, read at each use: the root, whether anybody may act
  (a freeze, a pending replacement), the payout address and the pending change. Every address
  that has been a root still names its account. An account that moved keeps its ID, its new
  root and its payout address; the address its ID was made from has no power.
- **What it decides itself.** Which wallets are consolidated with a root is the new module's
  own consolidation source's answer, also for inherited accounts; the old module's source
  no longer decides anything once it is replaced. A payout address the old module holds
  and the new one refuses by address (a contract of the deployment, a vault of the split
  ledger) is not paid: the share is held, and the account names another in the new module.
  The payout contract itself is not called for this, so it cannot stand in the way.
- **What it never does.** It never creates an account for an address the old module knows as
  a root or a former root, or reserves for a pending change (`AccountTaken`). Only an address
  no module of the chain knows registers as a new artist, with the ID its address gives.
- **The first change copies the account.** The first time a function of the new module changes
  an inherited account (`freeze`, `unfreeze`, `stageReplacement`, `stageChange`, `revokeNonce`,
  a cancel, a contest, an execution), it copies the record there, with its freeze and its
  pending change (`AccountInherited`, and `ChangeStaged` for the pending change).
  `copyAccounts(ids)` does the same for a list, and anyone may call it. From then on the new
  module alone answers for that account. A copy calls only the old module and the statement
  log, never an address the account chose, so nothing an account does can hold up a freeze
  or a replacement. What the new module recorded comes first: an address it already maps to
  an account keeps that account, and a pending change whose new root a change pending in
  the new module reserves is left behind (the account is copied without it). A change is
  signed in the new module's EIP-712 domain, at the account's nonce there (zero until its
  first change there). A contested replacement that was copied is resolved by a
  DISPUTE_OUTCOME recorded for the new module's address after the copy: copy the account
  first, then record the outcome. The copy maps the root and the address the ID is made
  from; any other address that was a root before the copy is still looked up in the old
  module.
- **What it does not inherit.** Nothing signed for the old module verifies in the new one:
  used replacement acceptances, the change nonce, and every consent (`requireConsent`: a
  collaborator's consent to an Independent Stream work, a consent to a relicense or a
  renunciation) are bound to the old module's EIP-712 domain. Consents not yet used are
  signed again for the new module. The list of contracts refused as a payout by address
  (`notPayouts`) is a constructor argument: pass the old list and add what was deployed
  since.
- **What a read of the old module costs.** A start whose artist the new module has not
  copied pays for those reads: about 5,600 gas more when the root signed the move and
  about 12,800 more when another wallet did (measured, a whole start, one replacement back). A
  copied account starts for what it cost before the replacement. The ceilings of the
  [gas table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table) hold for copied
  accounts; a start signed by a consolidated wallet of an account not yet copied passes
  the 370,000 ceiling. So copy the accounts after activation (below).
- **A chain of replacements** works the same way: each module asks the one it replaced. Each
  generation adds reads for accounts no later module recorded.
- **If the old module stops answering** (it cannot, with the current code, short of running out
  of gas), its accounts have nobody acting and their payout held, and no new artist
  registers. The accounts the new module recorded keep acting, being paid and being frozen;
  naming a new root for one of them still needs the old module's answer, because the
  address must be known to be free. A read that runs short of gas reverts. The remedy is
  another replacement.

Before announcing a new accounts module:

1. **Deploy it with `previous` set to the module in force**, with the same consolidation
   source and wiring, and the `notPayouts` list.
2. **Map its roles** (step 2 above), `freeze` and `unfreeze` first: an unmapped `freeze`
   would wait 7 days.
3. **Compare it with the module in force.** Run
   [`script/CheckReplacement.s.sol`](../../script/CheckReplacement.s.sol) with every artist
   ID (`ArtistRegistered`, `AccountInherited`) and every address that was ever a root
   (`ChangeExecuted`, `AccountInherited`): the candidate must answer alike for the root, the
   acting root, the payout address, the freeze, the pending change and each wallet. The
   check covers only what is on its lists. Build them from the whole event history of the
   module in force and of every module before it (follow `previous()` back to the first):
   a module emits nothing for an account it only reads from the one it replaced, so its
   own events leave such accounts out. Run it again right before activation.
   [`AccountsSuccessor.t.sol`](../../test/integration/AccountsSuccessor.t.sol) shows the
   whole replacement on the deployed stack, a moved account included.
4. **Bind the package registry** as the new module's `register` caller (a constructor
   argument), so new artists can still accept a package.

After it takes effect:

1. **Copy the accounts**: `copyAccounts` with every artist ID, in batches, starting with the
   artists who have a sale coming. Run the comparison again afterwards.
2. Check `payoutAddress` for a sample of artists with money waiting, including every artist
   whose account has moved.
3. Set the statement log's artist resolver (below).
4. Tell artists and collaborators that consents and changes signed for the old module must
   be signed again.

A module with other code must do the same by its own means: serve every existing account
under its existing ID, with the same wallets, payout address, pending change and freeze,
and give no power to an address that lost it. A module that cannot must not be activated
while any artist has money waiting or a work that can still be edited.

## Mint policy (`PackageRegistry`)

A curator's attestation is signed in the verifier's domain and names no registry. A second
registry on the same verifier would therefore take any attestation the first took. So a new
`PackageRegistry` is deployed naming the one it replaces (`previous`), and:

- **What it inherits: revocations.** A root the old policy reports as revoked (`isRevoked`)
  is never registered in the new one and is not live there: a root revoked after
  registration, a root revoked in advance, and every root a signer registered before its
  approvals were killed. The new policy asks the old one at each use, so a revocation made
  in the old policy after the replacement still stops the root in the new one. A kill made
  in the old policy stops only the roots that signer registered in the old policy; a root
  it registered only in the new policy needs the kill there. A chain of replacements works
  the same way. The read costs each start under the new policy about 8,000 gas, which takes
  a start signed by a consolidated wallet past the gas table's 370,000 ceiling (a
  root-signed start stays well inside).
- **What it does not inherit.** Approvals: a root that was approved and never revoked is
  registered again in the new policy by anyone, with the attestation it already has.
  Acceptances and move signatures: they are signed in the registry's own domain, so every
  party accepts again and the lead artist signs the move again. Move nonces start again at
  zero. Retired verifiers: do not build the new policy on a verifier the old one retired.
  Content releases and barred items: content uniqueness still holds through
  `Stream6529.tokenOfContent`, so the content of a burned work stays unmintable until the
  network releases it again in the new policy (`releaseContent`), which bars the burned
  item there too. A release made in the old policy and not yet used must be made again.
- **Revoke and kill in both until the transition is over.** A revocation or a kill made in
  the new policy does not reach the old one, which a sale contract may still be reading
  during the transition, and a kill made in the old one does not reach roots registered
  only in the new one: until every sale contract reads the new policy, do both in both.
  A root registered in the new policy before the sale contracts switch is covered by the
  same rule: the new policy never copies anything from the old one, it asks at each use.
- **If the old policy stops answering**, every root is refused in the new one. A read that
  runs short of gas reverts.

**The other way: a new verifier and no predecessor.** A policy deployed with `previous` zero
inherits nothing. It is safe only on a new `Eip712CurationVerifier` instance: its domain is
new, so no earlier attestation verifies, and the curation signers attest again every root
that is to carry over, including the roots of edition masters whose 1/1 is running. Use it
when the old policy itself is what must be left behind, or does not declare `IRevokedRoots`
(an instance of earlier code cannot be named as `previous`). Never deploy a policy with no
predecessor on a verifier that has attested before.

Before switching the sale contracts to a new mint policy, run
[`script/CheckReplacement.s.sol`](../../script/CheckReplacement.s.sol) with every root of
`PackageRevoked` and every root registered by a signer named in `SignerApprovalsKilled`,
from the events of the old policy and of every policy before it: each one the old policy
reports as revoked must be revoked in the candidate. A root left off the list is not
checked.
[`MintPolicySuccessor.t.sol`](../../test/integration/MintPolicySuccessor.t.sol) shows both
ways on the deployed stack.

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
