# Sepolia r8: an unsold work offered again, beside its edition sales (23 November 2026)

On 23 November 2026 the flows below ran on **r8**
([README](README.md#sepolia-r8-23-november-2026-current-instance)), the current Sepolia instance
of the plain permanent core ([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)), `main` at
`961bc956`, record [`core-1795440624.json`](core-1795440624.json). r8 carries the module changes
of that commit, which r6 and r7 do not: an edition sale follows only the 1/1 sale it was opened
in, `EnglishAuction.restart` is accepted from 15 minutes after the ended sale's end, and
`auctionClock` answers a fourth value, when the work was last offered again. The flows are
about those changes; the basics ran once. r7's flows are in [flows-r7.md](flows-r7.md).
Nothing here changed r8's governance: no module was announced, no setting, role or minter
changed, and `script/VerifyCore.s.sol` passed at the chain's head after the last transaction
below (block 12,197,562).

This is a testnet rehearsal with throwaway keys, and the code is pre-audit. The figures are
Sepolia receipts: Sepolia reprices state creation (Glamsterdam), so they are not the Prague
figures the gas budgets are written in. The tables give both: the Sepolia receipt and the same
transaction replayed on its parent block's state at Prague prices (`flows.ps1 -Step prague`,
which runs `cast run --quick --evm-version prague`).

Every transaction was planned by [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol)
against the live chain and sent by [`script/sepolia/flows.ps1`](../../script/sepolia/flows.ps1)
with `cast send`. The state file is [`flows/r8.json`](flows/r8.json); it also holds every
reading quoted below (`notes.snapshots`). Accounts: `any` is the keeper key (no role);
`platform`, `curator`, `artist` and the four bidders are the throwaway keys of r5 to r7, and the
network's one call went through its Safe with two owner signatures. All times are UTC.

**A pause in the run.** The run stopped between 14:56 and 16:41 for a reason outside the chain.
Nothing was sent in that time. The steps that had to fall inside a window had already been
sent (the refused early restart and the late edition bid, both within three minutes of the
1/1's end); the steps after it have no upper time limit (a restart is accepted at any time from
15 minutes after the end, an edition sale settles at any time after its close), so they ran
when the run resumed, and the times below show it.

## The three works

The artist key deployed its own Independent Stream 1/1 contract
([`0xB7dd405dCeeD1d8Bf75f513C2656E07d5a8EC374`](https://sepolia.etherscan.io/address/0xB7dd405dCeeD1d8Bf75f513C2656E07d5a8EC374), [`0x01191058…`](https://sepolia.etherscan.io/tx/0x01191058c81c95f528a9c2c154a36b86f61fd320f998d7b44d571c3edf2e6dd9)) and the
editions contract that partners it
([`0x435c8f877841D64451e920b4124CC84e8F273143`](https://sepolia.etherscan.io/address/0x435c8f877841D64451e920b4124CC84e8F273143), [`0x0116e607…`](https://sepolia.etherscan.io/tx/0x0116e607a92500f1a17e2088140a4af1dd01247138eec18163e5657d062b0fe7)),
listed both ([`0xe68619e8…`](https://sepolia.etherscan.io/tx/0xe68619e8a49ed4ad73187e4010ca56f7fcbf4cb0ffaa4131e82e4808e82d98b2), [`0x3290b145…`](https://sepolia.etherscan.io/tx/0x3290b1459a62e32aaa57b495c5e77e8ce884419cc78dc9a21a04054abc569902)) and approved
three edition masters, each with its own media ([`0x7ef30b25…`](https://sepolia.etherscan.io/tx/0x7ef30b2575808b3dbab30a0f99c74a2e022659d48573d9dbc4146c10eb40630b),
[`0x7c45b6ff…`](https://sepolia.etherscan.io/tx/0x7c45b6ff3d85f2de30adc1e978e1c1ea9bfaac9235cb6b92aa624f1110b9f5ef), [`0xd9cb63e3…`](https://sepolia.etherscan.io/tx/0xd9cb63e3213853a561f2960640674d116de87455745d9b227c5c963682b38442)). Anyone may
start an approved work; the keeper key started all three **with no bid**
([`0xf2e23c6a…`](https://sepolia.etherscan.io/tx/0xf2e23c6a82da257792bd0677f1d1e9526a781bfa912de7c475ed61dd4287ee72), [`0xa36bd5ee…`](https://sepolia.etherscan.io/tx/0xa36bd5eead4ded93e07fda893cf54b365078c39d69b5de7e53b955c6119077e9),
[`0x745e856d…`](https://sepolia.etherscan.io/tx/0x745e856dab7af9a6b75a2e5b0e9b4fd9dce9fe3a9ecd78598d56230ed0359e12)): tokens 1, 2 and 3, called A, B and C below. Their 1-hour
sales ended at 14:53:48, 14:54:00 and
14:54:12 with no bid.

## A. The edition sale finishes on its own clock; then the 1/1 is offered again

1. **An edition sale beside the 1/1.** Anyone opened A's edition sale in the Independent Stream
   edition auction ([`0xe83c5d02…`](https://sepolia.etherscan.io/tx/0xe83c5d02a2969c225d505a58a79c4b35ccb190979d4e7d9ab512a39f5cdc6c93)). It recorded the 1/1's end,
   14:53:48, and its own close 15 minutes later,
   15:08:48. Bidder 1 bid for 2 copies at step 20
   ([`0x09813170…`](https://sepolia.etherscan.io/tx/0x098131702584f4de2f20b184f6f0ef26edd4d52574e45849b5102675c26141f4)) and bidder 3 for 1 copy at step 10 ([`0xb9bd2eb4…`](https://sepolia.etherscan.io/tx/0xb9bd2eb4191086a4d941bffc2eb50146dea8d3bfabb5c33308e8cc58369fbb2a)).
2. **The 1/1 ends unsold and is settled.** After the end the keeper key settled it
   ([`0xd1950a2f…`](https://sepolia.etherscan.io/tx/0xd1950a2ff24e322aa40c5312816283a3c2002dfb55d9e2d8fe79789da118d268)): state SETTLED, the token still held by the auction, no outcome.
3. **A restart at once is refused.** `restart`, sent 120 seconds after the end, reverted
   with `RestartTooEarly(saleId, 1795446528)`: 1795446528 is the end plus 900 seconds
   (15:08:48). The failed transaction is [`0x2b871952…`](https://sepolia.etherscan.io/tx/0x2b87195226b442c4d95a85f547ddae3846d2bef0cbc75e5d1dd45c60addbe870).
4. **The edition sale is still open and takes a late bid.** Bidder 2 bid for 1 copy at step 25
   after the 1/1's end and before the edition's close ([`0x832498fc…`](https://sepolia.etherscan.io/tx/0x832498fc533cbbd8416d8cb7a8f4d4b2b08e94d74cbf4e535374c38184db7b67), read back
   at 14:56:00). The clearing moved from 3 copies at step
   10 to 3 copies at step 20.
5. **The edition sale settles and its bidders claim.** After the close anyone settled it
   ([`0xeadd8eda…`](https://sepolia.etherscan.io/tx/0xeadd8edad2186973ccfb062ebc7f88744146ccd91f901bac2917bbd314685fe7)): 3 copies at 0.000261 ETH each. Bidder 1 claimed 2 copies
   ([`0x28e8b773…`](https://sepolia.etherscan.io/tx/0x28e8b7733da83426d2b8470ced7c8a2c61d5e698bb158f8493431349ca35cdc9)), bidder 2 one copy and the rest of its step-25 escrow
   ([`0x76d05635…`](https://sepolia.etherscan.io/tx/0x76d05635c68b6c1e7186266d895b835c3dae562702cf79fd033fccaa688595c3)), and bidder 3, below the clearing step, its whole escrow and no copy
   ([`0xd7cf405f…`](https://sepolia.etherscan.io/tx/0xd7cf405fa219405bf4cb59cac4dd0883560ad429d008832a77d2839846dc97c3)).
6. **After the 15 minutes the restart succeeds.** [`0xb0ae0650…`](https://sepolia.etherscan.io/tx/0xb0ae0650c3712d615afc9fad113db8f27b72a641cb0cefff324ec5e91f8d07f4): the work is ACTIVE
   again under the same sale ID with a new end, and `auctionClock`'s fourth value holds the
   time of the restart.
7. **The restarted 1/1 runs on its own.** It took no bid, ended at
   17:42:24 and was settled unsold again ([`0x6bd773d7…`](https://sepolia.etherscan.io/tx/0x6bd773d74415f4860540a6b490f2dfa445a96104be01f8fe633e2d85e2840ce6)).
8. **A second restart later moves nothing in the settled edition sale.** [`0x5fbb5b23…`](https://sepolia.etherscan.io/tx/0x5fbb5b23fefdfb96788ffb4312c54781a79644a1d4dce96fc7c1ae8e60058f5a),
   then a third sale with no bid, settled at its end ([`0xadd6ff56…`](https://sepolia.etherscan.io/tx/0xadd6ff568437a96d567e8e57da7ed643635f4c4568e8ae20459c7a13ab050a2c)). The edition sale
   reads the same before and after each of them: SETTLED, the 1/1 end it recorded
   (14:53:48), its close (15:08:48), 3
   copies at step 20.

`auctionClock(saleId)` of A's 1/1 (the four words):

| When | Block | Read at (UTC) | `state` | `endTime` | `pausedAt` | `restartedAt` |
| --- | ---: | --- | --- | --- | ---: | --- |
| Started | 12,196,113 | 13:54:12 | ACTIVE | 1795445628 (14:53:48) | 0 | 0 |
| After the end, before `settle` | 12,196,406 | 14:55:00 | ENDED | 1795445628 (14:53:48) | 0 | 0 |
| Settled unsold | 12,196,407 | 14:55:24 | SETTLED | 1795445628 (14:53:48) | 0 | 0 |
| Before the first restart | 12,196,906 | 16:42:12 | SETTLED | 1795445628 (14:53:48) | 0 | 0 |
| After the first restart | 12,196,907 | 16:42:24 | ACTIVE | 1795455744 (17:42:24) | 0 | 1795452144 (16:42:24) |
| Second sale settled unsold | 12,197,202 | 17:44:36 | SETTLED | 1795455744 (17:42:24) | 0 | 1795452144 (16:42:24) |
| After the second restart | 12,197,266 | 17:57:48 | ACTIVE | 1795460268 (18:57:48) | 0 | 1795456668 (17:57:48) |
| Third sale settled unsold | 12,197,559 | 18:59:00 | SETTLED | 1795460268 (18:57:48) | 0 | 1795456668 (17:57:48) |

A's edition sale, as the Independent Stream edition auction answers it (`endTimes`, `auction`,
`clearing`):

| When | Block | Read at (UTC) | Status | 1/1 end it keeps | Close | 1/1 as the sale reads it | Bidding open | Bids | Clearing now |
| --- | ---: | --- | --- | --- | --- | --- | --- | ---: | --- |
| Open, two bids | 12,196,120 | 13:55:48 | OPEN | 14:53:48 | 15:08:48 | ACTIVE | true | 2 | 3 at step 10 |
| After the late bid (1/1 settled unsold) | 12,196,410 | 14:56:00 | OPEN | 14:53:48 | 15:08:48 | SETTLED | true | 3 | 3 at step 20 |
| Closed, before `settle` | 12,196,902 | 16:41:24 | CLOSED | 14:53:48 | 15:08:48 | SETTLED | false | 3 | 3 at step 20 |
| Settled | 12,196,903 | 16:41:36 | SETTLED | 14:53:48 | 15:08:48 | SETTLED | false | 3 | 3 at step 20 |
| After the first restart (1/1 ACTIVE) | 12,196,907 | 16:42:24 | SETTLED | 14:53:48 | 15:08:48 | SETTLED | false | 3 | 3 at step 20 |
| After the second restart (1/1 ACTIVE) | 12,197,266 | 17:57:48 | SETTLED | 14:53:48 | 15:08:48 | SETTLED | false | 3 | 3 at step 20 |
| After the third sale settled | 12,197,559 | 18:59:00 | SETTLED | 14:53:48 | 15:08:48 | SETTLED | false | 3 | 3 at step 20 |

## B. The 1/1 is offered again first; the closed edition sale then settles on its own clock

B ran as A up to the close: an edition sale beside the 1/1 ([`0xa94aa49d…`](https://sepolia.etherscan.io/tx/0xa94aa49dbeb5fa513cdb8f7f40bc70fff05dc2de35a19caa5bd3ae160ca68a38)),
bidder 4 for 1 copy at step 20 ([`0xe9cd5147…`](https://sepolia.etherscan.io/tx/0xe9cd5147c495bf5307ba4cf1265381b0d2a1810052d340fabe9ec9fc1c73a866)) and bidder 2 for 1 copy at step 15
([`0x68c211e8…`](https://sepolia.etherscan.io/tx/0x68c211e8ed559e87d9bd9b58b0b9cda8293abd11b1549fd0479588f01b4687c4)), the 1/1 settled unsold ([`0xdfb0d363…`](https://sepolia.etherscan.io/tx/0xdfb0d3637cc7d9bb4a25fafe7676dd34879fb453923736927af77ff67f0c3160)), and a restart at once
refused with `RestartTooEarly` ([`0x43cd682e…`](https://sepolia.etherscan.io/tx/0x43cd682e9fdaeae5f476ef88b53dbb78e75e5fd69da37e1f8fc634c0c322bc3d)).

Then the order was reversed. With the edition sale closed and **not** settled, anyone restarted
the 1/1 ([`0xe5f3544f…`](https://sepolia.etherscan.io/tx/0xe5f3544f1f45d0410e4b431010a2e7cd6e42828857e51d176ffd14b2137dfe2b)): ACTIVE, ending 17:42:48. The
edition sale did not follow it: it still read its 1/1 as SETTLED, kept the end it recorded
(14:54:00) and its close (15:09:00), and
stayed closed to bids. Anyone settled it while the restarted 1/1 was ACTIVE
([`0xf17f9ae3…`](https://sepolia.etherscan.io/tx/0xf17f9ae3a8b1e9700f4007a7cb04957d2d8e281ff0205c0262c1bf18849f72a9), one block after the restart): 2 copies at 0.000205 ETH each. Bidder
4 claimed one copy and the rest of its step-20 escrow ([`0xc60b899a…`](https://sepolia.etherscan.io/tx/0xc60b899a18a4197c582deefc2479f7258afe4f7b60c4ee6b828cc2c31d194a2c)) and bidder 2 one
copy ([`0x3cc846fa…`](https://sepolia.etherscan.io/tx/0x3cc846fac224cf3d718ce548b9af423bdc10ad6999b875e0a8fd29b9463194fc)). The restarted 1/1 took no bid and was settled unsold at its end
([`0xa0a07968…`](https://sepolia.etherscan.io/tx/0xa0a079681e540c8b2fc69b2a3b238a0e12cbdae60a368d8879b90c984cc72b9c)).

| When | Block | Read at (UTC) | `state` | `endTime` | `pausedAt` | `restartedAt` |
| --- | ---: | --- | --- | --- | ---: | --- |
| Started | 12,196,113 | 13:54:12 | ACTIVE | 1795445640 (14:54:00) | 0 | 0 |
| Settled unsold, before the restart | 12,196,907 | 16:42:24 | SETTLED | 1795445640 (14:54:00) | 0 | 0 |
| After the restart | 12,196,909 | 16:42:48 | ACTIVE | 1795455768 (17:42:48) | 0 | 1795452168 (16:42:48) |
| When the edition sale settled | 12,196,910 | 16:43:00 | ACTIVE | 1795455768 (17:42:48) | 0 | 1795452168 (16:42:48) |
| Second sale settled unsold | 12,197,202 | 17:44:36 | SETTLED | 1795455768 (17:42:48) | 0 | 1795452168 (16:42:48) |

| When | Block | Read at (UTC) | Status | 1/1 end it keeps | Close | 1/1 as the sale reads it | Bidding open | Bids | Clearing now |
| --- | ---: | --- | --- | --- | --- | --- | --- | ---: | --- |
| Open, two bids | 12,196,120 | 13:55:48 | OPEN | 14:54:00 | 15:09:00 | ACTIVE | true | 2 | 2 at step 15 |
| Closed, before the restart | 12,196,907 | 16:42:24 | CLOSED | 14:54:00 | 15:09:00 | SETTLED | false | 2 | 2 at step 15 |
| Closed, the restarted 1/1 ACTIVE | 12,196,909 | 16:42:48 | CLOSED | 14:54:00 | 15:09:00 | SETTLED | false | 2 | 2 at step 15 |
| Settled, the restarted 1/1 ACTIVE | 12,196,910 | 16:43:00 | SETTLED | 14:54:00 | 15:09:00 | SETTLED | false | 2 | 2 at step 15 |
| After the second sale settled | 12,197,202 | 17:44:36 | SETTLED | 14:54:00 | 15:09:00 | SETTLED | false | 2 | 2 at step 15 |

## C. An edition sale opened inside the restarted 1/1 follows that sale

C had no edition sale in its first sale. It was settled unsold ([`0x3ff6a7fd…`](https://sepolia.etherscan.io/tx/0x3ff6a7fd558703da08c82e0888d1621ed36333470e1ef9e8b8530b57f1bae28e)) and offered
again ([`0x6cb7846b…`](https://sepolia.etherscan.io/tx/0x6cb7846b232ce96512974bb8ba01ab404657bb949e077d485d7cbe847b93f90c)), ending 17:43:36. Anyone then
opened its edition sale ([`0x014791d4…`](https://sepolia.etherscan.io/tx/0x014791d4ac67ddc2a93124707053e44534700f40c8e62240a4b0fe195a59bc69)), which recorded the restarted sale's
end and a close 15 minutes after it, 17:58:36. Bidder 2 bid for 1 copy
at step 10 ([`0x9ea4b1af…`](https://sepolia.etherscan.io/tx/0x9ea4b1af224f55d647d7494df003cc7bbf09815ef8489d37bacd02491c4adc92)) and bidder 3 for 1 copy at step 20
([`0x0f3da991…`](https://sepolia.etherscan.io/tx/0x0f3da991e13f25cd10adb91dbe5d52fb3907973f6cf1350c77f8c3b922cf1a1d)).

Bidder 1 bid 0.05 ETH on the 1/1 inside its last 15 minutes ([`0xe905c461…`](https://sepolia.etherscan.io/tx/0xe905c4613bc3ae96b02c31d21b9122bb360659e42c1090975dce04e684bc8cf1)), which moved
the 1/1's end to 17:49:48, 15 minutes after the bid. The
edition sale followed: its close moved from 17:58:36 to
18:04:48. The 1/1 was settled after its new end
([`0x3bee5f11…`](https://sepolia.etherscan.io/tx/0x3bee5f11fab26a432a2a5779824795eb8d9e1f88aa3bd46cd2e2a48db34cf820)): the token went to bidder 1. After the edition's close anyone settled it
([`0x7cc79b71…`](https://sepolia.etherscan.io/tx/0x7cc79b713750956b5866aa6fffebdf1e6ad74373668d0995b80c8b996adca347)): 2 copies at step 10, 0.000162 ETH each. Bidder 2 and bidder 3 claimed
([`0xe08f45c0…`](https://sepolia.etherscan.io/tx/0xe08f45c00a0dee0fb3f0879c9e026a51f48643296a4f8d6ff7bb5a45351cbe8b), [`0x773dadf6…`](https://sepolia.etherscan.io/tx/0x773dadf69543187e44073f713353f6e81b3aa33ec7be0975da3e042a3fefeda7)).

| When | Block | Read at (UTC) | `state` | `endTime` | `pausedAt` | `restartedAt` |
| --- | ---: | --- | --- | --- | ---: | --- |
| Started | 12,196,113 | 13:54:12 | ACTIVE | 1795445652 (14:54:12) | 0 | 0 |
| Settled unsold, before the restart | 12,196,912 | 16:43:24 | SETTLED | 1795445652 (14:54:12) | 0 | 0 |
| After the restart | 12,196,913 | 16:43:36 | ACTIVE | 1795455816 (17:43:36) | 0 | 1795452216 (16:43:36) |
| After the late bid | 12,197,159 | 17:34:48 | ACTIVE | 1795456188 (17:49:48) | 0 | 1795452216 (16:43:36) |
| Sold and settled | 12,197,233 | 17:51:12 | SETTLED | 1795456188 (17:49:48) | 0 | 1795452216 (16:43:36) |

| When | Block | Read at (UTC) | Status | 1/1 end it keeps | Close | 1/1 as the sale reads it | Bidding open | Bids | Clearing now |
| --- | ---: | --- | --- | --- | --- | --- | --- | ---: | --- |
| Open in the restarted sale, two bids | 12,196,916 | 16:44:12 | OPEN | 17:43:36 | 17:58:36 | ACTIVE | true | 2 | 2 at step 10 |
| Before the late 1/1 bid | 12,197,158 | 17:34:36 | OPEN | 17:43:36 | 17:58:36 | ACTIVE | true | 2 | 2 at step 10 |
| After the late 1/1 bid | 12,197,159 | 17:34:48 | OPEN | 17:49:48 | 18:04:48 | ACTIVE | true | 2 | 2 at step 10 |
| Settled | 12,197,301 | 18:05:12 | SETTLED | 17:49:48 | 18:04:48 | SETTLED | false | 2 | 2 at step 10 |

## A 6529 Stream work is never offered again

A curated edition master with no bid (token 3 of `Stream6529`) was settled after its hour
([`0x68728901…`](https://sepolia.etherscan.io/tx/0x68728901ed4369c5d9e88036f1b28d36069120e45d510f07a2b1e6b8b699268d)) and went to the museum vault. `restart` of its sale reverted with
`InvalidAuctionState(saleId, SETTLED)` ([`0x9da88f7f…`](https://sepolia.etherscan.io/tx/0x9da88f7f8eefb3bdb050517554e4f29f7972e7912608d5fb3635706723d27f30)); its `auctionClock`
answers `restartedAt` 0. The curated edition sales therefore behave as before.

## The two refused settings (simulated, not sent)

Both are calls of the network, so they were not sent: they would be governance transactions,
and r8's governance is kept as installed. They were simulated on the live chain at block
12,196,153 with `eth_simulateV1`, from the network Safe's address: the Safe schedules the call
on the manager and executes it after the role's delay (3 days for `setFeeTerms`, 7 days for
`setEntropyModule`). A direct call from the Safe stops earlier, at the delay
(`AccessManagerNotScheduled`).

| Call the Safe would make | Result of the execution |
| --- | --- |
| `EconomicsResolver.setFeeTerms(PRODUCT_INDEPENDENT, 1, address(0), 10000)` | Reverts: `InvalidEconomics()` |
| `EconomicsResolver.setFeeTerms(PRODUCT_INDEPENDENT, 1, address(0), 0)` | Reverts: `InvalidEconomics()` |
| The same with the current recipient and a share of 9,000 (control) | Passes |
| `IndependentStreamRegistry.setEntropyModule(0x…dEaD)`, an address with no code | Reverts: `SaleContractInvalid(0x…dEaD)` |
| `setEntropyModule` with the current module, and with zero (controls) | Pass |

## The basics, once

**Genesis.** The network Safe accepted ([`0x5d594d25…`](https://sepolia.etherscan.io/tx/0x5d594d25d34ef24c6ffea37f79c0674e9323c6c962f1a71d1620242441625df8)); the deployer added r8's
entropy module to the VRF subscription ([`0x0dcb9b2a…`](https://sepolia.etherscan.io/tx/0x0dcb9b2ae4bb4207c636cf81b7d19d29b681c88edbe9b49fc3947c5d4b114e0a)).

**Content, collections, package.** 36 uploads to `ContentStore`, as on r6 and r7; the platform
key created two collections; the package of ten works was registered with curation signer 1's
approval ([`0xd812d2f8…`](https://sepolia.etherscan.io/tx/0xd812d2f8ada4aafd6b49f3ee4f0dda4075a65c27e654b3f1c86b578e9dfc2878)), the curator appended the evidence statement
([`0x2dbf37fa…`](https://sepolia.etherscan.io/tx/0x2dbf37fad91c8a63db2b29ef2fae8944cf3edca6a7ed3f615cadf7500bf4ce35)) and the artist accepted, which created its account
([`0xb8962b38…`](https://sepolia.etherscan.io/tx/0xb8962b389838c4bd9545fd577e2df5b63b80830c5faf5af0cfd4898a0fb427a6)).

**A curated 1/1 with a competing bid (token 1).** The keeper key started it
([`0x8aff6719…`](https://sepolia.etherscan.io/tx/0x8aff6719c6507c9bf2ab3230075a4a47e25a582edec49fd209fa693af986e472)). Bidder 1 bid 0.05 ETH ([`0x9d357e32…`](https://sepolia.etherscan.io/tx/0x9d357e32386aa82d46d6db39a5c0806f326fc38a46fa54ef64e293870944f809)); bidder 3 outbid it at 0.0525
ETH ([`0x6450a6b4…`](https://sepolia.etherscan.io/tx/0x6450a6b433b9abbca28419adf2cb6c4b2b14a6dbbca85c27871f42430f55572a)), which credited bidder 1's 0.05 ETH, and bidder 1 claimed the refund
([`0x8623331b…`](https://sepolia.etherscan.io/tx/0x8623331b2a5ea644a5b29d1a2a8da55065c5c5269ad234e9905fc79ff680099b)). The record was opened in `StreamWorkFacts6529`
([`0x7d3552b8…`](https://sepolia.etherscan.io/tx/0x7d3552b886f9ff70183f299601fe59ed92a1c60e9d7100ba132a7bf6742b5a54)). After the hour anyone settled it ([`0x0d3aee12…`](https://sepolia.etherscan.io/tx/0x0d3aee12257025121e10bb15af4829b1def222e7b2b7e412be09f19be4af32c8)): `ownerOf(1)` is
bidder 3. Its media was marked complete on chain ([`0xae4b6fdc…`](https://sepolia.etherscan.io/tx/0xae4b6fdcb79163bd16636e59e235761c8ab0bc608dc2af11be99e8fa35273031)) and the artist
finalized the record ([`0x73609802…`](https://sepolia.etherscan.io/tx/0x73609802d9928a8b9e3227f10fa14c0783323668163d678b90cda0be1b9b35b7)), which pinned the genesis renderer; `tokenURI(1)`
then answered 1,812 bytes.

**A curated edition master with a five-step edition sale (token 2).** Bidder 4 started it with a
0.05 ETH bid ([`0xe0fe12b5…`](https://sepolia.etherscan.io/tx/0xe0fe12b5265c5379085d621aba7c817cc652bf63b2fce41a39360138f90a5afb)); anyone opened its edition sale ([`0xd6db8df6…`](https://sepolia.etherscan.io/tx/0xd6db8df6eba0698811ca2712c43bd8f4461b1b79cb8f906455474d3271de899b)).
Bidder 2 placed five bids of one copy each at steps 0, 8, 16, 24 and 32, each in its own
8-step word ([`0x3ed35d4e…`](https://sepolia.etherscan.io/tx/0x3ed35d4eeea98d98844d5ac0bf5e23f492733a64baa53b177851e6b8769c7fcd), [`0xd8f70820…`](https://sepolia.etherscan.io/tx/0xd8f70820e2991b1b40de5cdee65ea5aa2cf2b0c7065b7d57a6ab169a24f50260),
[`0xa345d44d…`](https://sepolia.etherscan.io/tx/0xa345d44ddb07306289fc6811dadec60a92646ff799c0c7ddd043aac99b850198), [`0xf2c8a3eb…`](https://sepolia.etherscan.io/tx/0xf2c8a3eb624d5bc5249c19c41dbf384e37b90e98c1acb908e60ae67d5ea7a46d),
[`0x5ae4107a…`](https://sepolia.etherscan.io/tx/0x5ae4107a48b3437c647dd961c189f01f03abc4ecb41f812f8f24f132af50f7d7)). The 1/1 settled to bidder 4 ([`0xfc160f79…`](https://sepolia.etherscan.io/tx/0xfc160f79cd7e67105d5c9881537161974903673e22e3358e771f1a752be34cd4)) and the
edition settled in one call ([`0xa99b3fd4…`](https://sepolia.etherscan.io/tx/0xa99b3fd48cbd50b72ae807b206a9330dd77145039852dbd4d74bca270b8a9585)): 4 copies at step 8,
0.000147 ETH each. The bid at step 0 was refunded whole ([`0xef430d86…`](https://sepolia.etherscan.io/tx/0xef430d86300e3edb2a3d677fefb6c4c5bc03aca76f0f9d63477904bd2b7b8c79)) and the
other four claimed a copy each ([`0xaab63bdb…`](https://sepolia.etherscan.io/tx/0xaab63bdbb679af3fbbfc39552155d5e53090226af54f3c8901c465a8ed9f6ef4), [`0x472c4695…`](https://sepolia.etherscan.io/tx/0x472c4695804c191c718bfc339996e8000c5dbe6eeee50c90c2c710665eb0fc44),
[`0x32645912…`](https://sepolia.etherscan.io/tx/0x3264591215fd0beb9c76dfbfad61977e32b969d757f1ed05112caf02e79051aa), [`0x6df0fdbe…`](https://sepolia.etherscan.io/tx/0x6df0fdbe69f3865618c2a621dbee54502c29bc1a0b7118b2d98f23da20ee71af)).

**A second curated master, no bids (token 3).** Started ([`0x979f944b…`](https://sepolia.etherscan.io/tx/0x979f944b3e488260d9316daeb1a14c19f06e0395800464ba3a5e72b9dbb03cb2)), its edition sale
opened ([`0x4df9e60f…`](https://sepolia.etherscan.io/tx/0x4df9e60f96899d137271825ccd7904388c7f456b92798d9b1989593a0dce4bcd), the steady-state `open`), settled to the museum vault with no
bid ([`0x68728901…`](https://sepolia.etherscan.io/tx/0x68728901ed4369c5d9e88036f1b28d36069120e45d510f07a2b1e6b8b699268d)); its edition sale, with no bids, settled with nothing sold
([`0x74f8aa3f…`](https://sepolia.etherscan.io/tx/0x74f8aa3f4dbaca3286e6e530e3806f27fdbc465c9d18ad8cbb50430de87fc8e6)).

**Payouts.** The artist released its share of the seller vault ([`0xe609b2c9…`](https://sepolia.etherscan.io/tx/0xe609b2c93b25ed3d50714d71d4c3502c273aceee77cc260e68541752a209f16e)):
0.1236813 ETH. The network fee vault forwarded 0.0309237 ETH to the network Safe
([`0x23f37418…`](https://sepolia.etherscan.io/tx/0x23f37418f4897f707cb53af40bd7752f0c8c461ddec60e42f131bbbddf9e1102)). Together that is everything the sales raised, 0.154605 ETH: 0.103088 ETH on 6529 Stream (two 1/1s sold for 0.1025 ETH and one edition sale, 0.000588 ETH), of which the network's share is 25%, and 0.051517 ETH on the Independent Stream pair (work C's 1/1, 0.05 ETH, and the three edition sales, 0.001517 ETH), of which it is 10%. Afterwards both auctions, both edition auctions, the fee vault, the split ledger and the revenue escrow held no ETH, and every outbid, losing or refunded bid had been claimed.

## Gas against ADR 0004's rows

Each transaction replayed on its parent block's state at Prague prices, beside the row of
[ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) it is an instance
of.

| Transaction | Gas on Sepolia | Replay at Prague prices | Row | CI | Ceiling |
| --- | ---: | ---: | --- | ---: | ---: |
| [`0xb0ae0650…`](https://sepolia.etherscan.io/tx/0xb0ae0650c3712d615afc9fad113db8f27b72a641cb0cefff324ec5e91f8d07f4) `restart`, A's first | 201,871 | 111,151 | Independent Stream `restart`, a work's first | 111,151 | 114,000 |
| [`0xe5f3544f…`](https://sepolia.etherscan.io/tx/0xe5f3544f1f45d0410e4b431010a2e7cd6e42828857e51d176ffd14b2137dfe2b) `restart`, B's first | 201,871 | 111,151 | the same | 111,151 | 114,000 |
| [`0x6cb7846b…`](https://sepolia.etherscan.io/tx/0x6cb7846b232ce96512974bb8ba01ab404657bb949e077d485d7cbe847b93f90c) `restart`, C's first | 201,871 | 111,151 | the same | 111,151 | 114,000 |
| [`0x5fbb5b23…`](https://sepolia.etherscan.io/tx/0x5fbb5b23fefdfb96788ffb4312c54781a79644a1d4dce96fc7c1ae8e60058f5a) `restart`, A's second | 103,951 | 94,051 | Independent Stream `restart`, a later one | 94,051 | 96,000 |
| [`0x4df9e60f…`](https://sepolia.etherscan.io/tx/0x4df9e60f96899d137271825ccd7904388c7f456b92798d9b1989593a0dce4bcd) curated edition `open`, steady state | 696,058 | 259,058 | Edition auction `open`, steady state | 257,207 | 260,000 |
| [`0xa99b3fd4…`](https://sepolia.etherscan.io/tx/0xa99b3fd48cbd50b72ae807b206a9330dd77145039852dbd4d74bca270b8a9585) curated edition `settle`, 5 used steps (steps 0 to 32, one copy each) | 260,197 | 156,677 | Edition `settle`, 5 used steps (CI: steps 96 to 192, 280 copies) | 180,815 | 185,000 |
| [`0xd6db8df6…`](https://sepolia.etherscan.io/tx/0xd6db8df6eba0698811ca2712c43bd8f4461b1b79cb8f906455474d3271de899b) curated edition `open`, the artist's first on r8 | 1,107,577 | 331,159 | none: between the steady-state row and the row that deploys both vaults (396,779) | — | — |
| [`0xe83c5d02…`](https://sepolia.etherscan.io/tx/0xe83c5d02a2969c225d505a58a79c4b35ccb190979d4e7d9ab512a39f5cdc6c93) Independent Stream edition `open`, the pair's first | 840,091 | 314,671 | none on the plain core | — | — |
| [`0x014791d4…`](https://sepolia.etherscan.io/tx/0x014791d4ac67ddc2a93124707053e44534700f40c8e62240a4b0fe195a59bc69) Independent Stream edition `open`, in a restarted 1/1 | 840,079 | 314,659 | none on the plain core | — | — |
| [`0xeadd8eda…`](https://sepolia.etherscan.io/tx/0xeadd8edad2186973ccfb062ebc7f88744146ccd91f901bac2917bbd314685fe7) Independent Stream edition `settle`, 3 used steps | 299,716 | 195,396 | none on the plain core | — | — |
| [`0xf17f9ae3…`](https://sepolia.etherscan.io/tx/0xf17f9ae3a8b1e9700f4007a7cb04957d2d8e281ff0205c0262c1bf18849f72a9) Independent Stream edition `settle`, 2 used steps, the 1/1 restarted | 296,860 | 192,540 | none on the plain core | — | — |
| [`0x7cc79b71…`](https://sepolia.etherscan.io/tx/0x7cc79b713750956b5866aa6fffebdf1e6ad74373668d0995b80c8b996adca347) Independent Stream edition `settle`, 2 used steps, opened in a restarted 1/1 | 296,685 | 192,365 | none on the plain core | — | — |

- The three first restarts replay at the row's figure to the unit, and the later restart
  at its row's figure too; all are under their ceilings.
- The curated `open` and `settle` are under their rows' ceilings. The live `settle` is below
  CI's figure: its five steps are the ladder's lowest and one copy each, where CI's row
  spreads 280 copies over steps 96 to 192.
- The Independent Stream edition auction's `open` and `settle` have no row in the table
  re-measured on the plain core (the earlier table's Independent Stream rows predate it), so
  the three settlements are recorded here without a ceiling to hold them to. The curated
  row's 185,000 is not their ceiling: they are a different contract.

## Not run on r8

Anything that changes governance after genesis (a module proposal, activation or removal, a
minter, a setting, a role): r8 is kept as installed, and the two refused settings above were
simulated only. A VRF-seeded work, the dispute pause and cancel, the capped edition, a move
signed by a consolidated wallet and the reference keeper: r7 ran them
([flows-r7.md](flows-r7.md)). Anything behind a long wait: `expireCredit` and `forfeit` (180
days), `rescue` and `rebind` (14 days), a finalize notice (14 days), the edition auction's
`abandon` (21 days).

**Left as it is.** Works A and B are unsold and in the English auction's custody with no
outcome; anyone may offer either again at any time. Nothing else on r8 is open or waits for a
date.

## Every transaction

| # | Step | From | Block | Gas on Sepolia | Prague replay | Transaction |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| 1 | `acceptNetwork` | any | 12,196,043 | 174,102 | 83,698 | [`0x5d594d25…`](https://sepolia.etherscan.io/tx/0x5d594d25d34ef24c6ffea37f79c0674e9323c6c962f1a71d1620242441625df8) |
| 2 | `vrf-addConsumer` | deployer | 12,196,045 | 255,326 | 78,086 | [`0x0dcb9b2a…`](https://sepolia.etherscan.io/tx/0x0dcb9b2ae4bb4207c636cf81b7d19d29b681c88edbe9b49fc3947c5d4b114e0a) |
| 3 | `writeChunk-b64-1024` | any | 12,196,049 | 1,911,018 | 301,850 | [`0xb43591e6…`](https://sepolia.etherscan.io/tx/0xb43591e6b3c202aa0f281f178729ce79c388d57e10d1362021a3f78493b68f52) |
| 4 | `registerManifest-b64-1024` | any | 12,196,050 | 579,348 | 145,448 | [`0xf1d1657e…`](https://sepolia.etherscan.io/tx/0xf1d1657e860f6fd1dc90c5e5b04c8d36be85c3a558243d809d777f9335abc13e) |
| 5 | `attestBase64-1024` | any | 12,196,051 | 154,216 | 71,196 | [`0xb12e1882…`](https://sepolia.etherscan.io/tx/0xb12e1882a3b8e67e2fbc6f0d4d284522d89ad77e491f2d9f04e75a41e2c9f9d3) |
| 6 | `writeChunk-b64-8192` | any | 12,196,052 | 13,003,921 | 1,859,969 | [`0x4e1b1fa6…`](https://sepolia.etherscan.io/tx/0x4e1b1fa6b5d61b068f59e2e50408378b538dca41501dd186b2ab492891b222cd) |
| 7 | `registerManifest-b64-8192` | any | 12,196,053 | 579,348 | 145,448 | [`0x800c8b05…`](https://sepolia.etherscan.io/tx/0x800c8b05f8d2c38d7a7643ca48f91438dea2b939c5e4579edfc6ae3e873e7a8e) |
| 8 | `attestBase64-8192` | any | 12,196,054 | 206,341 | 123,321 | [`0x52920dd8…`](https://sepolia.etherscan.io/tx/0x52920dd8f2b44c5e5594a7269187db9fdb1e408d1dda188b6efde9d9d57ab657) |
| 9 | `writeChunk-b64-24572` | any | 12,196,055 | 38,356,636 | 5,424,218 | [`0x52435c41…`](https://sepolia.etherscan.io/tx/0x52435c41f734bb2e88b60d8107bbf7229a45900a4936a4f785c4490c713270b4) |
| 10 | `registerManifest-b64-24572` | any | 12,196,056 | 579,360 | 145,460 | [`0x8ff0e89d…`](https://sepolia.etherscan.io/tx/0x8ff0e89dad84d57e9065a7030e310d1e22a04fe0873ae44aa478ef7e2acc2dff) |
| 11 | `attestBase64-24572` | any | 12,196,057 | 326,265 | 243,245 | [`0x54e6acda…`](https://sepolia.etherscan.io/tx/0x54e6acda84c83af31482cf8999cb6373234b9c97601b6cbe9ee8b9e56bf908d5) |
| 12 | `writeChunk-record-0` | any | 12,196,058 | 621,958 | 120,842 | [`0x1d6039a1…`](https://sepolia.etherscan.io/tx/0x1d6039a1d04fc763f00e91a4a8f43245af90b3fc4f162c994799a4a18ed38119) |
| 13 | `registerManifest-record-0` | any | 12,196,059 | 581,870 | 147,970 | [`0x7075e616…`](https://sepolia.etherscan.io/tx/0x7075e616b0ffa78d09239b0baa8a2398d8bfff4fd8835debf327e28f34c5ca83) |
| 14 | `writeChunk-record-1` | any | 12,196,060 | 621,958 | 120,842 | [`0xe0ac21e7…`](https://sepolia.etherscan.io/tx/0xe0ac21e7ee2d05d5282c2ee08ea07e488da9fba9674405b6d6cac548baa36580) |
| 15 | `registerManifest-record-1` | any | 12,196,061 | 581,870 | 147,970 | [`0x85c7f20b…`](https://sepolia.etherscan.io/tx/0x85c7f20b8169b684f80f076bd771c29dbf18611812bc501e65a76a15d298c2a8) |
| 16 | `writeChunk-record-2` | any | 12,196,062 | 621,958 | 120,842 | [`0x8dea1612…`](https://sepolia.etherscan.io/tx/0x8dea1612a3406ad372fc375a1b831ae87c3d9c97b6cc103aeca5e2859e77bec6) |
| 17 | `registerManifest-record-2` | any | 12,196,063 | 581,858 | 147,958 | [`0x95c688aa…`](https://sepolia.etherscan.io/tx/0x95c688aa4e576728a7ac5cd5e2494a80f7ac3dbedb634fd7c9904bb8a0afc735) |
| 18 | `registerManifest-media-2` | any | 12,196,064 | 579,324 | 145,424 | [`0x7ffef2e6…`](https://sepolia.etherscan.io/tx/0x7ffef2e67789a7d829159fcc705607c3a3cd91b8a0e34a6a01f4eeb2a6ec9fae) |
| 19 | `writeChunk-record-3` | any | 12,196,066 | 621,958 | 120,842 | [`0xcfbe42e6…`](https://sepolia.etherscan.io/tx/0xcfbe42e67ebfbee75aa891ddfc4811dcd35d1a29d8bab40b4057ec68b6a89b45) |
| 20 | `registerManifest-record-3` | any | 12,196,067 | 581,870 | 147,970 | [`0x0155b7ff…`](https://sepolia.etherscan.io/tx/0x0155b7ffa913fa70f48c977ffa75e3b235e19531c0af224ef2c843d85db9d082) |
| 21 | `registerManifest-media-3` | any | 12,196,068 | 579,336 | 145,436 | [`0x974bb09e…`](https://sepolia.etherscan.io/tx/0x974bb09e8587a1c5dcdc504cbb94fe50d33223aeeccd90053d6f168eb5ec54b3) |
| 22 | `writeChunk-record-4` | any | 12,196,069 | 621,958 | 120,842 | [`0x5db9da05…`](https://sepolia.etherscan.io/tx/0x5db9da055442f0ee07eb2e5298e948fbbf6e5f7eb59a2b778f417d1d7ac48821) |
| 23 | `registerManifest-record-4` | any | 12,196,070 | 581,870 | 147,970 | [`0xda99a393…`](https://sepolia.etherscan.io/tx/0xda99a393c1a4e720376e088c3db707b8f111359d905f06e0a4519c46ac609514) |
| 24 | `writeChunk-record-5` | any | 12,196,071 | 621,958 | 120,842 | [`0x35af59ed…`](https://sepolia.etherscan.io/tx/0x35af59eda2f3248613087a896f79c9ae3fcfae15fe1a4abd85e8430a4739b230) |
| 25 | `registerManifest-record-5` | any | 12,196,072 | 581,870 | 147,970 | [`0xf2951966…`](https://sepolia.etherscan.io/tx/0xf2951966fc8f8803cd9f3a60030e120b703886c507c58959fd844317e1224c3d) |
| 26 | `registerManifest-media-5` | any | 12,196,073 | 579,312 | 145,412 | [`0x7471baa6…`](https://sepolia.etherscan.io/tx/0x7471baa605e3aeece54fef345d58b418896c3f45405a1137a00e7aef68c58e61) |
| 27 | `writeChunk-record-6` | any | 12,196,074 | 621,958 | 120,842 | [`0xebc0484e…`](https://sepolia.etherscan.io/tx/0xebc0484e80faa3eeefba901841736a5c759ff9a590e8d3af9f83fba6e27c15f4) |
| 28 | `registerManifest-record-6` | any | 12,196,075 | 581,870 | 147,970 | [`0xe48108c9…`](https://sepolia.etherscan.io/tx/0xe48108c9cfff2c4e4bb9710008085bef6e1ad9c46ecb838b136f79b596fa8cb3) |
| 29 | `registerManifest-media-6` | any | 12,196,076 | 579,336 | 145,436 | [`0xe62e4c04…`](https://sepolia.etherscan.io/tx/0xe62e4c04bbcae55ff6294d32d4086830be530c0f57b0f2b2987928f47b1c198f) |
| 30 | `writeChunk-record-7` | any | 12,196,077 | 621,958 | 120,842 | [`0xa435e800…`](https://sepolia.etherscan.io/tx/0xa435e8002012416d0cd33f5af4e3f01967a855c1c800cd790fdce240cc8d9cfa) |
| 31 | `registerManifest-record-7` | any | 12,196,078 | 581,870 | 147,970 | [`0x9891ce80…`](https://sepolia.etherscan.io/tx/0x9891ce80772790cee17b16325367a51aa2e6d1fa66c5adbe9978084818c4f29a) |
| 32 | `registerManifest-media-7` | any | 12,196,079 | 579,336 | 145,436 | [`0x0e2ac888…`](https://sepolia.etherscan.io/tx/0x0e2ac888d7772ff4628a9daab2fa10a297689042804f4d79924847357c788366) |
| 33 | `writeChunk-record-8` | any | 12,196,080 | 621,958 | 120,842 | [`0xbb5e15fb…`](https://sepolia.etherscan.io/tx/0xbb5e15fb92b7a520fda8ee987b38c0a954223a644d7a14d723bf77c4dbc823ec) |
| 34 | `registerManifest-record-8` | any | 12,196,081 | 581,870 | 147,970 | [`0x601a9c9e…`](https://sepolia.etherscan.io/tx/0x601a9c9e55b06198076dc41d44120886fd040605d19372f4dd54ad5eab7ca69d) |
| 35 | `registerManifest-media-8` | any | 12,196,082 | 579,324 | 145,424 | [`0x52881036…`](https://sepolia.etherscan.io/tx/0x5288103663a2b32d913af6ec7d12815494c8639ebe28fe96fd84047bb75f98ad) |
| 36 | `writeChunk-record-9` | any | 12,196,083 | 621,958 | 120,842 | [`0x11a2c463…`](https://sepolia.etherscan.io/tx/0x11a2c463af333c531436ad143c7cf40fe1036138f5e71e80373e892b1d17bb6a) |
| 37 | `registerManifest-record-9` | any | 12,196,084 | 581,870 | 147,970 | [`0x46554579…`](https://sepolia.etherscan.io/tx/0x4655457931d467313c8ea965e1d7b1df58331bb02a6cf2d025110d5202fb03a7) |
| 38 | `registerManifest-media-9` | any | 12,196,085 | 579,336 | 145,436 | [`0xfd2ab651…`](https://sepolia.etherscan.io/tx/0xfd2ab651ace7f2c33d5b5249d1e237f5b3039b412558410e86d63731e969f871) |
| 39 | `createCollection-Flows` | platform | 12,196,086 | 474,912 | 128,532 | [`0xa5b7891d…`](https://sepolia.etherscan.io/tx/0xa5b7891deba65909cfc427dbf030e262b9a06df96161806396259b3ad898d68f) |
| 40 | `createCollection-Flows-2` | platform | 12,196,087 | 377,004 | 111,444 | [`0x9a3baddd…`](https://sepolia.etherscan.io/tx/0x9a3baddd302cbf4279be98574dc71000198ee54db9cdb6224ec09fdf9d9dd31c) |
| 41 | `registerPackage` | any | 12,196,088 | 280,558 | 109,318 | [`0xd812d2f8…`](https://sepolia.etherscan.io/tx/0xd812d2f8ada4aafd6b49f3ee4f0dda4075a65c27e654b3f1c86b578e9dfc2878) |
| 42 | `appendCurator` | curator | 12,196,089 | 272,370 | 101,930 | [`0x2dbf37fa…`](https://sepolia.etherscan.io/tx/0x2dbf37fad91c8a63db2b29ef2fae8944cf3edca6a7ed3f615cadf7500bf4ce35) |
| 43 | `acceptPackage` | any | 12,196,090 | 833,764 | 221,924 | [`0xb8962b38…`](https://sepolia.etherscan.io/tx/0xb8962b389838c4bd9545fd577e2df5b63b80830c5faf5af0cfd4898a0fb427a6) |
| 44 | `writeChunk-independent-media-master` | any | 12,196,091 | 513,668 | 105,664 | [`0x41b05bda…`](https://sepolia.etherscan.io/tx/0x41b05bda3ab0cbd1cc337ccf3a491c70338ddf64996e5955db835ba11e43cef0) |
| 45 | `registerManifest-independent-media-master` | any | 12,196,092 | 580,841 | 146,941 | [`0x889a8f05…`](https://sepolia.etherscan.io/tx/0x889a8f059e177978cc48afad55bf1ea25bca335a130d2653ec415a591985c9e2) |
| 46 | `writeChunk-independent-record-master` | any | 12,196,093 | 558,561 | 111,981 | [`0x548a761e…`](https://sepolia.etherscan.io/tx/0x548a761e7a71cf961567b695e01a87fab568f373a7fff83ebc5cd2c3d61aa1e1) |
| 47 | `registerManifest-independent-record-master` | any | 12,196,094 | 581,870 | 147,970 | [`0xb10a189a…`](https://sepolia.etherscan.io/tx/0xb10a189a24c0bfa72b1b662f064f9049c0264f40950a0fd8589dcf84eabd68f6) |
| 48 | `writeChunk-independent-media-master-2` | any | 12,196,095 | 513,668 | 105,664 | [`0xcd488893…`](https://sepolia.etherscan.io/tx/0xcd4888939958be76a954cde4e3fd9a2351aa4179b114c37dcc5645ea20c81265) |
| 49 | `registerManifest-independent-media-master-2` | any | 12,196,096 | 580,841 | 146,941 | [`0xf4332f8e…`](https://sepolia.etherscan.io/tx/0xf4332f8e40022f48cec862755e33d3ae097d1c71fbb9211d12b8bb9489355727) |
| 50 | `writeChunk-independent-record-master-2` | any | 12,196,097 | 558,561 | 111,981 | [`0x4a5d54ac…`](https://sepolia.etherscan.io/tx/0x4a5d54ac82c72d78393b581c5e4d951a13b7ea8ee4c55a60625c9ae13bc663c6) |
| 51 | `registerManifest-independent-record-master-2` | any | 12,196,098 | 581,870 | 147,970 | [`0x5c7158e1…`](https://sepolia.etherscan.io/tx/0x5c7158e1c769f5055fdb81ac786900b8ed5cf6fa97389ce003e76ba09682e5e3) |
| 52 | `writeChunk-independent-media-master-3` | any | 12,196,099 | 513,668 | 105,664 | [`0xba7abb46…`](https://sepolia.etherscan.io/tx/0xba7abb466e49d8366a8f07a0b5d8ae64c55e7bd78cc4c99de7ca1fe8ef1b342a) |
| 53 | `registerManifest-independent-media-master-3` | any | 12,196,100 | 580,841 | 146,941 | [`0x343ed21c…`](https://sepolia.etherscan.io/tx/0x343ed21c60d6e38c4d3d8c8ab81be7a4bbb9980e27650bccf346d89721a581bc) |
| 54 | `writeChunk-independent-record-master-3` | any | 12,196,101 | 558,561 | 111,981 | [`0xf37bd23e…`](https://sepolia.etherscan.io/tx/0xf37bd23e274fa470b8869b8f8f96c0529ec0f144daa5ac3d5225b14b6f20f313) |
| 55 | `registerManifest-independent-record-master-3` | any | 12,196,102 | 581,870 | 147,970 | [`0x648f140e…`](https://sepolia.etherscan.io/tx/0x648f140e096616f91060efe1c97e5646032e5b36c21ab9a90d6bbf4ce86d35af) |
| 56 | `independentDeploy` | artist | 12,196,103 | 22,953,329 | 3,143,323 | [`0x01191058…`](https://sepolia.etherscan.io/tx/0x01191058c81c95f528a9c2c154a36b86f61fd320f998d7b44d571c3edf2e6dd9) |
| 57 | `independentRegister` | artist | 12,196,104 | 296,894 | 124,754 | [`0xe68619e8…`](https://sepolia.etherscan.io/tx/0xe68619e8a49ed4ad73187e4010ca56f7fcbf4cb0ffaa4131e82e4808e82d98b2) |
| 58 | `independentApproveItem-master` | artist | 12,196,105 | 151,513 | 68,693 | [`0x7ef30b25…`](https://sepolia.etherscan.io/tx/0x7ef30b2575808b3dbab30a0f99c74a2e022659d48573d9dbc4146c10eb40630b) |
| 59 | `independentApproveItem-master-2` | artist | 12,196,106 | 151,513 | 68,693 | [`0x7c45b6ff…`](https://sepolia.etherscan.io/tx/0x7c45b6ff3d85f2de30adc1e978e1c1ea9bfaac9235cb6b92aa624f1110b9f5ef) |
| 60 | `independentApproveItem-master-3` | artist | 12,196,107 | 151,513 | 68,693 | [`0xd9cb63e3…`](https://sepolia.etherscan.io/tx/0xd9cb63e3213853a561f2960640674d116de87455745d9b227c5c963682b38442) |
| 61 | `independentEditionsDeploy` | artist | 12,196,108 | 17,806,172 | 2,416,312 | [`0x0116e607…`](https://sepolia.etherscan.io/tx/0x0116e607a92500f1a17e2088140a4af1dd01247138eec18163e5657d062b0fe7) |
| 62 | `independentEditionsRegister` | artist | 12,196,109 | 521,198 | 173,018 | [`0x3290b145…`](https://sepolia.etherscan.io/tx/0x3290b1459a62e32aaa57b495c5e77e8ce884419cc78dc9a21a04054abc569902) |
| 63 | `independentStart-master` | any | 12,196,111 | 2,133,319 | 562,483 | [`0xf2e23c6a…`](https://sepolia.etherscan.io/tx/0xf2e23c6a82da257792bd0677f1d1e9526a781bfa912de7c475ed61dd4287ee72) |
| 64 | `independentStart-master-2` | any | 12,196,112 | 1,010,861 | 368,521 | [`0xa36bd5ee…`](https://sepolia.etherscan.io/tx/0xa36bd5eead4ded93e07fda893cf54b365078c39d69b5de7e53b955c6119077e9) |
| 65 | `independentStart-master-3` | any | 12,196,113 | 1,010,849 | 368,509 | [`0x745e856d…`](https://sepolia.etherscan.io/tx/0x745e856dab7af9a6b75a2e5b0e9b4fd9dce9fe3a9ecd78598d56230ed0359e12) |
| 66 | `independentOpenEdition-1` | any | 12,196,115 | 840,091 | 314,671 | [`0xe83c5d02…`](https://sepolia.etherscan.io/tx/0xe83c5d02a2969c225d505a58a79c4b35ccb190979d4e7d9ab512a39f5cdc6c93) |
| 67 | `independentOpenEdition-2` | any | 12,196,116 | 840,091 | 314,671 | [`0xa94aa49d…`](https://sepolia.etherscan.io/tx/0xa94aa49dbeb5fa513cdb8f7f40bc70fff05dc2de35a19caa5bd3ae160ca68a38) |
| 68 | `a-editionBid-1` | bidder1 | 12,196,117 | 313,174 | 128,334 | [`0x09813170…`](https://sepolia.etherscan.io/tx/0x098131702584f4de2f20b184f6f0ef26edd4d52574e45849b5102675c26141f4) |
| 69 | `a-editionBid-2` | bidder3 | 12,196,118 | 313,197 | 128,357 | [`0xb9bd2eb4…`](https://sepolia.etherscan.io/tx/0xb9bd2eb4191086a4d941bffc2eb50146dea8d3bfabb5c33308e8cc58369fbb2a) |
| 70 | `b-editionBid-1` | bidder4 | 12,196,119 | 313,174 | 128,334 | [`0xe9cd5147…`](https://sepolia.etherscan.io/tx/0xe9cd5147c495bf5307ba4cf1265381b0d2a1810052d340fabe9ec9fc1c73a866) |
| 71 | `b-editionBid-2` | bidder2 | 12,196,120 | 313,197 | 128,357 | [`0x68c211e8…`](https://sepolia.etherscan.io/tx/0x68c211e8ed559e87d9bd9b58b0b9cda8293abd11b1549fd0479588f01b4687c4) |
| 72 | `start-0` | any | 12,196,122 | 1,159,555 | 355,875 | [`0x8aff6719…`](https://sepolia.etherscan.io/tx/0x8aff6719c6507c9bf2ab3230075a4a47e25a582edec49fd209fa693af986e472) |
| 73 | `bid-1-first` | bidder1 | 12,196,123 | 151,715 | 63,295 | [`0x9d357e32…`](https://sepolia.etherscan.io/tx/0x9d357e32386aa82d46d6db39a5c0806f326fc38a46fa54ef64e293870944f809) |
| 74 | `bid-1-outbid` | bidder3 | 12,196,124 | 169,824 | 74,204 | [`0x6450a6b4…`](https://sepolia.etherscan.io/tx/0x6450a6b433b9abbca28419adf2cb6c4b2b14a6dbbca85c27871f42430f55572a) |
| 75 | `claimCredits` | bidder1 | 12,196,125 | 32,255 | 32,018 | [`0x8623331b…`](https://sepolia.etherscan.io/tx/0x8623331b2a5ea644a5b29d1a2a8da55065c5c5269ad234e9905fc79ff680099b) |
| 76 | `openRecord-1` | any | 12,196,126 | 728,524 | 205,804 | [`0x7d3552b8…`](https://sepolia.etherscan.io/tx/0x7d3552b886f9ff70183f299601fe59ed92a1c60e9d7100ba132a7bf6742b5a54) |
| 77 | `startWithBid-5` | bidder4 | 12,196,128 | 1,088,030 | 351,970 | [`0xe0fe12b5…`](https://sepolia.etherscan.io/tx/0xe0fe12b5265c5379085d621aba7c817cc652bf63b2fce41a39360138f90a5afb) |
| 78 | `openEdition-2` | any | 12,196,129 | 1,107,577 | 331,159 | [`0xd6db8df6…`](https://sepolia.etherscan.io/tx/0xd6db8df6eba0698811ca2712c43bd8f4461b1b79cb8f906455474d3271de899b) |
| 79 | `curated-editionBid-step-0` | bidder2 | 12,196,130 | 269,343 | 86,103 | [`0x3ed35d4e…`](https://sepolia.etherscan.io/tx/0x3ed35d4eeea98d98844d5ac0bf5e23f492733a64baa53b177851e6b8769c7fcd) |
| 80 | `curated-editionBid-step-8` | bidder2 | 12,196,131 | 269,408 | 86,168 | [`0xd8f70820…`](https://sepolia.etherscan.io/tx/0xd8f70820e2991b1b40de5cdee65ea5aa2cf2b0c7065b7d57a6ab169a24f50260) |
| 81 | `curated-editionBid-step-16` | bidder2 | 12,196,132 | 269,408 | 86,168 | [`0xa345d44d…`](https://sepolia.etherscan.io/tx/0xa345d44ddb07306289fc6811dadec60a92646ff799c0c7ddd043aac99b850198) |
| 82 | `curated-editionBid-step-24` | bidder2 | 12,196,133 | 269,408 | 86,168 | [`0xf2c8a3eb…`](https://sepolia.etherscan.io/tx/0xf2c8a3eb624d5bc5249c19c41dbf384e37b90e98c1acb908e60ae67d5ea7a46d) |
| 83 | `curated-editionBid-step-32` | bidder2 | 12,196,134 | 269,408 | 86,168 | [`0x5ae4107a…`](https://sepolia.etherscan.io/tx/0x5ae4107a48b3437c647dd961c189f01f03abc4ecb41f812f8f24f132af50f7d7) |
| 84 | `start-9` | any | 12,196,135 | 962,266 | 320,226 | [`0x979f944b…`](https://sepolia.etherscan.io/tx/0x979f944b3e488260d9316daeb1a14c19f06e0395800464ba3a5e72b9dbb03cb2) |
| 85 | `openEdition-3` | any | 12,196,136 | 696,058 | 259,058 | [`0x4df9e60f…`](https://sepolia.etherscan.io/tx/0x4df9e60f96899d137271825ccd7904388c7f456b92798d9b1989593a0dce4bcd) |
| 86 | `a-settle-1` | any | 12,196,407 | 69,572 | 67,172 | [`0xd1950a2f…`](https://sepolia.etherscan.io/tx/0xd1950a2ff24e322aa40c5312816283a3c2002dfb55d9e2d8fe79789da118d268) |
| 87 | `a-restart-too-early` (refused, as intended) | any | 12,196,409 | 63,927 | 68,727 | [`0x2b871952…`](https://sepolia.etherscan.io/tx/0x2b87195226b442c4d95a85f547ddae3846d2bef0cbc75e5d1dd45c60addbe870) |
| 88 | `a-editionBid-3-late` | bidder2 | 12,196,410 | 313,227 | 128,387 | [`0x832498fc…`](https://sepolia.etherscan.io/tx/0x832498fc533cbbd8416d8cb7a8f4d4b2b08e94d74cbf4e535374c38184db7b67) |
| 89 | `b-settle-1` | any | 12,196,411 | 69,572 | 67,172 | [`0xdfb0d363…`](https://sepolia.etherscan.io/tx/0xdfb0d3637cc7d9bb4a25fafe7676dd34879fb453923736927af77ff67f0c3160) |
| 90 | `c-settle-1` | any | 12,196,412 | 69,572 | 67,172 | [`0x3ff6a7fd…`](https://sepolia.etherscan.io/tx/0x3ff6a7fd558703da08c82e0888d1621ed36333470e1ef9e8b8530b57f1bae28e) |
| 91 | `b-restart-too-early` (refused, as intended) | any | 12,196,413 | 63,927 | 68,727 | [`0x43cd682e…`](https://sepolia.etherscan.io/tx/0x43cd682e9fdaeae5f476ef88b53dbb78e75e5fd69da37e1f8fc634c0c322bc3d) |
| 92 | `a-editionSettle` | any | 12,196,903 | 299,716 | 195,396 | [`0xeadd8eda…`](https://sepolia.etherscan.io/tx/0xeadd8edad2186973ccfb062ebc7f88744146ccd91f901bac2917bbd314685fe7) |
| 93 | `a-claimBid-1` | bidder1 | 12,196,904 | 166,708 | 76,504 | [`0x28e8b773…`](https://sepolia.etherscan.io/tx/0x28e8b7733da83426d2b8470ced7c8a2c61d5e698bb158f8493431349ca35cdc9) |
| 94 | `a-claimBid-2` | bidder3 | 12,196,905 | 40,740 | 42,624 | [`0xd7cf405f…`](https://sepolia.etherscan.io/tx/0xd7cf405fa219405bf4cb59cac4dd0883560ad429d008832a77d2839846dc97c3) |
| 95 | `a-claimBid-3` | bidder2 | 12,196,906 | 175,861 | 83,357 | [`0x76d05635…`](https://sepolia.etherscan.io/tx/0x76d05635c68b6c1e7186266d895b835c3dae562702cf79fd033fccaa688595c3) |
| 96 | `a-restart-1` | any | 12,196,907 | 201,871 | 111,151 | [`0xb0ae0650…`](https://sepolia.etherscan.io/tx/0xb0ae0650c3712d615afc9fad113db8f27b72a641cb0cefff324ec5e91f8d07f4) |
| 97 | `b-restart-1` | any | 12,196,909 | 201,871 | 111,151 | [`0xe5f3544f…`](https://sepolia.etherscan.io/tx/0xe5f3544f1f45d0410e4b431010a2e7cd6e42828857e51d176ffd14b2137dfe2b) |
| 98 | `b-editionSettle` | any | 12,196,910 | 296,860 | 192,540 | [`0xf17f9ae3…`](https://sepolia.etherscan.io/tx/0xf17f9ae3a8b1e9700f4007a7cb04957d2d8e281ff0205c0262c1bf18849f72a9) |
| 99 | `b-claimBid-1` | bidder4 | 12,196,911 | 175,861 | 83,357 | [`0xc60b899a…`](https://sepolia.etherscan.io/tx/0xc60b899a18a4197c582deefc2479f7258afe4f7b60c4ee6b828cc2c31d194a2c) |
| 100 | `b-claimBid-2` | bidder2 | 12,196,912 | 166,708 | 76,504 | [`0x3cc846fa…`](https://sepolia.etherscan.io/tx/0x3cc846fac224cf3d718ce548b9af423bdc10ad6999b875e0a8fd29b9463194fc) |
| 101 | `c-restart-1` | any | 12,196,913 | 201,871 | 111,151 | [`0x6cb7846b…`](https://sepolia.etherscan.io/tx/0x6cb7846b232ce96512974bb8ba01ab404657bb949e077d485d7cbe847b93f90c) |
| 102 | `independentOpenEdition-3` | any | 12,196,914 | 840,079 | 314,659 | [`0x014791d4…`](https://sepolia.etherscan.io/tx/0x014791d4ac67ddc2a93124707053e44534700f40c8e62240a4b0fe195a59bc69) |
| 103 | `c-editionBid-1` | bidder2 | 12,196,915 | 313,174 | 128,334 | [`0x9ea4b1af…`](https://sepolia.etherscan.io/tx/0x9ea4b1af224f55d647d7494df003cc7bbf09815ef8489d37bacd02491c4adc92) |
| 104 | `c-editionBid-2` | bidder3 | 12,196,916 | 313,227 | 128,387 | [`0x0f3da991…`](https://sepolia.etherscan.io/tx/0x0f3da991e13f25cd10adb91dbe5d52fb3907973f6cf1350c77f8c3b922cf1a1d) |
| 105 | `settle-1` | any | 12,196,917 | 244,996 | 127,376 | [`0x0d3aee12…`](https://sepolia.etherscan.io/tx/0x0d3aee12257025121e10bb15af4829b1def222e7b2b7e412be09f19be4af32c8) |
| 106 | `settle-2` | any | 12,196,918 | 244,996 | 127,376 | [`0xfc160f79…`](https://sepolia.etherscan.io/tx/0xfc160f79cd7e67105d5c9881537161974903673e22e3358e771f1a752be34cd4) |
| 107 | `settle-3` | any | 12,196,919 | 198,774 | 93,770 | [`0x68728901…`](https://sepolia.etherscan.io/tx/0x68728901ed4369c5d9e88036f1b28d36069120e45d510f07a2b1e6b8b699268d) |
| 108 | `curated-restart-refused` (refused, as intended) | any | 12,196,920 | 23,459 | 29,459 | [`0x9da88f7f…`](https://sepolia.etherscan.io/tx/0x9da88f7f8eefb3bdb050517554e4f29f7972e7912608d5fb3635706723d27f30) |
| 109 | `markOnChainComplete-1` | any | 12,196,921 | 58,984 | 56,284 | [`0xae4b6fdc…`](https://sepolia.etherscan.io/tx/0xae4b6fdcb79163bd16636e59e235761c8ab0bc608dc2af11be99e8fa35273031) |
| 110 | `finalize-1` | artist | 12,196,922 | 408,155 | 226,115 | [`0x73609802…`](https://sepolia.etherscan.io/tx/0x73609802d9928a8b9e3227f10fa14c0783323668163d678b90cda0be1b9b35b7) |
| 111 | `curated-editionSettle-5-steps` | any | 12,196,923 | 260,197 | 156,677 | [`0xa99b3fd4…`](https://sepolia.etherscan.io/tx/0xa99b3fd48cbd50b72ae807b206a9330dd77145039852dbd4d74bca270b8a9585) |
| 112 | `curated-claimBid-1` | bidder2 | 12,196,924 | 40,660 | 42,525 | [`0xef430d86…`](https://sepolia.etherscan.io/tx/0xef430d86300e3edb2a3d677fefb6c4c5bc03aca76f0f9d63477904bd2b7b8c79) |
| 113 | `curated-claimBid-2` | bidder2 | 12,196,925 | 164,360 | 74,156 | [`0xaab63bdb…`](https://sepolia.etherscan.io/tx/0xaab63bdbb679af3fbbfc39552155d5e53090226af54f3c8901c465a8ed9f6ef4) |
| 114 | `curated-claimBid-3` | bidder2 | 12,196,926 | 75,593 | 63,909 | [`0x472c4695…`](https://sepolia.etherscan.io/tx/0x472c4695804c191c718bfc339996e8000c5dbe6eeee50c90c2c710665eb0fc44) |
| 115 | `curated-claimBid-4` | bidder2 | 12,196,927 | 75,593 | 63,909 | [`0x32645912…`](https://sepolia.etherscan.io/tx/0x3264591215fd0beb9c76dfbfad61977e32b969d757f1ed05112caf02e79051aa) |
| 116 | `curated-claimBid-5` | bidder2 | 12,196,928 | 75,593 | 63,909 | [`0x6df0fdbe…`](https://sepolia.etherscan.io/tx/0x6df0fdbe69f3865618c2a621dbee54502c29bc1a0b7118b2d98f23da20ee71af) |
| 117 | `curated-editionSettle-no-bids` | any | 12,196,929 | 202,286 | 104,966 | [`0x74f8aa3f…`](https://sepolia.etherscan.io/tx/0x74f8aa3f4dbaca3286e6e530e3806f27fdbc465c9d18ad8cbb50430de87fc8e6) |
| 118 | `c-bid-late` | bidder1 | 12,197,159 | 184,661 | 88,241 | [`0xe905c461…`](https://sepolia.etherscan.io/tx/0xe905c4613bc3ae96b02c31d21b9122bb360659e42c1090975dce04e684bc8cf1) |
| 119 | `a-settle-2` | any | 12,197,201 | 69,572 | 67,172 | [`0x6bd773d7…`](https://sepolia.etherscan.io/tx/0x6bd773d74415f4860540a6b490f2dfa445a96104be01f8fe633e2d85e2840ce6) |
| 120 | `b-settle-2` | any | 12,197,202 | 69,572 | 67,172 | [`0xa0a07968…`](https://sepolia.etherscan.io/tx/0xa0a079681e540c8b2fc69b2a3b238a0e12cbdae60a368d8879b90c984cc72b9c) |
| 121 | `c-settle-2` | any | 12,197,233 | 267,275 | 148,855 | [`0x3bee5f11…`](https://sepolia.etherscan.io/tx/0x3bee5f11fab26a432a2a5779824795eb8d9e1f88aa3bd46cd2e2a48db34cf820) |
| 122 | `a-restart-2` | any | 12,197,266 | 103,951 | 94,051 | [`0x5fbb5b23…`](https://sepolia.etherscan.io/tx/0x5fbb5b23fefdfb96788ffb4312c54781a79644a1d4dce96fc7c1ae8e60058f5a) |
| 123 | `c-editionSettle` | any | 12,197,301 | 296,685 | 192,365 | [`0x7cc79b71…`](https://sepolia.etherscan.io/tx/0x7cc79b713750956b5866aa6fffebdf1e6ad74373668d0995b80c8b996adca347) |
| 124 | `c-claimBid-1` | bidder2 | 12,197,302 | 166,708 | 76,504 | [`0xe08f45c0…`](https://sepolia.etherscan.io/tx/0xe08f45c00a0dee0fb3f0879c9e026a51f48643296a4f8d6ff7bb5a45351cbe8b) |
| 125 | `c-claimBid-2` | bidder3 | 12,197,303 | 175,861 | 83,357 | [`0x773dadf6…`](https://sepolia.etherscan.io/tx/0x773dadf69543187e44073f713353f6e81b3aa33ec7be0975da3e042a3fefeda7) |
| 126 | `a-settle-3` | any | 12,197,559 | 69,572 | 67,172 | [`0xadd6ff56…`](https://sepolia.etherscan.io/tx/0xadd6ff568437a96d567e8e57da7ed643635f4c4568e8ae20459c7a13ab050a2c) |
| 127 | `release-0` | artist | 12,197,560 | 274,996 | 101,456 | [`0xe609b2c9…`](https://sepolia.etherscan.io/tx/0xe609b2c93b25ed3d50714d71d4c3502c273aceee77cc260e68541752a209f16e) |
| 128 | `forwardFees` | any | 12,197,561 | 39,052 | 39,420 | [`0x23f37418…`](https://sepolia.etherscan.io/tx/0x23f37418f4897f707cb53af40bd7752f0c8c461ddec60e42f131bbbddf9e1102) |

128 transactions: 145,561,640 gas on Sepolia, 29,847,642 replayed at Prague prices.
