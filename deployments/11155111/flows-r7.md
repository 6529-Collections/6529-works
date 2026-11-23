# Sepolia r7: the flows on the clean reference instance (23 November 2026)

On 23 November 2026 the flows below ran on **r7**
([README](README.md#sepolia-r7-23-november-2026-clean-reference-instance)), the second Sepolia
instance of the plain permanent core ([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)),
`main` at `5de6abaa`, record [`core-1795423896.json`](core-1795423896.json). r6's flows are in
[flows-r6.md](flows-r6.md); r7 ran the basics once and then the flows r6 did not run. Nothing
here changed r7's governance: no module was announced, no setting, role or minter changed, and
`script/VerifyCore.s.sol` passed at the chain's head after the last transaction below.

This is a testnet rehearsal with throwaway keys, and the code is pre-audit. The figures are
Sepolia receipts: Sepolia reprices state creation (Glamsterdam), so they are not the Prague
figures the gas budgets are written in. The last table gives both: the Sepolia receipt and the
same transaction replayed on its parent block's state at Prague prices (`flows.ps1 -Step
prague`, which runs `cast run --quick --evm-version prague`).
[ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) compares each start
with its own row and ceiling.

Every transaction was planned by [`script/sepolia/Flows.s.sol`](../../script/sepolia/Flows.s.sol)
against the live chain and sent by [`script/sepolia/flows.ps1`](../../script/sepolia/flows.ps1)
with `cast send`, except those marked `keeper.py`, which the reference keeper
([`keeper/keeper.py`](../../keeper/README.md)) decided and sent itself with the keeper key. The
state file is [`flows/r7.json`](flows/r7.json). Accounts: `any` is the keeper key (no role);
`platform`, `curator`, `pauser`, `artist`, its consolidated wallet `wallet2`, `wallet3` and the
four bidders are the throwaway keys of r5 and r6, and calls of the network go through its Safe
with two owner signatures.

## What ran

**Genesis.** The network Safe accepted ([`0xa56bfbfa…`](https://sepolia.etherscan.io/tx/0xa56bfbfa73a2ed1048788ccfac688b7aecabf3d85012dc5a93a0929a3359fc7b)); the deployer added r7's entropy
module to the VRF subscription ([`0xef544f17…`](https://sepolia.etherscan.io/tx/0xef544f1730f6db341be954ddf2897464eca593fd9b412a34249f9cae780548a3)).

**Content, collections, package.** 36 uploads to `ContentStore`, as on r6; the platform key
created two collections; the package of ten works was registered with curation signer 1's
approval ([`0x96a3818a…`](https://sepolia.etherscan.io/tx/0x96a3818a6a67897a9e85fd46dcbd79ec30e7bd7fcf0c1e740f4bd315e074fc95)), the curator appended the evidence statement
([`0x99aef3b8…`](https://sepolia.etherscan.io/tx/0x99aef3b8d12f2ad8cc5721c1de619162b9352a7b3b4b91b0597f4275d3cca13b)) and the artist accepted, which created its account ([`0x1a3d895d…`](https://sepolia.etherscan.io/tx/0x1a3d895dda806da9b30c959935027d7845c4c31d672dd05a40df7fd65e619e23)).

**The starts, one per gas row.** Anyone may send a start; the keeper key sent these.

| Start | Token | Transaction | Gas on Sepolia | Replay at Prague prices |
| --- | ---: | --- | ---: | ---: |
| `start`, the deployment's first | 1 | [`0xb377f4ed…`](https://sepolia.etherscan.io/tx/0xb377f4ed0f0d7a63f255209f416c18e247d781b7ae1c3ddda73cc5d2291a9734) | 1,159,577 | 355,897 |
| `startWithBid`, the auction's first bid (bidder 1, 0.05 ETH) | 2 | [`0x3ccf0557…`](https://sepolia.etherscan.io/tx/0x3ccf05576943e60e2833caf6ff7730cbaa6ac0b30253a399a04bb67109716dce) | 1,087,971 | 351,911 |
| `start`, steady state | 3 | [`0x2ebef972…`](https://sepolia.etherscan.io/tx/0x2ebef972fa182740e0f5200ebcabf5bd37231e77aeb6fbc0d105d61dc3741a9d) | 963,757 | 321,717 |
| `startWithBid`, steady state (bidder 2, 0.05 ETH) | 4 | [`0xddccbf4e…`](https://sepolia.etherscan.io/tx/0xddccbf4ed74652491cf62175fc27f180fa238129d0df119a9777504049b1c04b) | 1,087,996 | 351,936 |
| `start`, the move signed by the artist's consolidated wallet | 5 | [`0x11233120…`](https://sepolia.etherscan.io/tx/0x11233120001342d2da2b27a5e5920520b3bd537b6d32dd98fcf4b1f031005360) | 1,011,745 | 368,905 |
| `start`, first work in a second collection | 6 | [`0xf34c2707…`](https://sepolia.etherscan.io/tx/0xf34c270720ecf32304930d60db47789edef8d2371a8149df9d65c91db63a5b89) | 963,747 | 321,707 |
| `SaleStarter.start`, an edition master, the artist's first (deploys both vaults); sent by the keeper | 7 | [`0x2045fdfb…`](https://sepolia.etherscan.io/tx/0x2045fdfbe90e83a17d15bb7166bedc52f919162becac182cb0c749ed2748f958) | 2,565,997 | 715,901 |
| `SaleStarter.start`, the capped edition master; sent by the keeper | 8 | [`0x32c11bbf…`](https://sepolia.etherscan.io/tx/0x32c11bbf3d1b8f2a3c33aa4c2b440289f0da66981745fa7edc4e21f5f22393fa) | 1,745,955 | 574,695 |
| `SaleStarter.start`, the edition master later disputed; sent by the keeper | 9 | [`0xd25a0ee2…`](https://sepolia.etherscan.io/tx/0xd25a0ee2b0d8c8b161ccebfa4d58907deb565fa2e41c9b6d9219612eb6090567) | 1,745,950 | 574,690 |
| `startWithBid`, the VRF work (bidder 3, 0.05 ETH) | 10 | [`0xedd3c2e3…`](https://sepolia.etherscan.io/tx/0xedd3c2e3f4f7934950257a8f734f8d304b399d2e25bff6a12ccc7e035f9ba51c) | 1,209,264 | 384,884 |

**A consolidated wallet's move (token 5).** The artist's account is its root wallet and every
wallet consolidated with it on the 6529 delegation contract (the two-way consolidation r5
registered there is shared by every instance). Item 1's move was signed by the consolidated
wallet, not the root, and the start passed ([`0x11233120…`](https://sepolia.etherscan.io/tx/0x11233120001342d2da2b27a5e5920520b3bd537b6d32dd98fcf4b1f031005360)).

**A curated 1/1 with a competing bid (token 1).** Bidder 1 bid 0.05 ETH ([`0x2eab01bf…`](https://sepolia.etherscan.io/tx/0x2eab01bf4f6a8d60f22ac33f99ca84d6b7e81bd999597adbfcdccc688dcfb25c));
bidder 2 outbid it at 0.0525 ETH ([`0xa7e0663c…`](https://sepolia.etherscan.io/tx/0xa7e0663cc2e6f4f6439e1cf88c8dcc82ac176895b590667f93a1878eddce2553)), which credited bidder 1's 0.05 ETH,
and bidder 1 claimed the refund ([`0xcfdad4b6…`](https://sepolia.etherscan.io/tx/0xcfdad4b67b99a1439d8699eb03e0f3c2e51e653d211c62692a34aa61e65b2f68)). The record was opened in
`StreamWorkFacts6529` ([`0x02f8815d…`](https://sepolia.etherscan.io/tx/0x02f8815d6aa09c1ba2385f0c2ee28c4b0e1e11bb7647748b2fc0a8e64f96de0a)). After the hour the keeper settled it
([`0xf2385eb1…`](https://sepolia.etherscan.io/tx/0xf2385eb1cfb185822bdb2b64ae448fc5219f2ac6c06106a3a04bdce9955e509d)): `ownerOf(1)` is bidder 2. The keeper marked its media complete on
chain ([`0xda962d7c…`](https://sepolia.etherscan.io/tx/0xda962d7c1a3fc193982f4872b00dc070a8e847af554b3ee7fe85c17c250f3b6a)) and the artist finalized the record
([`0x2a72d9cc…`](https://sepolia.etherscan.io/tx/0x2a72d9ccdea1da84f7b6fa1349bda0d393029fc3cdf1106a098fe7e83e2db0d4)), which pinned the genesis renderer. `tokenURI(1)` then answered
1,734 bytes, with the stored image inline.

**The reference keeper.** `keeper.py` ran with the keeper key and sent what it found due,
nothing else:
- from three request files (`flows.ps1 -Step starterRequest`), the three edition masters'
  starts through `SaleStarter` (tokens 7, 8 and 9, above);
- the edition sale beside each of them ([`0x0e5a71ba…`](https://sepolia.etherscan.io/tx/0x0e5a71bae0896d938cfe300f891a17d5de2dc4e5c3b7bd0fa507001aea93e63d), [`0xac6ea3b6…`](https://sepolia.etherscan.io/tx/0xac6ea3b63475cca4e532ff5e521d85abbe83d352db161de9fd4db22d66ac9007),
  [`0x79e90641…`](https://sepolia.etherscan.io/tx/0x79e906413024bf2867f21005cef9c6a2efcb3fd1d30e462b8b93275dc902656b));
- the voided edition sale of the cancelled token 9 ([`0x516a7e65…`](https://sepolia.etherscan.io/tx/0x516a7e65268681c791a5a0e56e9c501b0a564fba02e629bd13df4d52e35693a9));
- every 1/1 settlement once its hour had passed: tokens 1, 2, 4, 5, 6, 7 and 8 in one run ([`0xf2385eb1…`](https://sepolia.etherscan.io/tx/0xf2385eb1cfb185822bdb2b64ae448fc5219f2ac6c06106a3a04bdce9955e509d), [`0x72a4c083…`](https://sepolia.etherscan.io/tx/0x72a4c083d003c53e0a56adb93af4062b17a076a7b81362df4b9da5cc3788ed85), [`0xb47e53b6…`](https://sepolia.etherscan.io/tx/0xb47e53b6d077f51c8c4b094db28c503271c86238b2ae4fbc98abdbf28664044c), [`0x168cc4eb…`](https://sepolia.etherscan.io/tx/0x168cc4eb63834c7153506b527c524820da654da9ca1446032dfa52c28dae2350), [`0xe081a9c9…`](https://sepolia.etherscan.io/tx/0xe081a9c9bfb03642bc354b92291ee21b36b1cfd561ff506e0ffe7dc8f5bba63c), [`0xe6d7095b…`](https://sepolia.etherscan.io/tx/0xe6d7095b31f9e116ca1a2bdfb093c66926a1982084ffa738cbafa75b4c84744f), [`0x790fbcee…`](https://sepolia.etherscan.io/tx/0x790fbceea49264fa1c95884c3881c8e8790329d5c8af44e5e7555e5b44da6152)), then token 3, the Independent Stream 1/1 and token 10 in a later one ([`0x7429bf35…`](https://sepolia.etherscan.io/tx/0x7429bf3574c7ab19ed3ee53fd37870e8762e4aba01df1dad486e809b6cb27e6d), [`0x67eea6a5…`](https://sepolia.etherscan.io/tx/0x67eea6a52055ed067c682ceeac6cdcafe79ed39f1ad2559598aac48061871296), [`0xe10a16b8…`](https://sepolia.etherscan.io/tx/0xe10a16b894f7cf7d6f1bcf270fc119d52942ac6a4e41bc2b5cbb31cd97cb693d)). Tokens 5, 6 and 8 had no bid and went to the museum vault;
- the two edition settlements ([`0xa3e93660…`](https://sepolia.etherscan.io/tx/0xa3e93660deb8ce31eb741650e180aaa4778ac386d5241464f05a71c6efe0d1f7), [`0xd1449a6b…`](https://sepolia.etherscan.io/tx/0xd1449a6bea7db07ab8ea557447146a49f3471d53e74baaa3309ce61f2213de7f));
- token 1's media marked complete on chain ([`0xda962d7c…`](https://sepolia.etherscan.io/tx/0xda962d7c1a3fc193982f4872b00dc070a8e847af554b3ee7fe85c17c250f3b6a)); it skipped the three masters, whose media files are registered but not stored.

Its last run found nothing due.

**A dispute: pause, withdrawal, cancel (token 9).** Bidder 4 bid 0.05 ETH on the 1/1
([`0x5d63e663…`](https://sepolia.etherscan.io/tx/0x5d63e66331aa8c527172a02583cf33133c746a1e8feb98d731f3b51753220c89)) and bidder 3 bid for one copy in the edition sale beside it
([`0xa457e277…`](https://sepolia.etherscan.io/tx/0xa457e2772cbc0adf2e0d7817437cfe2ee9a5c7e6359e48677f0498587d34fb67)). A pauser key paused the 1/1 for a dispute
([`0x9cd8492a…`](https://sepolia.etherscan.io/tx/0x9cd8492ad4f2a78edab583c66a9b75157d1832efcd363e41fd59cfc6f0728b8a)): its state became PAUSED. While it was paused, bidder 4 withdrew its
bid ([`0x0fc1f08e…`](https://sepolia.etherscan.io/tx/0x0fc1f08e9f64fe2f3dd8109d29d199ae05aa6e78a638407782ab43b4f6986f93)), which credited the 0.05 ETH back; the sale kept the
amount as its reserve, with no bidder. The platform recorded the dispute's outcome in the
statement log ([`0x9a0c22f8…`](https://sepolia.etherscan.io/tx/0x9a0c22f8365cdeffebd22bb965fa90cfea2cfcb1633afc46ac3cee3a360ec27c)) and the network Safe cancelled the sale citing it
([`0x7c3430d9…`](https://sepolia.etherscan.io/tx/0x7c3430d9f99cc2a947f90916bb6000e419bde6b534ca753ffcfd3a9221396cf7), Safe nonce 8, no delay): the 1/1's state became CANCELLED. The
edition sale read the cancelled 1/1, and the keeper's next run settled it as void
([`0x516a7e65…`](https://sepolia.etherscan.io/tx/0x516a7e65268681c791a5a0e56e9c501b0a564fba02e629bd13df4d52e35693a9)); bidder 3 claimed its whole escrow back
([`0x0d3d765e…`](https://sepolia.etherscan.io/tx/0x0d3d765e2f936a43b1542ee350f01f9c42ced431ded4106b33ba7d7f0313187c)) and bidder 4 claimed its credit
([`0xb6b5c9f9…`](https://sepolia.etherscan.io/tx/0xb6b5c9f9dc4cc93a228a0fa0226f04316b2258bfcf32aac290e69bd03fe0113a)). A cancel is an action on one sale: it is
not a governance change, and `VerifyCore` passed afterwards.

**The anti-snipe extension (token 3).** Token 3 had no bid and was due to end at
10:11:12 UTC. Bidder 2 bid 0.05 ETH at 10:03:48 UTC ([`0x67de4cb9…`](https://sepolia.etherscan.io/tx/0x67de4cb9c4693f92e77d8c914467e9d11c5c19de2711f70ec522aa1fa9ddc4d7)), inside the
last 15 minutes, and the end moved to 10:18:48 UTC, 15 minutes after the bid. The
keeper settled it after the new end ([`0x7429bf35…`](https://sepolia.etherscan.io/tx/0x7429bf3574c7ab19ed3ee53fd37870e8762e4aba01df1dad486e809b6cb27e6d)).

**An edition master with its edition auction (token 7).** Bidder 3 bid 0.05 ETH on the 1/1
([`0x6ccb86ed…`](https://sepolia.etherscan.io/tx/0x6ccb86ed0ce46fef5691140d46312569096c48b857cf158922839f20b81af459)). Three edition bids followed: bidder 1, 2 copies at step 20; bidder 4, 3
copies at step 25; bidder 2, 1 copy at step 10. After the 1/1 settled and the edition closed,
the keeper settled the edition ([`0xa3e93660…`](https://sepolia.etherscan.io/tx/0xa3e93660deb8ce31eb741650e180aaa4778ac386d5241464f05a71c6efe0d1f7)): 5 copies cleared at step 20, 0.000261 ETH each (0.001305 ETH in all). Each bidder then claimed ([`0xe82fe23f…`](https://sepolia.etherscan.io/tx/0xe82fe23ffbbe5d42efcbdc6f7cb0b7eada9d9c103e8377c69f41796363217268), [`0x92c6af86…`](https://sepolia.etherscan.io/tx/0x92c6af86986b2d4080e05c99402247b3e8cf3b4c138c51995e331048050cba09), [`0x371cf668…`](https://sepolia.etherscan.io/tx/0x371cf668e569a0e3fed2894408e8d12100d29508bdf19673ab70453aa4c8010c)): bidder 1 received 2 copies, bidder 4 received 3 copies and the rest of its step-25 escrow, and bidder 2, below the clearing step, received its whole escrow back and no copy.

**A capped edition at the cut step (token 8, cap 3).** Four bids at step 10 asked for six
copies (bidder 1, 1; bidder 2, 2; bidder 3, 2; bidder 4, 1); bidder 1 then raised to step 20
([`0xf5fd1948…`](https://sepolia.etherscan.io/tx/0xf5fd1948886ca5c17ebca7f93bc9d27a3d190791eea72b596dbf5130d8eadb22)) and bidder 4 to step 15
([`0x7b503b94…`](https://sepolia.etherscan.io/tx/0x7b503b9432c2cf7394754f70bce983fc3b2e80476a2ed1641c5df620c9494dde)), which left two departures logged at step 10, the cut
step: three copies clear there, the two raised bids take one each and one copy is left for the
earliest bid still at step 10. The 1/1 had no bid and went to the museum vault ([`0x790fbcee…`](https://sepolia.etherscan.io/tx/0x790fbceea49264fa1c95884c3881c8e8790329d5c8af44e5e7555e5b44da6152)); the edition sale runs regardless. After the close, wallet 3 settled first with an order that skips departure 0 ([`0xc501130e…`](https://sepolia.etherscan.io/tx/0xc501130edf7747b06e5f66111cce6fc9fcb454b2844e7e1773136d38c72e880b)): the sale cleared and stayed SETTLING, and only wallet 3's own sweep was left unfinished. The keeper then settled with its own order ([`0xd1449a6b…`](https://sepolia.etherscan.io/tx/0xd1449a6bea7db07ab8ea557447146a49f3471d53e74baaa3309ce61f2213de7f)): SETTLED. Three copies sold at 0.000162 ETH each (0.000486 ETH): one each to bidders 1, 2 and 4, none to bidder 3. The keeper key pushed the claims of bids 1 and 2 ([`0x097baf51…`](https://sepolia.etherscan.io/tx/0x097baf511791ac2a7b464493674eda53d53c97891b892c1b23c38cac576a62de), [`0x33d35b13…`](https://sepolia.etherscan.io/tx/0x33d35b13a4175df0a479b9a13f87670c95b84d1bc79443cb6c78d63a9b344563)), which minted the copies and credited the refunds, and bidders 3 and 4 claimed their own ([`0xc941a340…`](https://sepolia.etherscan.io/tx/0xc941a34048c6068cc69b6e97ddb52b390873e62e245c5503a671a7f39a53a730), [`0xa6883689…`](https://sepolia.etherscan.io/tx/0xa6883689a632e788d8795efea03f0f95ede7a428499942e271aed8955da25240)); bidders 1 and 2 then claimed their credits ([`0xebca738c…`](https://sepolia.etherscan.io/tx/0xebca738cb6a2dfe048782c8332a3b7a34a8823ace5a2e1f8fe641bd65f1d175f), [`0x2f4de70d…`](https://sepolia.etherscan.io/tx/0x2f4de70d74fee87551be8bf0128d022226befc279fb9841bff3542d114bbdfb7)).

**A VRF-seeded work (token 10).** `requestSeed` for the VRF item ([`0x20cdc919…`](https://sepolia.etherscan.io/tx/0x20cdc919d30fa42a12d63230a2144f66e0eea563161cbe3853cf21699b4bd67f)) was
fulfilled by the Chainlink node five blocks later ([`0x04802174…`](https://sepolia.etherscan.io/tx/0x048021747542e89323c2de5105e6994528521c01a3de436ff1704fe6db968f23)); bidder 3 then started
the work with a bid ([`0xedd3c2e3…`](https://sepolia.etherscan.io/tx/0xedd3c2e3f4f7934950257a8f734f8d304b399d2e25bff6a12ccc7e035f9ba51c)) and the keeper settled it after the hour
([`0xe10a16b8…`](https://sepolia.etherscan.io/tx/0xe10a16b894f7cf7d6f1bcf270fc119d52942ac6a4e41bc2b5cbb31cd97cb693d)). The token stores the delivered seed: `workOf(10).seed` is `0xce1f9ae2…c678`, the value in the module's `SeedDelivered` log.

**An Independent Stream pair with an edition sale.** The artist key deployed its own 1/1
contract from the approved template
([`0xe0D0D9327c5dfc371db85d05d25b9743DAE563d6`](https://sepolia.etherscan.io/address/0xe0D0D9327c5dfc371db85d05d25b9743DAE563d6),
[`0xc74a9934…`](https://sepolia.etherscan.io/tx/0xc74a993438adf3f2b23597a36dbe6695f3667e096733f00ff95036cc3a476661)), listed it with one consent signature ([`0x121aab0f…`](https://sepolia.etherscan.io/tx/0x121aab0f479ef9a5f52e12cf5db788e433f47030c7150443b820953086a54ca3)) and
approved an edition master at a 5% royalty ([`0x03ae79cf…`](https://sepolia.etherscan.io/tx/0x03ae79cfe943e989e8c2cbdf22c8e1e19ae2024d38c009670ce2deb89210f4a7)). It then
deployed the editions contract that partners it
([`0x357754A70F754b3D4A7b5c96e4B95d65B09b5F16`](https://sepolia.etherscan.io/address/0x357754A70F754b3D4A7b5c96e4B95d65B09b5F16),
[`0x7da7f555…`](https://sepolia.etherscan.io/tx/0x7da7f555eb727d6a33b4cc915631040a60d075de02270c8577188a31f999a9a2), 17,806,172 gas on Sepolia) and listed it
with a second consent signature ([`0xd5ab0022…`](https://sepolia.etherscan.io/tx/0xd5ab00225cc63fb863e3caf1aa69d00013f9b1fcafa3bb7eff1ac7d4e3116af2)). Bidder 4 started the
master's 1/1 on the shared English auction with a 0.05 ETH bid
([`0x9251e9db…`](https://sepolia.etherscan.io/tx/0x9251e9dbe3e86c33e842fa089677d4d1abfd8818fb07d30196d94644d23b4da7)); anyone opened its edition sale in the Independent
Stream edition auction, which created the edition ([`0x91782f87…`](https://sepolia.etherscan.io/tx/0x91782f87a8e4d201871f7d1ec58d7584cc8336af6d148e4ea02b3c681b6362e9)), and its
record ([`0x95a5538a…`](https://sepolia.etherscan.io/tx/0x95a5538a23ef9dbc2630afd9ff52271a20a4614669fa79e3863adb49d03c9786)). Three edition bids followed: bidder 1, 2 copies at
step 20; bidder 2, 1 copy at step 25; bidder 3, 1 copy at step 10. After the hour the keeper settled the 1/1 ([`0x67eea6a5…`](https://sepolia.etherscan.io/tx/0x67eea6a52055ed067c682ceeac6cdcafe79ed39f1ad2559598aac48061871296)): the token's `ownerOf(1)` is bidder 4. After the edition's close anyone settled it ([`0x2e57a691…`](https://sepolia.etherscan.io/tx/0x2e57a6915d702a5279806a9d7bd17422fde5d59cd1934a322631e497462f50e4)): 3 copies cleared at step 20, 0.000261 ETH each (0.000783 ETH). The bidders claimed ([`0xa996e460…`](https://sepolia.etherscan.io/tx/0xa996e46028c8bca5b8bb0dc53a5c55a9af3d317f09cbabe7036ba05ba94058e0), [`0xf22649b2…`](https://sepolia.etherscan.io/tx/0xf22649b2693bc066fdd4a1ebee5ed0ad3c1e065fc43bf3c4a01b5d08865132f0), [`0x00cef829…`](https://sepolia.etherscan.io/tx/0x00cef8298d5014793ddc2a800c7f6e0ba0dedf032cdeda2bb64c4f4eca835bef)): bidder 1 received 2 copies, bidder 2 one copy and the rest of its step-25 escrow, and bidder 3 its whole escrow back. The master's media was marked complete on chain ([`0xca378dd1…`](https://sepolia.etherscan.io/tx/0xca378dd110d9ff92d926233a70dde7ec7c59ad3d50bc0ddb14e9e52632b1cc4d)) and the artist finalized its record ([`0xb2450807…`](https://sepolia.etherscan.io/tx/0xb24508074edfa496c40e07eb1bb4efc5870bd94adaf2f440deaaf8911517c6a9)); its `tokenURI(1)` answered 807 bytes, with the SVG inline.

**Payouts.** The artist released its share of the seller vault ([`0x950ab455…`](https://sepolia.etherscan.io/tx/0x950ab45551e4ef250d50715b73e566ce9cd3b253d94b0da72dc9f4a2134507ea)): 0.27392295 ETH. The network fee vault forwarded 0.08115105 ETH to the network Safe ([`0x7dc2ceb3…`](https://sepolia.etherscan.io/tx/0x7dc2ceb3c0e2a50d8a249b856e236bd129d96631a84a9c7d17a9533c3d691656)). Together that is everything the sales raised, 0.355074 ETH: 0.304291 ETH on 6529 Stream (six 1/1s sold for 0.3025 ETH and the two edition sales, 0.001791 ETH), of which the network's share is 25%, and 0.050783 ETH on the Independent Stream pair (the 1/1 and its edition), of which it is 10%. Afterwards both auctions, both edition auctions, the fee vault, the seller vault and the revenue escrow held no ETH, and every outbid, withdrawn, losing or voided bid had been claimed.

## Tooling faults found and fixed

Neither is a fault of a deployed contract.

- **The reference keeper's `rescues` report** stopped on token 9: after a cancel the token is
  burned, `workOf` still answers with no outcome and `ownerOf` reverts, which the step did not
  expect. It now skips such a token ([`keeper.py`](../../keeper/keeper.py), with a unit test).
  The steps the keeper had sent before that run were not affected.
- **`flows.ps1 -Step sync`** used a local variable that the new `-Work` parameter shadows
  (PowerShell names are case-insensitive); renamed.

## Not run on r7

Anything that changes governance after genesis (a module proposal, activation or removal, a
minter, a setting, a role): r7 is kept as installed, and r6 holds the module-swap test.
Anything behind a long wait: `expireCredit` and `forfeit` (180 days), `rescue` and `rebind`
(14 days), a finalize notice (14 days). A payout wallet change (2 days). The edition auction's
`abandon` (21 days). An Independent Stream `restart` or `settleOrRefund`.

## Every transaction

| # | Step | From | Block | Gas on Sepolia | Prague replay | Transaction |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| 1 | `acceptNetwork` | any | 12,194,674 | 174,102 | 83,698 | [`0xa56bfbfa…`](https://sepolia.etherscan.io/tx/0xa56bfbfa73a2ed1048788ccfac688b7aecabf3d85012dc5a93a0929a3359fc7b) |
| 2 | `vrf-addConsumer` | deployer | 12,194,676 | 255,326 | 78,086 | [`0xef544f17…`](https://sepolia.etherscan.io/tx/0xef544f1730f6db341be954ddf2897464eca593fd9b412a34249f9cae780548a3) |
| 3 | `writeChunk-b64-1024` | any | 12,194,680 | 1,911,018 | 301,850 | [`0xca9473b5…`](https://sepolia.etherscan.io/tx/0xca9473b5fa2065de368dffed786039e4bfdea053512b40c07fa029f061881762) |
| 4 | `registerManifest-b64-1024` | any | 12,194,681 | 579,348 | 145,448 | [`0xc076fd1c…`](https://sepolia.etherscan.io/tx/0xc076fd1c6fd404233aac7b17f6d422a44fb7128c3dc711e0b12ae495008653e3) |
| 5 | `attestBase64-1024` | any | 12,194,682 | 154,216 | 71,196 | [`0x411b1fb3…`](https://sepolia.etherscan.io/tx/0x411b1fb33ff80d72fbb597a30db7e987b1a3254e57d627a530b36e1af868269f) |
| 6 | `writeChunk-b64-8192` | any | 12,194,683 | 13,003,921 | 1,859,969 | [`0xddf9fd54…`](https://sepolia.etherscan.io/tx/0xddf9fd541fd89733bde0f2cafd07a9e62fb64e85c492a8e80bb6522f12c5a5a0) |
| 7 | `registerManifest-b64-8192` | any | 12,194,684 | 579,348 | 145,448 | [`0x17c492f0…`](https://sepolia.etherscan.io/tx/0x17c492f00f93e57b23a5199b9df8d471f12d6ad10ce5551f6d5b1870b4bbde43) |
| 8 | `attestBase64-8192` | any | 12,194,685 | 206,341 | 123,321 | [`0x096ae6af…`](https://sepolia.etherscan.io/tx/0x096ae6afe80f2828e762df5de4596d3ba23ce1744d0e1e65cfb7a78ec90fbbc7) |
| 9 | `writeChunk-b64-24572` | any | 12,194,686 | 38,356,636 | 5,424,218 | [`0x131c04fc…`](https://sepolia.etherscan.io/tx/0x131c04fc21f4cc54ece2742673df370464c2575e77fdd46d3e7626e7a97129eb) |
| 10 | `registerManifest-b64-24572` | any | 12,194,687 | 579,360 | 145,460 | [`0xd3b1cefc…`](https://sepolia.etherscan.io/tx/0xd3b1cefccd000320099ccf7195ccd8900c71cc7d8364cc4522aaf151b15d850a) |
| 11 | `attestBase64-24572` | any | 12,194,688 | 326,265 | 243,245 | [`0xb27bbead…`](https://sepolia.etherscan.io/tx/0xb27bbeadfba8edfd576ef6f4e3f881414656bafa73cf919a06f48d59eada3db1) |
| 12 | `writeChunk-record-0` | any | 12,194,689 | 621,958 | 120,842 | [`0xe3f63568…`](https://sepolia.etherscan.io/tx/0xe3f63568565773f0fe76869fb2c15e9c1e220e42fab11c65868d825849a2a717) |
| 13 | `registerManifest-record-0` | any | 12,194,690 | 581,870 | 147,970 | [`0xda28a38a…`](https://sepolia.etherscan.io/tx/0xda28a38a3096bef06c73837dfb1a2ba9b81f52f294f0ee70208f3c67ef31f17e) |
| 14 | `writeChunk-record-1` | any | 12,194,691 | 621,958 | 120,842 | [`0x9090bfa2…`](https://sepolia.etherscan.io/tx/0x9090bfa2d534575028c879d4858dd1188dd1ad5b9c5c086a30b581cf126e0142) |
| 15 | `registerManifest-record-1` | any | 12,194,692 | 581,870 | 147,970 | [`0x80ae6498…`](https://sepolia.etherscan.io/tx/0x80ae64986ac192cf30bc913283112cd772cfca8629351a1d2a6c9879018ad87d) |
| 16 | `writeChunk-record-2` | any | 12,194,693 | 621,958 | 120,842 | [`0xdd7e7c5b…`](https://sepolia.etherscan.io/tx/0xdd7e7c5b0834835a52387753bbf383897de87cca6b94cf2322a5d1eb0c7b4fa6) |
| 17 | `registerManifest-record-2` | any | 12,194,694 | 581,858 | 147,958 | [`0xf918ec0e…`](https://sepolia.etherscan.io/tx/0xf918ec0e65d41189d6d281d35f6d556f6cef166d7435983d5b80af979643d47a) |
| 18 | `registerManifest-media-2` | any | 12,194,695 | 579,324 | 145,424 | [`0x7e8e8ebf…`](https://sepolia.etherscan.io/tx/0x7e8e8ebf4a62c385113583aaa4885f7accc4c207271170e9043e65b8f039386a) |
| 19 | `writeChunk-record-3` | any | 12,194,696 | 621,958 | 120,842 | [`0xbf0068c4…`](https://sepolia.etherscan.io/tx/0xbf0068c4faa3236d48c73d9c0192006098c4a1685d8cdd5a1f3b27429cb30283) |
| 20 | `registerManifest-record-3` | any | 12,194,697 | 581,870 | 147,970 | [`0xf12398b2…`](https://sepolia.etherscan.io/tx/0xf12398b26fc791276875f2f924ed7a61f7f6d38435eac45ca9a22348dbf5f0d9) |
| 21 | `registerManifest-media-3` | any | 12,194,698 | 579,336 | 145,436 | [`0x7da888cf…`](https://sepolia.etherscan.io/tx/0x7da888cf93fc0f23eae547fe6845e750646325168dcbdbdef686a4e1d3337a2f) |
| 22 | `writeChunk-record-4` | any | 12,194,699 | 621,958 | 120,842 | [`0xf71836dd…`](https://sepolia.etherscan.io/tx/0xf71836dd847f82375757466930b5fd34d32cb7eb2900240784a98640ad5fd178) |
| 23 | `registerManifest-record-4` | any | 12,194,700 | 581,870 | 147,970 | [`0x42450bff…`](https://sepolia.etherscan.io/tx/0x42450bff152aee622b17ab7e8475e2148d788befd7f5ea346897b61229f5b8a9) |
| 24 | `writeChunk-record-5` | any | 12,194,701 | 621,958 | 120,842 | [`0x5ad29505…`](https://sepolia.etherscan.io/tx/0x5ad29505e970b437b070908e1c479e4b0316e665939cadc291d26ab93b59be08) |
| 25 | `registerManifest-record-5` | any | 12,194,702 | 581,870 | 147,970 | [`0xd6dd7fa5…`](https://sepolia.etherscan.io/tx/0xd6dd7fa587c09b8990db3cbae4fb6fb98b93de8c21da63b7ff6a000516db9542) |
| 26 | `registerManifest-media-5` | any | 12,194,703 | 579,312 | 145,412 | [`0x1d48609f…`](https://sepolia.etherscan.io/tx/0x1d48609feaf83557906a9f9b7e80b6dff7583855fa727ed69550c92d33861447) |
| 27 | `writeChunk-record-6` | any | 12,194,704 | 621,958 | 120,842 | [`0xbc0802ae…`](https://sepolia.etherscan.io/tx/0xbc0802ae70adfc648a71528320674dec4ebe8cc55cb2d49314c6f63902346fe9) |
| 28 | `registerManifest-record-6` | any | 12,194,705 | 581,870 | 147,970 | [`0xab488948…`](https://sepolia.etherscan.io/tx/0xab48894833f6bc535369d94e14356d105bfdba5aee213bd2efc12aae5dcf3820) |
| 29 | `registerManifest-media-6` | any | 12,194,706 | 579,336 | 145,436 | [`0x86c521a2…`](https://sepolia.etherscan.io/tx/0x86c521a257a076ae498c820f5c260c4efc979d01fa8b2f30d1e3355bf3071a37) |
| 30 | `writeChunk-record-7` | any | 12,194,707 | 621,958 | 120,842 | [`0x23512809…`](https://sepolia.etherscan.io/tx/0x2351280907cc343e3da2ba4733ad3c175fea9a556e968b8e536a0a217f88f23d) |
| 31 | `registerManifest-record-7` | any | 12,194,708 | 581,870 | 147,970 | [`0x469ac931…`](https://sepolia.etherscan.io/tx/0x469ac9312e5f2ddea7449652e96c771245bb7c3ba6b02f912704048dcb8d677a) |
| 32 | `registerManifest-media-7` | any | 12,194,709 | 579,336 | 145,436 | [`0x92678838…`](https://sepolia.etherscan.io/tx/0x926788382bbb06e909516be8a59c606f66095877625f05fa5840b14ce0501cbd) |
| 33 | `writeChunk-record-8` | any | 12,194,710 | 621,958 | 120,842 | [`0xee44af6c…`](https://sepolia.etherscan.io/tx/0xee44af6cc8c3af5aeb670dbede42e2a871269e6e1fb7217dfffe138b3f7df8c5) |
| 34 | `registerManifest-record-8` | any | 12,194,711 | 581,870 | 147,970 | [`0xfc67b8c1…`](https://sepolia.etherscan.io/tx/0xfc67b8c1b240e5a0c2aea94f758bde6071b6225ff4efc82090ee1db38a859a87) |
| 35 | `registerManifest-media-8` | any | 12,194,712 | 579,324 | 145,424 | [`0x508f9139…`](https://sepolia.etherscan.io/tx/0x508f91398d0ae9e90c7eb7a25c425818b6ee9603c9a37c68e33966f1c0681c4d) |
| 36 | `writeChunk-record-9` | any | 12,194,713 | 621,958 | 120,842 | [`0xf2dc03ca…`](https://sepolia.etherscan.io/tx/0xf2dc03ca3f9d9d860344de993e130ac87ebea3a95866cc47caf0298b98cb23da) |
| 37 | `registerManifest-record-9` | any | 12,194,714 | 581,870 | 147,970 | [`0x1987d28b…`](https://sepolia.etherscan.io/tx/0x1987d28b0701bd56b8d8cf28336e43edbf5c08d0ce4569a27d1d344f1ce40dc0) |
| 38 | `registerManifest-media-9` | any | 12,194,715 | 579,336 | 145,436 | [`0x2e029774…`](https://sepolia.etherscan.io/tx/0x2e0297747cacd0f2c435f89799cfbe67ddaab372b7dacebe1fed83b7dfccdee0) |
| 39 | `createCollection-Flows` | platform | 12,194,716 | 474,912 | 128,532 | [`0xddeb93c4…`](https://sepolia.etherscan.io/tx/0xddeb93c434a07071c6397776b0c658bd48037dc9c2f5ffe54adbaf31594b17a6) |
| 40 | `createCollection-Flows-2` | platform | 12,194,717 | 377,004 | 111,444 | [`0x63b365b7…`](https://sepolia.etherscan.io/tx/0x63b365b717f7386c76334087019d473bd8e1cd299072528022184df025aa7c36) |
| 41 | `registerPackage` | any | 12,194,718 | 280,558 | 109,318 | [`0x96a3818a…`](https://sepolia.etherscan.io/tx/0x96a3818a6a67897a9e85fd46dcbd79ec30e7bd7fcf0c1e740f4bd315e074fc95) |
| 42 | `appendCurator` | curator | 12,194,719 | 272,370 | 101,930 | [`0x99aef3b8…`](https://sepolia.etherscan.io/tx/0x99aef3b8d12f2ad8cc5721c1de619162b9352a7b3b4b91b0597f4275d3cca13b) |
| 43 | `acceptPackage` | any | 12,194,720 | 833,764 | 221,924 | [`0x1a3d895d…`](https://sepolia.etherscan.io/tx/0x1a3d895dda806da9b30c959935027d7845c4c31d672dd05a40df7fd65e619e23) |
| 44 | `writeChunk-independent-media-master` | any | 12,194,721 | 513,668 | 105,664 | [`0xbbf05b5e…`](https://sepolia.etherscan.io/tx/0xbbf05b5e2a7d74eaa05b4b685f00399dba1c7220f03ec272c4af090d8d4f6770) |
| 45 | `registerManifest-independent-media-master` | any | 12,194,722 | 580,841 | 146,941 | [`0x229ffe68…`](https://sepolia.etherscan.io/tx/0x229ffe688c7639cc3c87c28703cc50ddde379bb3ceb10c267c2a551b21d0bab8) |
| 46 | `writeChunk-independent-record-master` | any | 12,194,723 | 558,561 | 111,981 | [`0x78299c8a…`](https://sepolia.etherscan.io/tx/0x78299c8a5a22a2dc4d54dc6b7e703881c8936c487247d14f064761626b9bccf3) |
| 47 | `registerManifest-independent-record-master` | any | 12,194,724 | 581,870 | 147,970 | [`0xd83acc83…`](https://sepolia.etherscan.io/tx/0xd83acc8303c572fc1da8a434e536cf463dad93ca3aa9dad76c5a54a332a2d647) |
| 48 | `requestSeed` | any | 12,194,726 | 646,061 | 203,761 | [`0x20cdc919…`](https://sepolia.etherscan.io/tx/0x20cdc919d30fa42a12d63230a2144f66e0eea563161cbe3853cf21699b4bd67f) |
| 49 | `start-0-first-work-ever` | any | 12,194,727 | 1,159,577 | 355,897 | [`0xb377f4ed…`](https://sepolia.etherscan.io/tx/0xb377f4ed0f0d7a63f255209f416c18e247d781b7ae1c3ddda73cc5d2291a9734) |
| 50 | `startWithBid-3-first-bid-of-the-auction` | bidder1 | 12,194,729 | 1,087,971 | 351,911 | [`0x3ccf0557…`](https://sepolia.etherscan.io/tx/0x3ccf05576943e60e2833caf6ff7730cbaa6ac0b30253a399a04bb67109716dce) |
| 51 | `start-2-steady` | any | 12,194,730 | 963,757 | 321,717 | [`0x2ebef972…`](https://sepolia.etherscan.io/tx/0x2ebef972fa182740e0f5200ebcabf5bd37231e77aeb6fbc0d105d61dc3741a9d) |
| 52 | `startWithBid-4-steady` | bidder2 | 12,194,731 | 1,087,996 | 351,936 | [`0xddccbf4e…`](https://sepolia.etherscan.io/tx/0xddccbf4ed74652491cf62175fc27f180fa238129d0df119a9777504049b1c04b) |
| 53 | `vrf-fulfilment` | chainlink | 12,194,731 | 140,081 | 106,598 | [`0x04802174…`](https://sepolia.etherscan.io/tx/0x048021747542e89323c2de5105e6994528521c01a3de436ff1704fe6db968f23) |
| 54 | `start-1-consolidated-wallet-signs` | any | 12,194,732 | 1,011,745 | 368,905 | [`0x11233120…`](https://sepolia.etherscan.io/tx/0x11233120001342d2da2b27a5e5920520b3bd537b6d32dd98fcf4b1f031005360) |
| 55 | `start-7-new-collection` | any | 12,194,733 | 963,747 | 321,707 | [`0xf34c2707…`](https://sepolia.etherscan.io/tx/0xf34c270720ecf32304930d60db47789edef8d2371a8149df9d65c91db63a5b89) |
| 56 | `keeper-saleStarter-5-master` | keeper.py | 12,194,739 | 2,565,997 | 715,901 | [`0x2045fdfb…`](https://sepolia.etherscan.io/tx/0x2045fdfbe90e83a17d15bb7166bedc52f919162becac182cb0c749ed2748f958) |
| 57 | `keeper-saleStarter-8-capped-master` | keeper.py | 12,194,740 | 1,745,955 | 574,695 | [`0x32c11bbf…`](https://sepolia.etherscan.io/tx/0x32c11bbf3d1b8f2a3c33aa4c2b440289f0da66981745fa7edc4e21f5f22393fa) |
| 58 | `keeper-saleStarter-9-dispute-master` | keeper.py | 12,194,741 | 1,745,950 | 574,690 | [`0xd25a0ee2…`](https://sepolia.etherscan.io/tx/0xd25a0ee2b0d8c8b161ccebfa4d58907deb565fa2e41c9b6d9219612eb6090567) |
| 59 | `keeper-openEdition-7` | keeper.py | 12,194,742 | 695,413 | 258,413 | [`0x0e5a71ba…`](https://sepolia.etherscan.io/tx/0x0e5a71bae0896d938cfe300f891a17d5de2dc4e5c3b7bd0fa507001aea93e63d) |
| 60 | `keeper-openEdition-8` | keeper.py | 12,194,743 | 693,657 | 256,657 | [`0xac6ea3b6…`](https://sepolia.etherscan.io/tx/0xac6ea3b63475cca4e532ff5e521d85abbe83d352db161de9fd4db22d66ac9007) |
| 61 | `keeper-openEdition-9` | keeper.py | 12,194,745 | 693,634 | 256,634 | [`0x79e90641…`](https://sepolia.etherscan.io/tx/0x79e906413024bf2867f21005cef9c6a2efcb3fd1d30e462b8b93275dc902656b) |
| 62 | `bid-1-opening` | bidder1 | 12,194,748 | 151,715 | 63,295 | [`0x2eab01bf…`](https://sepolia.etherscan.io/tx/0x2eab01bf4f6a8d60f22ac33f99ca84d6b7e81bd999597adbfcdccc688dcfb25c) |
| 63 | `bid-1-competing` | bidder2 | 12,194,749 | 169,824 | 74,204 | [`0xa7e0663c…`](https://sepolia.etherscan.io/tx/0xa7e0663cc2e6f4f6439e1cf88c8dcc82ac176895b590667f93a1878eddce2553) |
| 64 | `claimCredits-english-bidder1` | bidder1 | 12,194,750 | 32,255 | 32,018 | [`0xcfdad4b6…`](https://sepolia.etherscan.io/tx/0xcfdad4b67b99a1439d8699eb03e0f3c2e51e653d211c62692a34aa61e65b2f68) |
| 65 | `openRecord-1` | any | 12,194,752 | 728,536 | 205,816 | [`0x02f8815d…`](https://sepolia.etherscan.io/tx/0x02f8815d6aa09c1ba2385f0c2ee28c4b0e1e11bb7647748b2fc0a8e64f96de0a) |
| 66 | `bid-7-master` | bidder3 | 12,194,753 | 151,715 | 63,295 | [`0x6ccb86ed…`](https://sepolia.etherscan.io/tx/0x6ccb86ed0ce46fef5691140d46312569096c48b857cf158922839f20b81af459) |
| 67 | `editionBid-7-1-bidder1-s20x2` | bidder1 | 12,194,754 | 269,355 | 86,115 | [`0x04bb3e4c…`](https://sepolia.etherscan.io/tx/0x04bb3e4c689537218eb5e408267cadaff8e811e2800ca9cfdc24ebd2db15612e) |
| 68 | `editionBid-7-2-bidder4-s25x3` | bidder4 | 12,194,755 | 269,408 | 86,168 | [`0x0ada89b8…`](https://sepolia.etherscan.io/tx/0x0ada89b86761fc6a5c6d02b11735394934ead101e117244ed82f939bd87fd4fe) |
| 69 | `editionBid-7-3-bidder2-s10x1` | bidder2 | 12,194,756 | 269,378 | 86,138 | [`0xbb0164e5…`](https://sepolia.etherscan.io/tx/0xbb0164e551e405277ee568337f5d2c9be03b0c44c8f921e10146f630b5cc11a6) |
| 70 | `editionBid-8-1-bidder1-s10x1` | bidder1 | 12,194,758 | 271,805 | 88,565 | [`0x32f498df…`](https://sepolia.etherscan.io/tx/0x32f498df201b59f1d5cd92f66e098133fb520b2063295c91b10ece235493c9a6) |
| 71 | `editionBid-8-2-bidder2-s10x2` | bidder2 | 12,194,759 | 173,917 | 71,497 | [`0x3efd2c13…`](https://sepolia.etherscan.io/tx/0x3efd2c1374c5ddfbe6e7d59bcc26f095bc0b56d03661cef7d6840850328f6703) |
| 72 | `editionBid-8-3-bidder3-s10x2` | bidder3 | 12,194,760 | 173,917 | 71,497 | [`0x1dbc77eb…`](https://sepolia.etherscan.io/tx/0x1dbc77ebc2c279c636b6b41566e8e56edce1163539d459710dee616c8580bf25) |
| 73 | `editionBid-8-4-bidder4-s10x1` | bidder4 | 12,194,761 | 173,917 | 71,497 | [`0xb1e7acde…`](https://sepolia.etherscan.io/tx/0xb1e7acde320752e50f133ebf510654a25e40fdc526716fee5615e2f3b92b2008) |
| 74 | `editionRaise-8-bid1-s10-to-s20` | bidder1 | 12,194,762 | 298,079 | 100,439 | [`0xf5fd1948…`](https://sepolia.etherscan.io/tx/0xf5fd1948886ca5c17ebca7f93bc9d27a3d190791eea72b596dbf5130d8eadb22) |
| 75 | `editionRaise-8-bid4-s10-to-s15` | bidder4 | 12,194,763 | 80,218 | 58,618 | [`0x7b503b94…`](https://sepolia.etherscan.io/tx/0x7b503b9432c2cf7394754f70bce983fc3b2e80476a2ed1641c5df620c9494dde) |
| 76 | `bid-9-dispute-master` | bidder4 | 12,194,764 | 151,715 | 63,295 | [`0x5d63e663…`](https://sepolia.etherscan.io/tx/0x5d63e66331aa8c527172a02583cf33133c746a1e8feb98d731f3b51753220c89) |
| 77 | `editionBid-9-1-bidder3-s10x1` | bidder3 | 12,194,765 | 269,367 | 86,127 | [`0xa457e277…`](https://sepolia.etherscan.io/tx/0xa457e2772cbc0adf2e0d7817437cfe2ee9a5c7e6359e48677f0498587d34fb67) |
| 78 | `pause-9-pauser-key` | pauser | 12,194,766 | 167,345 | 77,325 | [`0x9cd8492a…`](https://sepolia.etherscan.io/tx/0x9cd8492ad4f2a78edab583c66a9b75157d1832efcd363e41fd59cfc6f0728b8a) |
| 79 | `withdrawBid-9-while-paused` | bidder4 | 12,194,767 | 149,811 | 60,591 | [`0x0fc1f08e…`](https://sepolia.etherscan.io/tx/0x0fc1f08e9f64fe2f3dd8109d29d199ae05aa6e78a638407782ab43b4f6986f93) |
| 80 | `disputeOutcome-9` | platform | 12,194,768 | 395,262 | 136,502 | [`0x9a0c22f8…`](https://sepolia.etherscan.io/tx/0x9a0c22f8365cdeffebd22bb965fa90cfea2cfcb1633afc46ac3cee3a360ec27c) |
| 81 | `cancel-9-network-safe` | any | 12,194,769 | 243,034 | 136,546 | [`0x7c3430d9…`](https://sepolia.etherscan.io/tx/0x7c3430d9f99cc2a947f90916bb6000e419bde6b534ca753ffcfd3a9221396cf7) |
| 82 | `keeper-editionSettle-9-void` | keeper.py | 12,194,771 | 72,920 | 63,620 | [`0x516a7e65…`](https://sepolia.etherscan.io/tx/0x516a7e65268681c791a5a0e56e9c501b0a564fba02e629bd13df4d52e35693a9) |
| 83 | `claimBid-9-1-void-refund` | bidder3 | 12,194,772 | 38,609 | 39,961 | [`0x0d3d765e…`](https://sepolia.etherscan.io/tx/0x0d3d765e2f936a43b1542ee350f01f9c42ced431ded4106b33ba7d7f0313187c) |
| 84 | `claimCredits-english-bidder4-withdrawn-bid` | bidder4 | 12,194,773 | 32,255 | 32,018 | [`0xb6b5c9f9…`](https://sepolia.etherscan.io/tx/0xb6b5c9f9dc4cc93a228a0fa0226f04316b2258bfcf32aac290e69bd03fe0113a) |
| 85 | `independentDeploy` | artist | 12,194,775 | 22,953,317 | 3,143,311 | [`0xc74a9934…`](https://sepolia.etherscan.io/tx/0xc74a993438adf3f2b23597a36dbe6695f3667e096733f00ff95036cc3a476661) |
| 86 | `independentRegister` | artist | 12,194,776 | 296,906 | 124,766 | [`0x121aab0f…`](https://sepolia.etherscan.io/tx/0x121aab0f479ef9a5f52e12cf5db788e433f47030c7150443b820953086a54ca3) |
| 87 | `independentApproveItem-master` | artist | 12,194,777 | 151,513 | 68,693 | [`0x03ae79cf…`](https://sepolia.etherscan.io/tx/0x03ae79cfe943e989e8c2cbdf22c8e1e19ae2024d38c009670ce2deb89210f4a7) |
| 88 | `independentEditionsDeploy` | artist | 12,194,778 | 17,806,172 | 2,416,312 | [`0x7da7f555…`](https://sepolia.etherscan.io/tx/0x7da7f555eb727d6a33b4cc915631040a60d075de02270c8577188a31f999a9a2) |
| 89 | `independentEditionsRegister` | artist | 12,194,779 | 521,178 | 172,998 | [`0xd5ab0022…`](https://sepolia.etherscan.io/tx/0xd5ab00225cc63fb863e3caf1aa69d00013f9b1fcafa3bb7eff1ac7d4e3116af2) |
| 90 | `independentStartWithBid-master` | bidder4 | 12,194,781 | 1,853,602 | 528,164 | [`0x9251e9db…`](https://sepolia.etherscan.io/tx/0x9251e9dbe3e86c33e842fa089677d4d1abfd8818fb07d30196d94644d23b4da7) |
| 91 | `independentOpenEdition-1` | any | 12,194,782 | 837,668 | 312,248 | [`0x91782f87…`](https://sepolia.etherscan.io/tx/0x91782f87a8e4d201871f7d1ec58d7584cc8336af6d148e4ea02b3c681b6362e9) |
| 92 | `independentOpenRecord-master` | any | 12,194,783 | 728,934 | 206,214 | [`0x95a5538a…`](https://sepolia.etherscan.io/tx/0x95a5538a23ef9dbc2630afd9ff52271a20a4614669fa79e3863adb49d03c9786) |
| 93 | `independentEditionBid-1-1-bidder1-s20x2` | bidder1 | 12,194,784 | 313,174 | 128,334 | [`0x01d53911…`](https://sepolia.etherscan.io/tx/0x01d539118032d368d5b27b275a5f63b0ad6a525c7f11edf187920536ffb4def5) |
| 94 | `independentEditionBid-1-2-bidder2-s25x1` | bidder2 | 12,194,785 | 313,227 | 128,387 | [`0x7026b3df…`](https://sepolia.etherscan.io/tx/0x7026b3df35a8bd5fe577a540395ff71c294390792637e0d00336c88c6d592429) |
| 95 | `independentEditionBid-1-3-bidder3-s10x1` | bidder3 | 12,194,786 | 313,197 | 128,357 | [`0x0c2f1665…`](https://sepolia.etherscan.io/tx/0x0c2f1665a00d81da971ee51e8aecbb59ad7beb189a1edb03f09195209e269f1f) |
| 96 | `startWithBid-6-vrf` | bidder3 | 12,194,788 | 1,209,264 | 384,884 | [`0xedd3c2e3…`](https://sepolia.etherscan.io/tx/0xedd3c2e3f4f7934950257a8f734f8d304b399d2e25bff6a12ccc7e035f9ba51c) |
| 97 | `bid-3-antisnipe` | bidder2 | 12,194,987 | 162,174 | 66,554 | [`0x67de4cb9…`](https://sepolia.etherscan.io/tx/0x67de4cb9c4693f92e77d8c914467e9d11c5c19de2711f70ec522aa1fa9ddc4d7) |
| 98 | `keeper-settle-1` | keeper.py | 12,195,039 | 244,974 | 127,354 | [`0xf2385eb1…`](https://sepolia.etherscan.io/tx/0xf2385eb1cfb185822bdb2b64ae448fc5219f2ac6c06106a3a04bdce9955e509d) |
| 99 | `keeper-settle-2` | keeper.py | 12,195,040 | 244,962 | 127,342 | [`0x72a4c083…`](https://sepolia.etherscan.io/tx/0x72a4c083d003c53e0a56adb93af4062b17a076a7b81362df4b9da5cc3788ed85) |
| 100 | `keeper-settle-4` | keeper.py | 12,195,041 | 147,054 | 110,254 | [`0xb47e53b6…`](https://sepolia.etherscan.io/tx/0xb47e53b6d077f51c8c4b094db28c503271c86238b2ae4fbc98abdbf28664044c) |
| 101 | `keeper-settle-5-unbid` | keeper.py | 12,195,042 | 210,356 | 98,536 | [`0x168cc4eb…`](https://sepolia.etherscan.io/tx/0x168cc4eb63834c7153506b527c524820da654da9ca1446032dfa52c28dae2350) |
| 102 | `keeper-settle-6-unbid` | keeper.py | 12,195,043 | 112,448 | 81,448 | [`0xe081a9c9…`](https://sepolia.etherscan.io/tx/0xe081a9c9bfb03642bc354b92291ee21b36b1cfd561ff506e0ffe7dc8f5bba63c) |
| 103 | `keeper-settle-7` | keeper.py | 12,195,046 | 244,974 | 127,354 | [`0xe6d7095b…`](https://sepolia.etherscan.io/tx/0xe6d7095b31f9e116ca1a2bdfb093c66926a1982084ffa738cbafa75b4c84744f) |
| 104 | `keeper-settle-8-unbid` | keeper.py | 12,195,047 | 112,448 | 81,448 | [`0x790fbcee…`](https://sepolia.etherscan.io/tx/0x790fbceea49264fa1c95884c3881c8e8790329d5c8af44e5e7555e5b44da6152) |
| 105 | `keeper-markOnChainComplete-1` | keeper.py | 12,195,050 | 58,996 | 56,296 | [`0xda962d7c…`](https://sepolia.etherscan.io/tx/0xda962d7c1a3fc193982f4872b00dc070a8e847af554b3ee7fe85c17c250f3b6a) |
| 106 | `finalize-1` | artist | 12,195,052 | 408,155 | 226,115 | [`0x2a72d9cc…`](https://sepolia.etherscan.io/tx/0x2a72d9ccdea1da84f7b6fa1349bda0d393029fc3cdf1106a098fe7e83e2db0d4) |
| 107 | `keeper-settle-3` | keeper.py | 12,195,085 | 147,054 | 110,254 | [`0x7429bf35…`](https://sepolia.etherscan.io/tx/0x7429bf3574c7ab19ed3ee53fd37870e8762e4aba01df1dad486e809b6cb27e6d) |
| 108 | `keeper-settle-independent-1` | keeper.py | 12,195,086 | 255,637 | 144,033 | [`0x67eea6a5…`](https://sepolia.etherscan.io/tx/0x67eea6a52055ed067c682ceeac6cdcafe79ed39f1ad2559598aac48061871296) |
| 109 | `keeper-settle-10` | keeper.py | 12,195,087 | 135,438 | 105,454 | [`0xe10a16b8…`](https://sepolia.etherscan.io/tx/0xe10a16b894f7cf7d6f1bcf270fc119d52942ac6a4e41bc2b5cbb31cd97cb693d) |
| 110 | `markOnChainComplete-independent-1` | any | 12,195,091 | 58,952 | 56,252 | [`0xca378dd1…`](https://sepolia.etherscan.io/tx/0xca378dd110d9ff92d926233a70dde7ec7c59ad3d50bc0ddb14e9e52632b1cc4d) |
| 111 | `finalize-independent-1` | artist | 12,195,092 | 432,986 | 250,546 | [`0xb2450807…`](https://sepolia.etherscan.io/tx/0xb24508074edfa496c40e07eb1bb4efc5870bd94adaf2f440deaaf8911517c6a9) |
| 112 | `editionSettle-8-wallet3-order-skips-departure-0` | wallet3 | 12,195,111 | 363,364 | 171,924 | [`0xc501130e…`](https://sepolia.etherscan.io/tx/0xc501130edf7747b06e5f66111cce6fc9fcb454b2844e7e1773136d38c72e880b) |
| 113 | `keeper-editionSettle-7` | keeper.py | 12,195,112 | 251,263 | 147,743 | [`0xa3e93660…`](https://sepolia.etherscan.io/tx/0xa3e93660deb8ce31eb741650e180aaa4778ac386d5241464f05a71c6efe0d1f7) |
| 114 | `keeper-editionSettle-8` | keeper.py | 12,195,113 | 57,804 | 49,404 | [`0xd1449a6b…`](https://sepolia.etherscan.io/tx/0xd1449a6bea7db07ab8ea557447146a49f3471d53e74baaa3309ce61f2213de7f) |
| 115 | `claimBid-7-1` | bidder1 | 12,195,117 | 164,360 | 74,156 | [`0xe82fe23f…`](https://sepolia.etherscan.io/tx/0xe82fe23ffbbe5d42efcbdc6f7cb0b7eada9d9c103e8377c69f41796363217268) |
| 116 | `claimBid-7-2` | bidder4 | 12,195,118 | 173,513 | 81,009 | [`0x92c6af86…`](https://sepolia.etherscan.io/tx/0x92c6af86986b2d4080e05c99402247b3e8cf3b4c138c51995e331048050cba09) |
| 117 | `claimBid-7-3` | bidder2 | 12,195,119 | 40,660 | 42,525 | [`0x371cf668…`](https://sepolia.etherscan.io/tx/0x371cf668e569a0e3fed2894408e8d12100d29508bdf19673ab70453aa4c8010c) |
| 118 | `claimBidFor-8-1` | any | 12,195,120 | 279,531 | 100,907 | [`0x097baf51…`](https://sepolia.etherscan.io/tx/0x097baf511791ac2a7b464493674eda53d53c97891b892c1b23c38cac576a62de) |
| 119 | `claimBidFor-8-2` | any | 12,195,121 | 279,689 | 101,065 | [`0x33d35b13…`](https://sepolia.etherscan.io/tx/0x33d35b13a4175df0a479b9a13f87670c95b84d1bc79443cb6c78d63a9b344563) |
| 120 | `claimBid-8-3` | bidder3 | 12,195,122 | 41,745 | 43,881 | [`0xc941a340…`](https://sepolia.etherscan.io/tx/0xc941a34048c6068cc69b6e97ddb52b390873e62e245c5503a671a7f39a53a730) |
| 121 | `claimBid-8-4` | bidder4 | 12,195,123 | 173,525 | 81,021 | [`0xa6883689…`](https://sepolia.etherscan.io/tx/0xa6883689a632e788d8795efea03f0f95ede7a428499942e271aed8955da25240) |
| 122 | `claimCredits-edition-bidder1` | bidder1 | 12,195,124 | 32,404 | 32,204 | [`0xebca738c…`](https://sepolia.etherscan.io/tx/0xebca738cb6a2dfe048782c8332a3b7a34a8823ace5a2e1f8fe641bd65f1d175f) |
| 123 | `claimCredits-edition-bidder2` | bidder2 | 12,195,125 | 32,404 | 32,204 | [`0x2f4de70d…`](https://sepolia.etherscan.io/tx/0x2f4de70d74fee87551be8bf0128d022226befc279fb9841bff3542d114bbdfb7) |
| 124 | `independentEditionSettle-1` | any | 12,195,152 | 297,201 | 192,881 | [`0x2e57a691…`](https://sepolia.etherscan.io/tx/0x2e57a6915d702a5279806a9d7bd17422fde5d59cd1934a322631e497462f50e4) |
| 125 | `independentClaimBid-1-1` | bidder1 | 12,195,153 | 166,708 | 76,504 | [`0xa996e460…`](https://sepolia.etherscan.io/tx/0xa996e46028c8bca5b8bb0dc53a5c55a9af3d317f09cbabe7036ba05ba94058e0) |
| 126 | `independentClaimBid-1-2` | bidder2 | 12,195,154 | 175,861 | 83,357 | [`0xf22649b2…`](https://sepolia.etherscan.io/tx/0xf22649b2693bc066fdd4a1ebee5ed0ad3c1e065fc43bf3c4a01b5d08865132f0) |
| 127 | `independentClaimBid-1-3` | bidder3 | 12,195,155 | 40,740 | 42,624 | [`0x00cef829…`](https://sepolia.etherscan.io/tx/0x00cef8298d5014793ddc2a800c7f6e0ba0dedf032cdeda2bb64c4f4eca835bef) |
| 128 | `release-0` | artist | 12,195,156 | 274,996 | 101,456 | [`0x950ab455…`](https://sepolia.etherscan.io/tx/0x950ab45551e4ef250d50715b73e566ce9cd3b253d94b0da72dc9f4a2134507ea) |
| 129 | `forwardFees` | any | 12,195,157 | 39,052 | 39,420 | [`0x7dc2ceb3…`](https://sepolia.etherscan.io/tx/0x7dc2ceb3c0e2a50d8a249b856e236bd129d96631a84a9c7d17a9533c3d691656) |

129 transactions: 149,788,479 gas on Sepolia, 31,394,517 replayed at Prague prices.
