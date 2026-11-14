# ADR 0006: Work powers and conventions

Status: Accepted by owner instruction, 13 November 2026. Recorded by the delivery owner (Claude
Code, acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md) §7 (royalty changes
become lower-only) and adds to §10 (the lead artist may renounce powers over a work).

## Context

`WorkRecords` is 6529 Stream's records satellite. 6529 Stream binds it once
(`Stream.bindWorkRecords` reverts with `AlreadyBound` after the first call), and 6529 Stream
Editions binds the same contract once; no contract in v1 is upgradeable. Whatever a work's
record can do after launch is therefore fixed by the `WorkRecords` that launches. Two
additions could only be made now:

- **The royalty rate moved either way.** ADR 0001 §7 says existing works keep the terms locked
  at mint and that changing them "requires the artist's agreement plus a governed action".
  `WorkRecords.setRoyaltyRate` implemented that as every party's signature plus FUNDS_SETTER's
  14-day action, in either direction. A collector buys under the rate the work shows; a later
  rise changes that bargain for every later sale.
- **No commitment could be made permanent.** An artist who wants to promise collectors that a
  work's rate or license will never change can only withhold a signature, which a later
  authority of the same artist ID, after a key rotation or a recovery, could give.

Constraints the change had to meet:

- **6529 Stream's code must not change.** Stream compiles `type(IWorkRecords).interfaceId` into
  its bind check, so adding a function to `IWorkRecords` would change its executable bytecode.
  An edit to `IWorkRecords.sol` comments changes only the CBOR metadata hash appended to the
  bytecode (ADR 0001), not the code.
- **The budgets hold.** `WorkRecords` had 1,437 bytes of EIP-170 margin, and CI requires 512 to
  remain; no new storage slot on any path; the source-line budget (13,000) is not raised.

## Decision

### 1. Royalty changes are lower-only (amends ADR 0001 §7)

- **Rule.** `setRoyaltyRate` refuses a rate above the work's current rate with
  `RoyaltyRateNotLowered(tokenId, current, rate)`, before any signature is checked. A lower rate
  needs, as before, every party's `RoyaltyRateChange` signature and FUNDS_SETTER's governed
  action. The current rate stays a no-op (WS-11), so tooling can retry safely.
- **The rate at mint is unaffected.** Governance sets the rate for new works through the
  economics resolver (`EconomicsResolver.setRoyaltyRate`, PARAMETER_SETTER); a work mints at
  that rate whatever earlier works were lowered to, and lower-only binds each work from its own
  current rate.
- **Editions follow.** A linked edition's rate is set only by its master's change
  (`IEditions.setRoyaltyRate`, callable only by `WorkRecords`), and an edition created later
  starts at the master's current rate, so an edition's rate never rises either.
- **Stream keeps its guard.** Stream's `InvalidRoyaltyRate` above its denominator is now
  unreachable through `WorkRecords` (any such rate is above the current one) and stays as a
  second guard.

### 2. Renounceable powers

- **What.** The lead artist may permanently give up, for one work, named powers:
  `WorkPowers.ROYALTY_RATE` (1), any further royalty change, after which `setRoyaltyRate` always
  reverts for the work with `PowerRenounced`, a no-op included; and `WorkPowers.RELICENSE` (2),
  any further license change, after which `relicense` always does. Any other bit reverts with
  `UnknownPower`.
- **Interface.** `renounce(tokenId, powers, expectedStateHash, deadline, artistSignature)`, the
  view `renouncedPowers(tokenId)`, the event `PowersRenounced(tokenId, powers, renounced,
  stateHash)` and the three errors are in a new interface, `IWorkPowers`, which `WorkRecords`
  reports through ERC-165 beside `IWorkRecords`. `IWorkRecords`' functions, events and errors
  and 6529 Stream's code are unchanged: Stream's runtime bytecode is identical before and after
  the change once its trailing CBOR metadata is stripped. Two NatSpec lines of `IWorkRecords`
  were corrected (a renunciation bumps the version; royalty changes are lower-only), which moves
  the metadata hash of every contract that compiles it.
- **Storage.** A `uint16` mask in the last two bytes of the record's first storage word, which
  were spare: no new slot. Bits are only ever added.
- **Authorization.** The lead artist's active authority signs the new EIP-712 type
  `RenouncePowers(uint256 tokenId,uint16 powers,bytes32 stateHash,uint64 deadline)` in the
  records domain, checked as the errata repin's signature is, through the shared signature
  verifier. Anyone may relay it; the function is not restricted, so it needs no role mapping.
  It is compare-and-set on the work's state hash, like `finalize`, and the version bumps, which
  is the storage-backed replay protection every consent in `WorkRecords` uses. The renounced
  mask is not part of the state hash.
- **Why the lead artist alone.** Both powers already need every party's signature, and party 0
  of every item is the lead artist, so the lead artist alone could always refuse them.
  Renouncing makes that refusal permanent and public. It grants nothing and removes nothing a
  collaborator could do without the lead artist, so collaborators do not co-sign.
