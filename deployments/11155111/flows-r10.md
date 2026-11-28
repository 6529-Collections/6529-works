# Sepolia r10: the open gate, and one work taken through it (28 November 2026)

On 28 November 2026 the flows below ran on **r10**
([README](README.md#sepolia-r10-28-november-2026-current-instance-with-an-open-gate)), the
current Sepolia instance of the plain permanent core
([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)), `main` at `c6d49658`, record
[`core-1795871904.json`](core-1795871904.json). It is the first instance deployed under the name 6529 Stream. The flows
open the instance to any wallet with
[`SepoliaOpenGate`](../../script/sepolia/SepoliaOpenGate.sol)
([The open gate](../../script/sepolia/open-gate.md)) and take one curated work through the gate
to a started sale, as on r9 ([flows-r9.md](flows-r9.md)).

The gate removes curation on this test instance: with its two roles, every package anyone
submits is approved and anyone creates collections. It is a Sepolia test convenience, refuses
every other chain and must never be deployed on mainnet. The two grants are governance changes:
`script/VerifyCore.s.sol` passed at the chain's head before them (block 12,230,311) and passes
after them with `ALLOW_GOVERNANCE_CHANGES=1`, which prints exactly the two grants (block
12,230,320).

This is a testnet rehearsal with throwaway keys, and the code is pre-audit. The figures are
Sepolia receipts: Sepolia reprices state creation (Glamsterdam), so they are not the Prague
figures the gas budgets are written in. The tables give both: the Sepolia receipt and the same
transaction replayed on its parent block's state at Prague prices (`flows.ps1 -Step prague`,
which runs `cast run --quick --evm-version prague`).

Every transaction was planned by [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol)
or [`script/sepolia/OpenGate.s.sol`](../../script/sepolia/OpenGate.s.sol) against the live chain
and sent by [`script/sepolia/flows.ps1`](../../script/sepolia/flows.ps1) with `cast send`. The
state file is [`flows/r10.json`](flows/r10.json). Accounts: `any` is the keeper key (no role);
`artist` is the throwaway artist key of r5 to r9; the network's three calls went through its
Safe with two owner signatures each, the digest computed locally and compared with the Safe's
own before signing. No curation signer, platform or curator key signed or sent anything.

## The gate and the work

| Step | Label | From | Block | Sepolia gas | Replay at Prague prices | Transaction |
| --- | --- | --- | ---: | ---: | ---: | --- |
| The network Safe accepts the network (Safe nonce 13) | `acceptNetwork` | any | 12,230,311 | 174,114 | 83,710 | [`0xa52348a3…`](https://sepolia.etherscan.io/tx/0xa52348a35206bec52a9f240584b58fbbdb630060e5e5955472480c1b8d8a06e7) |
| The gate is created through the CREATE2 factory | `deployOpenGate` | any | 12,230,316 | 5,782,064 | 842,766 | [`0xdf144eff…`](https://sepolia.etherscan.io/tx/0xdf144eff9c6a14db72b9accef8320429fe4ed34fde905839304248b6aa858aa0) |
| The Safe grants the gate `CURATION_SIGNER` (Safe nonce 14) | `grantOpenGate-curationSigner` | any | 12,230,317 | 294,245 | 116,205 | [`0x5311cace…`](https://sepolia.etherscan.io/tx/0x5311cace8f46bbf02d0519e1c1761fc82cf5bb071375f57ea64b431a82c1a75d) |
| The Safe grants the gate `PLATFORM` (Safe nonce 15) | `grantOpenGate-platform` | any | 12,230,318 | 294,245 | 116,205 | [`0xbea0e877…`](https://sepolia.etherscan.io/tx/0xbea0e8778e68c39dcaa03619099489634f4369e26ab9190962cafb3325773edf) |
| The artist creates collection 1 through the gate | `createCollection-openGate` | artist | 12,230,323 | 481,930 | 135,150 | [`0xfc63ce9f…`](https://sepolia.etherscan.io/tx/0xfc63ce9f09be575e2cad0e0db6febe6b7b4800cab9a2b770be82fe4b9746c0e7) |
| The package is registered with the gate's approval | `registerPackage-openGate` | any | 12,230,360 | 284,033 | 112,693 | [`0x72355728…`](https://sepolia.etherscan.io/tx/0x723557286a73b426303713f7da6ad7f63ca4df041ba80d09823cd96ab09d934f) |
| The artist's acceptance (relayed); it creates the account | `acceptPackage` | any | 12,230,361 | 841,752 | 229,912 | [`0x1d112210…`](https://sepolia.etherscan.io/tx/0x1d11221009d7327849f1dc4ff34256073c781673a18b422c50ef9b526486ae8e) |
| `SaleStarter.start` of item 3: auction, vaults and record | `saleStarter-3` | any | 12,230,362 | 2,763,049 | 751,313 | [`0xb861627f…`](https://sepolia.etherscan.io/tx/0xb861627f9d5ae23da9cac6fb879108de7900c84dd021ca25fef7f747b271e10d) |

1. **The gate.** Anyone can create it: its address,
   [`0xD40A02677136bd5F147775FC2C143d90c42A424F`](https://sepolia.etherscan.io/address/0xD40A02677136bd5F147775FC2C143d90c42A424F), depends only on its code and on
   r10's `CurationVerifier` and `Stream6529`. The two grants took effect in the blocks that
   mined them; `gateState` then read both roles.
2. **A collection.** The artist called `SepoliaOpenGate.createCollection("Open gate", …)`; the
   gate, holding `PLATFORM`, forwarded it to `Stream6529`, which created collection 1.
3. **The package.** The ten-item package of the flows (root
   `0xa2ca5e2e552241e4f8a5e2f8aecb4dce7cec682db353dce6023bcaadffe7d27d`) was registered by the keeper with the
   attestation `gate.attestationOf(root)` answered. `PackageRegistered` names the gate as the
   signer. No curator statement was appended; no contract requires one.
4. **Acceptance and start.** The artist signed its acceptance and the move of item 3; the
   keeper relayed both. `SaleStarter.start` minted token 1 into the English auction's custody,
   deployed the seller and royalty vaults and opened the record. Read at block
   12,230,362: state ACTIVE, end 1795876704 (one hour after the start), no bid,
   minimum bid 0.05 ETH.

## The uploads

The files of the ten-item package, sent by the keeper key (`ContentStore` is open to anyone).

| Step | Label | From | Block | Sepolia gas | Replay at Prague prices | Transaction |
| --- | --- | --- | ---: | ---: | ---: | --- |
| Upload | `writeChunk-b64-1024` | any | 12,230,324 | 1,911,018 | 301,850 | [`0x9025a0d1…`](https://sepolia.etherscan.io/tx/0x9025a0d146a79a9157dee502d9d52220d7e272d8c046ce7ba0aacd2003e9320f) |
| Upload | `registerManifest-b64-1024` | any | 12,230,325 | 579,348 | 145,448 | [`0x568e857b…`](https://sepolia.etherscan.io/tx/0x568e857b5bb7b87d027ff9df2520608c4907f5b0df06da979eb54134da1ac539) |
| Upload | `attestBase64-1024` | any | 12,230,326 | 154,240 | 71,220 | [`0xa7c5243f…`](https://sepolia.etherscan.io/tx/0xa7c5243f03dfaa0f228d830f0e7251de479622a7ae7cec881d4505cdaaa36dae) |
| Upload | `writeChunk-b64-8192` | any | 12,230,327 | 13,003,921 | 1,859,969 | [`0x7b7356ad…`](https://sepolia.etherscan.io/tx/0x7b7356ad23b7a065eae42a20c1860c058a5deb5122b4aa6044afcbd967304915) |
| Upload | `registerManifest-b64-8192` | any | 12,230,328 | 579,348 | 145,448 | [`0x6c646a9d…`](https://sepolia.etherscan.io/tx/0x6c646a9d302482fe64833bebb7ff9833004851968572282857b5ec5587c1e34c) |
| Upload | `attestBase64-8192` | any | 12,230,329 | 206,341 | 123,321 | [`0x041d3656…`](https://sepolia.etherscan.io/tx/0x041d3656e434f4ba3fcb99fc411c60510e292dd8001c49289da1184f353ba39e) |
| Upload | `writeChunk-b64-24572` | any | 12,230,330 | 38,356,636 | 5,424,218 | [`0xdae54e9e…`](https://sepolia.etherscan.io/tx/0xdae54e9e8075e8bccdffad6e0a0a00e9a5dff10ae49d8572719488a75cfa75ec) |
| Upload | `registerManifest-b64-24572` | any | 12,230,331 | 579,360 | 145,460 | [`0xa868cf59…`](https://sepolia.etherscan.io/tx/0xa868cf59a26da7350a9757d676bde35254f1161d2afa58837f9a8ccde5f84017) |
| Upload | `attestBase64-24572` | any | 12,230,332 | 326,265 | 243,245 | [`0x851b467a…`](https://sepolia.etherscan.io/tx/0x851b467abeee9a2f3dd394ccf7310e3ed6bdd341f47033c1cb3f5a6a25c2da70) |
| Upload | `writeChunk-record-0` | any | 12,230,333 | 621,958 | 120,842 | [`0xea905c3d…`](https://sepolia.etherscan.io/tx/0xea905c3d35568b7fafd4036bbf7aaa524566de4b030fd65ff057abeeb5df25ce) |
| Upload | `registerManifest-record-0` | any | 12,230,334 | 581,870 | 147,970 | [`0xd24a25f3…`](https://sepolia.etherscan.io/tx/0xd24a25f375a85fead73dc72738648262d34b4f13e9f77698ddd4e58de0fee21f) |
| Upload | `writeChunk-record-1` | any | 12,230,335 | 621,958 | 120,842 | [`0xe975a2b4…`](https://sepolia.etherscan.io/tx/0xe975a2b43b31d21089d3ad560904e475124a3aed00b47bb8223fefca22697bc0) |
| Upload | `registerManifest-record-1` | any | 12,230,336 | 581,870 | 147,970 | [`0xe8c79cf8…`](https://sepolia.etherscan.io/tx/0xe8c79cf8d492d4ec4f77a06eb62b439ccc0946ea2e92788dfb0ac30d36267b8a) |
| Upload | `writeChunk-record-2` | any | 12,230,337 | 621,958 | 120,842 | [`0x2e4b4ae1…`](https://sepolia.etherscan.io/tx/0x2e4b4ae1dcf3b64cb804370eb537e9bae4b77ef125be5b181c7b2fce0f5dc020) |
| Upload | `registerManifest-record-2` | any | 12,230,338 | 581,858 | 147,958 | [`0x99ceebd8…`](https://sepolia.etherscan.io/tx/0x99ceebd816dce47311a80e5e11c89454c2339c4fb64309569b5f325c9891fdea) |
| Upload | `registerManifest-media-2` | any | 12,230,339 | 579,336 | 145,436 | [`0xaff7cdd7…`](https://sepolia.etherscan.io/tx/0xaff7cdd72216ba628c11053969be1c1c6dc93d75e2c3a75e9155af91e2587059) |
| Upload | `writeChunk-record-3` | any | 12,230,340 | 621,958 | 120,842 | [`0x7691706b…`](https://sepolia.etherscan.io/tx/0x7691706b639ce3511590f706688267d7a41bbb3c7bc13cd1e296c0ea688ceea3) |
| Upload | `registerManifest-record-3` | any | 12,230,341 | 581,870 | 147,970 | [`0x7c3f8c84…`](https://sepolia.etherscan.io/tx/0x7c3f8c8432370cefae7eaafef0bdae4719b1c1d15683f4f0e603649eae0777f9) |
| Upload | `registerManifest-media-3` | any | 12,230,342 | 579,336 | 145,436 | [`0xb1ddd9a1…`](https://sepolia.etherscan.io/tx/0xb1ddd9a174db14dca567e1c444e5b2e2ccae8a6ee946adf88520f3c2f63cadc2) |
| Upload | `writeChunk-record-4` | any | 12,230,343 | 621,958 | 120,842 | [`0xdb0d7fa5…`](https://sepolia.etherscan.io/tx/0xdb0d7fa5d5d8601bd78a445d8ffef0e07f0bba2ec2142dc74cf40c1e7e0ece2c) |
| Upload | `registerManifest-record-4` | any | 12,230,344 | 581,870 | 147,970 | [`0x60afc951…`](https://sepolia.etherscan.io/tx/0x60afc951101cc4247370736056c1a02679e91cf289a552b88ece0b1521a5de3a) |
| Upload | `writeChunk-record-5` | any | 12,230,345 | 621,958 | 120,842 | [`0x9ada3ecd…`](https://sepolia.etherscan.io/tx/0x9ada3ecd76a7125bbf81a93af1ac25506b223d0725f0fbaf9294a3f662d3b965) |
| Upload | `registerManifest-record-5` | any | 12,230,346 | 581,870 | 147,970 | [`0xcc362017…`](https://sepolia.etherscan.io/tx/0xcc362017b3b364410d40b824bddf47448bc8997a59db64ee5b6fffef824461d9) |
| Upload | `registerManifest-media-5` | any | 12,230,347 | 579,336 | 145,436 | [`0xbc954f65…`](https://sepolia.etherscan.io/tx/0xbc954f65b4700cb012bd9d4b56aba69fe8d4112be606f20c6964c55483c8ff00) |
| Upload | `writeChunk-record-6` | any | 12,230,348 | 621,958 | 120,842 | [`0x93ebc7f8…`](https://sepolia.etherscan.io/tx/0x93ebc7f83e7ad11f2118ddeec23e65f256a7c64c754043111f26f02a259930ed) |
| Upload | `registerManifest-record-6` | any | 12,230,349 | 581,870 | 147,970 | [`0x9118f569…`](https://sepolia.etherscan.io/tx/0x9118f56921a5f1306524a592ddb001820ad8c80a9b56256f5d34dc0123abc7d7) |
| Upload | `registerManifest-media-6` | any | 12,230,350 | 579,336 | 145,436 | [`0x046283f0…`](https://sepolia.etherscan.io/tx/0x046283f0bd16d05890e241da9a807d3ecbbe67fabbbb99581b9d2a15db865188) |
| Upload | `writeChunk-record-7` | any | 12,230,351 | 621,958 | 120,842 | [`0x5ec95642…`](https://sepolia.etherscan.io/tx/0x5ec95642491e843b4b0374a93da35e8161e409a3ea090aea578d7ac759dc347a) |
| Upload | `registerManifest-record-7` | any | 12,230,352 | 581,870 | 147,970 | [`0xfa83e072…`](https://sepolia.etherscan.io/tx/0xfa83e0720c79292a4a92a3dfd16660851bc597a5b4ad8929a901e11e9656974d) |
| Upload | `registerManifest-media-7` | any | 12,230,353 | 579,336 | 145,436 | [`0xdaa6137e…`](https://sepolia.etherscan.io/tx/0xdaa6137eb7edb697cb0f326b535506e2621202a7979dc02db0331d1250a94dbc) |
| Upload | `writeChunk-record-8` | any | 12,230,354 | 621,958 | 120,842 | [`0xd1fd6eee…`](https://sepolia.etherscan.io/tx/0xd1fd6eeea2a47effab8f8aaaf822ec3e5e5bd47505a3801e57d8b28c702bc1f1) |
| Upload | `registerManifest-record-8` | any | 12,230,355 | 581,870 | 147,970 | [`0x4258082e…`](https://sepolia.etherscan.io/tx/0x4258082e84aafba0b963a00b8bfbc4e09427d1ec9618fc123fa9b64029c566c0) |
| Upload | `registerManifest-media-8` | any | 12,230,356 | 579,336 | 145,436 | [`0x0e23007e…`](https://sepolia.etherscan.io/tx/0x0e23007e31a010e6b9d435b428063444dcfd40b466fbb817cff8e696a96c062d) |
| Upload | `writeChunk-record-9` | any | 12,230,357 | 621,958 | 120,842 | [`0x5e1053e9…`](https://sepolia.etherscan.io/tx/0x5e1053e919c7bb39710bef1d06a79ba61554db2f5c41c7ecbc9d6aba2e7baf64) |
| Upload | `registerManifest-record-9` | any | 12,230,358 | 581,870 | 147,970 | [`0x119adac9…`](https://sepolia.etherscan.io/tx/0x119adac9c34e3a4ebea82585f5db56dd8603b68364e8fd7fd7bf045a2d563b7d) |
| Upload | `registerManifest-media-9` | any | 12,230,359 | 579,336 | 145,436 | [`0x413207c4…`](https://sepolia.etherscan.io/tx/0x413207c469ef70758e5fa86d6b1eaaf628659a588dbd02ead9ad9f6d0f5fd7bd) |

## Totals and what did not run

44 transactions, 82,705,529 gas in all. The deployment itself is in the
[README](README.md#sepolia-r10-28-november-2026-current-instance-with-an-open-gate).

Not run on r10: a bid, a settlement, an edition sale, an Independent Stream sale, a VRF work, a
dispute and a finalized record. The deployment, the Safe's three calls, the gate and this same
curated start were run on a local fork of Sepolia before the broadcast. The sale of token 1 was
left running with no bid; anyone may settle it after its end. Closing the gate
(`flows.ps1 -Step gateRevoke`) was not sent.
