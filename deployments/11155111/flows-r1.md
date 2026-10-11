# Sepolia r1: the v1 flows and their gas under Glamsterdam

On 11 October 2026 the v1 flows were run on the Sepolia rehearsal r1 deployment
([README](README.md), record [`1791746472.json`](1791746472.json)). Sepolia has run
Glamsterdam since 6 October 2026, and Glamsterdam reprices state creation. Every
budget in ADR 0001, ADR 0003 and the gas reports was measured with Prague costs in
Foundry. This file records what the flows cost on Sepolia now.

This is a testnet rehearsal with throwaway keys. The code is pre-audit. r1 was deployed
from `main` at `60edd9b`, so it does not include the Editions gas cuts
([#41](https://github.com/6529-Collections/6529-works/pull/41)) or the contested-override
recovery work. That matters for the Editions rows below.

## Summary

- **Every flow ran on the real stack.** This covers the content uploads and base64
  attestation, a curated package with its approval, the CURATOR evidence statement and
  the artist's acceptance, and eight auction starts, including `startWithBid` and a
  VRF work with a real Chainlink fulfilment. It also covers bids, outbid credits and
  their claim, opening and syncing records, `tokenURI`, and a 6529 consolidation with
  `refreshStanding`. Nothing reverted.
- **Transactions that create state cost 2 to 7 times their Prague gas.** A new storage
  slot costs about 89,000 gas more than on Prague, and a byte of contract code about
  1,330 more.
- **The `start` budget breaks.** The steady-state `start` costs **846,983** gas against
  the 350K budget, and `startWithBid` costs **982,312**. The same transactions cost
  293K and 335K on Prague. A steady-state start writes 6 new slots, which account for
  about 533K of the difference.
- **On-chain storage costs about 7 times more.** It is about 1,548 gas per byte
  (Prague: 218). 1 MiB costs about 1.65 ETH at 1 gwei, against 0.24 ETH on Prague.
- **Reads are unchanged.** `tokenURI` and `royaltyInfo` cost the same as on Prague,
  or slightly less. The `tokenURI` budget holds.
- **Settlement and editions have not been broadcast yet.** The 24-hour auctions end on
  12 October 2026, from 19:54 UTC. Until then, `settle`, `createEdition`, `openSale`
  and the mints were measured by simulation on the live state at a later timestamp
  (see Method). The commands to run them are under Pending.

## Method

- **Driver.** [`script/sepolia/FlowsR1.s.sol`](../../script/sepolia/FlowsR1.s.sol)
  encodes every call and reads every EIP-712 digest from the contract that checks it.
  [`script/sepolia/flows-r1.ps1`](../../script/sepolia/flows-r1.ps1) signs the
  digests, checks that each signature recovers to the expected signer, and sends each
  transaction with `cast send`.
  - Each gas limit therefore came from the node's `eth_estimateGas`, which applies
    Glamsterdam.
  - The priority fee was 0.05 gwei.
  - The 24 KB chunk went through `forge script --skip-simulation`, because its
    calldata is longer than a Windows command line.
- **Sepolia gas** is the receipt's `gasUsed`.
- **Prague gas** is the same transaction replayed on its parent block's state with
  Prague costs: `cast run <tx> --quick --evm-version prague` (Foundry 1.7.1). An anvil
  fork of the parent block with `--hardfork prague` gives the same gas for 26 of the 27
  rows checked. The exception is the `refreshStanding` that changes nothing: 76,478
  here, against 86,653 on anvil, which replayed it with a 30M gas limit.
- **New slots** are the storage slots the transaction writes from zero. They are
  counted from anvil's `prestateTracer` diff of the Prague replay.
- **Simulated rows** are calls run on the live state with `eth_simulateV1` (reth),
  in blocks with later timestamps. Their Prague numbers come from the same calls sent
  on an anvil Prague fork of the same block.
  - The simulation reproduced a mined transaction's receipt exactly (577,375 gas for
    `registerManifest`).
  - It is still a simulation. The rows are replaced by receipts once the transactions
    are sent.
- **Views** are measured as the gas a call uses: `eth_simulateV1` for Sepolia, and a
  transaction on the anvil Prague fork.
- **Repo gas report** is `forge test --match-contract IntegrationGasReport -vv` at
  `60edd9b`, the r1 source. It is what the budgets were set against. It does not
  deduct refunds, and it uses its own package. That is why its steady-state
  `start` is 275,730 where the Prague replay of the r1 transaction is 293,263.

**Accounts.**
- The operator (`0x26A3…3697`, no role) relayed the permissionless calls and funded
  the other accounts.
- The platform key and the curator key acted for their roles.
- Curation signer 1 and the artist key (`0x111C…Ae1B`) signed off-chain.
- Three throwaway keys made for this run: bidder 1 (`0x1fb4…2BE2`), bidder 2
  (`0x7B41…9C74`) and the artist's second wallet (`0x5817…5F6B`).
- The run used 0.079 ETH from the operator: 0.075 ETH of funding and 0.004 ETH of gas.

**What was created.**
- Collections 1 (`r1 Flows`) and 2 (`r1 Flows 2`).
- Package root `0xde416feb…e68d`, which has eight items by the artist.
- Stream tokens 1 to 8, all in live 24-hour auctions. Their items and current bids:

| Token | Item | State |
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

| Operation | Sepolia | Prague | Ratio | New slots |
| --- | ---: | ---: | ---: | ---: |
| [`writeChunk`, 1,024 bytes](https://sepolia.etherscan.io/tx/0xa83a50bdc2671278315dc6c04cce3fce1b712ba98033d3725fc3a037fe9021d1) | 1,914,322 | 304,754 | 6.28 | 1 and a contract |
| [`writeChunk`, 8,192 bytes](https://sepolia.etherscan.io/tx/0x504531e2842f3a94b42d039b4bceb86671b39bc194472756deffa6ecc098de18) | 13,008,576 | 1,864,224 | 6.98 | 1 and a contract |
| [`writeChunk`, 24,572 bytes](https://sepolia.etherscan.io/tx/0x384cf4410838dbd8ff9d39eb2d0ab37d9ce9e27c79dd013cdb700656bb2cf65d) | 38,364,370 | 5,431,552 | 7.06 | 1 and a contract |
| [`registerManifest`, one chunk](https://sepolia.etherscan.io/tx/0xc3f901893d2996a40df22a42902bf32e5ba6b69109fc32872d2a89be11e0fd25) | 577,375 | 143,475 | 4.02 | 5 |
| [`attestBase64`, 1,024 bytes](https://sepolia.etherscan.io/tx/0xb8bba0f8a06dcf5b45b968c575d5bd6de7f338761b623b2273ff4d3c3e4d92da) | 153,123 | 70,103 | 2.18 | 1 |
| [`attestBase64`, 8,192 bytes](https://sepolia.etherscan.io/tx/0x0e844e0c16e0de8a5b2f0138f115abd0c3235c819752d54f56b3c20302d20c8f) | 205,248 | 122,228 | 1.68 | 1 |
| [`attestBase64`, 24,572 bytes](https://sepolia.etherscan.io/tx/0x9036e3d6496e8379b429d01d9871171e052c1832a4768cf56e2f5c5c9ec750f2) | 325,172 | 242,152 | 1.34 | 1 |
| [`writeChunk`, a 191-byte record](https://sepolia.etherscan.io/tx/0x80123bc9aed418a59a60d33812a3cd6bbbcbe4073adcb141a1f150d82723c436) | 625,103 | 123,587 | 5.06 | 1 and a contract |
| [`registerManifest`, that record](https://sepolia.etherscan.io/tx/0x9360135af2bf3fd7d1e0d6b31a2b6456ab7a1d6fd06e618984135b89fae3c3f4) | 579,897 | 145,997 | 3.97 | 5 |

The eight records and five registered-only media manifests cost the same as these rows
(625,103 and about 577,000 to 580,000 each).

**Per byte.** A line through the three chunks fits each one within 0.03%:
- Sepolia: `writeChunk(n)` ≈ 328,760 + 1,547.9 × n gas.
- Prague: ≈ 81,303 + 217.7 × n gas.

A full chunk of 24,575 bytes costs about 38.4M gas: 1,561 per byte with the fixed
part. `attestBase64` only reads, so its per-byte cost is about the same as on Prague.
What changed is the new slot that records the attestation.

**Manifests by size** (from `eth_estimateGas`; nothing was uploaded): about 111,500 gas
per extra chunk hash.

| Chunks | Sepolia |
| ---: | ---: |
| 1 | 583,137 |
| 11 (256 KiB) | 1,698,112 |
| 43 (1 MiB) | 5,265,859 |
| 256 | 28,784,463 (simulated `gasUsed`) |
| 512 (the cap) | about 57.6M. The public RPC caps estimates and simulations at 50M, so it cannot measure this. |

**What a work costs to store on-chain** (upload, manifest and attestation; base fee
ignored):

| File | Sepolia gas | at 1 gwei | at 10 gwei | Prague gas | at 1 gwei |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256 KiB (11 chunks) | about 413M | 0.41 ETH | 4.1 ETH | about 60M | 0.06 ETH |
| 1 MiB (43 chunks) | about 1,650M | 1.65 ETH | 16.5 ETH | about 241M | 0.24 ETH |

The upload is about 99% of each figure. The attestation is interpolated from the three
measured files: about 2.1M gas for 256 KiB and 7.8M for 1 MiB.

## 2. The curated Stream sale

Budgets are from ADR 0003 (the steady-state gate) and from the integration gas report's
test ceilings (the first start in a new collection, and `settle`).

| Operation | Sepolia | Prague | Ratio | New slots | Budget | Result |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| [`createCollection` (PLATFORM)](https://sepolia.etherscan.io/tx/0x9f12f25bd5c8941514cecb6c90301da2dc6a3ade36886c48633f88c60a937991) | 378,158 | 112,598 | 3.36 | 3 | | |
| [`registerPackage` (curation signer 1's approval)](https://sepolia.etherscan.io/tx/0x2f44223f2d7a41675509c13ae31c2077aee1424ed092dae13858260510795d41) | 269,395 | 98,155 | 2.74 | 2 | | |
| [`appendCurator` (CURATOR evidence statement)](https://sepolia.etherscan.io/tx/0xd1785152fc93a23394154189f71d8d53180f190c07758a1ab15cfa12ce30126d) | 272,040 | 101,600 | 2.68 | 2 | | |
| [`acceptPackage`, first acceptance: registers the artist](https://sepolia.etherscan.io/tx/0x7d4beb14ac8a8e8609b3bbae292eec0e03b133d8c580fb1597da2ee0960797eb) | 957,595 | 257,035 | 3.73 | 8 | | |
| [`start`, first work ever](https://sepolia.etherscan.io/tx/0x7b0582f0b0134303b9a36c3adcbd0345c20b68390577ea27dcbb1d598895ea8a) | 1,604,870 | 442,310 | 3.63 | 13 | one-time, not gated (report: 437,334) | |
| [`start`, second work](https://sepolia.etherscan.io/tx/0xd9bd5fe54ab65c67c7f7dcc123c75fe964d9e2549fc779691c5b4c592d61ebd2) | 846,971 | 293,251 | 2.89 | 6 | 350,000 | **fail** |
| [`start`, steady state](https://sepolia.etherscan.io/tx/0x4eeebbb16e951397cfff3d00218dd35e0121461d384ec622adad46c1178965e5) | 846,983 | 293,263 | 2.89 | 6 | 350,000 (report: 275,730) | **fail** |
| [`start`, an edition master](https://sepolia.etherscan.io/tx/0x143de05853fcda8c44e086334809bbd7b9c8423ce0f828ff0e4d8c970e8ef029) | 847,598 | 293,878 | 2.88 | 6 | 350,000 | **fail** |
| [`start`, first work in a new collection](https://sepolia.etherscan.io/tx/0x47f367cb24bb4633eb75a665d31eae9b8b49aa1b940aa3a1945274a3ca53be9d) | 846,965 | 293,245 | 2.89 | 6 | 400,000 test ceiling (report: 275,756) | **fail** |
| [`start`, a VRF work](https://sepolia.etherscan.io/tx/0x1ea28624bdf5fc9482bd2ceda19cbcb5a18a4ebc27271a69e559545537b87cc1) | 852,856 | 298,736 | 2.85 | 6 | 350,000 | **fail** |
| [`startWithBid`, steady state](https://sepolia.etherscan.io/tx/0xe89a31cdbed285998931e1e6713ed3d6c821112264f60eb01bd68c739d650510) | 982,312 | 334,572 | 2.94 | 7 | 350,000 (report: 317,084) | **fail** |
| [`bid`, first bid under new sale terms (one-time)](https://sepolia.etherscan.io/tx/0xb646ae8b76a2e0ee4051a6ca26448a1a26215efe9882ae7e6779eef7605f1271) | 510,086 | 143,306 | 3.56 | 4 | one-time, not gated | |
| [`bid`, first bid on a sale](https://sepolia.etherscan.io/tx/0x25062f4d54350b0bfa079b8c5653d1b84c27c91488d2dbd2d1056a32152fc049) | 168,777 | 73,157 | 2.31 | 1 | | |
| [`bid`, outbids and credits the previous bidder](https://sepolia.etherscan.io/tx/0x0e1010d3dc7d1ebe05422a7c2455ba454d084513af8c4251447f7959cd8d15ed) | 168,944 | 73,324 | 2.30 | 1 | (report: 70,848) | |
| [`claim`, the outbid bidder's credit](https://sepolia.etherscan.io/tx/0xefe7f481a1630a9b185c87dc9320afc7a26d9165bce7d4e0099c40d65a591335) | 32,580 | 32,425 | 1.00 | 0 | | |
| `bid` in the last 5 minutes: the end moves 10 minutes later (simulated) | 179,366 | 76,546 | 2.34 | 1 | | |
| `settle`, with a bid, first payout to the seller (simulated) | 441,363 | 164,743 | 2.68 | 1 and an account | 400,000 test ceiling (report: 175,914) | **fail** |
| `settle`, with a bid (simulated) | 257,763 | 139,743 | 1.84 | 1 | 400,000 test ceiling | pass |
| `settle`, with a bid, the winner already holds a token (simulated) | 159,843 | 122,643 | 1.30 | 0 | 400,000 test ceiling | pass |
| `settle`, no bid: the token goes to the artist (simulated) | 335,817 | 135,577 | 2.48 | 2 | 400,000 test ceiling | pass |

- **Steady state.** The `start` rows from the second work on are all steady state:
  - the first start writes the custody balance, the fee recipient and the sale terms;
  - the artist's acceptance pre-writes the move-nonce word;
  - a new collection's counter word is written by `createCollection`, so a new
    collection's first start costs the same as any other.
- **The anti-snipe bid** was simulated at 5 minutes before token 1's end. It moved the
  end from 1,791,834,852 to 1,791,835,452, which is 15 minutes after the bid.
- **The first `settle` with a bid** pays the seller. The seller is the payee
  configuration's split wallet, at its predicted address: `0xa30f…c63d`, which is still
  empty. Sending ETH to an empty account creates it, and that costs about 184,000 gas
  more on Sepolia. This happens once per payee configuration.

## 3. 6529 Editions (simulated; r1 runs the Editions code from before #41)

`createEdition` needs the master's sale to be settled, so every row here was simulated.
The simulation settled master token 6, and tokens 1, 4 and 7, in a block dated
12 October 2026, 20:31:36 UTC. Then the edition was created, the PLATFORM opened a fixed-price sale with one public
phase, and buyers bought copies at the package price.

| Operation | Sepolia | Prague | Ratio | New slots |
| --- | ---: | ---: | ---: | ---: |
| `createEdition` | 1,133,867 | 338,987 | 3.34 | 9 |
| `openSale` (PLATFORM, one public phase, no artist consent) | 993,668 | 286,608 | 3.47 | 8 |
| `purchase`: mints the first copy (new holder) | 476,183 | 204,623 | 2.33 | 3 |
| `purchase`: a later copy (new holder) | 378,239 | 187,499 | 2.02 | 2 |
| `purchase`: two copies (existing holder) | 182,423 | 153,323 | 1.19 | 0 |

Neither ADR 0001 nor ADR 0003 sets a budget for these operations.

On `main`, after #41, the Editions gas report on Prague gives:
- `createEdition`: 322,317 (the r1 transaction replays at 338,987);
- the mint itself: 103,761 for the first copy and 84,149 for a later one.

#41 cuts execution, but each new slot still adds about 89,000 on Glamsterdam. A
later rehearsal should measure it.

## 4. `tokenURI` and other views

Each row is the gas the call uses as a transaction on the r1 state at block 11,893,969.

| Call | Sepolia | Prague | Output |
| --- | ---: | ---: | ---: |
| `tokenURI(1)`: 1,024 bytes of attested base64, inlined | 311,784 | 312,384 | 1,824 bytes |
| `tokenURI(2)`: 8,192 bytes, inlined | 330,815 | 331,415 | 8,992 bytes |
| `tokenURI(5)`: 24,572 bytes, inlined | 390,705 | 391,305 | 25,376 bytes |
| `tokenURI(3)`: record open, media registered only | 295,157 | 296,857 | 768 bytes |
| `tokenURI(4)`: record not open (core-only metadata) | 119,172 | 122,972 | 384 bytes |
| `tokenURI(8)`: VRF work, record not open, seed shown | 155,746 | 158,946 | 480 bytes |
| `royaltyInfo(1, 1 ETH)` | 40,667 | 46,267 | |

- **Reads are not repriced.** Each row is within 2% of Prague, a few hundred to a few
  thousand gas lower. The 8M `tokenURI` budget passes.
  - These rows reach 0.39M.
  - The repo's matrix (2.69M for 256 KiB of base64) and the renderer's 7.8M worst
    case are views too. They carry over unchanged.
- **Estimates are higher than use.** `eth_estimateGas` returns about 1.0M for each
  inlined `tokenURI` on both rule sets. The renderer's bounded reads require
  `gasleft()` to cover their caps (300,000 and 700,000 gas) before they call. A
  caller must therefore supply about 1M even though the call uses about 0.3M. This
  is by design, and it is well within what `eth_call` allows.

## 5. Identity

The artist and wallet 2 registered a use-case-999 consolidation of each other on the
real 6529 delegation contract. The collection was all collections (`0x8888…8888`), with
`allTokens` set. Anyone then called `ArtistRegistry.refreshStanding`.

| Operation | Sepolia | Prague | Ratio | New slots |
| --- | ---: | ---: | ---: | ---: |
| [`registerDelegationAddress`, artist to wallet 2](https://sepolia.etherscan.io/tx/0xfc78300958f918120e84cde2321b01010e9e9ac2d82405e7df5e657a1de6c8da) | 1,134,947 | 261,047 | 4.35 | 10 |
| [`registerDelegationAddress`, wallet 2 to artist](https://sepolia.etherscan.io/tx/0x19956e6f633c3b217644f258f0dafcb835a77d194f07b861a49713daaa5218f6) | 1,134,947 | 261,047 | 4.35 | 10 |
| [`refreshStanding`: records wallet 2 as pending](https://sepolia.etherscan.io/tx/0xdf1b2f11489fe98bd84147e0303171293d5efee24f932a1e15a65dbeeaa8dd7e) | 299,112 | 127,872 | 2.34 | 2 |
| [`refreshStanding`: nothing changed](https://sepolia.etherscan.io/tx/0x931fc2d32ac8a7ce1bd4ffcaf691368bcaef0c237166672fb4e66a35aeb79da3) | 81,853 | 76,478 | 1.07 | 0 |

- **The recorded entry.** `standingOf` now lists wallet 2 with
  `effectiveAt` = 1,794,340,656, which is the registration time plus 30 days.
- **Stipends.** The adapter's 50,000-gas stipend per delegation-contract getter was
  enough: reads are not repriced.
- **Who pays.** ADR 0003 has artists pay for their own refreshes. Each consolidation
  now costs about 1.13M gas per direction on the delegation contract, outside this
  protocol.

## 6. VRF

| Operation | Sepolia | Prague | Ratio | New slots |
| --- | ---: | ---: | ---: | ---: |
| [`requestSeed`](https://sepolia.etherscan.io/tx/0xaf97ba7d6a6db9ce5e6eaa70dc3b0208aea5b9a07a8e42bdd54748b6d5c361a9) | 525,029 | 171,149 | 3.07 | 4 |
| [Chainlink's fulfilment](https://sepolia.etherscan.io/tx/0xfdcfb71aa8726295857b4eebe366b57fa0a6469d58ef4ad943932ff97b0922d1) | 246,799 | 127,098 | 1.94 | |
| [`start` of the VRF work](https://sepolia.etherscan.io/tx/0x1ea28624bdf5fc9482bd2ceda19cbcb5a18a4ebc27271a69e559545537b87cc1) | 852,856 | 298,736 | 2.85 | 6 |

- **Delivery.** The real coordinator delivered the seed five blocks after the request
  (block 11,893,939 to 11,893,944), from the dedicated subscription. The seed is
  `0xa593589f…e110`.
- **Callback gas.** The callback writes one new slot. Under Prague its frame used
  34,213 gas. Simulated on the block before the fulfilment, the callback on its own
  cost 145,701 gas on Sepolia and 56,581 on Prague. The callback therefore used about
  123,000 of its 200,000 limit, or 62%. It fits, with about 77,000 to spare.

## 7. Records and transfers

| Operation | Sepolia | Prague | Ratio | New slots |
| --- | ---: | ---: | ---: | ---: |
| [`openRecord`](https://sepolia.etherscan.io/tx/0xf9370976e664990715e9542db9e21a20766e4fb331629d0eb0ff399546b728ef) | 505,752 | 159,172 | 3.18 | 4 |
| [`syncOnChain`](https://sepolia.etherscan.io/tx/0x67ccfad8934453687681896de637b3ac44079481af07b5cfe061ce088599678f) | 58,821 | 56,121 | 1.05 | 0 |
| [ETH transfer to an empty account](https://sepolia.etherscan.io/tx/0xb9a7e27a0878f34f7e37a5926d7b388d48e9c57c012786e056b421fa8073545a) | 204,600 | 21,000 | 9.74 | an account |
| [ETH transfer to an existing account](https://sepolia.etherscan.io/tx/0x8bcda1443b73fbbf7fdc4a5953375afa4d66215468c055cbe9d258336922b7f7) | 21,000 | 21,000 | 1.00 | |

## Budgets under Glamsterdam

| Budget | Where | Sepolia | Result |
| --- | --- | --- | --- |
| `start` ≤ 350K at steady state, one artist | ADR 0003 (CI gate), AGENTS.md | 846,983 | **breaks (2.4 times over)** |
| `startWithBid` ≤ 350K at steady state, one artist | ADR 0003 | 982,312 | **breaks (2.8 times over)** |
| `start` ≤ 300K | ADR 0001 (superseded by ADR 0003) | 846,983 | breaks |
| First start in a new collection ≤ 400K | `GasReport.t.sol` ceiling | 846,965 | **breaks** |
| `settle` ≤ 400K | `GasReport.t.sol` ceiling | 441,363 for the first payout to a new seller (simulated); 160K to 336K otherwise | **breaks once per payee configuration** |
| `tokenURI` ≤ 8M | ADR 0001, ADR 0003, AGENTS.md | at most 0.39M measured; views are not repriced | holds |
| `royaltyInfo`: one external view, about 25K | ADR 0003 | 40,667 for the whole call | holds |
| Every transaction ≤ 16,777,216 gas for worst-case bounded inputs | AGENTS.md, ADR 0003, content README | Sepolia accepts transactions above the cap for state gas. One full chunk is about 38.4M and a 256-chunk manifest 28.8M; a 512-chunk manifest is about 57.6M | **no longer holds as written** |
| Two full chunks per Multicall3 transaction, at about two thirds of the cap | content README | about 76.7M | **guidance obsolete** |
| Upload cost about 0.23 ETH per MB per gwei | content README | about 1.65 ETH per MiB per gwei | **changes about 7 times** |
| `registerManifest` for 1 MB about 1.05M | content README | 5.27M | **changes** |
| VRF callback gas limit 200,000 | r1 genesis (ADR 0003 entropy) | about 123,000 used | holds, 62% used |
| Delegation-contract getters within a 50,000-gas stipend | identity README | `refreshStanding` succeeds; reads not repriced | holds |
| A federated factory deploy at about 4–5M gas per contract | ADR 0001 §16 (v1.1) | not measured; r1's creations cost 6.0 to 6.6 times their Prague gas | likely about 25–30M |

## Where the gas goes

A steady-state `start` writes six new slots:
- Stream, four:
  - the three words of the token record (`TokenData`: seller, serial and flags; the
    artist ID and economics; the item hash);
  - the ERC-721 owner.
- PackageRegistry, one: the consumed-content record, which is also the uniqueness
  record.
- EnglishAuction, one: the sale.

Each new slot costs about 89,000 more than on Prague, so the six cost about 533,000 of
the 553,720 difference. `startWithBid` adds the bid's slot. The other rows follow the
same rule; the new-slot column explains most of each ratio.

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
2. **Optional design work to cut new slots. Each slot saved is about 89K per start.**
   - Stream writes four words per token. Its economics fields (royalty rate, fee share,
     fee recipient, minter) could become a deduplicated terms ID, the way the auction
     already stores its terms. The ERC-721 owner could then share a word with what
     remains.
   - Four words down to three would bring a steady-state `start` to about 760K.
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

No contract bug was found. Every call behaved as its tests describe. Two behaviors are
worth knowing:
- the first payout to a predicted split-wallet address creates that account;
- `tokenURI` needs about 1M gas supplied for about 0.3M used.

## Pending

**Real settlement and editions.** Settlement can run after the auctions end, from
12 October 2026, 19:54:12 UTC (token 1) to 19:56:36 UTC (token 8). Run these from
the repository root. `<module>` is the operator's signer module (see the script
header), and `<state>` is the run's state file. Each step records the receipt, and
`prague` adds the replayed Prague gas:

```powershell
function Flow {
    powershell -NoProfile -ExecutionPolicy Bypass -File script/sepolia/flows-r1.ps1 `
        -SignerModule '<module>' -State '<state>' @args
}
foreach ($t in 6, 4, 1, 7, 2, 3, 5, 8) { Flow -Step settle -TokenId $t }
Flow -Step createEdition -TokenId 6
Flow -Step openSale -TokenId 6
Flow -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 1
Flow -Step purchase -SaleId 1 -Bidder bidder2 -Quantity 1
Flow -Step purchase -SaleId 1 -Bidder bidder1 -Quantity 2
Flow -Step prague
Flow -Step report
```

- **Fixed-price sale ID.** `openSale` returns it. It was 1 in simulation, and it
  stays 1 if nobody opens another fixed-price sale first.
- **Anti-snipe.** A real anti-snipe bid needs a bid in the last 15 minutes of an
  auction. A bid on token 2, 3, 5, 7 or 8 in the 15 minutes before its end measures
  it. Those auctions end between 19:54 and 19:57 UTC on 12 October:
  `Flow -Step bid -TokenId <id> -Bidder bidder1 -Amount 1000000000000000`.

**Needs a scheduled operation (not done).**
- **A shorter auction.** `EnglishAuction.setConfig` is PARAMETER_SETTER (48 hours).
  PLATFORM cannot shorten an auction.
- **A higher VRF callback limit.** `VrfEntropyModule.setConfig` is PARAMETER_SETTER.
- **The UNPAUSER, upheld-dispute `cancel`, relicense, re-rate and repin paths.** Each
  is delayed 48 hours to 30 days.

**Not run in this pass.**
- the Dutch sale;
- Permit2 and ERC-20 payments;
- `finalize`;
- a STANDARD identity change (it needs a 7-day wait);
- the guardian `pause` and `cancel` (Safe operations).
