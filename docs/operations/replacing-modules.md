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

- **What it inherits.** For an account it has not recorded, the new module answers from the
  record of the module it replaces, read at each use: the root, whether anybody may act
  (a freeze, a pending replacement), the payout address and the pending change. Every address
  that has been a root still names its account. An account that moved keeps its ID, its new
  root and its payout address; the address its ID was made from has no power. Changes made
  in the old module during the wait and after it are served, for as long as the new module
  has not recorded the account itself.
- **What it decides itself.** Which wallets are consolidated with a root is the new module's
  own consolidation source's answer, also for inherited accounts. The payout check is the
  new module's: a payout address the old module holds and the new one refuses is not paid
  (the share is held), and the account names another in the new module.
- **What it never does.** It never creates an account for an address the old module knows as
  a root or a former root, or reserves for a pending change (`AccountTaken`). Only an address
  no module of the chain knows registers as a new artist, with the ID its address gives.
- **The first change copies the account.** The first time a function of the new module changes
  an inherited account (`freeze`, `unfreeze`, `stageReplacement`, `stageChange`, `revokeNonce`,
  a cancel, a contest, an execution), it copies the record there, with its freeze and its
  pending change (`AccountInherited`, and `ChangeStaged` for the pending change). From then
  on the new module alone answers for that account, and nothing done in the old module
  reaches it. What the new module recorded comes first: an address it already maps to an
  account keeps that account, and a pending change whose new root a change pending in the
  new module reserves cannot be copied until one of the two ends (`AccountTaken`). So after
  activation, act in the new module. A change is signed in the new module's EIP-712 domain,
  at the account's nonce there (zero until its first change there). A contested replacement
  that was copied is resolved by a DISPUTE_OUTCOME recorded for the new module's address
  after the copy.
- **What it does not inherit.** Used replacement acceptances and the change nonce (both are
  bound to the old module's domain, so they cannot be replayed in the new one). The list of
  contracts refused as a payout by address (`notPayouts`) is a constructor argument: pass
  the old list and add what was deployed since.
- **A chain of replacements** works the same way: each module asks the one it replaced. Each
  generation adds reads for accounts no later module recorded.
- **If the old module stops answering** (it cannot, with the current code, short of running out
  of gas), its accounts have nobody acting and their payout held, no new artist registers,
  and the accounts the new module recorded are unaffected. A read that runs short of gas
  reverts. The remedy is another replacement.

Before announcing a new accounts module:

1. **Deploy it with `previous` set to the module in force**, with the same consolidation
   source and wiring, and the `notPayouts` list.
2. **Map its roles** (step 2 above), `freeze` and `unfreeze` first: an unmapped `freeze`
   would wait 7 days.
3. **Compare it with the module in force.** Run
   [`script/CheckReplacement.s.sol`](../../script/CheckReplacement.s.sol) with every artist
   ID (`ArtistRegistered`) and every address that was ever a root (`ChangeExecuted`): the
   candidate must answer alike for the root, the acting root, the payout address, the
   freeze, the pending change and each wallet. The check covers only what is on its
   lists: build them from the whole event history of the module in force, since a list
   that leaves an account out says nothing about it. Run it again right before activation.
   [`AccountsSuccessor.t.sol`](../../test/integration/AccountsSuccessor.t.sol) shows the
   whole replacement on the deployed stack, a moved account included.
4. **Bind the package registry** as the new module's `register` caller (a constructor
   argument), so new artists can still accept a package.
5. **Keep the old module's roles mapped** until every account it holds has been copied or
   no longer matters: its record is still read.

A module with other code must do the same by its own means: serve every existing account
under its existing ID, with the same wallets, payout address, pending change and freeze,
and give no power to an address that lost it. A module that cannot must not be activated
while any artist has money waiting or a work that can still be edited.

After it takes effect, check `payoutAddress` for a sample of artists with money waiting,
including every artist whose account has moved, and set the statement log's artist resolver
(below).

## Mint policy (`PackageRegistry`)

A curator's attestation is signed in the verifier's domain and names no registry. A second
registry on the same verifier would therefore take any attestation the first took. So a new
`PackageRegistry` is deployed naming the one it replaces (`previous`), and:

- **What it inherits: revocations.** A root the old policy reports as revoked (`isRevoked`)
  is never registered in the new one and is not live there: a root revoked after
  registration, a root revoked in advance, and every root a signer registered before its
  approvals were killed. The new policy asks the old one at each use, so a revocation or a
  kill made in the old policy after the replacement still stops the root in the new one. A
  chain of replacements works the same way.
- **What it does not inherit.** Approvals: a root that was approved and never revoked is
  registered again in the new policy by anyone, with the attestation it already has.
  Acceptances and move signatures: they are signed in the registry's own domain, so every
  party accepts again and the lead artist signs the move again. Move nonces start again at
  zero. Retired verifiers: do not build the new policy on a verifier the old one retired.
  Content releases and barred items: content uniqueness still holds through
  `Stream6529.tokenOfContent`, so the content of a burned work stays unmintable until the
  network releases it again in the new policy (`releaseContent`), which bars the burned
  item there too. A release made in the old policy and not yet used must be made again.
- **Revoke in the new policy from now on.** A revocation made in the new policy does not
  reach the old one, which a sale contract may still be reading during the transition:
  until every sale contract reads the new policy, revoke in both.
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
`PackageRevoked` and every root registered by a signer named in `SignerApprovalsKilled`:
each one the old policy reports as revoked must be revoked in the candidate. A root left off
the list is not checked.
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

- A removed sale contract still finishes the sales it started.
- A token left in a removed sale contract with no outcome can be rescued after `rescueDelay`
  (`Stream6529.rescue`); an edition with no seal can be rebound after `rebindDelay`
  (`StreamEditions6529.rebind`), then opened with `adopt` or closed with `closeEdition` on the new
  edition auction.
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
