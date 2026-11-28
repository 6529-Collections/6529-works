# Sepolia r9: the open gate, and one work taken through it (28 November 2026)

On 28 November 2026 the flows below ran on **r9**
([README](README.md#sepolia-r9-28-november-2026-current-instance-with-an-open-gate)), the
current Sepolia instance of the plain permanent core
([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)), `main` at `355a7a71`, record
[`core-1795840548.json`](core-1795840548.json). They open the instance to any wallet with
[`SepoliaOpenGate`](../../script/sepolia/SepoliaOpenGate.sol)
([The open gate](../../script/sepolia/open-gate.md)) and take one curated work through the gate
to a started sale. r8's flows are in [flows-r8.md](flows-r8.md).

The gate removes curation on this test instance: with its two roles, every package anyone
submits is approved and anyone creates collections. It is a Sepolia test convenience, refuses
every other chain and must never be deployed on mainnet. The two grants are governance changes:
`script/VerifyCore.s.sol` passed at the chain's head before them (block 12,227,876) and passes
after them with `ALLOW_GOVERNANCE_CHANGES=1`, which prints exactly the two grants (block
12,227,886).

This is a testnet rehearsal with throwaway keys, and the code is pre-audit. The figures are
Sepolia receipts: Sepolia reprices state creation (Glamsterdam), so they are not the Prague
figures the gas budgets are written in. The tables give both: the Sepolia receipt and the same
transaction replayed on its parent block's state at Prague prices (`flows.ps1 -Step prague`,
which runs `cast run --quick --evm-version prague`).

Every transaction was planned by [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol)
or [`script/sepolia/OpenGate.s.sol`](../../script/sepolia/OpenGate.s.sol) against the live chain
and sent by [`script/sepolia/flows.ps1`](../../script/sepolia/flows.ps1) with `cast send`. The
state file is [`flows/r9.json`](flows/r9.json). Accounts: `any` is the keeper key (no role);
`artist` is the throwaway artist key of r5 to r8; the network's three calls went through its
Safe with two owner signatures each, the digest computed locally and compared with the Safe's
own before signing. No curation signer, platform or curator key signed or sent anything.

## The gate and the work

| Step | Label | From | Block | Sepolia gas | Replay at Prague prices | Transaction |
| --- | --- | --- | ---: | ---: | ---: | --- |
| The network Safe accepts the network (Safe nonce 10) | `acceptNetwork` | any | 12,227,874 | 174,114 | 83,710 | [`0x831048c1…`](https://sepolia.etherscan.io/tx/0x831048c1fb0adc3d8cca1fcf02eb039a4ccb2cb7dabe6ddcd2f8e91947b36bf0) |
| The gate is created through the CREATE2 factory | `deployOpenGate` | any | 12,227,880 | 5,780,518 | 842,550 | [`0xf7eb3e57…`](https://sepolia.etherscan.io/tx/0xf7eb3e57d2fa81fd20d607b7241f4b6ad2094ffa50af5434442896b8935135fe) |
| The Safe grants the gate `CURATION_SIGNER` (Safe nonce 11) | `grantOpenGate-curationSigner` | any | 12,227,881 | 294,257 | 116,217 | [`0xcfaf7c39…`](https://sepolia.etherscan.io/tx/0xcfaf7c399ccb9c4bcd6979ae3ddbef3d9e49385e1ec6d28a4a5e1313e957ec75) |
| The Safe grants the gate `PLATFORM` (Safe nonce 12) | `grantOpenGate-platform` | any | 12,227,882 | 294,257 | 116,217 | [`0x10765790…`](https://sepolia.etherscan.io/tx/0x10765790c5bc3b1c4c6732a5347f315c056e937902a847624841b1109bd384b7) |
| The artist creates collection 1 through the gate | `createCollection-openGate` | artist | 12,227,887 | 481,954 | 135,174 | [`0x2767a064…`](https://sepolia.etherscan.io/tx/0x2767a064c07ee1f8715ae3e8883d2057da584765633df6659abbd06e3f6d7c51) |
| The package is registered with the gate's approval | `registerPackage-openGate` | any | 12,227,927 | 284,033 | 112,693 | [`0xd8d1b14d…`](https://sepolia.etherscan.io/tx/0xd8d1b14d75cb334f80db5d48c9d9fe3477be493053dbb5e1d0fc062f1bc11a60) |
| The artist's acceptance (relayed); it creates the account | `acceptPackage` | any | 12,227,928 | 841,740 | 229,900 | [`0x1aa0065b…`](https://sepolia.etherscan.io/tx/0x1aa0065bae4bce8e76a90e9f93e9a2c25aadcfe56656303fd8c50df304d2d72f) |
| `SaleStarter.start` of item 3: auction, vaults and record | `saleStarter-3` | any | 12,227,929 | 2,761,886 | 750,150 | [`0x3e672f4b…`](https://sepolia.etherscan.io/tx/0x3e672f4b55d30306b1a494cc68b9e8fd07f49bed1289f8be7bb3df1d1990d0db) |

1. **The gate.** Anyone can create it: its address,
   [`0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac`](https://sepolia.etherscan.io/address/0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac), depends only on its code and on
   r9's `CurationVerifier` and `Stream6529`. The two grants took effect in the blocks that
   mined them; `gateState` then read both roles.
2. **A collection.** The artist called `SepoliaOpenGate.createCollection("Open gate", …)`; the
   gate, holding `PLATFORM`, forwarded it to `Stream6529`, which created collection 1.
3. **The package.** The ten-item package of the flows (root
   `0xdfbe6402d33bc60d8513e660868a1de970f7daec1832dbef95c68b1915f0559d`) was registered by the keeper with the
   attestation `gate.attestationOf(root)` answered. `PackageRegistered` names the gate as the
   signer. No curator statement was appended; no contract requires one.
4. **Acceptance and start.** The artist signed its acceptance and the move of item 3; the
   keeper relayed both. `SaleStarter.start` minted token 1 into the English auction's custody,
   deployed the seller and royalty vaults and opened the record. Read at block
   12,227,929: state ACTIVE, end 1795845420 (one hour after the start), no bid,
   minimum bid 0.05 ETH.

## The uploads

The files of the ten-item package, sent by the keeper key (`ContentStore` is open to anyone).

| Step | Label | From | Block | Sepolia gas | Replay at Prague prices | Transaction |
| --- | --- | --- | ---: | ---: | ---: | --- |
| Upload | `writeChunk-b64-1024` | any | 12,227,888 | 1,911,018 | 301,850 | [`0xdf484727…`](https://sepolia.etherscan.io/tx/0xdf48472765dd3d09d2d89a7a290a552a8fc85a87f24b33c7080566231641d13c) |
| Upload | `registerManifest-b64-1024` | any | 12,227,889 | 579,348 | 145,448 | [`0xbe7f0ab4…`](https://sepolia.etherscan.io/tx/0xbe7f0ab4501d78a7b2e5ccf8b2fa789ad8cf6225231430d26d3f3c81de928066) |
| Upload | `attestBase64-1024` | any | 12,227,891 | 154,216 | 71,196 | [`0x964e91e1…`](https://sepolia.etherscan.io/tx/0x964e91e1fa3d9b6dd16a15dbb33e2790fb21179672dd246c95fc2e65349f3c0d) |
| Upload | `writeChunk-b64-8192` | any | 12,227,892 | 13,003,921 | 1,859,969 | [`0x5caa466f…`](https://sepolia.etherscan.io/tx/0x5caa466f53fddfdea686b4843e769f55da6d847043e6991e7a6f71ea37f15771) |
| Upload | `registerManifest-b64-8192` | any | 12,227,893 | 579,348 | 145,448 | [`0x385ec36e…`](https://sepolia.etherscan.io/tx/0x385ec36e9f734a2962fd78eec3ecfd1ea5eba932ff1aca014f9cb572026d9af5) |
| Upload | `attestBase64-8192` | any | 12,227,894 | 206,341 | 123,321 | [`0x1552af41…`](https://sepolia.etherscan.io/tx/0x1552af41bb99e80ad61921f202d5878bd212810b2f7a9d4872c476daf9d7a18c) |
| Upload | `writeChunk-b64-24572` | any | 12,227,895 | 38,356,636 | 5,424,218 | [`0xb23afdcc…`](https://sepolia.etherscan.io/tx/0xb23afdcca52cb67a38ca42cb69b4a60ec74742ead0151ea2dd867a26a45bcddb) |
| Upload | `registerManifest-b64-24572` | any | 12,227,896 | 579,360 | 145,460 | [`0x1c4f5a3e…`](https://sepolia.etherscan.io/tx/0x1c4f5a3e90e5ee2bf3c2deb64945d3b5bbcc46ac325c543926a7e98ddf46c996) |
| Upload | `attestBase64-24572` | any | 12,227,897 | 326,265 | 243,245 | [`0xb10cf32d…`](https://sepolia.etherscan.io/tx/0xb10cf32d448491eb388fc46cd0801d4e1ba993d9e22933fa445cef48798fc397) |
| Upload | `writeChunk-record-0` | any | 12,227,898 | 621,958 | 120,842 | [`0x9c20b83a…`](https://sepolia.etherscan.io/tx/0x9c20b83a1ac70283e5fc1cc896d659c1cf35d1ff6b6f0c90247acf839cdf1ed9) |
| Upload | `registerManifest-record-0` | any | 12,227,899 | 581,870 | 147,970 | [`0x76c1a519…`](https://sepolia.etherscan.io/tx/0x76c1a5199f83fd2b1c0b86915ce3fa7b62c4aba1554f35b8894732456062b81e) |
| Upload | `writeChunk-record-1` | any | 12,227,900 | 621,958 | 120,842 | [`0x6a9013d0…`](https://sepolia.etherscan.io/tx/0x6a9013d07191941340b88b74240a097c6f2a93f021116eb9d9635b80698030a8) |
| Upload | `registerManifest-record-1` | any | 12,227,901 | 581,870 | 147,970 | [`0x5f619f49…`](https://sepolia.etherscan.io/tx/0x5f619f49991c86eaaf8db9df5957ea82b0e7ed9d9499647ffd03887131ec7ee1) |
| Upload | `writeChunk-record-2` | any | 12,227,902 | 621,958 | 120,842 | [`0xaa81ed1b…`](https://sepolia.etherscan.io/tx/0xaa81ed1bd2df69c2be487a0e17cbc0d78effc0213f2fe2a8ea0325d1d1f2b183) |
| Upload | `registerManifest-record-2` | any | 12,227,903 | 581,858 | 147,958 | [`0x33329027…`](https://sepolia.etherscan.io/tx/0x333290275d21de35a12804f80a783e15b4b92f841a386b6382676d9c66e83a66) |
| Upload | `registerManifest-media-2` | any | 12,227,904 | 579,324 | 145,424 | [`0xd8058948…`](https://sepolia.etherscan.io/tx/0xd805894846e2e0ac82d1143e70a6799db43cf0360fc48a6be37bb11b33819750) |
| Upload | `writeChunk-record-3` | any | 12,227,905 | 621,958 | 120,842 | [`0x6cb1ee54…`](https://sepolia.etherscan.io/tx/0x6cb1ee54a61efd582d7bdba9b9e848024696a1e409ad3a08777d336fae3327db) |
| Upload | `registerManifest-record-3` | any | 12,227,906 | 581,870 | 147,970 | [`0x79141379…`](https://sepolia.etherscan.io/tx/0x7914137905f95ecea2badc9275b81c179328275ace338ee5249092e7e9d54fe0) |
| Upload | `registerManifest-media-3` | any | 12,227,907 | 579,336 | 145,436 | [`0x4f5b75bf…`](https://sepolia.etherscan.io/tx/0x4f5b75bf70ccb5f344ada88fee692159dc9c81ebdf71ea91440b5ada2fddefff) |
| Upload | `writeChunk-record-4` | any | 12,227,908 | 621,958 | 120,842 | [`0xf7295de5…`](https://sepolia.etherscan.io/tx/0xf7295de5034a3bacafc067a930b48052a4bc1914599fa21013522d3fc6660122) |
| Upload | `registerManifest-record-4` | any | 12,227,909 | 581,870 | 147,970 | [`0x41c3692d…`](https://sepolia.etherscan.io/tx/0x41c3692d7941fa0b44aa347524632754cba132da9a8216bd32a78c97d22b2e93) |
| Upload | `writeChunk-record-5` | any | 12,227,910 | 621,958 | 120,842 | [`0xd2e4b328…`](https://sepolia.etherscan.io/tx/0xd2e4b328bfc62dee6a3cab4a8027bce91bbfaa550f6363c3fcb86e16c8f4ae93) |
| Upload | `registerManifest-record-5` | any | 12,227,911 | 581,870 | 147,970 | [`0x609d2b5d…`](https://sepolia.etherscan.io/tx/0x609d2b5d4e78f0c795da5f10dee5ed8138d47a513b22835660416aaa4624db38) |
| Upload | `registerManifest-media-5` | any | 12,227,912 | 579,312 | 145,412 | [`0xf45cdacd…`](https://sepolia.etherscan.io/tx/0xf45cdacd6cd5f0d13440915121c5465f50dad314c7c058e31022702f3d0860bb) |
| Upload | `writeChunk-record-6` | any | 12,227,913 | 621,958 | 120,842 | [`0xe63e802c…`](https://sepolia.etherscan.io/tx/0xe63e802c2a905935d69c49545fdb1b88990904602e72ea9b5d4727a46aeefeca) |
| Upload | `registerManifest-record-6` | any | 12,227,914 | 581,870 | 147,970 | [`0x1024b18e…`](https://sepolia.etherscan.io/tx/0x1024b18e1186bd3fe43e5af05a0277bca6c27c5abe0195825e947a14dfca09ee) |
| Upload | `registerManifest-media-6` | any | 12,227,915 | 579,336 | 145,436 | [`0x3a00b9ef…`](https://sepolia.etherscan.io/tx/0x3a00b9ef71e125d1a7bf5b47a0e38ae65a7c859e4e5cc774a09d3e5442b6e36d) |
| Upload | `writeChunk-record-7` | any | 12,227,916 | 621,958 | 120,842 | [`0xedcfd9d9…`](https://sepolia.etherscan.io/tx/0xedcfd9d925d0782f9cdc15589ef9a49232e9e8c3c69429e7244d9d9e92c3dfc4) |
| Upload | `registerManifest-record-7` | any | 12,227,917 | 581,870 | 147,970 | [`0xc735787f…`](https://sepolia.etherscan.io/tx/0xc735787f1bf3512217111024d6398d1f268476e89b1126f056ca97fc01276108) |
| Upload | `registerManifest-media-7` | any | 12,227,918 | 579,336 | 145,436 | [`0xc1208747…`](https://sepolia.etherscan.io/tx/0xc1208747bdd9cba82383659659d8ebdb27539af26b8144b156c085652b27bdcb) |
| Upload | `writeChunk-record-8` | any | 12,227,919 | 621,958 | 120,842 | [`0x4a8dca5c…`](https://sepolia.etherscan.io/tx/0x4a8dca5c52523ae0832964463bba9466c0f712a105a4c6315f75992c8257121d) |
| Upload | `registerManifest-record-8` | any | 12,227,920 | 581,870 | 147,970 | [`0x1ea62c26…`](https://sepolia.etherscan.io/tx/0x1ea62c26d73d5bca8d3106332e021b9179efe02d6c257cce25dc4e9f762bd579) |
| Upload | `registerManifest-media-8` | any | 12,227,921 | 579,324 | 145,424 | [`0x3fe69f47…`](https://sepolia.etherscan.io/tx/0x3fe69f4791e3f7899b13e6088e2eddaab26fdd1b0e87ea2d8a889665a19bd0c5) |
| Upload | `writeChunk-record-9` | any | 12,227,922 | 621,958 | 120,842 | [`0xe5cbaad4…`](https://sepolia.etherscan.io/tx/0xe5cbaad4fb51166c2e1f80a8a5722a35d3c08a4d974f31fe3e56d0a8a881dc7d) |
| Upload | `registerManifest-record-9` | any | 12,227,923 | 581,870 | 147,970 | [`0xf0b3cb8a…`](https://sepolia.etherscan.io/tx/0xf0b3cb8ac6eeee0c9c84f9f3dc2442291d2b51ba8536b8ea867f903ba1d24352) |
| Upload | `registerManifest-media-9` | any | 12,227,924 | 579,336 | 145,436 | [`0xd2909fa5…`](https://sepolia.etherscan.io/tx/0xd2909fa533b7d0954969dc28d67341a3b7a098fc9d78211490c530808dd37da1) |

## Totals and what did not run

44 transactions, 82,702,784 gas in all. The deployment itself is in the
[README](README.md#sepolia-r9-28-november-2026-current-instance-with-an-open-gate).

Not run on r9: a bid, a settlement, an edition sale, an Independent Stream sale, a VRF work, a
dispute and a finalized record. A curated sale with an edition sale, bids, settlement and
claims, and an Independent Stream sale, were run from fresh wallets on a local fork of Sepolia
before the broadcast, not on the live instance. The sale of token 1 was left running with no
bid; anyone may settle it after its end. Closing the gate (`flows.ps1 -Step gateRevoke`) was
rehearsed on the fork and not sent.
