# Replacing a module

A checklist for the network when it replaces a module of `Stream`, `Editions`, `Directory` or a
federated token. The calls and their timing are in the
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

## Accounts (`ACCOUNTS` on `Directory`)

A new accounts module starts empty. It has no read-through to the one it replaces and no
import function, so:

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

Before announcing a new accounts module, make sure every existing artist is in it (same IDs,
wallets and payout addresses), or publish the date from which artists register again. After
it takes effect, check `payoutAddress` for a sample of artists with money waiting.

## Mint policy (`PackageRegistry`)

A new mint policy starts with no content releases and no barred items. Content uniqueness
still holds through `Stream.tokenOfContent`, so the content of a burned work stays unmintable
until the network releases it again in the new policy (`releaseContent`), which bars the
burned item there too. A release made in the old policy and not yet used must be made again.

## Sale contracts (minters)

- A removed sale contract still finishes the sales it started.
- A token left in a removed sale contract with no outcome can be rescued after `rescueDelay`
  (`Stream.rescue`); an edition with no copies and no seal can be rebound after `rebindDelay`
  (`Editions.rebind`), then opened with `adopt` or closed with `closeEdition` on the new
  edition auction.
- For federated tokens, the federation module's `setAdapter(adapter, form, admitted)` admits
  a sale contract for one token form (ERC-721 or ERC-1155).

## Delivery (`WorkRules.setDelivery`)

A finalized work's content hashes are permanent in `WorkFacts`. Where its off-chain copies are
served from is the delivery module's answer, so a new delivery module needs the locators of
existing works set again.

## Renderer (`RENDERER`)

A finalized work keeps the renderer it pinned. Works not yet finalized render with the new one
from its activation.