- **Interactions.**
  - *Unfinalized records:* allowed. Both powers exist before and after finalize; renouncing does
    not finalize and does not block it. The record must be open, since the mask lives in it.
  - *A work in dispute:* treated like any other amendment; no dispute state is kept on the work.
    An upheld dispute that burns the work ends its record. The accepted risk is below.
  - *An authority mid-change:* the artist registry reports no active authority while an
    authority-moving override is pending (owner decision on IDENTITY-1), so nobody renounces
    then; after a change, a former authority's signature no longer verifies.
  - *Editions:* a linked edition follows its master's rate and reads its master's license, so a
    renunciation on the master fixes both for the edition.
  - *Renouncing twice:* renouncing only bits already renounced, or none, is a no-op: it still
    needs an open record and known bits, but checks no state hash, deadline or signature. It
    changes nothing and authorizes nothing, and a revert would only make retries fail.
  - *Pending consents:* the version bump makes every consent collected for the work lapse.
- **The errata repin cannot be renounced.** The errata path (ADR 0001 §10) is how a finalized
  work's renderer is repaired. A pinned renderer that a future gas repricing or another protocol
  change breaks would, with the repin renounced, stay broken for good, and the work's metadata
  with it. The repin keeps its own safeguards: the artist's signature, the code hash, and
  SUCCESSOR_SETTER's 30-day delay.

### 3. Delivered as conventions, without contract code

These need no change to any contract and are specified by a sibling change:

- **Statement kinds** for catalogue entries, citations, custody attestations and the acceptance
  of proposed content. The statement log accepts any non-zero kind, so new kinds need no
  deployment (`StatementKinds`).
- **A declarations document** carried as an `AUXILIARY` media file of the work.
- **An off-chain promise card.**
- **Grade and control proof.**

### 4. Not decided here

Left to the owner, with no code in this change:

- a fixed-price sale adapter;
- declared on-chain content states, with renderer support;
- reveals after settlement;
- any raise of the source-line budget.

## What this amends

ADRs stay as written; [ADR 0001](0001-v1-scope.md) gets a pointer to this record.

- **ADR 0001 §7, "Flexibility".** "Changing them requires the artist's agreement plus a
  governed action" now holds for a lower royalty rate only; a higher one is refused. The rate
  for new works stays governed.
- **ADR 0001 §10, "Permanence".** Beside finalize, the lead artist may make a work's royalty rate
  and license permanent by renouncing the powers to change them. The errata path stays
  available to every work.

## Consequences

- **Bytecode.** `WorkRecords`' runtime grows from 23,139 to 23,946 bytes, leaving 630 bytes of
  EIP-170 margin (512 required). The errata repin and `renounce` share one artist-signature
  check (`_checkArtistConsent`), which saved 38 bytes. 6529 Stream (24,373 bytes, margin 203) is
  unchanged byte for byte.
- **Storage and gas.** No new storage slot on any path. `setRoyaltyRate` and `relicense` read
  the record's first word once more (warm). The re-rate row of `GasReport.t.sol` now lowers the
  rate; its slot and account counts are unchanged.
- **Interfaces.** `IWorkPowers`' ERC-165 ID is `0xbd18229c`; `IWorkRecords`' stays
  `0xc109676d`. The `RenouncePowers` typehash is
  `0xff8cc1b150cf1b390fd870b4a587d3c2632e80f32efbefe166b9f7b0131d3aff`.
- **Rules.** WS-14 (lower-only), WS-37 and WS-38 in
  [Works and storage](../spec/works-and-storage.md#rules-and-invariants).

## Accepted risks

- **A renunciation is permanent.** One signed in error, or by an authority the network later
  finds to be the wrong one, cannot be undone; the work keeps its rate and license. The
  registry's restraint covers the window in which a recovery is pending, not a dispute that is
  never raised as one.
- **A lowered rate cannot be restored.** A rate lowered by mistake, or by agreement the parties
  later regret, stays lowered.
- **A renunciation is immediate, with no guardian veto.** `renounce` is not a governed action:
  it takes effect in the transaction that carries the signature, with no delay a guardian could
  cancel, and nothing can reverse it.
- **Renouncing `RELICENSE` freezes the license entirely.** It also blocks a later move to CC0
  and any correction of the license-text pointer, since both go through `relicense`.
- **After finalize, renouncing lapses collected consents.** The version bump makes every
  consent collected for the work lapse, so the lead artist can, by renouncing any power not yet
  renounced, void consents other parties already signed for a pending amendment (a lower rate,
  a new license or a repin).

## Alternatives considered

- **Add the functions to `IWorkRecords`.** It changes the interface ID compiled into 6529 Stream
  and 6529 Stream Editions, and so their bytecode. Rejected.
- **A separate powers contract.** `WorkRecords` would still have to consult it on every
  `setRoyaltyRate` and `relicense`, at more bytecode and an external call. Rejected.
- **Let collaborators co-sign the renunciation.** It protects no one (see "Why the lead artist
  alone") and costs every party a signature.
- **Commit the mask in the state hash.** It would change WS-10's formula, its golden test and
  every signer's state computation; the version bump already moves the state hash.
- **Revert on a repeated renunciation.** It would only make retries fail; the no-op changes
  nothing.
- **Make the errata repin renounceable.** Rejected for the reason in §2.

## Open items

The items in §4, and the sibling change specifying the conventions in §3.
