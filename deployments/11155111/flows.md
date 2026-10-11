# Sepolia: the v1 flows and their gas under Glamsterdam

On 11 October 2026 the v1 flows were run on two Sepolia rehearsal deployments
([README](README.md)):

| Instance | Source | Record | Role here |
| --- | --- | --- | --- |
| **r2** | `main` at `400f96d`: the full v1 scope, including the Editions gas cuts ([#41](https://github.com/6529-Collections/6529-works/pull/41)) and the contested overrides ([#44](https://github.com/6529-Collections/6529-works/pull/44)) | [`1791750816.json`](1791750816.json) | **Reference** |
| r1 | `main` at `60edd9b`, before #41 and #44 | [`1791746472.json`](1791746472.json) | Measured first; kept for comparison |

Every gas figure below names its instance. Where a table has an r1 column, r1 ran the
same operation on its own contracts.

Sepolia has run Glamsterdam since 6 October 2026, and Glamsterdam reprices state
creation. Every budget in ADR 0001, ADR 0003 and the gas reports was measured with
Prague costs in Foundry. This file records what the flows cost on Sepolia now.

These are testnet rehearsals with throwaway keys, and the code is pre-audit.

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
- **Settlement and editions have not been broadcast yet.** The 24-hour auctions end on
  12 October 2026: r1 from 19:54 UTC, r2 from 20:45 UTC. Until then, `settle`,
  `createEdition`, `openSale` and the mints were measured by simulation on the live state
  at a later timestamp (see Method). The commands to run them are under Pending.

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
  - It is still a simulation. The rows are replaced by receipts once the transactions
    are sent.
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
  those accounts, and used about 0.009 ETH of gas (170M gas).

**What was created on each instance.**
- Collections 1 and 2.
- Package root `0xde416feb…e68d`, which has eight items by the artist.
- Stream tokens 1 to 8, all in live 24-hour auctions:

| Token | Item | State (r2 and r1) |
| ---: | --- | --- |
| 1 | 1,024-byte base64 media | Record opened and synced. 0.002 ETH bid (bidder 2). |
| 2 | 8,192-byte base64 media | Record opened and synced. |
| 3 | Registered-only media | Record opened. |
| 4 | Registered-only media | `startWithBid`: 0.001 ETH (bidder 2). |
| 5 | 24,572-byte base64 media | Record opened and synced. |
| 6 | `EDITION_MASTER`: fixed edition of 10 at 0.0001 ETH | 0.001 ETH bid (bidder 1). |
| 7 | In collection 2 | No bid. |
| 8 | VRF seed | No bid. |

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
| `bid` 5 minutes before the end (simulated) | 179,354 | 76,534 | 2.34 | 1 | 179,366 | | |
| `settle`, with a bid, first payout to the seller (simulated) | 441,363 | 164,743 | 2.68 | 1 and an account | 441,363 | 400,000 test ceiling | **fail** |
| `settle`, with a bid (simulated) | 257,763 | 139,743 | 1.84 | 1 | 257,763 | 400,000 test ceiling | pass |
| `settle`, with a bid, the winner already holds a token (simulated) | 159,831 | 122,631 | 1.30 | 0 | 159,843 | 400,000 test ceiling | pass |
| `settle`, no bid: the token goes to the artist (simulated) | 335,817 | 135,577 | 2.48 | 2 | 335,817 | 400,000 test ceiling | pass |

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
- **The anti-snipe bid** was simulated 5 minutes before token 1's end, on both instances.
  It moved the end to 15 minutes after the bid: on r1, from 1,791,834,852 to
  1,791,835,452.
- **The first `settle` with a bid** pays the seller. The seller is the payee
  configuration's split wallet, at its predicted address, which is still empty. Sending
  ETH to an empty account creates it, and that costs about 184,000 gas more on Sepolia.
  This happens once per payee configuration.

## 3. 6529 Editions (simulated)

`createEdition` needs the master's sale to be settled, so every row here was simulated.
On r2 the simulation settled master token 6, and tokens 1, 4 and 7, in a block dated
12 October 2026, 21:22:48 UTC. Then:
- the edition was created;
- the PLATFORM opened a fixed-price sale with one public phase;
- buyers bought copies at the package price.

r1 ran the same sequence on its own state.

| Operation | r2 Sepolia | r2 Prague | Ratio | New slots (r2) | r1 Sepolia | r1 Prague |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `createEdition` | 1,118,699 | 323,819 | 3.45 | 9 | 1,133,867 | 338,987 |
| `openSale` (PLATFORM, one public phase, no artist consent) | 993,668 | 286,608 | 3.47 | 8 | 993,668 | 286,608 |
| `purchase`: mints the first copy (new holder) | 468,086 | 196,926 | 2.38 | 3 | 476,183 | 204,623 |
| `purchase`: a later copy (new holder) | 370,142 | 179,802 | 2.06 | 2 | 378,239 | 187,499 |
| `purchase`: two copies (existing holder) | 174,326 | 145,626 | 1.20 | 0 | 182,423 | 153,323 |

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
| `settle` ≤ 400K | `GasReport.t.sol` ceiling | 441,363 for the first payout to a new seller (simulated); 160K to 336K otherwise | **breaks once per payee configuration** |
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

**Real settlement and editions.**
- r2's auctions end on 12 October 2026, from 20:45:36 UTC (token 1) to 20:47:48 UTC
  (token 8). Token 3, the anti-snipe target below, ends at 20:46:12.
- r1's auctions end from 19:54:12 to 19:56:36 UTC.

The runs' state files are committed:
- [`flows/r2.json`](flows/r2.json) and [`flows/r1.json`](flows/r1.json) hold each run's
  addresses, receipts and Prague replays;
- in `r2.json`, the content rows sent by the second relayer say `relay2`.

The driver appends each new receipt to the state file it is given. Run these from the
repository root:
- `<module>` is the operator's signer module (see the script header);
- run `prague` within minutes, because the public RPC keeps only recent state.

```powershell
function Flow {
    powershell -NoProfile -ExecutionPolicy Bypass -File script/sepolia/flows.ps1 `
        -SignerModule '<module>' @args
    if ($LASTEXITCODE -ne 0) { throw "flow step failed ($LASTEXITCODE)" }
}
$r2 = @('-State', 'deployments/11155111/flows/r2.json')
$r1 = @('-State', 'deployments/11155111/flows/r1.json', '-Record', 'deployments/11155111/1791746472.json')

# r2, only between 20:31:12 and 20:46:12 UTC: a real anti-snipe bid (token 3 has no bid).
Flow @r2 -Step bid -TokenId 3 -Bidder bidder1 -Amount 1000000000000000 -Label bid-3-antisnipe

# r2, after 20:47:48 UTC. Token 6 goes first, so its row is the first payout to the seller.
foreach ($t in 6, 4, 1, 7, 2, 5, 8) { Flow @r2 -Step settle -TokenId $t }
Flow @r2 -Step settle -TokenId 3   # after its end: 15 minutes after the anti-snipe bid
Flow @r2 -Step createEdition -TokenId 6
Flow @r2 -Step openSale -TokenId 6
Flow @r2 -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 1 -Label purchase-first-copy
Flow @r2 -Step purchase -SaleId 1 -Bidder bidder2 -Quantity 1 -Label purchase-later-copy
Flow @r2 -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 2 -Label purchase-two-copies
Flow @r2 -Step prague

# r1 (ended at 19:56:36 UTC): the same steps without the anti-snipe bid.
foreach ($t in 6, 4, 1, 7, 2, 3, 5, 8) { Flow @r1 -Step settle -TokenId $t }
Flow @r1 -Step createEdition -TokenId 6
Flow @r1 -Step openSale -TokenId 6
Flow @r1 -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 1 -Label purchase-first-copy
Flow @r1 -Step purchase -SaleId 1 -Bidder bidder2 -Quantity 1 -Label purchase-later-copy
Flow @r1 -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 2 -Label purchase-two-copies
Flow @r1 -Step prague
```

- **Fixed-price sale ID.** `openSale` returns it. It was 1 in simulation on both
  instances, and it stays 1 if nobody opens another fixed-price sale first.
- **Anti-snipe timing.** A real anti-snipe bid needs a bid in the last 15 minutes of an
  auction. After 20:46:12 UTC on r2, and after 19:56:36 on r1, no auction in this
  package is live. The simulated row then stands, and a later package would need a new
  24-hour auction.

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
