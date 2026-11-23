# Sepolia r6: the flows on the plain core (23 November 2026)

On 23 November 2026 the flows below ran on **r6**
([README](README.md#sepolia-r6-23-november-2026-current)), the first Sepolia rehearsal of the
plain permanent core ([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)), `main` at
`2aac8579`, record [`core-1795412520.json`](core-1795412520.json). Earlier rounds are in
[flows.md](flows.md); their contracts are an earlier design.

This is a testnet rehearsal with throwaway keys, and the code is pre-audit. The figures are
Sepolia receipts: Sepolia reprices state creation (Glamsterdam), so they are not the Prague
figures the gas budgets are written in. The last table gives both: the Sepolia receipt and
the same transaction replayed on its parent block's state at Prague prices
(`flows.ps1 -Step prague`, which runs `cast run --quick --evm-version prague`). The starts
here are first starts (a new collection, the artist's first works), which
[ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md) measures apart from its
steady-state rows.

Every transaction was planned by [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol)
against the live chain and sent by [`script/sepolia/flows.ps1`](../../script/sepolia/flows.ps1)
with `cast send`; the state file is [`flows/r6.json`](flows/r6.json). Accounts: `any` is the
keeper key (no role), `platform`, `curator`, `artist` and the four bidders are r5's throwaway
keys, and calls of the network go through its Safe with two owner signatures.

## What ran

**Genesis.** The network Safe accepted ([`0x8429ff17…`](https://sepolia.etherscan.io/tx/0x8429ff17229bb9b8f8392e9730fa67daa1a12a9a695bba3a947e95c732be2f22)); the deployer added r6's entropy
module to the VRF subscription ([`0x8b3d8ccd…`](https://sepolia.etherscan.io/tx/0x8b3d8ccd85dc65098de20b7915c001f5c412e3343e373343e79ac592f8aa3b30)).

**Content, collections, package.** 36 uploads to `ContentStore` (three base64 files of 1,024,
8,192 and 24,572 stored bytes with their attestations, ten records, seven registered-only
media manifests); the platform key created two collections; the package of ten works was
registered with curation signer 1's approval ([`0xd9f2e4b4…`](https://sepolia.etherscan.io/tx/0xd9f2e4b4c79ececb2a23126f5abc469d4eacd063cce8824782a4280f724208a9)), the curator appended
the evidence statement ([`0x1ae75d34…`](https://sepolia.etherscan.io/tx/0x1ae75d34ce6c428686eee33c2e7b5cef3773a1d6a99dfb309248e975513138b9)) and the artist accepted, which created its
account ([`0xfa7b2512…`](https://sepolia.etherscan.io/tx/0xfa7b2512ea4d37a88db88ce53eb17f9c6068ecb0d70246dc178afe47308db2c2)).

**A curated 1/1 (token 1).** Bidder 1 started the auction with a 0.05 ETH bid
([`0xb8298fb4…`](https://sepolia.etherscan.io/tx/0xb8298fb46e6520496b693c5b11961548e3d02ca8e5ae797e3ccbc1e5c5596c1e)); bidder 2 outbid it at 0.0525 ETH ([`0xe56334a7…`](https://sepolia.etherscan.io/tx/0xe56334a73e7082180454735f5278e066b107281f8144bd68021723141b1d164b)), which
credited bidder 1's 0.05 ETH, and bidder 1 claimed the refund ([`0x0fca05dd…`](https://sepolia.etherscan.io/tx/0x0fca05ddc08b15f14db7e169c988e5d717e78b2a2297b88115dfd39f091512d0)). The
record was opened in `StreamWorkFacts6529` ([`0x667f6f7f…`](https://sepolia.etherscan.io/tx/0x667f6f7f07a333ee76b8847763d24e1e72c69ca83a054eeb8b3227bbd875c1f8)). After the hour the keeper
settled it ([`0xa30f5526…`](https://sepolia.etherscan.io/tx/0xa30f5526766bc1b5c13c7381f300d5f9da6a6b75639106c8f1acded78d161d25)): `ownerOf(1)` is bidder 2. Anyone marked its media complete on
chain ([`0xaec9a5b0…`](https://sepolia.etherscan.io/tx/0xaec9a5b0e5dc36685d5dd3e5ebad644087e58a96e30f6399aa815336fc453db5)) and the artist finalized the record
([`0x3879969a…`](https://sepolia.etherscan.io/tx/0x3879969a77562efb922407e0c028fcafdc28cb7e9a5bae56b04b1599fd5acc13)), which pinned the genesis renderer. `tokenURI(1)` then answered
1,734 bytes: a `data:application/json;utf8` document that names the work, its
content hash and licence and carries the stored image inline as base64.

**An edition master with its edition auction (token 2).** The keeper started it through
`SaleStarter` (auction, seller and royalty vaults and record in one transaction,
[`0x897f2a38…`](https://sepolia.etherscan.io/tx/0x897f2a38a6b1a875c9559818997fead8290f739a3a9dec3ba66fdafebee921f5)); bidder 3 bid 0.05 ETH on the 1/1 ([`0xee1dfc8c…`](https://sepolia.etherscan.io/tx/0xee1dfc8c1e294c047911ab25e3d40dc3f2bc222120229453b68c9fa90fe7ceee)); the keeper opened the
uniform-price edition auction beside it ([`0x71fc4045…`](https://sepolia.etherscan.io/tx/0x71fc4045b554ea0375536accd075748eed6d6b25786f5ce509b14a2f484caf38)). Three edition bids followed:
bidder 1, 2 copies at step 20; bidder 4, 3 copies at step 25; bidder 2, 1 copy at step 10. The
1/1 settled to bidder 3 ([`0x6d80189e…`](https://sepolia.etherscan.io/tx/0x6d80189e47c215fea3f5da984562a81ec7b38c3330f8ecac9642ef7d061a8629)), and after the edition's close the keeper settled the
edition ([`0x93837520…`](https://sepolia.etherscan.io/tx/0x938375207eb2ecac6ab64fc59ffc3fae26ab15dca89f08e2f6ea806d4b0b9e6e)): 5 copies cleared at step 20, 0.000261 ETH each (0.001305 ETH in all). Each bidder then claimed
([`0x52811889…`](https://sepolia.etherscan.io/tx/0x528118890df172dc4a7a3b219a29788637371ef18a9ab72e627ea01acb5dc2a6), [`0xae1fdff3…`](https://sepolia.etherscan.io/tx/0xae1fdff34ca54df333ef27bfde9088c49c9325675c6fd3bdc0b70b0498d7d17e), [`0x243a2ced…`](https://sepolia.etherscan.io/tx/0x243a2ced1ac2af4dad2e54798fae25eff520de63766cf95218eee311b4a5159c)): bidder 1 received 2 copies, bidder 4 received 3 copies and a refund of 0.000213 ETH (its step-25 escrow less the clearing price), and bidder 2, below the clearing step, received its whole 0.000162 ETH back and no copy.

**A VRF-seeded work (token 3).** `requestSeed` for the VRF item ([`0x7896c90f…`](https://sepolia.etherscan.io/tx/0x7896c90fcb2e8da3fef347ef33b65251fe85451a1c7a3816f76d3a8ae89bb251)) was
fulfilled by the Chainlink node four blocks later ([`0x3f02efaa…`](https://sepolia.etherscan.io/tx/0x3f02efaaac545f4d095bf176b4788861dcbd300323e41e66a8815c20224418c4)); bidder 1 then
started the work with a bid ([`0xfdd6aeb5…`](https://sepolia.etherscan.io/tx/0xfdd6aeb53b84155097b66d397f29b02c00b20cc47b3dbb57b72f5599a2f54cc5)), and the keeper settled it after the hour
([`0xc2be041e…`](https://sepolia.etherscan.io/tx/0xc2be041ec9fe977bfc6073586ec6a939d9154533a3769855f5053be28d5015ed)). The token stores the delivered seed: `workOf(3).seed` is `0xd5b4a023…1e02`, the value in the module's `SeedDelivered` log.

**An Independent Stream collection.** After the work's two files were stored, the artist key
deployed its own 1/1 contract from the approved template
([`0xFc8BA4f8A0E40A977A6eB746F0E313E6eD07013C`](https://sepolia.etherscan.io/address/0xFc8BA4f8A0E40A977A6eB746F0E313E6eD07013C), [`0x999ffe28…`](https://sepolia.etherscan.io/tx/0x999ffe28a5590475beff3ffe0d23c7a30abeea4606441ed2b17e472cf7f642a8),
22,953,329 gas on Sepolia), listed it in the Independent Stream module with one consent
signature ([`0x406f947b…`](https://sepolia.etherscan.io/tx/0x406f947bad4d8358eedbb2788da2b13320090d0ee6bc961e5558288fc7aab739)) and approved one work at a 5% royalty
([`0xadf7111b…`](https://sepolia.etherscan.io/tx/0xadf7111b20407064711f7d23a876360bd7c0924a135c5e290017d90b8da2cd3e)). Bidder 4 started its sale on the shared English auction with
a 0.05 ETH bid ([`0xd867f892…`](https://sepolia.etherscan.io/tx/0xd867f892068eea2def80c45c0976c66918b9ec44d0d501634409406805ec8cbd)); the keeper settled it after the hour
([`0x181c6e4b…`](https://sepolia.etherscan.io/tx/0x181c6e4b1d3f73a08d4ccfd96d335734cbdb757b3ff161336bea98c569dae7b7)), and the token's `ownerOf(1)` is bidder 4. Its record was opened
([`0xd44c5f77…`](https://sepolia.etherscan.io/tx/0xd44c5f774f134e62f529bb3635e2ad0489562e376cd6225df21df6003e927163)), its media marked complete on chain
([`0x7519132f…`](https://sepolia.etherscan.io/tx/0x7519132fad0ef95e5aa5254b27dd7034b6e42da43ce556274c851f1e63c13781)) and the record finalized by the artist
([`0x45290989…`](https://sepolia.etherscan.io/tx/0x4529098965e873ca7a12ca62372446b476b4ddc54864e6c6c6bfed03802ff165)); its `tokenURI(1)` answered 781 bytes, with the
SVG inline.

**A renderer proposal.** The keeper deployed a second instance of the renderer
([`0xf88a87cc…`](https://sepolia.etherscan.io/tx/0xf88a87cc1125d38fa1b1cc8c89c45ae9dc25c1b7030ac158903114951add1543), 37,411,462 gas) and the network Safe announced it for `Stream6529`'s
`RENDERER` slot ([`0x4303443b…`](https://sepolia.etherscan.io/tx/0x4303443b573fe5be40257338c12095972752b4ada73a5ea6244378edc0fa63d7)). It is ready on 30 November 2026 at 06:18:12
UTC (`moduleDelay`, 7 days) and was not activated; the slot still holds the genesis renderer.

**Payouts.** The artist released its share of the seller vault ([`0xbaf0605f…`](https://sepolia.etherscan.io/tx/0xbaf0605fdd851c503327daa8628d09639d2beafef9d1bf786aba6e4ff8aa1663)): 0.121875 ETH, the three sales settled by then (0.0525, 0.05 and 0.05 ETH) less the network fee. The network fee vault forwarded its 0.030625 ETH to the network Safe ([`0xa85b266d…`](https://sepolia.etherscan.io/tx/0xa85b266dbcea1bacfa445c99e5304d71ae4a5b59cc6580a849b1f28cf59d5ee1)). The proceeds of token 3 and of the edition sale, settled afterwards, are still in their vaults.

## Not run on r6

The dispute pause and cancel, the cut step and per-settler sweep of a capped edition, a
consolidated wallet's move signature, the anti-snipe extension, `expireCredit` and `forfeit`
(180 days), a module activation (7 days), `rescue` and `rebind` (14 days), an Independent
Stream edition sale, and the reference keeper sending transactions on r6.

## Every transaction

| # | Step | From | Block | Gas on Sepolia | Prague replay | Transaction |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| 1 | `acceptNetwork` | any | 12,193,760 | 174,102 | 83,698 | [`0x8429ff17…`](https://sepolia.etherscan.io/tx/0x8429ff17229bb9b8f8392e9730fa67daa1a12a9a695bba3a947e95c732be2f22) |
| 2 | `vrf-addConsumer` | deployer | 12,193,762 | 255,326 | 78,086 | [`0x8b3d8ccd…`](https://sepolia.etherscan.io/tx/0x8b3d8ccd85dc65098de20b7915c001f5c412e3343e373343e79ac592f8aa3b30) |
| 3 | `writeChunk-b64-1024` | any | 12,193,769 | 1,911,018 | 301,850 | [`0x280f9eda…`](https://sepolia.etherscan.io/tx/0x280f9edaa74796c11db976a19c99df77252679b0fe9c6a15ea17976cf65dd249) |
| 4 | `registerManifest-b64-1024` | any | 12,193,770 | 579,348 | 145,448 | [`0x0ff99eb3…`](https://sepolia.etherscan.io/tx/0x0ff99eb37b8f792763f04f4482d5a99f41ff876a9640a4284b3b7f838a17c9bd) |
| 5 | `attestBase64-1024` | any | 12,193,771 | 154,216 | 71,196 | [`0x2c41664b…`](https://sepolia.etherscan.io/tx/0x2c41664bde6f706a3572442137ed600eff2ff178507b301a13888bb85b2b6441) |
| 6 | `writeChunk-b64-8192` | any | 12,193,772 | 13,003,921 | 1,859,969 | [`0x0c9a0cea…`](https://sepolia.etherscan.io/tx/0x0c9a0ceac29db6e1192f638e305baea7d2ee58276b6cf2272c747773de979832) |
| 7 | `registerManifest-b64-8192` | any | 12,193,773 | 579,348 | 145,448 | [`0xdc664cc9…`](https://sepolia.etherscan.io/tx/0xdc664cc9cb2520f78f1fd6bfb258a8e546db419825380c1f0dccc1fe1a88d03a) |
| 8 | `attestBase64-8192` | any | 12,193,774 | 206,341 | 123,321 | [`0x6f704a24…`](https://sepolia.etherscan.io/tx/0x6f704a2490afcf52d70d870ef4d9cf3587f19cff11f1824046272da4a2cd7bef) |
| 9 | `writeChunk-b64-24572` | any | 12,193,775 | 38,356,636 | 5,424,218 | [`0xcdd183cc…`](https://sepolia.etherscan.io/tx/0xcdd183cc5e6544a9e0d82ae11885a7d6bcdde7a6af74331ca76fa210696342b4) |
| 10 | `registerManifest-b64-24572` | any | 12,193,776 | 579,360 | 145,460 | [`0xd2b9d628…`](https://sepolia.etherscan.io/tx/0xd2b9d628ae149f7e517eedf8b964b167768e0801a2e682cebe63c437cd41d9c2) |
| 11 | `attestBase64-24572` | any | 12,193,777 | 326,265 | 243,245 | [`0x72eb1e8a…`](https://sepolia.etherscan.io/tx/0x72eb1e8ab69991e664685aa7d61a76e63769405de25e3b078553bd9ebf73d79b) |
| 12 | `writeChunk-record-0` | any | 12,193,778 | 621,958 | 120,842 | [`0x924497bd…`](https://sepolia.etherscan.io/tx/0x924497bd7da92f7296aee5ff82355e4ab8a2095d15a886d88b342668199d5eef) |
| 13 | `registerManifest-record-0` | any | 12,193,779 | 581,870 | 147,970 | [`0xd0c8f232…`](https://sepolia.etherscan.io/tx/0xd0c8f232213334f1b09a906e256b24025d3765ea8265a9fb126409090c84984b) |
| 14 | `writeChunk-record-1` | any | 12,193,780 | 621,958 | 120,842 | [`0x38fbd5bb…`](https://sepolia.etherscan.io/tx/0x38fbd5bb9c20edcf34cdf0e052ade4f0687d565a3798ad5c70be484249d8b019) |
| 15 | `registerManifest-record-1` | any | 12,193,781 | 581,870 | 147,970 | [`0x2cfbc157…`](https://sepolia.etherscan.io/tx/0x2cfbc1576e2e0fae2b14ca99f53c5d6e24399b7a4f13d84ea6c4275d54b7a902) |
| 16 | `writeChunk-record-2` | any | 12,193,782 | 621,958 | 120,842 | [`0x5782a6cb…`](https://sepolia.etherscan.io/tx/0x5782a6cb220cf9087e610a1a39919202bddaf62fc4bc543ab2aa1f03b298fc38) |
| 17 | `registerManifest-record-2` | any | 12,193,783 | 581,858 | 147,958 | [`0x75176175…`](https://sepolia.etherscan.io/tx/0x75176175d821adacf4d3d8318805e386f3bf0416075a82b25cc67611277a677e) |
| 18 | `registerManifest-media-2` | any | 12,193,784 | 579,324 | 145,424 | [`0x8e06bbfc…`](https://sepolia.etherscan.io/tx/0x8e06bbfc163b9a0ed0090adf02530925952d54f65fb4a00a9b3875db8c10018e) |
| 19 | `writeChunk-record-3` | any | 12,193,785 | 621,958 | 120,842 | [`0xcd91317a…`](https://sepolia.etherscan.io/tx/0xcd91317a4c1f94ce249395353bdf33b5725c48d22f34cf926fb517981851c463) |
| 20 | `registerManifest-record-3` | any | 12,193,786 | 581,870 | 147,970 | [`0x686e13fb…`](https://sepolia.etherscan.io/tx/0x686e13fb47115c2fcd93b978172b419c47c756905a294b6f3e5f694351e5c586) |
| 21 | `registerManifest-media-3` | any | 12,193,787 | 579,336 | 145,436 | [`0x14726389…`](https://sepolia.etherscan.io/tx/0x147263894309a295951011234e6596c9bfc3ebcc77529942cc527ecc3eadb509) |
| 22 | `writeChunk-record-4` | any | 12,193,788 | 621,958 | 120,842 | [`0xf71df3dd…`](https://sepolia.etherscan.io/tx/0xf71df3ddcac2fe606d1e6f7ce31cbacb9b7bf2fb389f812ed3f2bab2a147aaba) |
| 23 | `registerManifest-record-4` | any | 12,193,789 | 581,870 | 147,970 | [`0x5234f946…`](https://sepolia.etherscan.io/tx/0x5234f946eaa6ae876b8e82af2ee20bfe24bd1caf11ecb1a216501a62162bc145) |
| 24 | `writeChunk-record-5` | any | 12,193,790 | 621,958 | 120,842 | [`0x7b54dd0f…`](https://sepolia.etherscan.io/tx/0x7b54dd0fe4d12fe644f4edfdb34938b406e7dac5991fd22ebe65f239a5a905b2) |
| 25 | `registerManifest-record-5` | any | 12,193,791 | 581,870 | 147,970 | [`0xe248c1e8…`](https://sepolia.etherscan.io/tx/0xe248c1e8c1de6e34e1fef5fef1d9d2782cb43bdf41a54930082dfd6fac4fdd11) |
| 26 | `registerManifest-media-5` | any | 12,193,792 | 579,312 | 145,412 | [`0xf5ce4f96…`](https://sepolia.etherscan.io/tx/0xf5ce4f9621d3e8999e866e83851fbffd27fd6726cdc4f661cc44c643ca99bf82) |
| 27 | `writeChunk-record-6` | any | 12,193,793 | 621,958 | 120,842 | [`0x761dec90…`](https://sepolia.etherscan.io/tx/0x761dec90581194e637505e14764b601d0f23fe49f1a88ea1ebde57123fd708f6) |
| 28 | `registerManifest-record-6` | any | 12,193,794 | 581,870 | 147,970 | [`0xb6f7970b…`](https://sepolia.etherscan.io/tx/0xb6f7970bcacb94b449d078c719d71189a4175623a9f4b639df249e9aff8d1e63) |
| 29 | `registerManifest-media-6` | any | 12,193,795 | 579,336 | 145,436 | [`0x8a90ec6f…`](https://sepolia.etherscan.io/tx/0x8a90ec6f0a5a2eb4673c79481a46825fe52df3846efec256af458002df6afd2b) |
| 30 | `writeChunk-record-7` | any | 12,193,796 | 621,958 | 120,842 | [`0x1de0108b…`](https://sepolia.etherscan.io/tx/0x1de0108b69a4dc7030ab9aa106e2f30955be51c59a67e955b89ca4fb396e150c) |
| 31 | `registerManifest-record-7` | any | 12,193,797 | 581,870 | 147,970 | [`0x59c41b95…`](https://sepolia.etherscan.io/tx/0x59c41b955272094d0cc61daf71d1e72c40e68562da35b5c75a4d1ceccd999777) |
| 32 | `registerManifest-media-7` | any | 12,193,798 | 579,336 | 145,436 | [`0x640baab6…`](https://sepolia.etherscan.io/tx/0x640baab6e5bdfe802cc550740ba68736ecdf8f8610aa452ad76c5e2f646a6e12) |
| 33 | `writeChunk-record-8` | any | 12,193,799 | 621,958 | 120,842 | [`0x5648f3a6…`](https://sepolia.etherscan.io/tx/0x5648f3a6295f4e48feff9a2ad4028febe51aaa6b0b179b4620bb63a768a59c77) |
| 34 | `registerManifest-record-8` | any | 12,193,800 | 581,870 | 147,970 | [`0x0f3d3e61…`](https://sepolia.etherscan.io/tx/0x0f3d3e61b1f131500cb51980a4990e7d09e752346be787e933369a8027e7032b) |
| 35 | `registerManifest-media-8` | any | 12,193,801 | 579,324 | 145,424 | [`0x8e46d4fa…`](https://sepolia.etherscan.io/tx/0x8e46d4fadf4ac9c41cc4a42421fd682306b8a18598699409efbd0aff32d22d95) |
| 36 | `writeChunk-record-9` | any | 12,193,802 | 621,958 | 120,842 | [`0x56d88ba0…`](https://sepolia.etherscan.io/tx/0x56d88ba091c7e0d0df525bbc8ce1a269e85e48068f91048dd671e405b0d09610) |
| 37 | `registerManifest-record-9` | any | 12,193,803 | 581,870 | 147,970 | [`0x491cec41…`](https://sepolia.etherscan.io/tx/0x491cec41ee73ec205cb22444d5d6cce1b3ae29f8f40e732a786c662c1cbe1721) |
| 38 | `registerManifest-media-9` | any | 12,193,804 | 579,336 | 145,436 | [`0x0d3b000b…`](https://sepolia.etherscan.io/tx/0x0d3b000b7a5fe1fb2a154f70c9f62f5b03e705e4a4a6e53f5d56d3b6f588af3d) |
| 39 | `createCollection-Flows` | platform | 12,193,805 | 474,912 | 128,532 | [`0xc73472d1…`](https://sepolia.etherscan.io/tx/0xc73472d13a608437ae86fed1995a7d938d18c54d921d2b55cfcffd3548db510a) |
| 40 | `createCollection-Flows-2` | platform | 12,193,806 | 377,004 | 111,444 | [`0x3a6eb279…`](https://sepolia.etherscan.io/tx/0x3a6eb279d5b24493f2011ff1ce4469636766a3e6d2ca05e31b3ec31450a8df0d) |
| 41 | `registerPackage` | any | 12,193,807 | 280,578 | 109,338 | [`0xd9f2e4b4…`](https://sepolia.etherscan.io/tx/0xd9f2e4b4c79ececb2a23126f5abc469d4eacd063cce8824782a4280f724208a9) |
| 42 | `appendCurator` | curator | 12,193,808 | 272,370 | 101,930 | [`0x1ae75d34…`](https://sepolia.etherscan.io/tx/0x1ae75d34ce6c428686eee33c2e7b5cef3773a1d6a99dfb309248e975513138b9) |
| 43 | `acceptPackage` | any | 12,193,809 | 833,772 | 221,932 | [`0xfa7b2512…`](https://sepolia.etherscan.io/tx/0xfa7b2512ea4d37a88db88ce53eb17f9c6068ecb0d70246dc178afe47308db2c2) |
| 44 | `requestSeed` | any | 12,193,815 | 646,061 | 203,761 | [`0x7896c90f…`](https://sepolia.etherscan.io/tx/0x7896c90fcb2e8da3fef347ef33b65251fe85451a1c7a3816f76d3a8ae89bb251) |
| 45 | `startWithBid-0` | bidder1 | 12,193,816 | 1,283,846 | 386,146 | [`0xb8298fb4…`](https://sepolia.etherscan.io/tx/0xb8298fb46e6520496b693c5b11961548e3d02ca8e5ae797e3ccbc1e5c5596c1e) |
| 46 | `bid-1-competing` | bidder2 | 12,193,817 | 169,824 | 74,204 | [`0xe56334a7…`](https://sepolia.etherscan.io/tx/0xe56334a73e7082180454735f5278e066b107281f8144bd68021723141b1d164b) |
| 47 | `claimCredits` | bidder1 | 12,193,818 | 32,255 | 32,018 | [`0x0fca05dd…`](https://sepolia.etherscan.io/tx/0x0fca05ddc08b15f14db7e169c988e5d717e78b2a2297b88115dfd39f091512d0) |
| 48 | `openRecord-1` | any | 12,193,819 | 728,536 | 205,816 | [`0x667f6f7f…`](https://sepolia.etherscan.io/tx/0x667f6f7f07a333ee76b8847763d24e1e72c69ca83a054eeb8b3227bbd875c1f8) |
| 49 | `saleStarter-5` | any | 12,193,821 | 2,565,947 | 715,851 | [`0x897f2a38…`](https://sepolia.etherscan.io/tx/0x897f2a38a6b1a875c9559818997fead8290f739a3a9dec3ba66fdafebee921f5) |
| 50 | `bid-2` | bidder3 | 12,193,822 | 151,715 | 63,295 | [`0xee1dfc8c…`](https://sepolia.etherscan.io/tx/0xee1dfc8c1e294c047911ab25e3d40dc3f2bc222120229453b68c9fa90fe7ceee) |
| 51 | `openEdition-2` | any | 12,193,823 | 695,393 | 258,393 | [`0x71fc4045…`](https://sepolia.etherscan.io/tx/0x71fc4045b554ea0375536accd075748eed6d6b25786f5ce509b14a2f484caf38) |
| 52 | `editionBid-2` | bidder1 | 12,193,824 | 269,367 | 86,127 | [`0x8dbebc59…`](https://sepolia.etherscan.io/tx/0x8dbebc5981808432d8f2508fee9b6ce81f44edff3b23027d95d96b4a74f73106) |
| 53 | `editionBid-2` | bidder4 | 12,193,825 | 269,420 | 86,180 | [`0xf67650b9…`](https://sepolia.etherscan.io/tx/0xf67650b92f8683ac4d4eef1342ef68198002ff5f5a36cbe979a615e2abc3bb58) |
| 54 | `editionBid-2` | bidder2 | 12,193,826 | 269,390 | 86,150 | [`0x42d46e0b…`](https://sepolia.etherscan.io/tx/0x42d46e0b68d64729766890647dd994aa644ca8b188b690e982571b779de36e7e) |
| 55 | `writeChunk-independent-media` | any | 12,193,827 | 496,695 | 103,321 | [`0x925bab7d…`](https://sepolia.etherscan.io/tx/0x925bab7d03eed77ee7f6d33d34180e5847cc4d2ef63f8c44ea3babf0c213df99) |
| 56 | `registerManifest-independent-media` | any | 12,193,828 | 580,841 | 146,941 | [`0x426b95a6…`](https://sepolia.etherscan.io/tx/0x426b95a6cf2c5c1e76976927b54dd6c2b9b41bc2c6c7bdf2baba140c16586856) |
| 57 | `writeChunk-independent-record` | any | 12,193,829 | 543,130 | 109,850 | [`0xf4927b56…`](https://sepolia.etherscan.io/tx/0xf4927b5686b63beb74424ae274fdda5d4f0d2a8e7750c74289c9931b34f46e03) |
| 58 | `registerManifest-independent-record` | any | 12,193,830 | 581,870 | 147,970 | [`0xf4aaef97…`](https://sepolia.etherscan.io/tx/0xf4aaef9760b424c96f8bfa12e0156d2f4394efb1b8445599bd988c838127cc39) |
| 59 | `independentDeploy` | artist | 12,193,831 | 22,953,329 | 3,143,323 | [`0x999ffe28…`](https://sepolia.etherscan.io/tx/0x999ffe28a5590475beff3ffe0d23c7a30abeea4606441ed2b17e472cf7f642a8) |
| 60 | `independentRegister` | artist | 12,193,832 | 296,906 | 124,766 | [`0x406f947b…`](https://sepolia.etherscan.io/tx/0x406f947bad4d8358eedbb2788da2b13320090d0ee6bc961e5558288fc7aab739) |
| 61 | `independentApproveItem` | artist | 12,193,833 | 151,513 | 68,693 | [`0xadf7111b…`](https://sepolia.etherscan.io/tx/0xadf7111b20407064711f7d23a876360bd7c0924a135c5e290017d90b8da2cd3e) |
| 62 | `independentStartWithBid` | bidder4 | 12,193,834 | 1,845,339 | 519,901 | [`0xd867f892…`](https://sepolia.etherscan.io/tx/0xd867f892068eea2def80c45c0976c66918b9ec44d0d501634409406805ec8cbd) |
| 63 | `vrf-fulfilment` | chainlink | 12,193,819 | 140,074 | 106,591 | [`0x3f02efaa…`](https://sepolia.etherscan.io/tx/0x3f02efaaac545f4d095bf176b4788861dcbd300323e41e66a8815c20224418c4) |
| 64 | `startWithBid-6` | bidder1 | 12,193,894 | 1,209,222 | 384,842 | [`0xfdd6aeb5…`](https://sepolia.etherscan.io/tx/0xfdd6aeb53b84155097b66d397f29b02c00b20cc47b3dbb57b72f5599a2f54cc5) |
| 65 | `deploy-renderer-2` | any | 12,193,896 | 37,411,462 | 5,256,540 | [`0xf88a87cc…`](https://sepolia.etherscan.io/tx/0xf88a87cc1125d38fa1b1cc8c89c45ae9dc25c1b7030ac158903114951add1543) |
| 66 | `proposeModule-RENDERER` | any | 12,193,898 | 191,907 | 100,987 | [`0x4303443b…`](https://sepolia.etherscan.io/tx/0x4303443b573fe5be40257338c12095972752b4ada73a5ea6244378edc0fa63d7) |
| 67 | `settle-1` | any | 12,194,108 | 244,974 | 127,354 | [`0xa30f5526…`](https://sepolia.etherscan.io/tx/0xa30f5526766bc1b5c13c7381f300d5f9da6a6b75639106c8f1acded78d161d25) |
| 68 | `markOnChainComplete-1` | any | 12,194,109 | 58,996 | 56,296 | [`0xaec9a5b0…`](https://sepolia.etherscan.io/tx/0xaec9a5b0e5dc36685d5dd3e5ebad644087e58a96e30f6399aa815336fc453db5) |
| 69 | `finalize-1` | artist | 12,194,110 | 408,167 | 226,127 | [`0x3879969a…`](https://sepolia.etherscan.io/tx/0x3879969a77562efb922407e0c028fcafdc28cb7e9a5bae56b04b1599fd5acc13) |
| 70 | `settle-2` | any | 12,194,111 | 244,974 | 127,354 | [`0x6d80189e…`](https://sepolia.etherscan.io/tx/0x6d80189e47c215fea3f5da984562a81ec7b38c3330f8ecac9642ef7d061a8629) |
| 71 | `settle-independent-1` | any | 12,194,123 | 255,625 | 144,021 | [`0x181c6e4b…`](https://sepolia.etherscan.io/tx/0x181c6e4b1d3f73a08d4ccfd96d335734cbdb757b3ff161336bea98c569dae7b7) |
| 72 | `independentOpenRecord` | any | 12,194,124 | 728,526 | 205,806 | [`0xd44c5f77…`](https://sepolia.etherscan.io/tx/0xd44c5f774f134e62f529bb3635e2ad0489562e376cd6225df21df6003e927163) |
| 73 | `markOnChainComplete-independent-1` | any | 12,194,125 | 58,952 | 56,252 | [`0x7519132f…`](https://sepolia.etherscan.io/tx/0x7519132fad0ef95e5aa5254b27dd7034b6e42da43ce556274c851f1e63c13781) |
| 74 | `finalize-independent-1` | artist | 12,194,126 | 424,083 | 242,143 | [`0x45290989…`](https://sepolia.etherscan.io/tx/0x4529098965e873ca7a12ca62372446b476b4ddc54864e6c6c6bfed03802ff165) |
| 75 | `release-0` | artist | 12,194,128 | 274,996 | 101,456 | [`0xbaf0605f…`](https://sepolia.etherscan.io/tx/0xbaf0605fdd851c503327daa8628d09639d2beafef9d1bf786aba6e4ff8aa1663) |
| 76 | `forwardFees` | any | 12,194,129 | 39,052 | 39,420 | [`0xa85b266d…`](https://sepolia.etherscan.io/tx/0xa85b266dbcea1bacfa445c99e5304d71ae4a5b59cc6580a849b1f28cf59d5ee1) |
| 77 | `settle-3` | any | 12,194,186 | 233,346 | 122,542 | [`0xc2be041e…`](https://sepolia.etherscan.io/tx/0xc2be041ec9fe977bfc6073586ec6a939d9154533a3769855f5053be28d5015ed) |
| 78 | `editionSettle-2` | any | 12,194,187 | 251,275 | 147,755 | [`0x93837520…`](https://sepolia.etherscan.io/tx/0x938375207eb2ecac6ab64fc59ffc3fae26ab15dca89f08e2f6ea806d4b0b9e6e) |
| 79 | `claimBid-2-1` | bidder1 | 12,194,188 | 164,372 | 74,168 | [`0x52811889…`](https://sepolia.etherscan.io/tx/0x528118890df172dc4a7a3b219a29788637371ef18a9ab72e627ea01acb5dc2a6) |
| 80 | `claimBid-2-2` | bidder4 | 12,194,189 | 173,525 | 81,021 | [`0xae1fdff3…`](https://sepolia.etherscan.io/tx/0xae1fdff34ca54df333ef27bfde9088c49c9325675c6fd3bdc0b70b0498d7d17e) |
| 81 | `claimBid-2-3` | bidder2 | 12,194,190 | 40,670 | 42,537 | [`0x243a2ced…`](https://sepolia.etherscan.io/tx/0x243a2ced1ac2af4dad2e54798fae25eff520de63766cf95218eee311b4a5159c) |

81 transactions: 151,543,664 gas on Sepolia, 27,207,145 replayed at Prague prices.
