# Sepolia: the v1 flows and their gas under Glamsterdam

On 11 October 2026 the v1 flows were run on two Sepolia rehearsal deployments
([README](README.md)). Settlement and the edition flow followed on 13 October, once the
24-hour auctions had ended. A lifecycle check on r3 followed on 15 October, and the rc.2 flows,
with the uniform edition auction, on r4 on 1 November:

| Instance | Source | Record | Role here |
| --- | --- | --- | --- |
| **r4** | `main` at `1e7022b`: the rc.2 candidate, with the uniform edition auction, the museum rule and the 0.05 ETH opening bid | [`1793536584.json`](1793536584.json) | **Current.** The rc.2 flows on 1 November 2026, every edition-auction step on chain: [r4](#r4-the-rc2-candidate-1-november-2026) |
| r3 | `main` at `e5fe78c`: every review fix, the state-growth gas diet and the source-quality pass | [`1792095396.json`](1792095396.json) | A lifecycle check on 15 October 2026, measured against r2: [r3](#r3-the-release-candidate-15-october-2026) |
| r2 | `main` at `400f96d`: the full v1 scope, including the Editions gas cuts ([#41](https://github.com/6529-Collections/6529-works/pull/41)) and the contested overrides ([#44](https://github.com/6529-Collections/6529-works/pull/44)) | [`1791750816.json`](1791750816.json) | Reference for every section below the r3 one |
| r1 | `main` at `60edd9b`, before #41 and #44 | [`1791746472.json`](1791746472.json) | Measured first; kept for comparison |

Every gas figure below names its instance. Where a table has an r1 column, r1 ran the
same operation on its own contracts.

Sepolia has run Glamsterdam since 6 October 2026, and Glamsterdam reprices state
creation. Every budget in ADR 0001, ADR 0003 and the gas reports was measured with
Prague costs in Foundry. This file records what the flows cost on Sepolia now.

These are testnet rehearsals with throwaway keys, and the code is pre-audit.

> **Measured on the deployed code, not today's `main`.** Every figure from the
> [Summary (r2)](#summary-r2) on is from r1 and r2 (`60edd9b` and `400f96d`); the r3 section
> measures `e5fe78c`. `main` has changed since r1 and r2, so read their figures as
> measurements of those instances. The gas budgets are now defined by
> [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md) (Prague gas plus exact
> counts of new slots), so the "fail" marks against 350K below are superseded. Later changes
> also alter some details recorded here: the consolidation adapter's per-getter stipend is
> 200,000 gas on `main` (50,000 in r1 and r2), the VRF callback writes no new slot since
> DEPS-2, and the renderer's media-list read has its own 1,000,000-gas cap since the content
> fixes (#56), so `tokenURI` needs about 1.07M gas available rather than about 1.0M.

## r4: the rc.2 candidate (1 November 2026)

On 1 November 2026 the rc.2 flows ran on **r4**, `main` at `1e7022b`
([README](README.md#sepolia-r4-1-november-2026-current)): the uniform-price edition auction of
[ADR 0005](../../docs/adr/0005-stream-editions-auction.md) beside each edition master's 1/1,
the museum rule (owner decision 17), the 0.05 ETH opening bid (decision 19) and a dispute
pause and cancel. r4's 1/1 auctions run **1 hour** (a testnet setting, the governed minimum);
every other parameter is the mainnet default, so the edition close is 15 minutes after the
1/1's final end and the soft close 5 minutes.

- **Driver.** [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol) and
  [`flows.ps1`](../../script/sepolia/flows.ps1), extended for r4: the rc.2 package (ten items,
  three edition masters: uncapped, capped at 3, and one for the dispute), the edition
  auction's open, bid, raise, withdrawal, settlement with a settler's own departure order and
  claims, Safe-relayed calls (a guardian's pause, the hot admin's `schedule` and `execute`), and
  refusals sent on purpose and recorded as failed receipts (`-ExpectRevert`). State files:
  [`flows/r4.json`](flows/r4.json) and [`flows/r4-content.json`](flows/r4-content.json) (the
  content uploads, run beside it from a second relayer).
- **Accounts.** Throwaway testnet keys: the keeper (`0xe3Aac284…7214`, no role) sent every
  permissionless call, starts, opens, settles, `createEdition` and `claimBidFor`; bidders 1 to 4
  and wallet 3 bid and claimed; Guardian Safe 1 and the hot admin Safe signed 2-of-3 through the
  driver. The museum is the testnet EOA `0xd954e414…D840`.
- **Gas.** Sepolia gas is the receipt's; Prague is the receipt replayed with
  `cast run --quick --evm-version prague` on an archive RPC
  (`https://sepolia.gateway.tenderly.co`; the default public RPC had pruned the older blocks).

### What ran

| Token | Item | Role | Outcome |
| ---: | --- | --- | --- |
| 1 | 9: edition master, no cap | The dispute | 1/1 paused by a guardian at 12:46:24 UTC; edition sale open (bids accepted during the pause) until the cancel voids it |
| 2 | 5: edition master, no cap | The main sale | 1/1 SOLD to bidder 1 at 0.055125 ETH; edition: 11 bids, 11 copies at 0.000422 ETH (step 30) |
| 3 | 8: edition master, cap 3 | The cut step | 1/1 UNBID, moved to the museum; edition: 4 bids and two raises, 3 copies at 0.000162 ETH (step 10), rationed |
| 4 | 0: an original | The museum | 1/1 UNBID, moved to the museum |

Before them: two collections, the package (registration with curation signer 1's approval,
the CURATOR statement, the artist's first acceptance) and the content uploads.

### The checklist

| Flow | Result |
| --- | --- |
| Ten or more edition bids from several wallets, beside a 1/1 English auction | **Pass.** 11 bids on token 2's edition from four wallets (bidders 1 to 4), [first](https://sepolia.etherscan.io/tx/0xc1cc727d229e67eac189f7dbe66f0b87b3599df932e2db7f8fb5196b09aab2da) to [eleventh](https://sepolia.etherscan.io/tx/0x1230751d867ee0b8a27a2da2898a4f43f9b9fe1b4cc03274007280ebfcf90084), while its 1/1 drew three bids: [0.05](https://sepolia.etherscan.io/tx/0x91b5170b2a5d17d4f4f3c211188989497e25d0fc4f20c0e2a5152a13bce0eade), [0.0525](https://sepolia.etherscan.io/tx/0x5067e29f7097f26ea633124fb86f45c941e5e02f7d256a559b28890787a725d5) and [0.055125 ETH](https://sepolia.etherscan.io/tx/0x98bf7134a86a70cf8a9b1e99577407aedb576785ad3b7a5e1ee4a73ebf6991ee). |
| A raise | **Pass.** Bid 4 on token 2 raised from step 20 to 32, paying the difference: [`0x321f1f16…`](https://sepolia.etherscan.io/tx/0x321f1f1650971ca51d31043a8a47c7fb82dc83ce3cce6c74600033a5c2f081e1). Two more on the capped sale: [`0xb310592f…`](https://sepolia.etherscan.io/tx/0xb310592f9de945c0e59ef9df4f096b0bef62bada5a6a985c616ab6daf4be8ee3), [`0xf6d870c7…`](https://sepolia.etherscan.io/tx/0xf6d870c762974e0d2c8cd652fe5f90ca3eabe35a02d43af84f73fabf439c9ceb). |
| The 1/1's anti-snipe moves the edition close | **Pass.** Bidder 1's bid at 13:31:24 UTC, inside the 1/1's last 15 minutes, [`0x98bf7134…`](https://sepolia.etherscan.io/tx/0x98bf7134a86a70cf8a9b1e99577407aedb576785ad3b7a5e1ee4a73ebf6991ee), moved the 1/1's end from 13:45:00 to 13:46:24 and the edition's `closeAt` from 14:00:00 to 14:01:24 (`endTimes`, read before and after). |
| A soft-close extension | **Pass.** Bidder 3's edition bid at 13:57:36 UTC, inside the last 5 minutes before `closeAt` 14:01:24, [`0x1230751d…`](https://sepolia.etherscan.io/tx/0x1230751d867ee0b8a27a2da2898a4f43f9b9fe1b4cc03274007280ebfcf90084), set `softEnd` to 14:02:36, so the sale closed at 14:02:36. |
| A capped edition auction with a hole at the cut step, settled through the per-settler sweep | **Pass.** Token 3's edition (cap 3): the two raises left departures at positions 0 and 5 of the cut step (step 10). Wallet 3 settled first with an order that skips departure 0, [`0x5e90096a…`](https://sepolia.etherscan.io/tx/0x5e90096a7b2950e7b73e4d3fe9db7e400bd130754068742499800852ea4aaed9): the call cleared and paid the sale but stranded only wallet 3's own sweep (1 of 2 swept, cutoff 1; `sweepOf`). The keeper then settled with its own order `[0,1]`, [`0xb1d9707a…`](https://sepolia.etherscan.io/tx/0xb1d9707a51601e56290dadfc2da430237a53658256b63f11098e50755c6524aa): SETTLED, cutoff 2. Bid 2 (positions 1 and 2) wins 1 copy through the hole at position 0. |
| An unbid 1/1 that Stream moves to the museum (decision 17) | **Pass.** Tokens 4 (an original) and 3 (the capped master) drew no 1/1 bid; `settle` [`0x69c8e790…`](https://sepolia.etherscan.io/tx/0x69c8e7905c84f5a4a118eeff10e2b170e6ff1700dda0751a0d13fcbaea956813), [`0x11a8f33b…`](https://sepolia.etherscan.io/tx/0x11a8f33b0c40bf587bbb03949d029cf0ce3146bccda16b39e3ed5e231d0facbe): Stream recorded UNBID (`primarySale`) and moved each to the testnet museum (`ownerOf`). Token 3's edition sold anyway (D141). |
| A dispute pause, a pre-pause bid withdrawn, and a bid placed during the pause that cannot be | **Pass.** Guardian Safe 1 (2-of-3) paused token 1's 1/1, [`0xe4462884…`](https://sepolia.etherscan.io/tx/0xe4462884f6f59c70a349e8d49b402295fa7c385e2a6b8802d4d6ff1d25779fdd). Bidder 1 withdrew its pre-pause edition bid, [`0x3981428f…`](https://sepolia.etherscan.io/tx/0x3981428ff823e8abc128d40bf16a4d4fa1dd240a8cb393d1309ec9b825c2525a), and bidder 4 its pre-pause 0.05 ETH 1/1 bid, [`0x44c8f86c…`](https://sepolia.etherscan.io/tx/0x44c8f86c4830ba835ffd59ffe190b6b97634d26aec39ebe5c3edf1f289d160c4) (credited, then claimed [`0xc893e952…`](https://sepolia.etherscan.io/tx/0xc893e952dfb95f4a1a3c1d3ae3a3b2d463618d69a5a0b45cac6349d4e2dafaad)). Bidder 3's edition bid during the pause was accepted, [`0x05cfe486…`](https://sepolia.etherscan.io/tx/0x05cfe4868a77b278960d10bd5a82bf5b84c1fa65a1c0326680a83db9d11362ff), and its withdrawal reverted on chain with `WithdrawalsClosed(saleId)`, [`0x719cd6e0…`](https://sepolia.etherscan.io/tx/0x719cd6e0254d863b2277a3d55e605c8380f5610edf67c79b68f8c9ff33eaf8e8). |
| A dispute that voids an edition auction, with refunds | **Pending** until the cancel can execute, from **3 November 2026, 12:48:00 UTC** (the 48-hour PARAMETER_SETTER delay from the schedule; the contract also requires 48 hours from the pause). Done so far: the pause, the PLATFORM `DISPUTE_OUTCOME` statement [`0xcc6d2a00…`](https://sepolia.etherscan.io/tx/0xcc6d2a000b94317a9b388162eff86534593cd0a3ce2c439b6d18868fc5bf82f5) and the hot admin Safe's `schedule` [`0x4eb73e04…`](https://sepolia.etherscan.io/tx/0x4eb73e04b11cd90d856032d76236f9f28d9ba39a2dbc62815caa2db123ad135d) (operation `0xfee38ae8…72f4`). The commands that finish it are under [Pending (r4)](#pending-r4). |
| Settle and claims: `claimBid` and `claimBidFor` | **Pass.** Keeper settles [`0xfa395cca…`](https://sepolia.etherscan.io/tx/0xfa395cca32865c4e79393302b1af6515160198c8d3acd3643f31daa99aeae752) (token 2) and the sweep above (token 3); every bid claimed: `claimBid` by the bidder ([token 2 bid 1](https://sepolia.etherscan.io/tx/0x386c554930ef850474b9a0ff8466c632cafe0efa82d37ba92cb24c4edc76d79c), [token 3 bid 2](https://sepolia.etherscan.io/tx/0xaf261f8731869cfe3595d28935206bfd648bf25fad8e9dbe763a26fe8a777099) and two more) and `claimBidFor` by the keeper ([token 2 bid 4](https://sepolia.etherscan.io/tx/0x9e72ede93cf7ababa28cbc78e72c23799ce029133d59fc06d1d654cf3babc218), [token 3 bid 3, refund only](https://sepolia.etherscan.io/tx/0x5f727b4fabd3cd6ac68a76751196a26a03c66f18ae8b8142001b0d46967624eb) and nine more); the bidders then claimed their credited refunds (`claim`). |
| `createEdition` by the keeper | **Pass.** The keeper, an EOA with no role, created both editions once their 1/1s settled: [`0x774d7e72…`](https://sepolia.etherscan.io/tx/0x774d7e7268c938fea4a78e6532deb6f1b52e86708e4f3a7730d0dbfc013e00a1), [`0xda8aaf6b…`](https://sepolia.etherscan.io/tx/0xda8aaf6b122df4c5f0360ba6b0f2b714465dfa0172f5821bc846327775fb2e55). |
| A 1/1 sold above 0.05 ETH | **Pass.** Token 2 settled SOLD to bidder 1 at 0.055125 ETH, [`0x6a4e5916…`](https://sepolia.etherscan.io/tx/0x6a4e5916f20b46cc427130573b84ba0a11b2e49494a3d9502e3a537ab7f03e71). |
| A 1-wei bid refused | **Pass.** Bidder 3's 1-wei first bid on token 2 reverted on chain with `BidTooLow(50000000000000000, 1)`, [`0xd93d150b…`](https://sepolia.etherscan.io/tx/0xd93d150b683ef2cb225d7de5a854603ed056f741e6aed292ded03bb62252d77e): the 0.05 ETH opening bid (decision 19). |

### Token 2: the main edition sale

The clocks, from `endTimes` (UTC, 1 November):

| When | 1/1 end | `closeAt` | `softEnd` | `endTime` |
| --- | --- | --- | --- | --- |
| After the bids (12:54:48) | 13:45:00 | 14:00:00 | — | 14:00:00 |
| Before the anti-snipe bid (13:31:12) | 13:45:00 | 14:00:00 | — | 14:00:00 |
| After it (13:31:24) | 13:46:24 | 14:01:24 | — | 14:01:24 |
| Before the soft-close bid (13:57:24) | 13:46:24 | 14:01:24 | — | 14:01:24 |
| After it (13:57:36) | 13:46:24 | 14:01:24 | 14:02:36 | 14:02:36 |

The clearing: 21 units bid; the result is 11 copies at step 30
(0.000422 ETH each, revenue 0.004642 ETH), not rationed (no cap). The
network fee is the 25% locked at open; the rest went to the artist's split wallet.

| Bid | Bidder | Step | Units | Won | Refund (ETH) | Placed | Claimed |
| ---: | --- | --- | ---: | ---: | ---: | --- | --- |
| 1 | bidder 1 | 48 | 1 | 1 | 0.000578 | [`0xc1cc727d…`](https://sepolia.etherscan.io/tx/0xc1cc727d229e67eac189f7dbe66f0b87b3599df932e2db7f8fb5196b09aab2da) | `claimBid` [`0x386c5549…`](https://sepolia.etherscan.io/tx/0x386c554930ef850474b9a0ff8466c632cafe0efa82d37ba92cb24c4edc76d79c) |
| 2 | bidder 2 | 40 | 2 | 2 | 0.000518 | [`0xce307e00…`](https://sepolia.etherscan.io/tx/0xce307e00498279029eef8ede644df68d6342dec6d10facab2f2135eebc713275) | `claimBid` [`0x56dc3cf3…`](https://sepolia.etherscan.io/tx/0x56dc3cf3fee7be4e39ae8429a0801540591b6ac5f03f261bd2bda9d0a96588a8) |
| 3 | bidder 3 | 30 | 3 | 3 | 0 | [`0x57fd461e…`](https://sepolia.etherscan.io/tx/0x57fd461e331335f50fbf6661a132a3d88218a1d8dc9773a7509e6813c7d9e6f4) | `claimBid` [`0x1642ff2c…`](https://sepolia.etherscan.io/tx/0x1642ff2c93b7d3fd6cdf60da704d4fcf8666ae1f84687a95a38e53714b187f1a) |
| 4 | bidder 4 | 20, raised to 32 | 2 | 2 | 0.000084 | [`0xde7a47c4…`](https://sepolia.etherscan.io/tx/0xde7a47c498fc6dd160f3c72ca5fc67e1301c4e6321a01b92735ee5de3e438e3a) | `claimBidFor` [`0x9e72ede9…`](https://sepolia.etherscan.io/tx/0x9e72ede93cf7ababa28cbc78e72c23799ce029133d59fc06d1d654cf3babc218) |
| 5 | bidder 1 | 10 | 4 | 0 | 0.000648 | [`0xa82be197…`](https://sepolia.etherscan.io/tx/0xa82be1976a58767552911c3341db90a99f7be55d6d0b9367e0d5cc08b0e6b3ee) | `claimBidFor` [`0xc06e6e1d…`](https://sepolia.etherscan.io/tx/0xc06e6e1dc7e6ef686b4670c444c9aa0e585abec928e84607f48da03b61e8f99a) |
| 6 | bidder 2 | 0 | 3 | 0 | 0.0003 | [`0x822f6aee…`](https://sepolia.etherscan.io/tx/0x822f6aeeb00e329fbbfa2b00becd225c40400a14a12514d11c32057d0794db37) | `claimBidFor` [`0x830a1059…`](https://sepolia.etherscan.io/tx/0x830a1059809dad65cf9a408e1fd0a19446451d14e335342a7cbd1b077a28ed81) |
| 7 | bidder 3 | 44 | 1 | 1 | 0.000403 | [`0x0da18db8…`](https://sepolia.etherscan.io/tx/0x0da18db8126a8b0a1c153441fd1329c220c665dbab348c6889016bf1b00a7005) | `claimBidFor` [`0x5a41a6dc…`](https://sepolia.etherscan.io/tx/0x5a41a6dcf175b2e4147f4dc9253eaaf007071d9e6b0daeccd40c52035fff8472) |
| 8 | bidder 4 | 36 | 1 | 1 | 0.00014 | [`0x483a4f02…`](https://sepolia.etherscan.io/tx/0x483a4f02571cea962e473fb3a57887a25ec95628d257a44f1f62dab02bd2f0bb) | `claimBidFor` [`0xdf1da4fd…`](https://sepolia.etherscan.io/tx/0xdf1da4fd0d2064412291599a2e0969864b89ce9985534027d1116a466b89a313) |
| 9 | bidder 1 | 24 | 2 | 0 | 0.000632 | [`0x5593247d…`](https://sepolia.etherscan.io/tx/0x5593247d2781e035e08a7bb3a80ed3a709f8e3fb3ab3331bf68edd7caf1f04ae) | `claimBidFor` [`0x0888db85…`](https://sepolia.etherscan.io/tx/0x0888db85895a7fb816ea541f7032a4a49800e6f30a9fc572ae70e75a69b8de7b) |
| 10 | bidder 2 | 12 | 1 | 0 | 0.000178 | [`0x1d5bc001…`](https://sepolia.etherscan.io/tx/0x1d5bc0018683af64ae4b31f688cc2d0790f4646acb82134721b7a5dc557a6ba4) | `claimBidFor` [`0x5d825393…`](https://sepolia.etherscan.io/tx/0x5d82539320b25c4f63b99d3f42bcf80368cef004921c325acdcd9c0e5833a9fc) |
| 11 | bidder 3 | 30 | 1 | 1 | 0 | [`0x1230751d…`](https://sepolia.etherscan.io/tx/0x1230751d867ee0b8a27a2da2898a4f43f9b9fe1b4cc03274007280ebfcf90084) | `claimBidFor` [`0x6ab3b36a…`](https://sepolia.etherscan.io/tx/0x6ab3b36aa118caf34b6fc917a40dacc7018948bc215a4220491be4f3ba79501d) |

### Token 3: the cut step and the per-settler sweep

Cap 3. All four bids entered step 10 (positions 0, 1, 3 and 5); bid 1 then raised to step 20
and bid 4 to step 15, each leaving a departure in step 10's log: `(position 0, 1 unit)` and
`(position 5, 1 unit)`. The clearing: 3 copies at step 10 (0.000162 ETH), two of them
above the cut step, so step 10 wins `cutUnits` = 1. The sweep moves the cutoff past every
departure below it: the one at position 0 lifts it from 1 to 2, the one at position 5 does
not. Without the hole, bid 2 (positions 1 and 2) would win nothing.

| Bid | Bidder | Step | Units | Position | Won | Refund (ETH) | Placed | Claimed |
| ---: | --- | --- | ---: | --- | ---: | ---: | --- | --- |
| 1 | bidder 1 | 10, raised to 20 | 1 | 0 at step 10; 0 at step 20 | 1 | 0.000099 | [`0x57337350…`](https://sepolia.etherscan.io/tx/0x573373504560d1be729443846f74b54eccb7c25b19a26184cd18bdbc8a156afd) | `claimBidFor` [`0xf613c92a…`](https://sepolia.etherscan.io/tx/0xf613c92a2c9a59b535cb4240881ab18ba1dec1762223b73a5a37dfda28d89239) |
| 2 | bidder 2 | 10 | 2 | 1 | 1 | 0.000162 | [`0xb3128ae3…`](https://sepolia.etherscan.io/tx/0xb3128ae3c4c4724e352bf658bdc06bf0dfd7dd5117ea340a0dbb8dddd876cfa2) | `claimBid` [`0xaf261f87…`](https://sepolia.etherscan.io/tx/0xaf261f8731869cfe3595d28935206bfd648bf25fad8e9dbe763a26fe8a777099) |
| 3 | bidder 3 | 10 | 2 | 3 | 0 | 0.000324 | [`0xbf8965b7…`](https://sepolia.etherscan.io/tx/0xbf8965b7cff6abc066ac2cce28b87c61870d636d6d1ba8d89b04901e4b99944a) | `claimBidFor` [`0x5f727b4f…`](https://sepolia.etherscan.io/tx/0x5f727b4fabd3cd6ac68a76751196a26a03c66f18ae8b8142001b0d46967624eb) |
| 4 | bidder 4 | 10, raised to 15 | 1 | 5 at step 10; 0 at step 15 | 1 | 0.000043 | [`0xcc817056…`](https://sepolia.etherscan.io/tx/0xcc817056216062556db39c09b9ca8208fdc6fb21ed8b3330f957fe9303040302) | `claimBidFor` [`0xf3e810a0…`](https://sepolia.etherscan.io/tx/0xf3e810a0a47fc9f4087264000b99e784b3b59860b5fe4931e87baf540e168135) |

1. **Wallet 3 settles first with the order `[1]`**, skipping departure 0
   ([`0x5e90096a…`](https://sepolia.etherscan.io/tx/0x5e90096a7b2950e7b73e4d3fe9db7e400bd130754068742499800852ea4aaed9), 335,513 gas). The call
   scans and clears the book, pays the seller and the fee, and sweeps departure 1 for wallet 3
   only: `sweepOf(wallet 3)` = 1 swept, next position 6, cutoff 1. The sale is SETTLING; wallet
   3 can never finish (departure 0's position is below its next position), and its progress
   touches no one else's.
2. **The keeper settles with its own order** from `settlementOrderFor(saleId, keeper)` =
   `[0,1]` ([`0xb1d9707a…`](https://sepolia.etherscan.io/tx/0xb1d9707a51601e56290dadfc2da430237a53658256b63f11098e50755c6524aa), 57,839 gas): its sweep starts from
   scratch and completes, so the sale is SETTLED with cutoff 2 (`settlement`).

### Token 1: the dispute

| Step | Transaction | Gas |
| --- | --- | ---: |
| Bidder 1's edition bid, step 20 (bid 1) | [`0xc54876ed…`](https://sepolia.etherscan.io/tx/0xc54876ed9c82142ccd6228afdde29e2f8cd68fab324bbe2fa34d0ee848d18609) | 268,801 |
| Bidder 2's edition bid, step 24 (bid 2) | [`0x562a5c59…`](https://sepolia.etherscan.io/tx/0x562a5c59279fa6236bca394ff9c38fbe5bbb8f00c58b0ea3d769c0c5190cd269) | 268,854 |
| Bidder 4's 0.05 ETH 1/1 bid | [`0x241bc311…`](https://sepolia.etherscan.io/tx/0x241bc311bc3b82a5494a3d265ce89ef2275d8185eea9ac3c122b3b6c1a1818d7) | 510,773 |
| Guardian Safe 1 pauses the 1/1 (`execTransaction`) | [`0xe4462884…`](https://sepolia.etherscan.io/tx/0xe4462884f6f59c70a349e8d49b402295fa7c385e2a6b8802d4d6ff1d25779fdd) | 211,418 |
| Bidder 1 withdraws bid 1: placed before the pause's minute | [`0x3981428f…`](https://sepolia.etherscan.io/tx/0x3981428ff823e8abc128d40bf16a4d4fa1dd240a8cb393d1309ec9b825c2525a) | 66,672 |
| Bidder 4 withdraws its 1/1 bid (credited) | [`0x44c8f86c…`](https://sepolia.etherscan.io/tx/0x44c8f86c4830ba835ffd59ffe190b6b97634d26aec39ebe5c3edf1f289d160c4) | 158,448 |
| Bidder 4 claims the credit | [`0xc893e952…`](https://sepolia.etherscan.io/tx/0xc893e952dfb95f4a1a3c1d3ae3a3b2d463618d69a5a0b45cac6349d4e2dafaad) | 32,581 |
| Bidder 3 bids during the pause, step 30 (bid 3): accepted | [`0x05cfe486…`](https://sepolia.etherscan.io/tx/0x05cfe4868a77b278960d10bd5a82bf5b84c1fa65a1c0326680a83db9d11362ff) | 170,934 |
| Bidder 3 tries to withdraw bid 3: **reverts** `WithdrawalsClosed` | [`0x719cd6e0…`](https://sepolia.etherscan.io/tx/0x719cd6e0254d863b2277a3d55e605c8380f5610edf67c79b68f8c9ff33eaf8e8) | 34,315 |
| PLATFORM records the `DISPUTE_OUTCOME` about token 1 | [`0xcc6d2a00…`](https://sepolia.etherscan.io/tx/0xcc6d2a000b94317a9b388162eff86534593cd0a3ce2c439b6d18868fc5bf82f5) | 397,757 |
| The hot admin Safe schedules `cancel(saleId, outcome)` on the manager | [`0x4eb73e04…`](https://sepolia.etherscan.io/tx/0x4eb73e04b11cd90d856032d76236f9f28d9ba39a2dbc62815caa2db123ad135d) | 188,105 |

The pause began at 12:46:24 UTC, in minute 2 of the edition sale (counted from
its open); bids 1 and 2 were placed in minute 0, bid 3 in minute 3. `withdrawalsOpen` read true
from the pause on.

### Pending (r4)

From **3 November 2026, 12:48:00 UTC** (the schedule's ready time; it expires a week later, and
the pause lapses on 8 November at 12:46:24 UTC), in the repository root with the operator's
signer module (`Flow` is the helper under [Pending](#pending) below, with
`-State deployments/11155111/flows/r4.json`):

```powershell
Flow -Step executeCancel -TokenId 1                       # the hot admin Safe: cancel, burn
Flow -Step editionSettle -TokenId 1 -Label editionSettle-1-void  # AuctionVoided
Flow -Step claimBid -TokenId 1 -BidId 2                  # bidder 2: full refund
Flow -Step claimBidFor -TokenId 1 -BidId 3               # bidder 3's during-pause bid
Flow -Step claimCredits -Adapter edition -Bidder bidder3 -Label claimCredits-edition-bidder3-void
```

### Gas (r4)

| Operation | Note | Sepolia | Prague |
| --- | --- | ---: | ---: |
| **Setup** | | | |
| [`createCollection-Flows`](https://sepolia.etherscan.io/tx/0xc7d183570d0a521b384ccd09ded56f6deaae737f14af15421d421cfe872e6e77) |  | 382,250 | 116,690 |
| [`createCollection-Flows-2`](https://sepolia.etherscan.io/tx/0x4b27eb80d8316111edddb088325cbbe7522317e8d8293a3892a4957b0a00c672) |  | 383,196 | 117,636 |
| [`registerPackage`](https://sepolia.etherscan.io/tx/0xc4ad319e1e06de03d1e1cb9b1a6cac121c4e9dab7fffda4d753e8c2757cabf96) |  | 274,607 | 103,367 |
| [`appendCurator`](https://sepolia.etherscan.io/tx/0x4b36c4426ff4383a72766489d726ee6fec8ed73375fbc40e4cd7b4af30912ef2) |  | 274,631 | 104,191 |
| [`acceptPackage`](https://sepolia.etherscan.io/tx/0xf8762fbca16c95ee34b7b8fa4eba211d59cd236c41d051ab1b4da1a22e54fbdc) |  | 1,381,522 | 416,202 |
| **1/1 starts and bids** | | | |
| [`start-9`](https://sepolia.etherscan.io/tx/0x55c8ac09be44b3077bd160b83566c47ec84f083a754076b4a038de77de23d354) | first start ever (one-time slots) | 1,598,898 | 436,338 |
| [`start-5`](https://sepolia.etherscan.io/tx/0x0098711095e51c97c1dccf8e5facf2f7479f897271ff5a43a8044abf9f8391e1) | steady state, edition master | 734,390 | 268,690 |
| [`start-8`](https://sepolia.etherscan.io/tx/0x4bff91719d6d2b00e3bffc772f59fd2a00528973652da9f1f72262fb7bb15acf) | steady state, capped master | 732,872 | 267,172 |
| [`start-0`](https://sepolia.etherscan.io/tx/0x8c2fbd104548a9415757054aa0910ebca4019e6d43b12ff86bf7c6f469db7c8b) | steady state, original | 734,361 | 268,661 |
| [`bid-1-prepause-0.05`](https://sepolia.etherscan.io/tx/0x241bc311bc3b82a5494a3d265ce89ef2275d8185eea9ac3c122b3b6c1a1818d7) | first bid on the auction (locks the increment floor) | 510,773 | 143,993 |
| [`bid-2-opening-0.05`](https://sepolia.etherscan.io/tx/0x91b5170b2a5d17d4f4f3c211188989497e25d0fc4f20c0e2a5152a13bce0eade) | first bid | 169,464 | 73,844 |
| [`bid-2-outbid-0.0525`](https://sepolia.etherscan.io/tx/0x5067e29f7097f26ea633124fb86f45c941e5e02f7d256a559b28890787a725d5) | outbids, credits the previous bidder | 169,138 | 73,518 |
| [`bid-2-antisnipe-0.055125`](https://sepolia.etherscan.io/tx/0x98bf7134a86a70cf8a9b1e99577407aedb576785ad3b7a5e1ee4a73ebf6991ee) | anti-snipe extension | 179,548 | 76,728 |
| [`bid-2-1-wei-refused`](https://sepolia.etherscan.io/tx/0xd93d150b683ef2cb225d7de5a854603ed056f741e6aed292ded03bb62252d77e) | reverted on purpose | 56,537 | 48,937 |
| **Edition auction** | | | |
| [`openEdition-1`](https://sepolia.etherscan.io/tx/0x727664d43b046bc21edf7a4dc8195ff577549313e0808530b613b5abcf55f9bf) | the adapter's first sale (fee recipient registered) | 1,025,742 | 317,982 |
| [`openEdition-2`](https://sepolia.etherscan.io/tx/0x70730afab21398b454da0acc166bb9c942e681730a64bc587ab3620af90c1dd5) | binds the edition, locks its economics | 796,765 | 272,245 |
| [`openEdition-3`](https://sepolia.etherscan.io/tx/0xee0b9b4b91bbc4fe174402b9a9330a88cabe28a6cdae5276b644feba4df7a73e) |  | 796,789 | 272,269 |
| [`editionBid-1-prepause-b1`](https://sepolia.etherscan.io/tx/0xc54876ed9c82142ccd6228afdde29e2f8cd68fab324bbe2fa34d0ee848d18609) | first bid on the sale | 268,801 | 85,561 |
| [`editionBid-2-1-bidder1-s48x1`](https://sepolia.etherscan.io/tx/0xc1cc727d229e67eac189f7dbe66f0b87b3599df932e2db7f8fb5196b09aab2da) | new step | 269,004 | 85,764 |
| [`editionBid-2-7-bidder3-s44x1`](https://sepolia.etherscan.io/tx/0x0da18db8126a8b0a1c153441fd1329c220c665dbab348c6889016bf1b00a7005) | a step's bitmap word already written | 170,913 | 68,493 |
| [`editionBid-3-1-bidder1-s10x1`](https://sepolia.etherscan.io/tx/0x573373504560d1be729443846f74b54eccb7c25b19a26184cd18bdbc8a156afd) | capped: first entry at a step | 271,239 | 87,999 |
| [`editionBid-3-2-bidder2-s10x2`](https://sepolia.etherscan.io/tx/0xb3128ae3c4c4724e352bf658bdc06bf0dfd7dd5117ea340a0dbb8dddd876cfa2) | capped: same step | 173,351 | 70,931 |
| [`editionBid-2-11-bidder3-s30x1-softclose`](https://sepolia.etherscan.io/tx/0x1230751d867ee0b8a27a2da2898a4f43f9b9fe1b4cc03274007280ebfcf90084) | sets `softEnd` | 180,339 | 77,519 |
| [`editionRaise-2-bid4-s20-to-s32`](https://sepolia.etherscan.io/tx/0x321f1f1650971ca51d31043a8a47c7fb82dc83ce3cce6c74600033a5c2f081e1) | uncapped | 65,300 | 50,516 |
| [`editionRaise-3-bid1-s10-to-s20`](https://sepolia.etherscan.io/tx/0xb310592f9de945c0e59ef9df4f096b0bef62bada5a6a985c616ab6daf4be8ee3) | capped: first departure, new step | 298,103 | 100,463 |
| [`editionRaise-3-bid4-s10-to-s15`](https://sepolia.etherscan.io/tx/0xf6d870c762974e0d2c8cd652fe5f90ca3eabe35a02d43af84f73fabf439c9ceb) | capped: second departure | 80,242 | 58,642 |
| [`editionSettle-3-wallet3-order-[1]-stranded`](https://sepolia.etherscan.io/tx/0x5e90096a7b2950e7b73e4d3fe9db7e400bd130754068742499800852ea4aaed9) | scan, clear, pay, partial sweep | 335,513 | 151,773 |
| [`editionSettle-3-keeper-own-sweep-[0,1]`](https://sepolia.etherscan.io/tx/0xb1d9707a51601e56290dadfc2da430237a53658256b63f11098e50755c6524aa) | a second settler's whole sweep | 57,839 | 49,439 |
| [`editionSettle-2-keeper`](https://sepolia.etherscan.io/tx/0xfa395cca32865c4e79393302b1af6515160198c8d3acd3643f31daa99aeae752) | scan, clear, pay (first payout to the seller wallet) | 237,862 | 142,042 |
| [`claimBid-2-1-bidder1`](https://sepolia.etherscan.io/tx/0x386c554930ef850474b9a0ff8466c632cafe0efa82d37ba92cb24c4edc76d79c) | first copy of the edition to a new holder, refund sent | 181,063 | 88,659 |
| [`claimBid-3-2-bidder2-marginal`](https://sepolia.etherscan.io/tx/0xaf261f8731869cfe3595d28935206bfd648bf25fad8e9dbe763a26fe8a777099) | the marginal bid: 1 of 2 units | 181,145 | 88,741 |
| [`claimBidFor-2-4-keeper`](https://sepolia.etherscan.io/tx/0x9e72ede93cf7ababa28cbc78e72c23799ce029133d59fc06d1d654cf3babc218) | 2 copies, refund credited | 188,605 | 90,901 |
| [`claimBidFor-3-1-keeper`](https://sepolia.etherscan.io/tx/0xf613c92a2c9a59b535cb4240881ab18ba1dec1762223b73a5a37dfda28d89239) | 1 copy, refund credited (new credit slot) | 286,664 | 108,140 |
| [`claimBidFor-3-3-keeper-refund-only`](https://sepolia.etherscan.io/tx/0x5f727b4fabd3cd6ac68a76751196a26a03c66f18ae8b8142001b0d46967624eb) | no copy, refund credited | 143,279 | 60,875 |
| [`claimBidFor-2-5-keeper`](https://sepolia.etherscan.io/tx/0xc06e6e1dc7e6ef686b4670c444c9aa0e585abec928e84607f48da03b61e8f99a) | no copy, credit to an existing slot | 44,509 | 42,436 |
| [`claimCredits-edition-bidder1`](https://sepolia.etherscan.io/tx/0x4091607f94cf9007b50ff6194dae09c8e82967441ad9cf4d8599b37099071183) | `claim` of the credited refunds | 32,391 | 32,188 |
| **Settlement and editions** | | | |
| [`settle-4-unbid-to-museum`](https://sepolia.etherscan.io/tx/0x69c8e7905c84f5a4a118eeff10e2b170e6ff1700dda0751a0d13fcbaea956813) | UNBID: Stream moves it to the museum | 341,011 | 140,971 |
| [`settle-3-unbid-master-to-museum`](https://sepolia.etherscan.io/tx/0x11a8f33b0c40bf587bbb03949d029cf0ce3146bccda16b39e3ed5e231d0facbe) | the same, an edition master | 243,103 | 123,883 |
| [`settle-2-sold-0.055125`](https://sepolia.etherscan.io/tx/0x6a4e5916f20b46cc427130573b84ba0a11b2e49494a3d9502e3a537ab7f03e71) | SOLD: delivery, first payout to the seller wallet | 554,082 | 189,642 |
| [`createEdition-2-keeper`](https://sepolia.etherscan.io/tx/0x774d7e7268c938fea4a78e6532deb6f1b52e86708e4f3a7730d0dbfc013e00a1) | economics already locked by the open | 339,990 | 147,350 |
| [`createEdition-3-keeper`](https://sepolia.etherscan.io/tx/0xda8aaf6b122df4c5f0360ba6b0f2b714465dfa0172f5821bc846327775fb2e55) | the same, capped | 348,524 | 148,684 |
| [`claimCredits-english-bidder1-0.05`](https://sepolia.etherscan.io/tx/0xb93b03c8dea5a9e883542287cd8e153de2138f500507cd54bede6e45e7509807) | `claim` of an outbid credit | 32,581 | 32,426 |
| **Dispute** | | | |
| [`pause-1`](https://sepolia.etherscan.io/tx/0xe4462884f6f59c70a349e8d49b402295fa7c385e2a6b8802d4d6ff1d25779fdd) | Guardian Safe `execTransaction` | 211,418 | 113,398 |
| [`editionWithdraw-1-prepause-b1`](https://sepolia.etherscan.io/tx/0x3981428ff823e8abc128d40bf16a4d4fa1dd240a8cb393d1309ec9b825c2525a) | escrow sent back | 66,672 | 55,440 |
| [`withdrawBid-1-prepause-0.05`](https://sepolia.etherscan.io/tx/0x44c8f86c4830ba835ffd59ffe190b6b97634d26aec39ebe5c3edf1f289d160c4) | 1/1 bid credited back | 158,448 | 68,828 |
| [`editionBid-1-during-pause-b3`](https://sepolia.etherscan.io/tx/0x05cfe4868a77b278960d10bd5a82bf5b84c1fa65a1c0326680a83db9d11362ff) | accepted while paused | 170,934 | 68,514 |
| [`editionWithdraw-1-during-pause-refused`](https://sepolia.etherscan.io/tx/0x719cd6e0254d863b2277a3d55e605c8380f5610edf67c79b68f8c9ff33eaf8e8) | reverted on purpose | 34,315 | 39,915 |
| [`disputeOutcome-1`](https://sepolia.etherscan.io/tx/0xcc6d2a000b94317a9b388162eff86534593cd0a3ce2c439b6d18868fc5bf82f5) | PLATFORM statement | 397,757 | 138,897 |
| [`scheduleCancel-1`](https://sepolia.etherscan.io/tx/0x4eb73e04b11cd90d856032d76236f9f28d9ba39a2dbc62815caa2db123ad135d) | hot admin Safe `execTransaction` → `manager.schedule` | 188,105 | 98,085 |

Every other row is in [`flows/r4.json`](flows/r4.json). The content uploads
([`flows/r4-content.json`](flows/r4-content.json), 36 transactions) cost what they cost on r3,
row for row: `writeChunk` of 1,024, 8,192 and 24,572 bytes is 1,914,322,
13,008,576 and 38,364,370 gas, a record chunk
625,103 and a manifest about 578K to 580K.

- **The edition auction on Sepolia.** A bid that opens a new step costs about 269K (Prague about
  85,764); one at an already-used step word about 171K. A raise is 65K uncapped and
  80K to 298K capped (a departure log entry, and a new step). Settling a sale is 238K to 336K;
  a second settler's sweep 58K. A claim is 44K (refund credited to an existing credit) to 287K
  (copies to a new holder and a new credit). Opening a sale is about 797K: it binds the edition
  and locks its economics, which is why `createEdition` after it costs only about 340K
  (r3's, which locked them, was 888K simulated).
- **Starts match r3.** A steady-state start is 734,390 (r3: 735,859); the first start
  ever 1,598,898 (r3: 1,601,871).
- **Refusals sent on purpose** cost what they ran before reverting: 56,537 for the
  1-wei bid, 34,315 for the refused withdrawal.

### Not run on r4

- The VRF request and fulfilment (r2 ran it), `openRecord` and `syncOnChain`, the views'
  gas, `refreshStanding`, ERC-20 and Permit2 bids, and governance operations other than the
  pause and the scheduled cancel.
- The live Verify (due from 6 November 2026, 12:41:36 UTC;
  [README](README.md#sepolia-r4-1-november-2026-current)).
- The state-gas reservoir test of the runbook's step 13.

## r3: the release candidate (15 October 2026)

On 15 October 2026 the lifecycle ran again on **r3**, `main` at `e5fe78c`
([README](README.md#sepolia-r3-15-october-2026-superseded-by-r4)): every review fix, the state-growth
gas diet and the source-quality pass. Same driver, same package (the same files, items and
root `0xde416feb…e68d`) and the same accounts as r2. The state file is
[`flows/r3.json`](flows/r3.json).

- **Ran on chain:** the content uploads, two collections, the curation approval, the CURATOR
  evidence statement, the artist's first acceptance (which registers the artist), seven
  auction starts (two of them `startWithBid`), three bids, `openRecord` and `syncOnChain`,
  and the views. Nothing reverted.
- **Simulated until the auctions end:** `createEdition` needs the master's sale settled, and
  every auction runs 24 hours. `settle`, `createEdition`, `openSale` and the purchases were
  run with `eth_simulateV1` on r3's live state, in blocks after the master's end, with the
  driver's own calldata. On r2 the same method reproduced all 18 later receipts exactly. The
  commands that finish the run are under [Pending (r3)](#pending-r3).
- **The driver needed one fix.** Since the review fix
  [#55](https://github.com/6529-Collections/6529-works/pull/55) a curation approval binds the
  signer's epoch: `approvalDigest(root, evidence, signerEpoch(signer))`. `Flows.s.sol` still
  called the two-argument digest of r1 and r2, which r3's verifier does not have; it now reads
  the epoch first. r3 is now the driver's default record.

### The gas diet on chain

Sepolia gas is the receipt's `gasUsed`, or the simulated call's; Prague is the receipt
replayed with `cast run --quick --evm-version prague`. The slot counts are ADR 0004's (CI), and
the estimate is ADR 0004's "Sepolia estimate (r2)": the r2 receipt minus the diet's expected
saving.

| Operation | r3 Sepolia | r3 Prague | r2 Sepolia | r3 − r2 | New slots r2 → r3 | ADR 0004 estimate |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| [`start`, steady state (item 2)](https://sepolia.etherscan.io/tx/0x0225780e7f11658d5c12469089c46106c7cb674c1e7ffeb6e3bd1cfe9a621505) | 735,859 | 270,159 | 846,963 | −111,104 | 6 → 5 | about 736K |
| [`start`, the artist's second work (item 1)](https://sepolia.etherscan.io/tx/0xb96a2ac251f6d17698e7e9b2de66aa843ebff87b3f142cd7f1449b6b188b4ef4) | 735,839 | 270,139 | 846,971 | −111,132 | 6 → 5 | about 736K |
| [`start`, an edition master (item 5)](https://sepolia.etherscan.io/tx/0xd07fb2f97f3dbf5cdb128a240a5dadae4bd734cd2cb159f3cfb7221a8258a148) | 736,477 | 270,777 | 847,598 | −111,121 | 6 → 5 | — |
| [`startWithBid`, steady state (item 7)](https://sepolia.etherscan.io/tx/0x76a0e1252114b1c790684a2abac46cd658596287a4c6fb6d56fbba84b1c70feb) | 871,980 | 312,260 | 982,312 | −110,332 | 7 → 6 | about 872K |
| `createEdition` (simulated) | 887,954 |  | 1,118,699 | −230,745 | 9 → 7 | about 895K |
| `openSale`, the adapter's first sale (simulated) | 992,031 |  | 993,668 | −1,637 | 8 → 8 | — |
| `purchase`, the first copy, new holder (simulated) | 232,182 |  | 468,086 | −235,904 | 3 → 1 | about 220K |
| `purchase`, a later copy, new holder (simulated) | 232,158 |  | 370,142 | −137,984 | 2 → 1 | about 228K |
| `purchase`, two copies, existing holder (simulated) | 134,262 |  | 174,326 | −40,064 | 0 → 0 | — |
| `settle`, with a bid, first payout to the seller wallet (simulated) | 449,934 |  | 441,363 | +8,571 | 1 and an account | — |
| Deploy, 25 transactions ([README](README.md#sepolia-r3-15-october-2026-superseded-by-r4)) | 476,686,821 | 76,583,081 (forge) | 447,912,784 | +28,774,037 | | |

- **Each slot the diet removed is about 88,000 to 89,000 gas on Sepolia,** on top of its
  Prague saving. A steady-state `start` fell by 111,104 gas (13%), `startWithBid` by 110,332
  (11%), `createEdition` by 230,745 (21%) and the first copy's `purchase` by 235,904 (50%).
- **ADR 0004's estimates hold.** The starts match them to the thousand; `createEdition` is
  about 7K under, and the purchases about 4K to 12K over.
- **`openSale` barely moves, as expected.** Both runs measure the adapter's *first* sale,
  which registers the fee recipient: 8 new slots before and after the diet. A later
  `openSale` writes 6 (ADR 0004: about 762K on Sepolia); this run has one edition, so it does
  not measure one.
- **The deploy costs more:** the contracts grew with the review fixes; the per-transaction
  table is in the [README](README.md#sepolia-r3-15-october-2026-superseded-by-r4).
- **`settle` of the first payout costs 8,571 more** than on r2. The diet did not change its
  slots, and its Prague gas grew by about 8K with the review fixes (ADR 0004's table: 166,585,
  against 158,414 in CI when r2 was measured).

### Other r3 rows

| Operation | r3 Sepolia | r3 Prague | r2 Sepolia |
| --- | ---: | ---: | ---: |
| [`createCollection` (PLATFORM)](https://sepolia.etherscan.io/tx/0xd8a684aa6b94de329edc7056c044f6044f20fcea60b2b7057508108ac539bd24) | 382,228 | 116,668 | 377,834 |
| [`registerPackage` (curation signer 1's approval)](https://sepolia.etherscan.io/tx/0x0e6a2408c1fa18f99a31420abbe0e6e85bb323cf7ed84212466f02bbceaa176a) | 274,595 | 103,355 | 269,395 |
| [`appendCurator` (CURATOR evidence statement)](https://sepolia.etherscan.io/tx/0x09bd63fc0966673bdcac8d743fb6288947a568711eb9a55ed31b22914bc75c42) | 274,619 | 104,179 | 272,040 |
| [`acceptPackage`, first acceptance: registers the artist](https://sepolia.etherscan.io/tx/0xa141c52a7e0fcb8f10de17e4456f6f43a252248728529b8d6f18ceffb50e4ff0) | 1,381,478 | 416,158 | 1,220,987 |
| [`start`, first work ever](https://sepolia.etherscan.io/tx/0x64be42ea8d461e201cbeaabe95bf53f3a0e5f5d66796ff807812722cb7623543) | 1,601,871 | 439,311 | 1,604,862 |
| [`startWithBid`, first bid under new sale terms (one-time)](https://sepolia.etherscan.io/tx/0xf9e00fc2d4b1464d76a393890ef898405e449d5eac9fb59e1fa32ec73e8dbedd) | 1,213,250 | 382,370 | — |
| [`bid`, first bid on a sale](https://sepolia.etherscan.io/tx/0x95958d0cd485edefdf2f772c0e6172e38237bf44addc2fc2b683941d71a9eb51) | 169,410 | 73,790 | 168,777 |
| [`bid`, outbids and credits the previous bidder](https://sepolia.etherscan.io/tx/0x4cde0ba6e11854b5872af465749624c7f1d11c3241ef5a934566a55e03a8d60e) | 169,060 | 73,440 | 168,932 |
| [`openRecord`](https://sepolia.etherscan.io/tx/0x1b8bc73dc94890c9887bfdcd7b17caab03a21bd5c6bf28596e9b4484caab49f8) | 504,555 | 157,975 | 505,728 |
| [`syncOnChain`](https://sepolia.etherscan.io/tx/0x17029a2069d4a07de99c560740092efe65441ab7f66b9a924c59148f1f195ee2) | 66,247 | 63,547 | 58,821 |

- **Content** costs the same as on r2, row for row (the content store did not change):
  `writeChunk` of 1,024, 8,192 and 24,572 bytes is 1,914,322, 13,008,576 and 38,364,370 gas.
- **The artist's first acceptance** records the wallets the artist had consolidated on the
  shared delegation contract: two by now (from r1 and r2), against one when r2 registered.
- **The first bid under new sale terms** was a `bid` on r2 (510,074) and is a `startWithBid`
  on r3 (item 3). On r2, `startWithBid` came after that bid, so r2's `startWithBid` row is
  steady state; r3's steady-state row is item 7's.
- **`syncOnChain` costs 7,426 more** on both rule sets, so in execution, not new state;
  WorkRecords changed in #53, #56 and #66.

**Views** (`eth_simulateV1`: the gas each call uses as a transaction):

| Call | r3 Sepolia | Output | r2 Sepolia | r2 output |
| --- | ---: | ---: | ---: | ---: |
| `tokenURI(1)`: 1,024 bytes of attested base64, inlined | 313,479 | 1,734 bytes | 311,148 | 1,824 bytes |
| `tokenURI(4)`: record not open (core-only metadata) | 122,083 | 298 bytes | 117,914 | 384 bytes |
| `royaltyInfo(1, 1 ETH)` | 36,426 |  | 40,667 |  |

The views stay far inside the 8M `tokenURI` budget; the metadata JSON changed with the review
fixes, hence the different output sizes.

### Pending (r3)

**What was created.** Collections 1 and 2; package root `0xde416feb…e68d`; Stream tokens 1 to
7, each a 24-hour auction:

| Token | Item | State on 15 October |
| ---: | --- | --- |
| 1 | 1,024-byte base64 media | Record opened and synced. Bidder 1 bid 0.001 ETH; bidder 2 outbid at 0.002 ETH. Ends 16 October, 20:33:12 UTC. |
| 2 | 8,192-byte base64 media | No bid. Ends 20:33:24 UTC. |
| 3 | Registered-only media | No bid. Ends 20:33:36 UTC. |
| 4 | Registered-only media | `startWithBid` by bidder 2, 0.001 ETH. Ends 20:33:48 UTC. |
| 5 | 24,572-byte base64 media | No bid. Ends 20:34:00 UTC. |
| 6 | `EDITION_MASTER`: fixed edition of 10 at 0.0001 ETH | Bidder 1 bid 0.001 ETH. Ends 20:34:12 UTC. |
| 7 | In collection 2 | `startWithBid` by bidder 1, 0.001 ETH. Ends 20:35:00 UTC. |

Item 6, the VRF work, was not started on r3: its seed request is the next thing to run if
the VRF path needs re-measuring.

**To finish, from 16 October 2026, 20:35 UTC,** in the repository root (r3 is the driver's
default record; `Flow` is the helper under [Pending](#pending) below):

```powershell
$r3 = @('-State', 'deployments/11155111/flows/r3.json')
Flow @r3 -Step settle -TokenId 6        # the master: first payout, creates the seller wallet
Flow @r3 -Step settle -TokenId 4
Flow @r3 -Step settle -TokenId 1
Flow @r3 -Step settle -TokenId 7
Flow @r3 -Step settle -TokenId 2        # no bid: the token goes to the artist
Flow @r3 -Step settle -TokenId 3
Flow @r3 -Step settle -TokenId 5
Flow @r3 -Step createEdition -TokenId 6
Flow @r3 -Step openSale -TokenId 6
Flow @r3 -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 1 -Label purchase-first-copy
Flow @r3 -Step purchase -SaleId 1 -Bidder bidder2 -Quantity 1 -Label purchase-later-copy
Flow @r3 -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 2 -Label purchase-two-copies
Flow @r3 -Step prague                    # soon after: the public RPC keeps recent state only
Flow @r3 -Step report
```

Then replace the simulated rows above with the receipts. The simulation predicts: `settle` of
token 6, 449,934; `createEdition`, 887,954; `openSale`, 992,031; the purchases, 232,182,
232,158 and 134,262.

**An anti-snipe bid** can be placed for real this time: a bid in the last 15 minutes of a
live r3 auction. For token 1, between 20:18:12 and 20:33:12 UTC on 16 October, bidder 1
outbids bidder 2's 0.002 ETH:

```powershell
Flow @r3 -Step bid -TokenId 1 -Bidder bidder1 -Amount 3000000000000000 -Label bid-antisnipe
```

It moves token 1's end to 15 minutes after the bid, so settle token 1 after that.

## Summary (r2)

- **Every flow ran on the real stack.** This covers:
  - content uploads and base64 attestation;
  - a curated package with its approval, the CURATOR evidence statement and the
    artist's acceptance;
  - eight auction starts, including `startWithBid` and a VRF work with a real Chainlink
    fulfilment;
  - bids, outbid credits and their claim;
  - opening and syncing records, and `tokenURI`;
  - a 6529 consolidation with `refreshStanding`.

  Nothing reverted. r1 ran the same flows.
- **Transactions that create state cost 2 to 7 times their Prague gas.** A new storage
  slot costs about 89,000 gas more than on Prague, and a byte of contract code about
  1,330 more.
- **The `start` budget breaks.** On r2 the steady-state `start` costs **846,963** gas
  against the 350K budget, and `startWithBid` costs **982,312**. The same transactions
  cost 293K and 335K on Prague. A steady-state start writes 6 new slots, which account
  for about 533K of the difference. r1 is within 20 gas of r2.
- **Editions creation stays near 1.1M.** `createEdition` costs **1,118,699** on r2, after
  #41, against 1,133,867 on r1. #41 saved 15K of execution, but the call still writes 9
  new slots. The first mint, through `purchase`, costs 468,086 on r2 (r1: 476,183).
- **On-chain storage costs about 7 times more.** It is about 1,548 gas per byte
  (Prague: 218), the same on r2 and r1. 1 MiB costs about 1.65 ETH at 1 gwei, against
  0.24 ETH on Prague.
- **Identity.** On r2, `refreshStanding` that records a new wallet costs 247,970, and a
  refresh with nothing new costs 128,785 with two recorded wallets. The artist's first
  acceptance costs 1,220,987 on r2: it registers the artist and records the wallet the
  artist had already consolidated.
- **Reads are unchanged.** `tokenURI` and `royaltyInfo` cost the same as on Prague, or
  slightly less. The `tokenURI` budget holds.
- **Settlement and editions match their simulation exactly.** They were first simulated
  at a later timestamp, then broadcast on 13 October 2026. All 18 receipts that had a
  simulated counterpart (9 per instance) gave the same Sepolia and Prague gas. Only the
  anti-snipe bid is still simulated: every auction had ended before it could be placed.

## Method

- **Driver.** [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol) encodes
  every call and reads every EIP-712 digest from the contract that checks it.
  [`script/sepolia/flows.ps1`](../../script/sepolia/flows.ps1) signs the digests,
  checks that each signature recovers to the expected signer, and sends each
  transaction with `cast send`.
  - Each gas limit therefore came from the node's `eth_estimateGas`, which applies
    Glamsterdam.
  - The priority fee was 0.05 gwei.
  - The 24 KB chunk went through `forge script --skip-simulation`, because its calldata
    is longer than a Windows command line.
  - `-Record` selects the deployment, and r2 is the default.
  - Both instances ran the same package: the same files, items and root.
- **Sepolia gas** is the receipt's `gasUsed`.
- **Prague gas** is the same transaction replayed on its parent block's state with
  Prague costs: `cast run <tx> --quick --evm-version prague` (Foundry 1.7.1).
  - An anvil fork of the parent block with `--hardfork prague` gives the same gas for
    every row checked (27 on r1 and 14 on r2), except `refreshStanding` with nothing
    new. anvil replayed that one with a 30M gas limit and reports more: 86,653 against
    76,478 on r1, and 133,285 against 117,484 on r2.
  - The public RPC keeps only recent state, so each replay ran within minutes of its
    transaction.
- **New slots** are the storage slots the transaction writes from zero. They are
  counted from anvil's `prestateTracer` diff of the Prague replay.
- **Simulated rows** are calls run on the live state with `eth_simulateV1` (reth), in
  blocks with later timestamps. Their Prague numbers come from the same calls sent on
  an anvil Prague fork of the same block.
  - The simulation reproduced a mined transaction's receipt exactly (577,375 gas for
    `registerManifest`).
  - Settlement and the edition flow were simulated on 11 October and broadcast on
    13 October. Each of the 18 receipts with a simulated counterpart equals it, on both
    rule sets.
  - One row is still simulated: the anti-snipe bid (see section 2).
- **Views** are measured as the gas a call uses: `eth_simulateV1` for Sepolia, and a
  transaction on the anvil Prague fork.
- **Repo gas report** is `forge test --match-contract IntegrationGasReport -vv` at
  `60edd9b`, the r1 source. It is what the budgets were set against. It does not deduct
  refunds, and it uses its own package. That is why its steady-state `start` is 275,730
  where the Prague replay of the Sepolia transaction is 293,243 (r2).

**Accounts** (the same on both instances).
- The operator (`0x26A3…3697`, no role) relayed the permissionless calls. A second
  relayer (`0xc905…5F72`) uploaded r2's content in parallel.
- The platform key and the curator key acted for their roles.
- Curation signer 1 and the artist key (`0x111C…Ae1B`) signed off-chain.
- Throwaway keys made for these runs:
  - bidder 1 (`0x1fb4…2BE2`) and bidder 2 (`0x7B41…9C74`);
  - the artist's second wallet (`0x5817…5F6B`), consolidated during r1;
  - a third wallet (`0xB95e…2211`), consolidated during r2.
- Both runs together sent 0.098 ETH of funding from the operator, most of it still in
  those accounts, and used about 0.009 ETH of gas (181M gas, settlement included).

**What was created on each instance.**
- Collections 1 and 2.
- Package root `0xde416feb…e68d`, which has eight items by the artist.
- Stream tokens 1 to 8, auctioned for 24 hours and settled on 13 October:

| Token | Item | State (r2 and r1) |
| ---: | --- | --- |
| 1 | 1,024-byte base64 media | Record opened and synced. Sold to bidder 2 for 0.002 ETH. |
| 2 | 8,192-byte base64 media | Record opened and synced. No bid: went to the artist. |
| 3 | Registered-only media | Record opened. No bid: went to the artist. |
| 4 | Registered-only media | `startWithBid`: sold to bidder 2 for 0.001 ETH. |
| 5 | 24,572-byte base64 media | Record opened and synced. No bid: went to the artist. |
| 6 | `EDITION_MASTER`: fixed edition of 10 at 0.0001 ETH | Sold to bidder 1 for 0.001 ETH. Edition 6 created; 4 copies sold (bidder 1: 3, bidder 2: 1). |
| 7 | In collection 2 | No bid: went to the artist. |
| 8 | VRF seed | No bid: went to the artist. |

## 1. Content

All three files are pseudo-random media stored as attested `Base64`, one chunk each.
r2 and r1 run the same `ContentStore` code and cost the same.

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots | r1 Sepolia |
| --- | ---: | ---: | ---: | ---: | ---: |
| [`writeChunk`, 1,024 bytes](https://sepolia.etherscan.io/tx/0x2a3f781437a5c1c2278781100ccf3695fa4f9148d8978a0252d7073803dece14) | 1,914,322 | 304,754 | 6.28 | 1 and a contract | [1,914,322](https://sepolia.etherscan.io/tx/0xa83a50bdc2671278315dc6c04cce3fce1b712ba98033d3725fc3a037fe9021d1) |
| [`writeChunk`, 8,192 bytes](https://sepolia.etherscan.io/tx/0xf8236b59dfe2a81fdad09f2df6f8a099f6783eec3a61ac4788c4521fa4f36ce3) | 13,008,576 | 1,864,224 | 6.98 | 1 and a contract | [13,008,576](https://sepolia.etherscan.io/tx/0x504531e2842f3a94b42d039b4bceb86671b39bc194472756deffa6ecc098de18) |
| [`writeChunk`, 24,572 bytes](https://sepolia.etherscan.io/tx/0x2a82b6ace7c7735d578b378399e76d01426dab1e05d1a16253c08cbca2c233b7) | 38,364,370 | 5,431,552 | 7.06 | 1 and a contract | [38,364,370](https://sepolia.etherscan.io/tx/0x384cf4410838dbd8ff9d39eb2d0ab37d9ce9e27c79dd013cdb700656bb2cf65d) |
| [`registerManifest`, one chunk](https://sepolia.etherscan.io/tx/0xa164e3000e5d30f4b94e99d7675301ba5a27128272f516fafbe2b335a9b421dc) | 577,375 | 143,475 | 4.02 | 5 | [577,375](https://sepolia.etherscan.io/tx/0xc3f901893d2996a40df22a42902bf32e5ba6b69109fc32872d2a89be11e0fd25) |
| [`attestBase64`, 1,024 bytes](https://sepolia.etherscan.io/tx/0x1682f324199ccbfb9e2c3942f947b3d492da9758d65b28bffb12f9fdaea33e6a) | 153,123 | 70,103 | 2.18 | 1 | [153,123](https://sepolia.etherscan.io/tx/0xb8bba0f8a06dcf5b45b968c575d5bd6de7f338761b623b2273ff4d3c3e4d92da) |
| [`attestBase64`, 8,192 bytes](https://sepolia.etherscan.io/tx/0xc34e3684ad336912550484069f000df80b7ce4a57219ec9563f69c1a4a6d1c76) | 205,248 | 122,228 | 1.68 | 1 | [205,248](https://sepolia.etherscan.io/tx/0x0e844e0c16e0de8a5b2f0138f115abd0c3235c819752d54f56b3c20302d20c8f) |
| [`attestBase64`, 24,572 bytes](https://sepolia.etherscan.io/tx/0xe0aad0a2ae98785f54c1180a7672db9e7b218ac9b6b46b37f81bf469044f3686) | 325,172 | 242,152 | 1.34 | 1 | [325,172](https://sepolia.etherscan.io/tx/0x9036e3d6496e8379b429d01d9871171e052c1832a4768cf56e2f5c5c9ec750f2) |
| [`writeChunk`, a 191-byte record](https://sepolia.etherscan.io/tx/0x542eda40347d316e13e8f4775ba052291638b6efb65c586fa49f63a58791deb7) | 625,103 | 123,587 | 5.06 | 1 and a contract | [625,103](https://sepolia.etherscan.io/tx/0x80123bc9aed418a59a60d33812a3cd6bbbcbe4073adcb141a1f150d82723c436) |
| [`registerManifest`, that record](https://sepolia.etherscan.io/tx/0x61eeb0222b0e0c50828ec4b8ca084340d7095ddcdfc3c54c46edd0ae8aea4397) | 579,897 | 145,997 | 3.97 | 5 | [579,897](https://sepolia.etherscan.io/tx/0x9360135af2bf3fd7d1e0d6b31a2b6456ab7a1d6fd06e618984135b89fae3c3f4) |

The other seven records and five registered-only media manifests cost the same as these
rows on both instances: 625,103, and about 577,000 to 580,000 each.

**Per byte (r2 and r1).** A line through the three chunks fits each one within 0.03%:
- Sepolia: `writeChunk(n)` ≈ 328,760 + 1,547.9 × n gas.
- Prague: ≈ 81,303 + 217.7 × n gas.

A full chunk of 24,575 bytes costs about 38.4M gas: 1,561 per byte with the fixed
part. `attestBase64` only reads, so its per-byte cost is about the same as on Prague.
What changed is the new slot that records the attestation.

**Manifests by size** (r1's store, from `eth_estimateGas`; nothing was uploaded): about
111,500 gas per extra chunk hash.

| Chunks | Sepolia (r1) |
| ---: | ---: |
| 1 | 583,137 |
| 11 (256 KiB) | 1,698,112 |
| 43 (1 MiB) | 5,265,859 |
| 256 | 28,784,463 (simulated `gasUsed`) |
| 512 (the cap) | about 57.6M. The public RPC caps estimates and simulations at 50M, so it cannot measure this. |

**What a work costs to store on-chain** (r2 and r1; upload, manifest and attestation;
base fee ignored):

| File | Sepolia gas | at 1 gwei | at 10 gwei | Prague gas | at 1 gwei |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256 KiB (11 chunks) | about 413M | 0.41 ETH | 4.1 ETH | about 60M | 0.06 ETH |
| 1 MiB (43 chunks) | about 1,650M | 1.65 ETH | 16.5 ETH | about 241M | 0.24 ETH |

The upload is about 99% of each figure. The attestation is interpolated from the three
measured files: about 2.1M gas for 256 KiB and 7.8M for 1 MiB.

## 2. The curated Stream sale

Budgets are from ADR 0003 (the steady-state gate) and from the integration gas report's
test ceilings (the first start in a new collection, and `settle`). The repo gas report's
Prague figures, at `60edd9b`, are:
- `start`: 275,730 at steady state, 275,756 for the first in a new collection, and
  437,334 for the first work ever;
- `startWithBid`: 317,084;
- `bid`: 70,848;
- `settle`: 175,914.

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots (r2) | r1 Sepolia | Budget | Result (r2) |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| [`createCollection` (PLATFORM)](https://sepolia.etherscan.io/tx/0x24289535f34b3904cf4f2837e6a2780de24dfbea72edfabc6dc23a2160745b91) | 377,834 | 112,274 | 3.37 | 3 | [378,158](https://sepolia.etherscan.io/tx/0x9f12f25bd5c8941514cecb6c90301da2dc6a3ade36886c48633f88c60a937991) | | |
| [`registerPackage` (curation signer 1's approval)](https://sepolia.etherscan.io/tx/0x9bbd0495485d2f916b067179b7ab01b3d2d8fc16f3417a46da73dc3812723616) | 269,395 | 98,155 | 2.74 | 2 | [269,395](https://sepolia.etherscan.io/tx/0x2f44223f2d7a41675509c13ae31c2077aee1424ed092dae13858260510795d41) | | |
| [`appendCurator` (CURATOR evidence statement)](https://sepolia.etherscan.io/tx/0xeedf7982f40d183050d9fc20dbfd3679d91bd815bcc93368c6eda90389aa97bf) | 272,040 | 101,600 | 2.68 | 2 | [272,040](https://sepolia.etherscan.io/tx/0xd1785152fc93a23394154189f71d8d53180f190c07758a1ab15cfa12ce30126d) | | |
| [`acceptPackage`, first acceptance: registers the artist](https://sepolia.etherscan.io/tx/0xbba20cd23e994f0127064f264d8c1287778c8d091ee95797d5660d25e2e723a1) | 1,220,987 | 344,087 | 3.55 | 10 | [957,595](https://sepolia.etherscan.io/tx/0x7d4beb14ac8a8e8609b3bbae292eec0e03b133d8c580fb1597da2ee0960797eb) | | |
| [`start`, first work ever](https://sepolia.etherscan.io/tx/0xe099a4abd05d3a2c636ee935e5dfe1dcf70255d062691fe31c3b5756ab5eb202) | 1,604,862 | 442,302 | 3.63 | 13 | [1,604,870](https://sepolia.etherscan.io/tx/0x7b0582f0b0134303b9a36c3adcbd0345c20b68390577ea27dcbb1d598895ea8a) | one-time, not gated | |
| [`start`, second work](https://sepolia.etherscan.io/tx/0x79a136a41ae92ff5ef9885f34a94d88863d1c85bf736d6887770c50996a8e4e8) | 846,971 | 293,251 | 2.89 | 6 | [846,971](https://sepolia.etherscan.io/tx/0xd9bd5fe54ab65c67c7f7dcc123c75fe964d9e2549fc779691c5b4c592d61ebd2) | 350,000 | **fail** |
| [`start`, steady state](https://sepolia.etherscan.io/tx/0x28b3b1afd0f7c5713d7db6b29792226df030593d81ab575ab10e320799835a67) | 846,963 | 293,243 | 2.89 | 6 | [846,983](https://sepolia.etherscan.io/tx/0x4eeebbb16e951397cfff3d00218dd35e0121461d384ec622adad46c1178965e5) | 350,000 | **fail** |
| [`start`, an edition master](https://sepolia.etherscan.io/tx/0x84564a35fbe4f9c589687875b644721a3d0e0393392429ddd5cdc25622e6aecd) | 847,598 | 293,878 | 2.88 | 6 | [847,598](https://sepolia.etherscan.io/tx/0x143de05853fcda8c44e086334809bbd7b9c8423ce0f828ff0e4d8c970e8ef029) | 350,000 | **fail** |
| [`start`, first work in a new collection](https://sepolia.etherscan.io/tx/0x8826bbf8f65a52d816b9a6b8a9d741b5ff48ac20b4f7223b18ad7cd50ea8af60) | 846,977 | 293,257 | 2.89 | 6 | [846,965](https://sepolia.etherscan.io/tx/0x47f367cb24bb4633eb75a665d31eae9b8b49aa1b940aa3a1945274a3ca53be9d) | 400,000 test ceiling | **fail** |
| [`start`, a VRF work](https://sepolia.etherscan.io/tx/0xd4a7d292986764fde5e06967e324a2722840ef4538af0df5f9121377d722572c) | 852,868 | 298,748 | 2.85 | 6 | [852,856](https://sepolia.etherscan.io/tx/0x1ea28624bdf5fc9482bd2ceda19cbcb5a18a4ebc27271a69e559545537b87cc1) | 350,000 | **fail** |
| [`startWithBid`, steady state](https://sepolia.etherscan.io/tx/0x3d14152a03856d7a13c1a9f887166a60b91b7e568cb4d7fa3d71cbb625047c12) | 982,312 | 334,572 | 2.94 | 7 | [982,312](https://sepolia.etherscan.io/tx/0xe89a31cdbed285998931e1e6713ed3d6c821112264f60eb01bd68c739d650510) | 350,000 | **fail** |
| [`bid`, first bid under new sale terms (one-time)](https://sepolia.etherscan.io/tx/0xe656e2fe0de917f4fdcdfad388d7fe7d9add0731c1dce26678ab9c59c8f99f04) | 510,074 | 143,294 | 3.56 | 4 | [510,086](https://sepolia.etherscan.io/tx/0xb646ae8b76a2e0ee4051a6ca26448a1a26215efe9882ae7e6779eef7605f1271) | one-time, not gated | |
| [`bid`, first bid on a sale](https://sepolia.etherscan.io/tx/0x149716babe91733fda495b9e1e24ae2bcf01f7015dc52b7bf59af48204357982) | 168,777 | 73,157 | 2.31 | 1 | [168,777](https://sepolia.etherscan.io/tx/0x25062f4d54350b0bfa079b8c5653d1b84c27c91488d2dbd2d1056a32152fc049) | | |
| [`bid`, outbids and credits the previous bidder](https://sepolia.etherscan.io/tx/0xdaf7c61d76e8bdf9b8219b5f36ce4081901759106bf91530222d9ed6b9038e84) | 168,932 | 73,312 | 2.30 | 1 | [168,944](https://sepolia.etherscan.io/tx/0x0e1010d3dc7d1ebe05422a7c2455ba454d084513af8c4251447f7959cd8d15ed) | | |
| [`claim`, the outbid bidder's credit](https://sepolia.etherscan.io/tx/0xcc11270e1882f2b04491a2dd8dc5a7ece95cce66fc45aa456bdc40ffce304c34) | 32,580 | 32,425 | 1.00 | 0 | [32,580](https://sepolia.etherscan.io/tx/0xefe7f481a1630a9b185c87dc9320afc7a26d9165bce7d4e0099c40d65a591335) | | |
| `bid` 5 minutes before the end (simulated; see below) | 179,354 | 76,534 | 2.34 | 1 | 179,366 | | |
| [`settle`, with a bid, first payout to the seller (token 6)](https://sepolia.etherscan.io/tx/0x2ef2f5e6c1735ffc60f31cf2534c96a938629720f086c68eba55299aa98f7e48) | 441,363 | 164,743 | 2.68 | 1 and an account | [441,363](https://sepolia.etherscan.io/tx/0x5dbbc598d80b64d75d8f59300885eb1efcb3c6ab579cd9a68aed362820b9ffaf) | 400,000 test ceiling | **fail** |
| [`settle`, with a bid (token 4)](https://sepolia.etherscan.io/tx/0x5caa9f050a95a29c57e6738a41b73d61ab097d610fae16ead6ae3ffc17c5593b) | 257,763 | 139,743 | 1.84 | 1 | [257,763](https://sepolia.etherscan.io/tx/0x10e0abc979bed8f6d73cde72f31b89da3325516fcada9c0d22521dcdacf2cab2) | 400,000 test ceiling | pass |
| [`settle`, with a bid, the winner already holds a token (token 1)](https://sepolia.etherscan.io/tx/0xb467df2fa0eae46bcb4cdc698cf1c66ece2aacb67e1b02987c99d4fa8df90958) | 159,831 | 122,631 | 1.30 | 0 | [159,843](https://sepolia.etherscan.io/tx/0x67bca628e9a96e267de998d7bf32b1825836b6e17bc665e158e3f61b94c44684) | 400,000 test ceiling | pass |
| [`settle`, no bid: the token goes to the artist (token 7)](https://sepolia.etherscan.io/tx/0x5dca7e59cc366e7b89aaa8e6a98d2a640c065dd7baece0e72368684599c0bade) | 335,817 | 135,577 | 2.48 | 2 | [335,817](https://sepolia.etherscan.io/tx/0xe922c1ecb573802748322c7a351b42321b371955851697a1c2141d3a1901576f) | 400,000 test ceiling | pass |
| [`settle`, no bid, the artist already holds a token (token 2)](https://sepolia.etherscan.io/tx/0xa5785bcf95c8c07cf9ee80b364a57fa746dc3d5b93f6d84e9ce05eee61f7bee5) | 237,897 | 118,477 | 2.01 | 1 | [237,897](https://sepolia.etherscan.io/tx/0x0c2da02d826d122c93b4aa186f1d322a799522d7bea1d8b9eb93528d194c84f0) | 400,000 test ceiling | pass |
| [`settle`, no bid, a VRF work (token 8)](https://sepolia.etherscan.io/tx/0x9f729a0478193949bc776bdbe9ca469b15500f8f74456cde3d22ea5cb6231305) | 226,281 | 113,677 | 1.99 | 1 | [226,281](https://sepolia.etherscan.io/tx/0x9b9f7d89595c0bfdf62028ac1b6985c5d7384fbc3ae71dcce2c9c3957086bce6) | 400,000 test ceiling | pass |

- **Steady state.** The `start` rows from the second work on are all steady state:
  - the first start writes the custody balance, the fee recipient and the sale terms;
  - the artist's acceptance pre-writes the move-nonce word;
  - a new collection's counter word is written by `createCollection`, so a new
    collection's first start costs the same as any other.
- **The artist's first acceptance.**
  - On r1 it registered an artist with no consolidation: 8 new slots.
  - On r2 the artist had already consolidated wallet 2 (during r1, on the shared
    delegation contract). Registration's own refresh recorded that wallet: 10 new slots,
    8 of them in the artist registry. Most of the 263K difference is that entry, not #44.
- **The anti-snipe bid** stays simulated. It ran 5 minutes before token 1's end, on both
  instances, and moved the end to 15 minutes after the bid: on r1, from 1,791,834,852 to
  1,791,835,452. The scheduled run that was to place a real one did not fire, and every
  auction had ended by 13 October.
- **The settlement order** was 6, 4, 1, 7, 2, 3, 5, 8, so token 6 carries the first
  payout. Tokens 3 and 5 cost the same as token 2:
  - r2: token 3 [237,897](https://sepolia.etherscan.io/tx/0x1ffbea91e4be60e7de40503132651568ebbe5ef0b14f77e2a8d0a5012565f961), token 5 [237,897](https://sepolia.etherscan.io/tx/0x234d65c6662dfecc4f9db6b6e608dbd6d5ff2758074c2abd0968283fcd5ca77b);
  - r1: token 3 [237,897](https://sepolia.etherscan.io/tx/0x3914938bd05fa922b552b2b12534412c8340f87a2e126c8b579100e39e5fe16e), token 5 [237,897](https://sepolia.etherscan.io/tx/0x7515aaeea831356e51bc6e359e63297abf5c8b9b45c15bef1c29c88cf848ca29).

  Every receipt is in the state files.
- **Each receipt matches its own instance's simulation.** r1 and r2 differ by a few gas
  in places, for example `settle` of token 1: 159,843 on r1 against 159,831 on r2, with
  Prague 122,643 against 122,631. Each instance's receipt equals its own simulation.
- **The first `settle` with a bid** pays the seller. The seller is the payee
  configuration's split wallet, at its predicted address, which is still empty. Sending
  ETH to an empty account creates it, and that costs about 184,000 gas more on Sepolia.
  This happens once per payee configuration.

## 3. 6529 Editions

`createEdition` needs the master's sale to be settled. On 13 October, after master
token 6 settled on each instance:
- the edition was created;
- the PLATFORM opened a fixed-price sale with one public phase;
- buyers bought copies at the package price.

Every row equals the figure simulated on 11 October.

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots (r2) | r1 Sepolia | r1 Prague |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [`createEdition`](https://sepolia.etherscan.io/tx/0x80ac7a621e081c0625b361a5e2f767321c1e217a34c0df7fa4ce3baa903a720a) | 1,118,699 | 323,819 | 3.45 | 9 | [1,133,867](https://sepolia.etherscan.io/tx/0x25cf2e44e34dcad4335226395ab8355be00c3a076fb8982b07df7d95729520ff) | 338,987 |
| [`openSale` (PLATFORM, one public phase, no artist consent)](https://sepolia.etherscan.io/tx/0x3238c1dc02f64a1c1043a6fe9cc58a432f7d66db8c60e37bf046220dfd1ee158) | 993,668 | 286,608 | 3.47 | 8 | [993,668](https://sepolia.etherscan.io/tx/0xd2f342a8c0466ea5397b35602dd365ee8f450017ddcd743fd4c69a38d26bdaf9) | 286,608 |
| [`purchase`: mints the first copy (new holder)](https://sepolia.etherscan.io/tx/0x6db2f3c207441d337d55c35a3e6f6ba9e2a1e2e188c5b2e71d0eb4323bbe6f48) | 468,086 | 196,926 | 2.38 | 3 | [476,183](https://sepolia.etherscan.io/tx/0x7ee16bd7a47af85fa0afde47903879239c7b9abf3c326e5c303210a6a8bd66ae) | 204,623 |
| [`purchase`: a later copy (new holder)](https://sepolia.etherscan.io/tx/0xfad32b96ca695baf80f7723281e78cd7d8b1b4b04aabe0916507a41ae0bad4f4) | 370,142 | 179,802 | 2.06 | 2 | [378,239](https://sepolia.etherscan.io/tx/0x3045c553a49d94051ef0883f15e2aea85363ebfdfabe7314ff99d912fc870c6b) | 187,499 |
| [`purchase`: two copies (existing holder)](https://sepolia.etherscan.io/tx/0x5c9509b5edb5578e65b29915acf76d4be5513acde5bd98581174e9adac02e5cf) | 174,326 | 145,626 | 1.20 | 0 | [182,423](https://sepolia.etherscan.io/tx/0x7f69a3fafd7422c1e41a040fa8f80ce47ec975e7bcbd33895775ed037f58616a) | 153,323 |

- **What #41 changed.** It saved 15,168 gas on `createEdition` and 8,097 per purchase.
  The Prague savings are about the same: 15,168 and 7,697. #41 cut execution, not new
  slots.
- **Where the new slots are on r2.**
  - `createEdition` writes 8 new slots in Editions and 1 in the package registry.
  - `openSale` writes 8 in the fixed-price sale.
- **Budgets.** Neither ADR 0001 nor ADR 0003 sets a budget for these operations.
- **The repo's Prague figures.** The Editions gas report (`EditionsGasReport.t.sol` on
  `main`) gives:
  - `createEdition`: 322,317, against the r2 Prague replay of 323,819;
  - the mint itself: 103,761 for the first copy and 84,149 for a later one, without the
    sale adapter around it.

## 4. `tokenURI` and other views

Each row is the gas the call uses as a transaction: r2 at block 11,894,232, r1 at
block 11,893,969.

| Call | r2 Sepolia | r2 Prague | r1 Sepolia | Output |
| --- | ---: | ---: | ---: | ---: |
| `tokenURI(1)`: 1,024 bytes of attested base64, inlined | 311,148 | 311,748 | 311,784 | 1,824 bytes |
| `tokenURI(2)`: 8,192 bytes, inlined | 330,177 | 330,777 | 330,815 | 8,992 bytes |
| `tokenURI(5)`: 24,572 bytes, inlined | 390,061 | 390,661 | 390,705 | 25,376 bytes |
| `tokenURI(3)`: record open, media registered only | 294,527 | 296,227 | 295,157 | 768 bytes |
| `tokenURI(4)`: record not open (core-only metadata) | 117,914 | 121,714 | 119,172 | 384 bytes |
| `tokenURI(8)`: VRF work, record not open, seed shown | 154,482 | 157,682 | 155,746 | 480 bytes |
| `royaltyInfo(1, 1 ETH)` | 40,667 | 46,267 | 40,667 | |

- **Reads are not repriced.** Each row is within about 3% of Prague, a few hundred to a few
  thousand gas lower. The 8M `tokenURI` budget passes.
  - These rows reach 0.39M.
  - The repo's matrix (2.69M for 256 KiB of base64) and the renderer's 7.8M worst case
    are views too. They carry over unchanged.
- **Estimates are higher than use.** `eth_estimateGas` returns about 1.0M for each
  inlined `tokenURI` (measured on r1, on both rule sets). The renderer's bounded reads
  require `gasleft()` to cover their caps (300,000 and 700,000 gas) before they call. A
  caller must therefore supply about 1M even though the call uses about 0.3M. This is by
  design, and it is well within what `eth_call` allows.

## 5. Identity

- **On r1:** the artist and wallet 2 registered a use-case-999 consolidation of each
  other on the real 6529 delegation contract, then anyone called `refreshStanding`.
- **On r2:** the delegation contract is shared, so wallet 2 was already consolidated
  when the artist registered, and registration recorded it. To measure a refresh that
  records something, the artist and a third wallet consolidated after r2's registration.

Every registration used all collections (`0x8888…8888`) with `allTokens` set.

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots (r2) | r1 Sepolia |
| --- | ---: | ---: | ---: | ---: | ---: |
| [`registerDelegationAddress`, artist to the new wallet](https://sepolia.etherscan.io/tx/0xf093e53c9a80a916f21adc4b6f73c3039c21a93eb22c9019740495755f0fbfda) | 1,037,027 | 243,947 | 4.25 | 9 | [1,134,947](https://sepolia.etherscan.io/tx/0xfc78300958f918120e84cde2321b01010e9e9ac2d82405e7df5e657a1de6c8da) |
| [`registerDelegationAddress`, the new wallet to the artist](https://sepolia.etherscan.io/tx/0xaa6bfb38c66027412b6feabc26b4c77cab291a960c4dac85b12faa465b29f09a) | 1,037,027 | 243,947 | 4.25 | not counted; same gas as the row above | [1,134,947](https://sepolia.etherscan.io/tx/0x19956e6f633c3b217644f258f0dafcb835a77d194f07b861a49713daaa5218f6) |
| [`refreshStanding`: records the new wallet as pending](https://sepolia.etherscan.io/tx/0xf0247dd9ba2d33bac4d2d942cabe92c0fa087c4abc24612c1db1d10b39b64edf) | 247,970 | 157,250 | 1.58 | 1 | [299,112](https://sepolia.etherscan.io/tx/0xdf1b2f11489fe98bd84147e0303171293d5efee24f932a1e15a65dbeeaa8dd7e) |
| [`refreshStanding`: nothing changed](https://sepolia.etherscan.io/tx/0xc1277927beca0017659ee636800d82cb2ff34e099964609a63d2e18ebec8d3f3) | 128,785 | 117,484 | 1.10 | 0 | [81,853](https://sepolia.etherscan.io/tx/0x931fc2d32ac8a7ce1bd4ffcaf691368bcaef0c237166672fb4e66a35aeb79da3) |

- **The rows are not like for like across instances.**
  - On r2 the recording refresh adds a second entry to an existing snapshot: 1 new slot.
  - On r1 it wrote the first entry: 2 new slots.
  - r2's refresh with nothing new walks two consolidations, where r1's walked one.
- **The recorded entries.** r2's `standingOf` lists wallet 2 (`effectiveAt`
  1,794,340,656) and the third wallet (`effectiveAt` 1,794,343,728, 10 November 2026). Each
  is its registration time plus 30 days.
- **Stipends.** The adapter's 50,000-gas stipend per delegation-contract getter was
  enough on both instances: reads are not repriced.
- **Who pays.** ADR 0003 has artists pay for their own refreshes. A consolidation now
  costs about 1.0M to 1.1M gas per direction on the delegation contract, outside this
  protocol.

## 6. VRF

Each instance has its own subscription and entropy module. Both seeds arrived from the
real Chainlink coordinator five blocks after the request.

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots (r2) | r1 Sepolia |
| --- | ---: | ---: | ---: | ---: | ---: |
| [`requestSeed`](https://sepolia.etherscan.io/tx/0x51171a74494953580e7973bb8d57f19c2993d5deb20ced83e4dfadf2c8119e41) | 525,029 | 171,149 | 3.07 | 4 | [525,029](https://sepolia.etherscan.io/tx/0xaf97ba7d6a6db9ce5e6eaa70dc3b0208aea5b9a07a8e42bdd54748b6d5c361a9) |
| [Chainlink's fulfilment](https://sepolia.etherscan.io/tx/0x0d73152d9de8c595a523ae3efd4d358b77e883c9529c829be6e3b8060537aee6) | 241,232 | 124,230 | 1.94 | | [246,799](https://sepolia.etherscan.io/tx/0xfdcfb71aa8726295857b4eebe366b57fa0a6469d58ef4ad943932ff97b0922d1) |
| [`start` of the VRF work](https://sepolia.etherscan.io/tx/0xd4a7d292986764fde5e06967e324a2722840ef4538af0df5f9121377d722572c) | 852,868 | 298,748 | 2.85 | 6 | [852,856](https://sepolia.etherscan.io/tx/0x1ea28624bdf5fc9482bd2ceda19cbcb5a18a4ebc27271a69e559545537b87cc1) |

**Callback gas** (measured on r1). The callback writes one new slot. Under Prague its
frame used 34,213 gas. Simulated on the block before the fulfilment, the callback on its
own cost 145,701 gas on Sepolia and 56,581 on Prague. The callback therefore used about
123,000 of its 200,000 limit, or 62%. It fits, with about 77,000 to spare.

## 7. Records and transfers

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots (r2) | r1 Sepolia |
| --- | ---: | ---: | ---: | ---: | ---: |
| [`openRecord`](https://sepolia.etherscan.io/tx/0x7a9d11dbe76068d415a69c3c168d101f68120346483407d5f510e776d30c0cdb) | 505,752 | 159,172 | 3.18 | 4 | [505,752](https://sepolia.etherscan.io/tx/0xf9370976e664990715e9542db9e21a20766e4fb331629d0eb0ff399546b728ef) |
| [`syncOnChain`](https://sepolia.etherscan.io/tx/0xdc3dffa1b07f33625fdd30fcae3f89cc4850e694c58bb88f9af4d8f28c5e01ea) | 58,821 | 56,121 | 1.05 | 0 | [58,821](https://sepolia.etherscan.io/tx/0x67ccfad8934453687681896de637b3ac44079481af07b5cfe061ce088599678f) |
| [ETH transfer to an empty account](https://sepolia.etherscan.io/tx/0x2a17f820226306402ae407d79f08e49c63e5adfcb974772888b1eda0ec5236f4) | 204,600 | 21,000 | 9.74 | an account | [204,600](https://sepolia.etherscan.io/tx/0xb9a7e27a0878f34f7e37a5926d7b388d48e9c57c012786e056b421fa8073545a) |
| ETH transfer to an existing account (not sent on r2) | | | | | [21,000](https://sepolia.etherscan.io/tx/0x8bcda1443b73fbbf7fdc4a5953375afa4d66215468c055cbe9d258336922b7f7) |

## Budgets under Glamsterdam (r2)

| Budget | Where | r2 Sepolia | Result |
| --- | --- | --- | --- |
| `start` ≤ 350K at steady state, one artist | ADR 0003 (CI gate), AGENTS.md | 846,963 | **breaks (2.4 times over)** |
| `startWithBid` ≤ 350K at steady state, one artist | ADR 0003 | 982,312 | **breaks (2.8 times over)** |
| `start` ≤ 300K | ADR 0001 (superseded by ADR 0003) | 846,963 | breaks |
| First start in a new collection ≤ 400K | `GasReport.t.sol` ceiling | 846,977 | **breaks** |
| `settle` ≤ 400K | `GasReport.t.sol` ceiling | 441,363 for the first payout to a new seller; 160K to 336K otherwise | **breaks once per payee configuration** |
| `tokenURI` ≤ 8M | ADR 0001, ADR 0003, AGENTS.md | at most 0.39M measured; views are not repriced | holds |
| `royaltyInfo`: one external view, about 25K | ADR 0003 | 40,667 for the whole call | holds |
| Every transaction ≤ 16,777,216 gas for worst-case bounded inputs | AGENTS.md, ADR 0003, content README | Sepolia accepts transactions above the cap for state gas. One full chunk is about 38.4M and a 256-chunk manifest 28.8M; a 512-chunk manifest is about 57.6M | **no longer holds as written** |
| Two full chunks per Multicall3 transaction, at about two thirds of the cap | content README | about 76.7M | **guidance obsolete** |
| Upload cost about 0.23 ETH per MB per gwei | content README | about 1.65 ETH per MiB per gwei | **changes about 7 times** |
| `registerManifest` for 1 MB about 1.05M | content README | 5.27M (r1) | **changes** |
| VRF callback gas limit 200,000 | genesis (ADR 0003 entropy) | about 123,000 used (r1) | holds, 62% used |
| Delegation-contract getters within a 50,000-gas stipend | identity README | `refreshStanding` succeeds; reads not repriced | holds |
| A federated factory deploy at about 4–5M gas per contract | ADR 0001 §16 (v1.1) | not measured; both deployments' creations cost 6.0 to 6.6 times their Prague gas | likely about 25–30M |

## Where the gas goes (r2)

A steady-state `start` writes six new slots:
- Stream, four:
  - the three words of the token record (`TokenData`: seller, serial and flags; the
    artist ID and economics; the item hash);
  - the ERC-721 owner.
- PackageRegistry, one: the consumed-content record, which is also the uniqueness
  record.
- EnglishAuction, one: the sale.

Each new slot costs about 89,000 more than on Prague, so the six cost about 533,000 of
the 553,720 difference. The other rows follow the same rule: the new-slot column
explains most of each ratio. Two examples:
- `createEdition` writes 9 new slots, 8 of them in the Editions record;
- `openSale` writes 8 in the fixed-price listing and its phase.

**350K cannot be reached by a start that mints.**
- A mint needs at least an owner word, a consumed-content record and a sale record.
- At about 111,000 per new slot, those three alone are about 333K before any
  execution.

## Recommendation

1. **Amend the budgets for Glamsterdam rather than chase 350K.**
   - Split the gate in two:
     - execution gas measured on Prague, which Foundry can measure, with 350K kept
       for `start` and `startWithBid`;
     - a cap on new storage slots per operation, counted in the gas-report tests from
       the state diff. For example, at most 6 for a steady-state `start` and 7 for
       `startWithBid`.
   - Publish the Glamsterdam totals next to them: about 850K and 985K.
   - Foundry 1.7.1 cannot simulate Amsterdam. A slot count is the part of the
     Glamsterdam cost that CI can still enforce.
2. **Optional design work to cut new slots. Each slot saved is about 89K.**
   - **Stream** writes four words per token. Its economics fields (royalty rate, fee
     share, fee recipient, minter) could become a deduplicated terms ID, the way the
     auction already stores its terms. The ERC-721 owner could then share a word with
     what remains. Four words down to three would bring a steady-state `start` to about
     760K.
   - **The Editions record (8 words) and the fixed-price listing (8 words)** are the
     next largest. Packing each to half would save about 350K per `createEdition` and
     per `openSale`.
   - Every other mint-path record (consumed content, the sale) is essential.
3. **Re-word the transaction-cap rule.**
   - "Fits 16,777,216 gas" no longer limits state-heavy transactions on Glamsterdam.
     Only their non-state gas is capped.
   - Worst-case content calls are far above the cap: a full chunk, or a manifest near
     512 chunks. A public RPC that caps `eth_estimateGas` at 50M cannot estimate a
     manifest above about 440 chunks.
   - Decide whether `MAX_CHUNKS` stays at 512, and restate the rule for regular gas.
4. **Re-price the storage guidance for artists.**
   - At about 1.65 ETH per MiB per gwei, the ≤1 MB default on-chain copy is about 7
     times dearer than the README says.
   - The Multicall3 batching advice is obsolete: one chunk is already 38M.
5. **Re-check the VRF callback limit before mainnet.** It is 62% used. A raise is a
   PARAMETER_SETTER operation (48 hours), raise-only.

No contract bug was found on either instance. Every call behaved as its tests describe.
Two behaviors are worth knowing:
- the first payout to a predicted split-wallet address creates that account;
- `tokenURI` needs about 1M gas supplied for about 0.3M used.

## Pending

**Done on 13 October.** The settlement and edition sequences ran on both instances,
from the driver with the committed state files, [`flows/r2.json`](flows/r2.json) and
[`flows/r1.json`](flows/r1.json). Each state file holds its run's addresses, receipts
and Prague replays. In `r2.json`, the content rows sent by the second relayer say
`relay2`.

**Anti-snipe.** A real anti-snipe bid needs a bid in the last 15 minutes of a live
auction, and every auction in this package has ended. The simulated row stands. A real
one needs a new 24-hour auction, and someone present in its last 15 minutes to run:

```powershell
Flow @r2 -Step bid -TokenId <id> -Bidder bidder1 -Amount <at least the minimum bid> -Label bid-antisnipe
```

`Flow` is a helper that runs `script/sepolia/flows.ps1` with the operator's signer
module, and `@r2` passes r2's state file and record (r3 is the driver's default since the r3
run):

```powershell
function Flow {
    powershell -NoProfile -ExecutionPolicy Bypass -File script/sepolia/flows.ps1 `
        -SignerModule '<module>' @args
    if ($LASTEXITCODE -ne 0) { throw "flow step failed ($LASTEXITCODE)" }
}
$r2 = @('-State', 'deployments/11155111/flows/r2.json', '-Record', 'deployments/11155111/1791750816.json')
$r1 = @('-State', 'deployments/11155111/flows/r1.json', '-Record', 'deployments/11155111/1791746472.json')
```

**Needs a scheduled operation (not done).**
- **A shorter auction.** `EnglishAuction.setConfig` is PARAMETER_SETTER (48 hours).
  PLATFORM cannot shorten an auction.
- **A higher VRF callback limit.** `VrfEntropyModule.setConfig` is PARAMETER_SETTER.
- **The UNPAUSER, upheld-dispute `cancel`, relicense, re-rate, repin, override and
  TDH-vote paths.** Each is delayed 48 hours to 30 days, or needs a Safe.

**Not run in this pass.**
- the Dutch sale;
- Permit2 and ERC-20 payments;
- `finalize`;
- a STANDARD identity change (it needs a 7-day wait);
- the guardian `pause` and `cancel` (Safe operations).
