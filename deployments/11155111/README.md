# Sepolia (chain 11155111)

Deployment records for 6529 Works on Sepolia. Each record is written by
[`script/Deploy.s.sol`](../../script/Deploy.s.sol) and confirmed by
[`script/Verify.s.sol`](../../script/Verify.s.sol); the runbook is
[`script/README.md`](../../script/README.md).

These are testnet rehearsals with throwaway signers. The code is pre-audit and nothing
here is a mainnet deployment.

Flow gas under Glamsterdam: [flows.md](flows.md).

r1 to r3 deploy the edition token under its former name, 6529 Editions, with the fixed-price
and Dutch sale adapters; r4, the rc.2 rehearsal, is the first deployment under the new name,
6529 Stream Editions (ADR 0005, D139), with the uniform edition auction and without those
adapters (decision 8).

## sepolia-r4: 1 November 2026 (current)

r4 is the rc.2 candidate: `main` at `1e7022b`
([#92](https://github.com/6529-Collections/6529-works/pull/92)), with the uniform-price edition
auction of ADR 0005 (`UniformEditionAuction` and its lens), the English auction's lens, Stream's
primary-sale outcomes and museum rule (owner decision 17), the 0.05 ETH opening bid (decision
19) and the rc.2 fix passes. It is the first deployment of the edition token as 6529 Stream
Editions, and the first without the fixed-price and Dutch adapters. It uses the same Safes and
keys as r1 to r3 (see [r1's holders](#holders)), a new namespace, its own VRF subscription and a
dedicated testnet museum. Every contract's source is verified on Sourcify. The flows run on it
are in [flows.md](flows.md#r4-the-rc2-candidate-1-november-2026).

| | |
| --- | --- |
| Status | Deployed and configured in blocks 12,041,046 to 12,041,071, on 1 November 2026 between 12:36:36 and 12:41:36 UTC. |
| Live Verify due | After the manager's 5-day `minSetback`, counted from the `configure` block (12:41:36 UTC): from **6 November 2026, 12:41:36 UTC**. |
| Verify so far | `Verify.s.sol` (with its `VerifyV1` checks) passes on a Sepolia fork advanced five days: 14 targets, 18 wiring calls and 17 holders, with every address and code hash (both lenses included), the CC0 text, the manifest, the museum and the VRF subscription's single consumer. It ran after the flows had begun, so it logged one pending manager operation (`ALLOW_PENDING_OPERATIONS=1`): the hot admin's scheduled dispute cancel of token 1 ([flows](flows.md#r4-the-rc2-candidate-1-november-2026)). On the live chain today it stops at the first role delay, which is still pending (`RoleMismatch(0)`), as expected. |
| Source | `main` at `1e7022b` ([#92](https://github.com/6529-Collections/6529-works/pull/92)), solc 0.8.37, `prague` |
| Source verification | [Sourcify](https://sourcify.dev): all 24 contracts, `exact_match` for both the runtime and the creation code (links below; [`script/sepolia/sourcify.ps1`](../../script/sepolia/sourcify.ps1)). Etherscan verification was not submitted: it needs an Etherscan API key, which this run did not have. |
| Record | [`1793536584.json`](1793536584.json) (`"confirmed": false` until the live Verify) |
| Live Verify | Run the runbook's step 11 with `DEPLOYMENT=deployments/11155111/1793536584.json` and `MANIFEST_PATH=config/sepolia-r4/manifest-epoch0.json`, from a commit with r4's `src/` and committed policy: this record's merge commit, or a checkout of `1e7022b` with this record and `config/sepolia-r4/` copied in (Verify recomputes every address from the build, and a later source change moves them). Once token 1's cancel has executed, no operation is pending. |
| Genesis | [`config/sepolia-r4/genesis.json`](../../config/sepolia-r4/genesis.json): the committed policy at `1e7022b` with r1's holders (`script/sepolia/make_genesis.py r4 r3`); `tools/check_genesis.py --config` passes on it |
| Epoch-0 manifest | [`config/sepolia-r4/manifest-epoch0.json`](../../config/sepolia-r4/manifest-epoch0.json), SHA-256 `d6958a00…83dd` (`script/sepolia/make_manifest.py`, in two passes) |
| Inputs | [`config/sepolia-r4/deploy.env`](../../config/sepolia-r4/deploy.env), run by [`script/sepolia/deploy.ps1`](../../script/sepolia/deploy.ps1) |
| Namespace | `keccak256("6529-works/sepolia/r4")` = `0x66e9a51e…3495` |
| Museum | [`0xd954e414a216Bc2D3d1fdc8C0e9b258ffDfDD840`](https://sepolia.etherscan.io/address/0xd954e414a216Bc2D3d1fdc8C0e9b258ffDfDD840): the **testnet museum**, a dedicated EOA the operator holds, with no role. It was funded with 0.0001 ETH before the run, so that it exists. |
| CC0 text | The committed fixture `test/fixtures/cc0-legalcode.txt`, the same file ID as r1 to r3 |
| Cost | 26 transactions, 496,057,168 gas (6.14x Foundry's Prague estimate of 80,815,534), 0.0248 Sepolia ETH at a 0.05 gwei priority fee. |

**Testnet deviations from the mainnet parameters.** One constructor parameter differs: the 1/1
English auction runs **1 hour** (`AUCTION_DURATION=3600`, the governed minimum) instead of 24
hours, so that the flows finish in hours. The anti-snipe window (15 minutes), the increment (5%,
floor 0.001 ETH), the 0.05 ETH opening bid and every edition-auction parameter (0.0001 ETH base,
48 steps per decade, 336 steps, 10% margin, a close 15 minutes after the 1/1's, a 5-minute soft
close, a 24-hour backstop) are the mainnet defaults, and the genesis file is the committed
policy. As on r1 to r3, the holders are throwaway testnet Safes and keys, the marketplace owner
is the platform key (the runbook recommends a separate account), the network fee recipient is
the hot admin Safe, and the VRF subscription is owned by the operator (on mainnet, the hot admin
Safe). The museum is the testnet EOA above. Owner decision 18's role-group guard runs on chain 1
only, so it did not run here.

**VRF subscription.**
- Subscription ID: `38903710378804317348705427001479286583650260158086313704334113777010605078141`.
- Owner: the operator.
- Funding: 0.1 Sepolia ETH, native payment.
- Same key hash and limits as r1 to r3.
- r4's entropy module is the only consumer.
- Transactions: created [`0x26eb2111…`](https://sepolia.etherscan.io/tx/0x26eb211112e3a377413016691548b28ff02adb0a0515fc67b42e45a314799013), funded [`0xdbafc5cc…`](https://sepolia.etherscan.io/tx/0xdbafc5cc8c2c569fa8f2f2378e8faab3ec207cf493c68b25bb2b50cca962f4ac), consumer added [`0x05de5ded…`](https://sepolia.etherscan.io/tx/0x05de5dedcfd03a50f82370dfa52ea8c3945f2e360bc8ea355bf18cad0dd7e56a).

### Contracts (r4)

| Contract | Address | Source |
| --- | --- | --- |
| WorksAccessManager | [`0x68115bEbdB73Bbe4E6e6D135eF76FbC32097C307`](https://sepolia.etherscan.io/address/0x68115bEbdB73Bbe4E6e6D135eF76FbC32097C307) | [Sourcify](https://repo.sourcify.dev/11155111/0x68115bEbdB73Bbe4E6e6D135eF76FbC32097C307) |
| GovernanceConfigurator | [`0xf3c2750759Da14a411841B82E5eCc6B268138D6f`](https://sepolia.etherscan.io/address/0xf3c2750759Da14a411841B82E5eCc6B268138D6f) | [Sourcify](https://repo.sourcify.dev/11155111/0xf3c2750759Da14a411841B82E5eCc6B268138D6f) |
| ContentStore | [`0x1922aA592CfCC1fdC3037EA7e033EA12D696F466`](https://sepolia.etherscan.io/address/0x1922aA592CfCC1fdC3037EA7e033EA12D696F466) | [Sourcify](https://repo.sourcify.dev/11155111/0x1922aA592CfCC1fdC3037EA7e033EA12D696F466) |
| DependencyRegistry | [`0xd74E938444C363Be4152268Eca625ABfA00933E4`](https://sepolia.etherscan.io/address/0xd74E938444C363Be4152268Eca625ABfA00933E4) | [Sourcify](https://repo.sourcify.dev/11155111/0xd74E938444C363Be4152268Eca625ABfA00933E4) |
| ConsolidationAdapter | [`0x4b6e792143bcf7443e4aC5456A8798bFb26CD9D0`](https://sepolia.etherscan.io/address/0x4b6e792143bcf7443e4aC5456A8798bFb26CD9D0) | [Sourcify](https://repo.sourcify.dev/11155111/0x4b6e792143bcf7443e4aC5456A8798bFb26CD9D0) |
| ArtistRegistry | [`0xf54f5465F1C4DB161145DA3C1369f8BF1195Aa91`](https://sepolia.etherscan.io/address/0xf54f5465F1C4DB161145DA3C1369f8BF1195Aa91) | [Sourcify](https://repo.sourcify.dev/11155111/0xf54f5465F1C4DB161145DA3C1369f8BF1195Aa91) |
| ReleaseVerifier | [`0x8E9dAd1480E0b9EA198DDD3a5EED1221420F7A98`](https://sepolia.etherscan.io/address/0x8E9dAd1480E0b9EA198DDD3a5EED1221420F7A98) | [Sourcify](https://repo.sourcify.dev/11155111/0x8E9dAd1480E0b9EA198DDD3a5EED1221420F7A98) |
| SplitFactory | [`0xB2638cfA692B32E39Da326E08d54aF4d539c7BB7`](https://sepolia.etherscan.io/address/0xB2638cfA692B32E39Da326E08d54aF4d539c7BB7) | [Sourcify](https://repo.sourcify.dev/11155111/0xB2638cfA692B32E39Da326E08d54aF4d539c7BB7) |
| ClaimRouter | [`0xF7BE40426d2dC4606664625a340fa74b3cB0C4bC`](https://sepolia.etherscan.io/address/0xF7BE40426d2dC4606664625a340fa74b3cB0C4bC) | [Sourcify](https://repo.sourcify.dev/11155111/0xF7BE40426d2dC4606664625a340fa74b3cB0C4bC) |
| AssetAllowlist | [`0x8458D77ff0fc34b3f3296F9aF418B4868afefcbB`](https://sepolia.etherscan.io/address/0x8458D77ff0fc34b3f3296F9aF418B4868afefcbB) | [Sourcify](https://repo.sourcify.dev/11155111/0x8458D77ff0fc34b3f3296F9aF418B4868afefcbB) |
| EconomicsResolver | [`0x34235b15CC7Ac63dedF1577f24a6bC1D4F1D8467`](https://sepolia.etherscan.io/address/0x34235b15CC7Ac63dedF1577f24a6bC1D4F1D8467) | [Sourcify](https://repo.sourcify.dev/11155111/0x34235b15CC7Ac63dedF1577f24a6bC1D4F1D8467) |
| RevenueEscrow | [`0x2da453bc5b9028a618613D6BeE489C0121bB57ee`](https://sepolia.etherscan.io/address/0x2da453bc5b9028a618613D6BeE489C0121bB57ee) | [Sourcify](https://repo.sourcify.dev/11155111/0x2da453bc5b9028a618613D6BeE489C0121bB57ee) |
| CurationVerifier | [`0x4dfAc76243f62B78034146605D537190F5106064`](https://sepolia.etherscan.io/address/0x4dfAc76243f62B78034146605D537190F5106064) | [Sourcify](https://repo.sourcify.dev/11155111/0x4dfAc76243f62B78034146605D537190F5106064) |
| PackageRegistry | [`0x1E12085C6001f3193776Ff9aDEc0C71b7c004C9A`](https://sepolia.etherscan.io/address/0x1E12085C6001f3193776Ff9aDEc0C71b7c004C9A) | [Sourcify](https://repo.sourcify.dev/11155111/0x1E12085C6001f3193776Ff9aDEc0C71b7c004C9A) |
| StatementLog | [`0x202F193109626416961c5f9642C8f8A7c5cb2e8B`](https://sepolia.etherscan.io/address/0x202F193109626416961c5f9642C8f8A7c5cb2e8B) | [Sourcify](https://repo.sourcify.dev/11155111/0x202F193109626416961c5f9642C8f8A7c5cb2e8B) |
| EntropyModule | [`0xd8365D17B0C16828F39f5697fd8101796A85A087`](https://sepolia.etherscan.io/address/0xd8365D17B0C16828F39f5697fd8101796A85A087) | [Sourcify](https://repo.sourcify.dev/11155111/0xd8365D17B0C16828F39f5697fd8101796A85A087) |
| Renderer | [`0xa4d100C8f6faEd2D7db97a3BC68f9E215A8aEA8f`](https://sepolia.etherscan.io/address/0xa4d100C8f6faEd2D7db97a3BC68f9E215A8aEA8f) | [Sourcify](https://repo.sourcify.dev/11155111/0xa4d100C8f6faEd2D7db97a3BC68f9E215A8aEA8f) |
| Stream | [`0x02617DbDc0b0521124cb4C2a3EF602977e29Bd91`](https://sepolia.etherscan.io/address/0x02617DbDc0b0521124cb4C2a3EF602977e29Bd91) | [Sourcify](https://repo.sourcify.dev/11155111/0x02617DbDc0b0521124cb4C2a3EF602977e29Bd91) |
| WorkRecords | [`0x99fA71dE184Be2b72cBcDEc660a5E8C881B7A1B2`](https://sepolia.etherscan.io/address/0x99fA71dE184Be2b72cBcDEc660a5E8C881B7A1B2) | [Sourcify](https://repo.sourcify.dev/11155111/0x99fA71dE184Be2b72cBcDEc660a5E8C881B7A1B2) |
| Editions | [`0xde41652f2f14260Fa4D800fdd7F77A0F9B95207e`](https://sepolia.etherscan.io/address/0xde41652f2f14260Fa4D800fdd7F77A0F9B95207e) | [Sourcify](https://repo.sourcify.dev/11155111/0xde41652f2f14260Fa4D800fdd7F77A0F9B95207e) |
| EnglishAuctionLens | [`0x42E5c7056bA0646eCBb770E6759aBbd43Ca17EA5`](https://sepolia.etherscan.io/address/0x42E5c7056bA0646eCBb770E6759aBbd43Ca17EA5) | [Sourcify](https://repo.sourcify.dev/11155111/0x42E5c7056bA0646eCBb770E6759aBbd43Ca17EA5) |
| EnglishAuction | [`0x50aCE619605F8C5093803194B58545aa6C36471d`](https://sepolia.etherscan.io/address/0x50aCE619605F8C5093803194B58545aa6C36471d) | [Sourcify](https://repo.sourcify.dev/11155111/0x50aCE619605F8C5093803194B58545aa6C36471d) |
| UniformEditionAuctionLens | [`0xA8F6af72eA5e58b571e551E9414D5430F4b10aCe`](https://sepolia.etherscan.io/address/0xA8F6af72eA5e58b571e551E9414D5430F4b10aCe) | [Sourcify](https://repo.sourcify.dev/11155111/0xA8F6af72eA5e58b571e551E9414D5430F4b10aCe) |
| UniformEditionAuction | [`0x5ffaC5C15BC631Bf928f47669981534cf4A3a3aB`](https://sepolia.etherscan.io/address/0x5ffaC5C15BC631Bf928f47669981534cf4A3a3aB) | [Sourcify](https://repo.sourcify.dev/11155111/0x5ffaC5C15BC631Bf928f47669981534cf4A3a3aB) |

`CurationVerifier` is `Eip712CurationVerifier` and `EntropyModule` is `VrfEntropyModule`. The
manager is created by the configurator's constructor; Sourcify matched its creation code
inside that transaction. Each auction's lens is deployed in its own transaction, just before
its auction, which pins the lens's code hash.

<details>
<summary>r4 gas per transaction</summary>

Every gas limit came from the node's `eth_estimateGas` (Glamsterdam costs) just before sending
(`--slow --skip-simulation`), times forge's 1.3 multiplier; the Estimate column is the limit
divided back. The runbook's estimates for the auction transactions: UniformEditionAuction about 39.9M (r4: 38,317,552); UniformEditionAuctionLens about 30.7M (r4: 30,234,170); EnglishAuction about 37.8M (r4: 36,848,337); EnglishAuctionLens about 10.4M (r4: 10,234,620). Every
transaction stayed under 40M; the largest estimate is Stream's
(38,682,590). Per-row data: [`script/sepolia/deploy_gas.py`](../../script/sepolia/deploy_gas.py).

| # | Transaction | Prague (forge) | Estimate (node) | Sepolia | Ratio to Prague |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | [GovernanceConfigurator creation](https://sepolia.etherscan.io/tx/0x7061de150ac21f4fa37aadca7a810a0512352edd6f050bcc3d42f4cf159b2bfd) | 5,594,085 | 35,320,208 | 35,040,939 | 6.26 |
| 1 | [ContentStore creation](https://sepolia.etherscan.io/tx/0x8172f1171f640a00b9c2ea571caacc4a3de08f98ed6c903f9b119fea3b4f2815) | 1,727,851 | 11,620,860 | 11,436,985 | 6.62 |
| 2 | [ContentStore `writeChunk`](https://sepolia.etherscan.io/tx/0x41bd205c8907c4bc2ecfab097c749ffd14317c483f07a5841208061bee2b62ff) | 1,716,351 | 11,328,364 | 11,238,006 | 6.55 |
| 3 | [ContentStore `registerManifest`](https://sepolia.etherscan.io/tx/0x445d578ffc29cf000f4139f708c74d11aada5566554d6da19ede56ab0e8add94) | 152,825 | 583,488 | 577,737 | 3.78 |
| 4 | [DependencyRegistry creation](https://sepolia.etherscan.io/tx/0xfc4080b684814d592614b98ac878ebb60cc28dc6f433bfc03ae4b57f31e7b9bf) | 784,257 | 5,065,670 | 4,984,219 | 6.36 |
| 5 | [ConsolidationAdapter creation](https://sepolia.etherscan.io/tx/0x1f0ada1b59d252a060fa7cc54544a9382b9a32eb42d8643a7f0b094554b02065) | 769,080 | 5,032,011 | 4,951,086 | 6.44 |
| 6 | [ArtistRegistry creation](https://sepolia.etherscan.io/tx/0x41eba52df669b258eaa0991e9290e03487c474e8bbe015a52c7ac3db2fe5d9ff) | 5,185,028 | 32,670,062 | 32,411,659 | 6.25 |
| 7 | [ReleaseVerifier creation](https://sepolia.etherscan.io/tx/0x393a0fd21eb18f296a065f47c10a95f44e0652f5f8cac8bd37a63cc89dfb41a4) | 962,598 | 5,993,642 | 5,897,693 | 6.13 |
| 8 | [SplitFactory creation](https://sepolia.etherscan.io/tx/0x87cb4288aa0b16fe593b3a906db3f7fe6768496c657e84cb92f58a26a70bb385) | 2,489,282 | 16,068,878 | 15,815,502 | 6.35 |
| 9 | [ClaimRouter creation](https://sepolia.etherscan.io/tx/0x508abbe5935761dfbc8296d1099cb2beb747bb407aebe2d7e6437bc7c9a8254e) | 753,625 | 4,972,032 | 4,892,045 | 6.49 |
| 10 | [AssetAllowlist creation](https://sepolia.etherscan.io/tx/0x60aaa1efbf79db6cc83a1c901629d6fb35110de775d5ec2ba3a138aa7baaefa9) | 1,276,912 | 7,772,705 | 7,648,958 | 5.99 |
| 11 | [EconomicsResolver creation](https://sepolia.etherscan.io/tx/0xf474d2c7c01fccd423a947143c76e24fdb59a4e8fd0104f7cfacae463752ac9f) | 2,780,787 | 17,017,398 | 16,749,202 | 6.02 |
| 12 | [RevenueEscrow creation](https://sepolia.etherscan.io/tx/0x37831a50fccd81758a62240b42e7301c1ce63368a221c10a90fe6ec4f92052d2) | 1,294,690 | 8,549,542 | 8,413,656 | 6.50 |
| 13 | [Eip712CurationVerifier creation](https://sepolia.etherscan.io/tx/0x48c0f6672e214f319396b75bd2f9bb49424d6fc87f6a14c8f29545e706a69b7a) | 1,402,524 | 9,287,142 | 9,139,731 | 6.52 |
| 14 | [PackageRegistry creation](https://sepolia.etherscan.io/tx/0xc7c0f92bb09703a44857a6cc69800827797f19a25a5ba0c88ef199317a0cb31e) | 3,382,218 | 22,550,040 | 22,195,396 | 6.56 |
| 15 | [StatementLog creation](https://sepolia.etherscan.io/tx/0x6fbb7ef4ae2d234da129ac469c2c1f56e4305f148d0d084ab2a773234c15971f) | 3,030,770 | 19,034,961 | 18,735,240 | 6.18 |
| 16 | [VrfEntropyModule creation](https://sepolia.etherscan.io/tx/0x9aa327dd678bf19f7955af4e713a4a457091c8763168180531e797bd82c2638a) | 2,172,037 | 14,051,835 | 13,829,977 | 6.37 |
| 17 | [Renderer creation](https://sepolia.etherscan.io/tx/0x9090360771281860d48f14a98b75bc196150d38f1999e8f50ce60a7559d4d3eb) | 5,667,774 | 38,203,975 | 37,901,998 | 6.69 |
| 18 | [Stream creation](https://sepolia.etherscan.io/tx/0x7a689b74122e52b6e45ea9e1717c7eaec18f35c47e651cd4f6032d5df3ebd75b) | 6,184,218 | 38,682,590 | 38,376,845 | 6.21 |
| 19 | [WorkRecords creation](https://sepolia.etherscan.io/tx/0x01039b0713545cd1eee2f8da1ad4a14d4510b56118bc2014f9284e050d024ca5) | 5,774,438 | 36,335,955 | 36,048,688 | 6.24 |
| 20 | [Editions creation](https://sepolia.etherscan.io/tx/0xe05005ce96c7eae80b3ee58f1e20a96839e384e16507a91d9649cf43d210cc79) | 4,789,614 | 30,345,680 | 29,869,229 | 6.24 |
| 21 | [EnglishAuctionLens creation](https://sepolia.etherscan.io/tx/0x8972ddcc7192077ffa413207da953cb62454580b7b567c365a48d871f80cd6f1) | 1,528,772 | 10,234,620 | 10,072,405 | 6.59 |
| 22 | [EnglishAuction creation](https://sepolia.etherscan.io/tx/0xf8ef31b10c2fbc0632d0e4d4caad88654f3bb5efe1d127fae9d5e46e769eb780) | 5,878,227 | 36,848,337 | 36,557,035 | 6.22 |
| 23 | [UniformEditionAuctionLens creation](https://sepolia.etherscan.io/tx/0xb9fa62a2afab6632387ebc60b6a4504fd0f57b9d4a25c69c420683cda518d213) | 4,454,658 | 30,234,170 | 29,759,462 | 6.68 |
| 24 | [UniformEditionAuction creation](https://sepolia.etherscan.io/tx/0xbe18f544269e9eaab1f5511fb0b43261f73a53daca7617774a24950556328e90) | 6,139,812 | 38,317,552 | 38,014,681 | 6.19 |
| 25 | [GovernanceConfigurator `configure`](https://sepolia.etherscan.io/tx/0x78d92289776dfd68cd0ae38fec79bf8c5751183edb8ffbe4b5b5eaf4e3a9958f) | 4,923,101 | 15,628,868 | 15,498,794 | 3.15 |
| | **Total** | **80,815,534** | **501,750,585** | **496,057,168** | **6.14** |

The Prague column is forge's simulation of the same run with the final manifest.

</details>

## sepolia-r3: 15 October 2026 (superseded by r4)

r3 stays deployed as a rehearsal record; new work targets r4.

r3 is the release-candidate code: `main` after every adversarial-review fix
([#51](https://github.com/6529-Collections/6529-works/pull/51) to
[#57](https://github.com/6529-Collections/6529-works/pull/57)), the state-growth gas diet
([#63](https://github.com/6529-Collections/6529-works/pull/63)) and the source-quality pass
([#66](https://github.com/6529-Collections/6529-works/pull/66)). It uses the same Safes and keys as
r1 and r2 (see [r1's holders](#holders)), a new namespace and its own VRF subscription. Every
contract's source is verified on Sourcify.

| | |
| --- | --- |
| Status | Deployed and configured in blocks 11,922,739 to 11,922,763, on 15 October 2026 between 20:16:48 and 20:21:36 UTC. |
| Live Verify due | After the manager's 5-day `minSetback`, counted from the `configure` block (20:21:36 UTC): from **20 October 2026, 20:21:36 UTC**. |
| Verify so far | `Verify.s.sol` passes on a Sepolia fork advanced five days: 15 targets, 19 wiring calls and 17 holders, with every address and code hash, the CC0 text, the manifest and the VRF subscription's single consumer. On the live chain today it stops at the first role delay, which is still pending (`RoleMismatch(0)`), as expected. |
| Source | `main` at `e5fe78c` ([#66](https://github.com/6529-Collections/6529-works/pull/66)), solc 0.8.37, `prague` |
| Source verification | [Sourcify](https://sourcify.dev): all 23 contracts, `exact_match` for both the runtime and the creation code (links below). Etherscan verification was not submitted: it needs an Etherscan API key, which this run did not have. |
| Record | [`1792095396.json`](1792095396.json) (`"confirmed": false` until the live Verify) |
| Live Verify | Run it from `e5fe78c` or any later commit whose committed policy is unchanged: the runbook's step 11 with `DEPLOYMENT=deployments/11155111/1792095396.json` and `MANIFEST_PATH=config/sepolia-r3/manifest-epoch0.json`. |
| Genesis | [`config/sepolia-r3/genesis.json`](../../config/sepolia-r3/genesis.json): the committed policy at `e5fe78c` with r1's holders; `tools/check_genesis.py --config` passes on it |
| Epoch-0 manifest | [`config/sepolia-r3/manifest-epoch0.json`](../../config/sepolia-r3/manifest-epoch0.json), SHA-256 `aa2d15fd…fcb5` |
| Namespace | `keccak256("6529-works/sepolia/r3")` = `0x1e2d250a…59f1` |
| CC0 text | The committed fixture `test/fixtures/cc0-legalcode.txt`, the same file ID as r1 and r2 |
| Cost | 25 transactions, 476,686,821 gas (6.22x Foundry's Prague estimate of 76,583,081), 0.0238 Sepolia ETH. r2's deploy took 447,912,784: the contracts grew with the review fixes. |

**VRF subscription.**
- Subscription ID: `17380386597866271432801956755306382836538403307654991060607305935714544308003`.
- Owner: the operator.
- Funding: 0.15 Sepolia ETH, native payment.
- Same key hash and limits as r1 and r2.
- r3's entropy module is the only consumer.
- Transactions: created [`0x6520cad7…`](https://sepolia.etherscan.io/tx/0x6520cad74188d4edac14b38491164ac90fd5f1aaf42ed5346f7d0405a574d92f), funded [`0xc5dd96a3…`](https://sepolia.etherscan.io/tx/0xc5dd96a30eb0c6186a44889f83447e9d899fb210d917ac76e0efc3b1e6ce91d7), consumer added [`0xab0eb5cb…`](https://sepolia.etherscan.io/tx/0xab0eb5cb6f49f737dbc251606bd0d0e2146ac716843f9c5fd5cae865b6a00fcc).

### Contracts (r3)

| Contract | Address | Source |
| --- | --- | --- |
| WorksAccessManager | [`0x1bD0d448B5B030d1b0bFE1A7A1BBA21ED3d18745`](https://sepolia.etherscan.io/address/0x1bD0d448B5B030d1b0bFE1A7A1BBA21ED3d18745) | [Sourcify](https://repo.sourcify.dev/11155111/0x1bD0d448B5B030d1b0bFE1A7A1BBA21ED3d18745) |
| GovernanceConfigurator | [`0xFbffd423a8CEADab85767985f281b16720a3A8a4`](https://sepolia.etherscan.io/address/0xFbffd423a8CEADab85767985f281b16720a3A8a4) | [Sourcify](https://repo.sourcify.dev/11155111/0xFbffd423a8CEADab85767985f281b16720a3A8a4) |
| ContentStore | [`0x102Fa07952733593036181bce6EA68Eacb288f08`](https://sepolia.etherscan.io/address/0x102Fa07952733593036181bce6EA68Eacb288f08) | [Sourcify](https://repo.sourcify.dev/11155111/0x102Fa07952733593036181bce6EA68Eacb288f08) |
| DependencyRegistry | [`0x48D7dB75981Be98041013151767322e335d24537`](https://sepolia.etherscan.io/address/0x48D7dB75981Be98041013151767322e335d24537) | [Sourcify](https://repo.sourcify.dev/11155111/0x48D7dB75981Be98041013151767322e335d24537) |
| ConsolidationAdapter | [`0x98D0c5A504047BF20c13cd534E58cd1F6E5bF85C`](https://sepolia.etherscan.io/address/0x98D0c5A504047BF20c13cd534E58cd1F6E5bF85C) | [Sourcify](https://repo.sourcify.dev/11155111/0x98D0c5A504047BF20c13cd534E58cd1F6E5bF85C) |
| ArtistRegistry | [`0x69617D97A6186F1b84591C741B42E6432A50ee00`](https://sepolia.etherscan.io/address/0x69617D97A6186F1b84591C741B42E6432A50ee00) | [Sourcify](https://repo.sourcify.dev/11155111/0x69617D97A6186F1b84591C741B42E6432A50ee00) |
| ReleaseVerifier | [`0x7a8b7A34Ac1A3A823C6463576FCe2C970C7C5fa9`](https://sepolia.etherscan.io/address/0x7a8b7A34Ac1A3A823C6463576FCe2C970C7C5fa9) | [Sourcify](https://repo.sourcify.dev/11155111/0x7a8b7A34Ac1A3A823C6463576FCe2C970C7C5fa9) |
| SplitFactory | [`0x9f016127Ea06AC90ac0E5d2D938e6f9761B2C4a7`](https://sepolia.etherscan.io/address/0x9f016127Ea06AC90ac0E5d2D938e6f9761B2C4a7) | [Sourcify](https://repo.sourcify.dev/11155111/0x9f016127Ea06AC90ac0E5d2D938e6f9761B2C4a7) |
| ClaimRouter | [`0x512fE15d72E3001C97688a4DC87dd33C8FA0d1fa`](https://sepolia.etherscan.io/address/0x512fE15d72E3001C97688a4DC87dd33C8FA0d1fa) | [Sourcify](https://repo.sourcify.dev/11155111/0x512fE15d72E3001C97688a4DC87dd33C8FA0d1fa) |
| AssetAllowlist | [`0xf639F666075Ffa068c9c5a652933A2D93436DEa7`](https://sepolia.etherscan.io/address/0xf639F666075Ffa068c9c5a652933A2D93436DEa7) | [Sourcify](https://repo.sourcify.dev/11155111/0xf639F666075Ffa068c9c5a652933A2D93436DEa7) |
| EconomicsResolver | [`0xeF46fed48bECC91be66716872c3Cca8dF312863c`](https://sepolia.etherscan.io/address/0xeF46fed48bECC91be66716872c3Cca8dF312863c) | [Sourcify](https://repo.sourcify.dev/11155111/0xeF46fed48bECC91be66716872c3Cca8dF312863c) |
| RevenueEscrow | [`0x41bb809F592518a27057b45227D22207E63b1D30`](https://sepolia.etherscan.io/address/0x41bb809F592518a27057b45227D22207E63b1D30) | [Sourcify](https://repo.sourcify.dev/11155111/0x41bb809F592518a27057b45227D22207E63b1D30) |
| CurationVerifier | [`0xdA2B89D3aF0563e8a2C3BD744b70B36f1AFA9B55`](https://sepolia.etherscan.io/address/0xdA2B89D3aF0563e8a2C3BD744b70B36f1AFA9B55) | [Sourcify](https://repo.sourcify.dev/11155111/0xdA2B89D3aF0563e8a2C3BD744b70B36f1AFA9B55) |
| PackageRegistry | [`0xB5f86498E01a4B197F1b8403075A45aD8b796FE9`](https://sepolia.etherscan.io/address/0xB5f86498E01a4B197F1b8403075A45aD8b796FE9) | [Sourcify](https://repo.sourcify.dev/11155111/0xB5f86498E01a4B197F1b8403075A45aD8b796FE9) |
| StatementLog | [`0x38d4C76be1864aCF5A4cD8517F5b855706BDF3ec`](https://sepolia.etherscan.io/address/0x38d4C76be1864aCF5A4cD8517F5b855706BDF3ec) | [Sourcify](https://repo.sourcify.dev/11155111/0x38d4C76be1864aCF5A4cD8517F5b855706BDF3ec) |
| EntropyModule | [`0x7CD0F20950975620c3A718871619ca89b26DC66F`](https://sepolia.etherscan.io/address/0x7CD0F20950975620c3A718871619ca89b26DC66F) | [Sourcify](https://repo.sourcify.dev/11155111/0x7CD0F20950975620c3A718871619ca89b26DC66F) |
| Renderer | [`0xf35E84765bad1CEF10Cf782125F4614Aa20B513F`](https://sepolia.etherscan.io/address/0xf35E84765bad1CEF10Cf782125F4614Aa20B513F) | [Sourcify](https://repo.sourcify.dev/11155111/0xf35E84765bad1CEF10Cf782125F4614Aa20B513F) |
| Stream | [`0x7377B99f91c6Ab88B7db41276B75e8ef8b1AEE2F`](https://sepolia.etherscan.io/address/0x7377B99f91c6Ab88B7db41276B75e8ef8b1AEE2F) | [Sourcify](https://repo.sourcify.dev/11155111/0x7377B99f91c6Ab88B7db41276B75e8ef8b1AEE2F) |
| WorkRecords | [`0xb5dd70dE6522f5bAfEba0af1D300B2c71b75aD3E`](https://sepolia.etherscan.io/address/0xb5dd70dE6522f5bAfEba0af1D300B2c71b75aD3E) | [Sourcify](https://repo.sourcify.dev/11155111/0xb5dd70dE6522f5bAfEba0af1D300B2c71b75aD3E) |
| Editions | [`0x3213D06f6906E2F4B6959c52dEac138006A86f2f`](https://sepolia.etherscan.io/address/0x3213D06f6906E2F4B6959c52dEac138006A86f2f) | [Sourcify](https://repo.sourcify.dev/11155111/0x3213D06f6906E2F4B6959c52dEac138006A86f2f) |
| EnglishAuction | [`0x429f5011e2c8706c7Cfe066678084874e6DfB4e9`](https://sepolia.etherscan.io/address/0x429f5011e2c8706c7Cfe066678084874e6DfB4e9) | [Sourcify](https://repo.sourcify.dev/11155111/0x429f5011e2c8706c7Cfe066678084874e6DfB4e9) |
| FixedPriceSale | [`0xC703f43E9E24eDF0c5FBbFf7A22ea2dbF145D505`](https://sepolia.etherscan.io/address/0xC703f43E9E24eDF0c5FBbFf7A22ea2dbF145D505) | [Sourcify](https://repo.sourcify.dev/11155111/0xC703f43E9E24eDF0c5FBbFf7A22ea2dbF145D505) |
| DutchSale | [`0x605c312fb42c643C17892E25b2d77bC7C8eC674A`](https://sepolia.etherscan.io/address/0x605c312fb42c643C17892E25b2d77bC7C8eC674A) | [Sourcify](https://repo.sourcify.dev/11155111/0x605c312fb42c643C17892E25b2d77bC7C8eC674A) |

`CurationVerifier` is `Eip712CurationVerifier` and `EntropyModule` is `VrfEntropyModule`. The
manager is created by the configurator's constructor; Sourcify matched its creation code
inside that transaction.

<details>
<summary>r3 gas per transaction, with r2's</summary>

| # | Transaction | Prague (forge) | Sepolia | Ratio | r2 Sepolia |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | [GovernanceConfigurator creation](https://sepolia.etherscan.io/tx/0x35439948af8b79e0f487012336175ddd9072be5dc83c3bd6df1147f26dd2f107) | 5,277,085 | 34,999,171 | 6.63 | 33,602,795 |
| 1 | [ContentStore creation](https://sepolia.etherscan.io/tx/0xce4765fac6036300c3d725baac39b670c5d122fc1267c9d260012e99c3080ac3) | 1,727,851 | 11,436,985 | 6.62 | 11,392,063 |
| 2 | [ContentStore `writeChunk`](https://sepolia.etherscan.io/tx/0xbb23ff6dcd2aad4260b20b6a77f3e6b270d26bdb53e0a1a2a96cbbec83d68d8f) | 1,716,351 | 11,238,006 | 6.55 | 11,238,006 |
| 3 | [ContentStore `registerManifest`](https://sepolia.etherscan.io/tx/0xbe35c03eeb950ab346eea02a3287d35129bdcade6384ee4700338395c3150091) | 152,825 | 577,737 | 3.78 | 577,737 |
| 4 | [DependencyRegistry creation](https://sepolia.etherscan.io/tx/0x1904232abadf39bf1028705c82690162e891bd90146af58bdffc09699bd3cece) | 830,377 | 4,984,207 | 6.00 | 4,981,963 |
| 5 | [ConsolidationAdapter creation](https://sepolia.etherscan.io/tx/0xc05daa0362a306ea61646718a62bb67cdace3443b9a2b208b13e61f9a0fdd92b) | 769,092 | 4,951,098 | 6.44 | 4,825,117 |
| 6 | [ArtistRegistry creation](https://sepolia.etherscan.io/tx/0x157c1f2c57def7b3079cf81e87732b98a11f9e3b0d914ff1fd923ade70bd9315) | 4,838,298 | 32,017,239 | 6.62 | 29,578,918 |
| 7 | [ReleaseVerifier creation](https://sepolia.etherscan.io/tx/0x61ce87ee4ef9c3a30bc699f1c61fb6ece15e3b2bd44505054904e35148adce83) | 909,107 | 5,897,681 | 6.49 | 5,842,008 |
| 8 | [SplitFactory creation](https://sepolia.etherscan.io/tx/0x49bff3d6065c461f1e6dcd189e837649e6a022a098982b131599741133bcb858) | 2,489,255 | 15,815,478 | 6.35 | 14,412,179 |
| 9 | [ClaimRouter creation](https://sepolia.etherscan.io/tx/0xa48746fa1f99dc481856aa74d420df37e4523dfd0d68330b5d60256d8e4d94c9) | 753,625 | 4,892,045 | 6.49 | 4,294,932 |
| 10 | [AssetAllowlist creation](https://sepolia.etherscan.io/tx/0x632ba95e126781255866830b91c7eb702bb55700c62551bb60f4c7d419919036) | 1,267,391 | 7,588,612 | 5.99 | 6,802,727 |
| 11 | [EconomicsResolver creation](https://sepolia.etherscan.io/tx/0xf69c6d1dfb8a2c3f024edcda6ba7b49c5faba8ede9e5449458effde3fdea04b9) | 2,785,501 | 15,862,355 | 5.69 | 12,947,427 |
| 12 | [RevenueEscrow creation](https://sepolia.etherscan.io/tx/0x1c1ee4b743dbf02fa5031f33b85c653d674e2e69dfb6155e551948cf8a873247) | 1,294,690 | 8,413,656 | 6.50 | 7,537,555 |
| 13 | [Eip712CurationVerifier creation](https://sepolia.etherscan.io/tx/0xa9a8e204aea5c3d118755a3039937fa98f8fb5a2b87abfae5f4aefeb6ccaea29) | 1,402,524 | 9,139,731 | 6.52 | 8,179,457 |
| 14 | [PackageRegistry creation](https://sepolia.etherscan.io/tx/0x02c37722b8f0a7d8ff169ef3852a2fd15b320c8b56f9346f5bcc144c4da446ad) | 3,777,788 | 23,443,627 | 6.21 | 22,553,948 |
| 15 | [StatementLog creation](https://sepolia.etherscan.io/tx/0xa7e245d6ed33bd166a7ea34c3de84ef8cfb94f924d1ee42d1442456cdc3928d4) | 2,862,298 | 18,735,150 | 6.55 | 16,884,691 |
| 16 | [VrfEntropyModule creation](https://sepolia.etherscan.io/tx/0x5877bbfaf781e999f059a4f4567fa3c48ef6047d055dba7e55007c57464ecce3) | 2,284,715 | 13,734,092 | 6.01 | 12,511,926 |
| 17 | [Renderer creation](https://sepolia.etherscan.io/tx/0xb9269e7f3ea35c0103c9a1bcc1ea7948a5b2be1dce65bec669950dffac801f06) | 6,008,951 | 37,951,478 | 6.32 | 38,118,823 |
| 18 | [Stream creation](https://sepolia.etherscan.io/tx/0x5cac5058e7a19904175cb8cd9969a08963f724b4ce47852eab1cad3b90cbb4bd) | 5,047,731 | 33,057,380 | 6.55 | 30,693,665 |
| 19 | [WorkRecords creation](https://sepolia.etherscan.io/tx/0xf0ca13178cf919802997440ae9720a205b3fb2873df0616093db1a53f08e9420) | 5,451,447 | 36,004,062 | 6.60 | 34,046,474 |
| 20 | [Editions creation](https://sepolia.etherscan.io/tx/0x76d2363b25e8a2248fc7e4e1b0942ae3f659037451b08b44fedfed4213aa2cad) | 4,411,402 | 29,135,858 | 6.60 | 29,065,991 |
| 21 | [EnglishAuction creation](https://sepolia.etherscan.io/tx/0x76bf30304635466f24886b0429d7c3e113a0bd16d779dfee281683d34f184662) | 5,772,620 | 38,174,397 | 6.61 | 36,234,008 |
| 22 | [FixedPriceSale creation](https://sepolia.etherscan.io/tx/0x9bb34b29d8327966ea3be420a80128f3b7e282314633e76424a95d3835bb922f) | 5,406,051 | 35,895,926 | 6.64 | 32,342,893 |
| 23 | [DutchSale creation](https://sepolia.etherscan.io/tx/0x1b374721520a6ebaa472dc2ea4cfaad4f14cb4eadf62172ccde40958e3c025c6) | 4,296,322 | 26,878,489 | 6.26 | 23,719,102 |
| 24 | [GovernanceConfigurator `configure`](https://sepolia.etherscan.io/tx/0x12d495cad37c78bdc6b74f35abc038f0f252f5e72bc15e049381b40e88c2a713) | 5,049,784 | 15,862,361 | 3.14 | 15,528,379 |
| | **Total** | **76,583,081** | **476,686,821** | **6.22** | **447,912,784** |

The Prague column is forge's simulation of the same run with the first-pass manifest, which
differs from the final one only in its contract addresses, so the `configure` row can differ
by a few dozen gas.

</details>

## sepolia-r2: 11 October 2026 (superseded by r3)

r2 stays deployed as a rehearsal record; new work targets r4.

r2 is the full v1 scope on `main`, including the contested-override recovery and the Editions
gas changes. It uses the same Safes and keys as r1 (see [r1's holders](#holders)), a new
namespace and its own VRF subscription.

| | |
| --- | --- |
| Status | Deployed and configured in blocks 11,894,139 to 11,894,163. Live Verify is due after the 5-day `minSetback`: from 16 October 2026, about 20:30 UTC. |
| Verify so far | `Verify.s.sol` passes on a Sepolia fork advanced five days: 15 targets, 19 wiring calls and 17 holders. It also checked every address and code hash, the CC0 text and the manifest. |
| Source | `main` at `400f96d` ([#44](https://github.com/6529-Collections/6529-works/pull/44)), solc 0.8.37, `prague` |
| Not included | [#46](https://github.com/6529-Collections/6529-works/pull/46): a bounded read in `ArtistRegistry.bindStatementLog`. It is a one-shot genesis binding; r2's genesis already bound its own statement log, and Verify reads that back. |
| Later on `main` | The fixes from the internal review of 14 October 2026 ([#51](https://github.com/6529-Collections/6529-works/pull/51) to [#57](https://github.com/6529-Collections/6529-works/pull/57)): among them the identity reservations, the fail-closed consolidation reads with a 200,000-gas stipend per getter, the no-return rule for authorities, the restraint while an override is pending, the code-hash re-checks at use, and the sales and auction fixes. r2 does not have them; [r3](#sepolia-r3-15-october-2026-superseded-by-r4) does. |
| Record | [`1791750816.json`](1791750816.json). Here `delegationMock` is `false`: since [#42](https://github.com/6529-Collections/6529-works/pull/42) the script compares the delegation's code hash with mainnet's and records it. |
| Live Verify | Run it from r2's source commit, because later policy changes (new governed selectors, wiring and genesis keys) make the current committed policy differ: `git worktree add ../works-r2 400f96d`, copy this record and `config/sepolia-r2/` into it, then run the Verify command in the runbook (step 11) there. For the same reason, `python tools/check_genesis.py --config config/sepolia-r2/genesis.json` on today's `main` reports policy differences, which is expected. |
| Genesis | [`config/sepolia-r2/genesis.json`](../../config/sepolia-r2/genesis.json): the committed policy at `400f96d` with r1's holders |
| Epoch-0 manifest | [`config/sepolia-r2/manifest-epoch0.json`](../../config/sepolia-r2/manifest-epoch0.json) |
| Namespace | `keccak256("6529-works/sepolia/r2")` = `0xd4cf2286…f090` |
| CC0 text | The committed fixture `test/fixtures/cc0-legalcode.txt` (the default since #42) |
| Cost | 25 transactions, 447,912,784 gas (6.17x Foundry's Prague estimate of 72,554,849), 0.0224 Sepolia ETH |

**VRF subscription.**
- Subscription ID: `26755781173204397845410634685189131694841872990785294795546827480670579805631`.
- Owner: the operator.
- Funding: 0.2 Sepolia ETH, native payment.
- Same key hash and limits as r1.
- r2's entropy module is the only consumer.
- Transactions: created [`0xf5ad50f7…`](https://sepolia.etherscan.io/tx/0xf5ad50f734eb5fc21583a318da02135be253fecd8ad6109e303d229d80f00e5d), funded [`0xee5835f5…`](https://sepolia.etherscan.io/tx/0xee5835f57c409458118c720db4aca2ed63d6da2b7eec98e94ab2a2421048db53), consumer added [`0xc2188e8c…`](https://sepolia.etherscan.io/tx/0xc2188e8cfd3efb3fae693e004298d43760f1c2cc323800bcf561f18744f0a288).

### Contracts (r2)

| Contract | Address |
| --- | --- |
| WorksAccessManager | [`0x7Aec16E5c5F9903a38cC8798838A336A9Ce4dB2B`](https://sepolia.etherscan.io/address/0x7Aec16E5c5F9903a38cC8798838A336A9Ce4dB2B) |
| GovernanceConfigurator | [`0x7720Ba52FC54DF9C749B88010BC191dbb0FD0e3E`](https://sepolia.etherscan.io/address/0x7720Ba52FC54DF9C749B88010BC191dbb0FD0e3E) |
| ContentStore | [`0x3E56048F2aaBEf5251f8e1469FB9979F324b3a11`](https://sepolia.etherscan.io/address/0x3E56048F2aaBEf5251f8e1469FB9979F324b3a11) |
| DependencyRegistry | [`0x4a8ed20fe380e2BB5136cD76c3590571C52dc27D`](https://sepolia.etherscan.io/address/0x4a8ed20fe380e2BB5136cD76c3590571C52dc27D) |
| ConsolidationAdapter | [`0x058E4c352410D3B0D791a691843755d1A34c3Bb9`](https://sepolia.etherscan.io/address/0x058E4c352410D3B0D791a691843755d1A34c3Bb9) |
| ArtistRegistry | [`0xd97D8c7492CeD34686C945BE7520aeF537e29F0F`](https://sepolia.etherscan.io/address/0xd97D8c7492CeD34686C945BE7520aeF537e29F0F) |
| ReleaseVerifier | [`0x83d98ad388f2FAb6CBA8cBe2BFCFe341cB763FD9`](https://sepolia.etherscan.io/address/0x83d98ad388f2FAb6CBA8cBe2BFCFe341cB763FD9) |
| SplitFactory | [`0x848AD949280d99Cc5D26ff2ec1Ffc1764Fd751E3`](https://sepolia.etherscan.io/address/0x848AD949280d99Cc5D26ff2ec1Ffc1764Fd751E3) |
| ClaimRouter | [`0x290E6A0643a169B59ECD246040062867eB479996`](https://sepolia.etherscan.io/address/0x290E6A0643a169B59ECD246040062867eB479996) |
| AssetAllowlist | [`0xf620Ea96cC8f34F9ba21b18447BfC14FD08830ad`](https://sepolia.etherscan.io/address/0xf620Ea96cC8f34F9ba21b18447BfC14FD08830ad) |
| EconomicsResolver | [`0xA86Dea795D01F49CcDe5c1Dba6541F849511cd45`](https://sepolia.etherscan.io/address/0xA86Dea795D01F49CcDe5c1Dba6541F849511cd45) |
| RevenueEscrow | [`0xFF1Edec521E9F73956C4f58F7C3A3e4208597294`](https://sepolia.etherscan.io/address/0xFF1Edec521E9F73956C4f58F7C3A3e4208597294) |
| CurationVerifier | [`0x3033958a90aFa377fCE4b61597F9ec0D8Af6EC9a`](https://sepolia.etherscan.io/address/0x3033958a90aFa377fCE4b61597F9ec0D8Af6EC9a) |
| PackageRegistry | [`0x48232794Cb568e068770039d1c4Da69861B2e786`](https://sepolia.etherscan.io/address/0x48232794Cb568e068770039d1c4Da69861B2e786) |
| StatementLog | [`0x054D783CC94b6c5Df06eDceB6910484D5423a3B5`](https://sepolia.etherscan.io/address/0x054D783CC94b6c5Df06eDceB6910484D5423a3B5) |
| EntropyModule | [`0x97f20345E6B0A9769733E42a98C6bfDC059De457`](https://sepolia.etherscan.io/address/0x97f20345E6B0A9769733E42a98C6bfDC059De457) |
| Renderer | [`0xA7e78e3825D407198790735BB95982679B03DeEF`](https://sepolia.etherscan.io/address/0xA7e78e3825D407198790735BB95982679B03DeEF) |
| Stream | [`0x7Ae459CCC1e8410912743d5FD6f832d1cf1981B4`](https://sepolia.etherscan.io/address/0x7Ae459CCC1e8410912743d5FD6f832d1cf1981B4) |
| WorkRecords | [`0xEEa4093106d5918Bc1D1Fa00369aE81c8EB7cAa2`](https://sepolia.etherscan.io/address/0xEEa4093106d5918Bc1D1Fa00369aE81c8EB7cAa2) |
| Editions | [`0xA83ed940684B7B4D706415c4315AD63b6cdD5cfc`](https://sepolia.etherscan.io/address/0xA83ed940684B7B4D706415c4315AD63b6cdD5cfc) |
| EnglishAuction | [`0xCa4FEFfA995210BcaDE279D74D7AadD824721813`](https://sepolia.etherscan.io/address/0xCa4FEFfA995210BcaDE279D74D7AadD824721813) |
| FixedPriceSale | [`0xbc3ee6DDDb3c117C387049e347573fcFAdEbD6D5`](https://sepolia.etherscan.io/address/0xbc3ee6DDDb3c117C387049e347573fcFAdEbD6D5) |
| DutchSale | [`0x47DCcCA6f5D09A6af747e02F432838091A17A501`](https://sepolia.etherscan.io/address/0x47DCcCA6f5D09A6af747e02F432838091A17A501) |

<details>
<summary>r2 gas per transaction</summary>

| # | Transaction | Prague (forge) | Sepolia | Ratio |
| ---: | --- | ---: | ---: | ---: |
| 0 | [GovernanceConfigurator creation](https://sepolia.etherscan.io/tx/0x1a09dbf0af877f51087ed2071a06edb27fa2ed76cbdc9d4daf1a6736699675ac) | 5,361,897 | 33,602,795 | 6.27 |
| 1 | [ContentStore creation](https://sepolia.etherscan.io/tx/0xe08a7c071327910e30440f3e7474d0b075ee8fdf180b59bd81b2f22b57e6dd35) | 1,822,350 | 11,392,063 | 6.25 |
| 2 | [ContentStore `writeChunk`](https://sepolia.etherscan.io/tx/0x6dcc6877cee0a9107542d14e19b680692f2d2d49bdf809ad1b73ee0594ca18c5) | 1,716,351 | 11,238,006 | 6.55 |
| 3 | [ContentStore `registerManifest`](https://sepolia.etherscan.io/tx/0x15eb1c0c5a56489886a318104f3c9439d55c5e95c0c4914b4587c8a978b1638b) | 152,825 | 577,737 | 3.78 |
| 4 | [DependencyRegistry creation](https://sepolia.etherscan.io/tx/0x754e3f04b61fac26efdf6add82798339bb7d31b46fd6fd8c85a9ea378a9b609b) | 827,965 | 4,981,963 | 6.02 |
| 5 | [ConsolidationAdapter creation](https://sepolia.etherscan.io/tx/0xd33a7f890b70ec2c50d56aacb5011ff518dec63fd8a8b56606be068f62df0378) | 748,405 | 4,825,117 | 6.45 |
| 6 | [ArtistRegistry creation](https://sepolia.etherscan.io/tx/0xbd7eab17bac643d1c08859bb955366b2afda8e104dfa6261383d9493f8fb8bc6) | 4,729,492 | 29,578,918 | 6.25 |
| 7 | [ReleaseVerifier creation](https://sepolia.etherscan.io/tx/0x3f8e10436f32bce1b2fc164cbb0d8f569f09970fde4e1ee25f9e9dfcc86d15ac) | 900,834 | 5,842,008 | 6.49 |
| 8 | [SplitFactory creation](https://sepolia.etherscan.io/tx/0x71217cd27f7637f9d4a148e6f21781e157f24c820540ae191a1cd8cc0e776f9b) | 2,303,524 | 14,412,179 | 6.26 |
| 9 | [ClaimRouter creation](https://sepolia.etherscan.io/tx/0x0f88360f1f1e7ad0c156ead7b01fd606fffa814ab5261d42e55f55417c8ca4ec) | 703,838 | 4,294,932 | 6.10 |
| 10 | [AssetAllowlist creation](https://sepolia.etherscan.io/tx/0x951f36a1d27be107693e3bd8623a16042ae6fdfd24f83f16b92958a400bd72c1) | 1,140,474 | 6,802,727 | 5.96 |
| 11 | [EconomicsResolver creation](https://sepolia.etherscan.io/tx/0x96340e5e420dc1cd2b06e1df7092979d116e42b456a6d42c1ccc57c78bf60a6e) | 2,115,962 | 12,947,427 | 6.12 |
| 12 | [RevenueEscrow creation](https://sepolia.etherscan.io/tx/0xfa8159eaa5a31269a0ac916e43a17155a03bd58f6316bcfefd756af367373ce8) | 1,163,775 | 7,537,555 | 6.48 |
| 13 | [Eip712CurationVerifier creation](https://sepolia.etherscan.io/tx/0xb5cef5e5362325ab9c3028b726173c180a645d8c68afa46bbfc9afd3cf6c9e03) | 1,334,017 | 8,179,457 | 6.13 |
| 14 | [PackageRegistry creation](https://sepolia.etherscan.io/tx/0x6d75339e18fcb1c37571a2ad64c981d641ec49126d9c6c327745d58ba9afaa88) | 3,428,352 | 22,553,948 | 6.58 |
| 15 | [StatementLog creation](https://sepolia.etherscan.io/tx/0x78fb7cb6c414bebfae1a58080222242539a2e6c9e9e6986fd31810ca3a979275) | 2,731,330 | 16,884,691 | 6.18 |
| 16 | [VrfEntropyModule creation](https://sepolia.etherscan.io/tx/0x8fb138ceb1dee9b0754486a257742075bb8744ab89d355aa64fb04cf10a6f39b) | 1,968,827 | 12,511,926 | 6.36 |
| 17 | [Renderer creation](https://sepolia.etherscan.io/tx/0xf417bda286a10f3d964909913da5f086c68e49dc85748c1973bb49b5876a4c76) | 6,035,598 | 38,118,823 | 6.32 |
| 18 | [Stream creation](https://sepolia.etherscan.io/tx/0xf7c13d7cfc109578a85dc11c535287edbaf5dbd0dea9a4f34ac4f41d8dee90a5) | 4,963,231 | 30,693,665 | 6.18 |
| 19 | [WorkRecords creation](https://sepolia.etherscan.io/tx/0x451e6a46e165310e73fcaeac71791ead1e3ef4e62458ac2dffa5e4a29c9a8573) | 5,162,194 | 34,046,474 | 6.60 |
| 20 | [Editions creation](https://sepolia.etherscan.io/tx/0xe1d39e84bd19d3e4bd3bc211a8bbc4d2b75e1ff8bfd6c5f67b3ec92b275f6c02) | 4,400,771 | 29,065,991 | 6.60 |
| 21 | [EnglishAuction creation](https://sepolia.etherscan.io/tx/0x1494c0823d975a5b35026d5f3b4785f4dbbcd3b61666401dc74265e401d2412e) | 5,476,835 | 36,234,008 | 6.62 |
| 22 | [FixedPriceSale creation](https://sepolia.etherscan.io/tx/0x6136eae5bba2afb813643367439f4993773e96135829db2c3aaeb7aeef0a561b) | 5,170,105 | 32,342,893 | 6.26 |
| 23 | [DutchSale creation](https://sepolia.etherscan.io/tx/0x34db0d154e1e5cd96719c22cf9b4f725e62a358e03c7b75dd0896bb6530041ec) | 3,593,727 | 23,719,102 | 6.60 |
| 24 | [GovernanceConfigurator `configure`](https://sepolia.etherscan.io/tx/0x8e25b328bd6c5e971afb1ede00fc874e5cc101949662ec1d51b8d2efb277e26e) | 4,602,170 | 15,528,379 | 3.37 |
| | **Total** | **72,554,849** | **447,912,784** | **6.17** |

</details>

## sepolia-r1: 11 October 2026 (superseded by r2)

r1 stays deployed as a rehearsal record; new work targets r4.

| | |
| --- | --- |
| Status | Deployed and configured in blocks 11,893,778 to 11,893,802. Live Verify is due after the manager's 5-day `minSetback`: from 16 October 2026, 19:21 UTC. |
| Verify so far | `Verify.s.sol` passes on a Sepolia fork advanced five days. It checked the 15 targets, 18 wiring calls and 17 holders, every address and code hash, the CC0 text and the manifest. On the live chain today it stops at the first role delay, which is still pending (`RoleMismatch(0)`), as expected. |
| Source | `main` at `60edd9b` ([#40](https://github.com/6529-Collections/6529-works/pull/40)), solc 0.8.37, `prague` |
| Not included | The Editions gas changes ([#41](https://github.com/6529-Collections/6529-works/pull/41), merged after this run) and the contested-override recovery (ADR 0003, decision 1, in progress). A later rehearsal redeploys under a new namespace. |
| Record | [`1791746472.json`](1791746472.json) (`"confirmed": false` until the live Verify) |
| Live Verify | Run it from r1's source commit, because later policy changes (new governed selectors, wiring and genesis keys) make the current committed policy differ: `git worktree add ../works-r1 60edd9b`, copy this record and `config/sepolia-r1/` into it, then run the Verify command in the runbook (step 11) there. `tools/check_genesis.py --config` on today's `main` reports differences for this copy too, as expected. |
| Genesis | [`config/sepolia-r1/genesis.json`](../../config/sepolia-r1/genesis.json): the committed policy with the holders below |
| Epoch-0 manifest | [`config/sepolia-r1/manifest-epoch0.json`](../../config/sepolia-r1/manifest-epoch0.json), SHA-256 `cfb688aa…7c56` |
| Namespace | `keccak256("6529-works/sepolia/r1")` = `0x5d0566b3…2454` |
| Operator | `0x26A3f4505145b5E6164260cc868e50ddd9863697`: signed the deploy and `configure`; holds no role |
| Cost | 25 transactions, 445,176,878 gas, 0.0223 Sepolia ETH at a 0.05 gwei priority fee |

### Contracts

| Contract | Address |
| --- | --- |
| WorksAccessManager | [`0x4aa96AA18088BfaD4919F14C4b396Cb98EBa2f33`](https://sepolia.etherscan.io/address/0x4aa96AA18088BfaD4919F14C4b396Cb98EBa2f33) |
| GovernanceConfigurator | [`0x16069B324d7adfa3007AEB08F877c5F0A3dF3EF9`](https://sepolia.etherscan.io/address/0x16069B324d7adfa3007AEB08F877c5F0A3dF3EF9) |
| ContentStore | [`0x3C59350687ae2B8e5584e60C8bDdbbE60f861B9a`](https://sepolia.etherscan.io/address/0x3C59350687ae2B8e5584e60C8bDdbbE60f861B9a) |
| DependencyRegistry | [`0xd4ca0655ca95CEE78bC1B5b070A4F8fDd9040AD1`](https://sepolia.etherscan.io/address/0xd4ca0655ca95CEE78bC1B5b070A4F8fDd9040AD1) |
| ConsolidationAdapter | [`0xd19D099F3cBeB42A11B2F58296E05D5Cc43Aa297`](https://sepolia.etherscan.io/address/0xd19D099F3cBeB42A11B2F58296E05D5Cc43Aa297) |
| ArtistRegistry | [`0xFEfCD96c3b3A95a852b475A2449Ce6E85ca6D253`](https://sepolia.etherscan.io/address/0xFEfCD96c3b3A95a852b475A2449Ce6E85ca6D253) |
| ReleaseVerifier | [`0xF58Fe3673024F7d89bd69797AB6825949d344F4a`](https://sepolia.etherscan.io/address/0xF58Fe3673024F7d89bd69797AB6825949d344F4a) |
| SplitFactory | [`0x28533594915A45D98938d12D5725B6ff4DF0f424`](https://sepolia.etherscan.io/address/0x28533594915A45D98938d12D5725B6ff4DF0f424) |
| ClaimRouter | [`0x8444805f76a44FbD3161eF52E484a6b1E5CE75cA`](https://sepolia.etherscan.io/address/0x8444805f76a44FbD3161eF52E484a6b1E5CE75cA) |
| AssetAllowlist | [`0x277B8aCc9dcEDB75AdE5668717e30EFe352001bb`](https://sepolia.etherscan.io/address/0x277B8aCc9dcEDB75AdE5668717e30EFe352001bb) |
| EconomicsResolver | [`0x556758418daF133784F9C75E7b63BaDB608aEAAd`](https://sepolia.etherscan.io/address/0x556758418daF133784F9C75E7b63BaDB608aEAAd) |
| RevenueEscrow | [`0x0115D20ab92ee2BAa3d83714f617854282c4f5bA`](https://sepolia.etherscan.io/address/0x0115D20ab92ee2BAa3d83714f617854282c4f5bA) |
| CurationVerifier | [`0xaDdD57B8480fBc1d85bd2427e2a58331729c93bd`](https://sepolia.etherscan.io/address/0xaDdD57B8480fBc1d85bd2427e2a58331729c93bd) |
| PackageRegistry | [`0x5Af03101871EB9414f16415Dd3E7C3CEb081c5b9`](https://sepolia.etherscan.io/address/0x5Af03101871EB9414f16415Dd3E7C3CEb081c5b9) |
| StatementLog | [`0x4F09b03F1FB31B368C60a6518aAf3E788fCE9b63`](https://sepolia.etherscan.io/address/0x4F09b03F1FB31B368C60a6518aAf3E788fCE9b63) |
| EntropyModule | [`0xF1afB4772C70207423cdE19d144CDd350E1F38Bd`](https://sepolia.etherscan.io/address/0xF1afB4772C70207423cdE19d144CDd350E1F38Bd) |
| Renderer | [`0xC506AA04EdDD7b3b3146dB9C0f78AEB50d27F2f6`](https://sepolia.etherscan.io/address/0xC506AA04EdDD7b3b3146dB9C0f78AEB50d27F2f6) |
| Stream | [`0x94DB49438E3940C5Cd48F4f71c7a4A26a0eb955f`](https://sepolia.etherscan.io/address/0x94DB49438E3940C5Cd48F4f71c7a4A26a0eb955f) |
| WorkRecords | [`0xE8a653585F460bb44F4f3E0D6F1173F900b43A2C`](https://sepolia.etherscan.io/address/0xE8a653585F460bb44F4f3E0D6F1173F900b43A2C) |
| Editions | [`0x29A1DEBB4DC4ABC99668C85B7D0BF37684b1B31F`](https://sepolia.etherscan.io/address/0x29A1DEBB4DC4ABC99668C85B7D0BF37684b1B31F) |
| EnglishAuction | [`0x6645064D9D5AcF8C674357E1B65df516F2247800`](https://sepolia.etherscan.io/address/0x6645064D9D5AcF8C674357E1B65df516F2247800) |
| FixedPriceSale | [`0xfAfFC71D691eDf722BFcEd68a647BC5d599CDE3d`](https://sepolia.etherscan.io/address/0xfAfFC71D691eDf722BFcEd68a647BC5d599CDE3d) |
| DutchSale | [`0x1D2326c0c4ae102943Adc532c926A70e10E2A347`](https://sepolia.etherscan.io/address/0x1D2326c0c4ae102943Adc532c926A70e10E2A347) |

### Holders

The Safes are Safe 1.4.1 (L1 singleton) with the mainnet structure. Each one executed a
threshold-signed test transaction before genesis (Safe pre-flight, runbook step 2). The
signer keys are encrypted keystores on the operator's machine; none is in this repository.

| Holder | Address | Threshold | Roles |
| --- | --- | --- | --- |
| Hot admin Safe | [`0x2588A62384F41bB32412841ab774CD574b427bd5`](https://sepolia.etherscan.io/address/0x2588A62384F41bB32412841ab774CD574b427bd5) | 2-of-3 | ADMIN, UNPAUSER, PARAMETER_SETTER, FUNDS_SETTER, SUCCESSOR_SETTER; network fee recipient |
| Cold recovery admin Safe | [`0x5090272f56f9139CfE91aa927bc547244FC0d6B9`](https://sepolia.etherscan.io/address/0x5090272f56f9139CfE91aa927bc547244FC0d6B9) | 3-of-5 | ADMIN only (recovery) |
| Guardian Safe 1 | [`0x5d1103f2FC0ce8D0E81a918A3819182208B6E916`](https://sepolia.etherscan.io/address/0x5d1103f2FC0ce8D0E81a918A3819182208B6E916) | 2-of-3 | GUARDIAN, PAUSER |
| Guardian Safe 2 | [`0x894D246cA153Be5a9b125d694e52cdD146f5be8C`](https://sepolia.etherscan.io/address/0x894D246cA153Be5a9b125d694e52cdD146f5be8C) | 2-of-3 | GUARDIAN, PAUSER |
| Guardian Safe 3 | [`0x708A1Eb9D5ea5678D5168752ee0bfe3D58f4bA7e`](https://sepolia.etherscan.io/address/0x708A1Eb9D5ea5678D5168752ee0bfe3D58f4bA7e) | 2-of-3 | GUARDIAN, PAUSER |
| Curation signer 1 | [`0xc7091A91Fa76f7494a3b847B6A08f164C7097830`](https://sepolia.etherscan.io/address/0xc7091A91Fa76f7494a3b847B6A08f164C7097830) | key | CURATION_SIGNER |
| Curation signer 2 | [`0x148F83Bd54Ef232d8e7056a21Ca777C6e8Bac709`](https://sepolia.etherscan.io/address/0x148F83Bd54Ef232d8e7056a21Ca777C6e8Bac709) | key | CURATION_SIGNER |
| Storage operator | [`0x4484CEBA86645575Fd1E48Ac06dCc8c6CEe44ACd`](https://sepolia.etherscan.io/address/0x4484CEBA86645575Fd1E48Ac06dCc8c6CEe44ACd) | key | STORAGE_OPERATOR |
| Platform | [`0x0a69CdD0d8De0680779237aFF610C90b61B83b2D`](https://sepolia.etherscan.io/address/0x0a69CdD0d8De0680779237aFF610C90b61B83b2D) | key | PLATFORM; marketplace owner (Stream `owner()`) |
| Curator | [`0xBDccCcBfAF7aAE8702bD41e79f0CF0441676906a`](https://sepolia.etherscan.io/address/0xBDccCcBfAF7aAE8702bD41e79f0CF0441676906a) | key | CURATOR |

The hot and cold admin Safes share no signer, and no guardian signer signs for an admin
Safe. The owners of each Safe are listed in the epoch-0 manifest.

### External contracts

| Contract | Address | Notes |
| --- | --- | --- |
| 6529 delegation contract | [`0x8f86c644f845A077999939C69Bc787662377d915`](https://sepolia.etherscan.io/address/0x8f86c644f845A077999939C69Bc787662377d915) | The official NFTDelegation deployment on Sepolia, listed in [6529-Collections/nftdelegation](https://github.com/6529-Collections/nftdelegation). Its runtime bytecode is byte-identical to mainnet `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`. |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Foundry's default factory |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | Dedicated subscription below |

**VRF subscription.**
- Subscription ID: `67141663544939655902710981754240722879597693570821648217296649312180545379426`.
- Owner: the operator.
- Funding: 0.25 Sepolia ETH, native payment.
- Key hash: `0x787d74ca…77ae` (500 gwei lane); callback gas limit 200,000; 3 confirmations.
- The entropy module is the only consumer.
- Transactions: created [`0xfae30277…`](https://sepolia.etherscan.io/tx/0xfae30277775300db15ae55d7938341077e32989055e9ab727b4194d17a225d32), funded [`0xc6e69fcf…`](https://sepolia.etherscan.io/tx/0xc6e69fcfc38953b00c6c11150b4cfe12f93678024751391aa42148ab5447cd8b), consumer added [`0x112c8d35…`](https://sepolia.etherscan.io/tx/0x112c8d3529bc03974a34b1909af13e512391a2d01605a288a23e8cb8e362dedd).

**The record's `delegationMock` is `true`.** When r1 ran, the script compared the address
with the mainnet one, so any other address counted as a mock. Here it is the official
contract with the mainnet bytecode. Since
[#42](https://github.com/6529-Collections/6529-works/pull/42) the script compares code hashes
and records the delegation's code hash, so later records get this right. This record is left
as generated.

### Glamsterdam: gas on Sepolia

Sepolia activated Glamsterdam on 6 October 2026 at 13:53 UTC (`eth_config`). State creation
is repriced. Foundry 1.7.1 has no Amsterdam EVM, so it simulates with Prague costs, and the
first broadcast attempt failed: the configurator's creation ran out of gas at the 1.3x
estimate. That failed transaction cost 0.0064 ETH and deployed nothing.

Measured on Sepolia with `eth_estimateGas`:

| Operation | Prague | Sepolia now |
| --- | ---: | ---: |
| Contract code, per byte | 200 | about 1,542 |
| New storage slot (`SSTORE` from zero) | 22,100 | about 111,000 |
| Contract creation, empty | about 53,000 | about 210,000 |
| Zero-value call to an empty account | 21,000 | 15,000 |

- Transactions above the EIP-7825 cap of 16,777,216 gas are accepted. The largest here
  used 38.1M.
- The block gas limit is 200M.
- The deployment was broadcast with `--skip-simulation --slow`, so each gas limit came from
  the node's `eth_estimateGas` when the transaction was sent.

| # | Transaction | Prague (forge) | Sepolia | Ratio |
| ---: | --- | ---: | ---: | ---: |
| 0 | [GovernanceConfigurator creation](https://sepolia.etherscan.io/tx/0x26207a550d7ae2b26272d61f42451a24b2e313e9055be10276b2cb4a0c2f7109) | 5,355,300 | 33,561,015 | 6.27 |
| 1 | [ContentStore creation](https://sepolia.etherscan.io/tx/0xd41bf9241dfdde59e0b2439375df47f74ba18d30e3274f417d747a37b0afbff8) | 1,721,121 | 11,392,075 | 6.62 |
| 2 | [ContentStore `writeChunk`](https://sepolia.etherscan.io/tx/0x7076b65ec2256c68f49c7a5fb7ebebf0de4a3ebb3d5c3b6b255b87856ce2b09e) | 1,716,351 | 11,238,006 | 6.55 |
| 3 | [ContentStore `registerManifest`](https://sepolia.etherscan.io/tx/0xefbc66150321882fc372774d5d29b821684fc3494d897b8f3a427db74463b27f) | 152,825 | 577,737 | 3.78 |
| 4 | [DependencyRegistry creation](https://sepolia.etherscan.io/tx/0x87305228c8af09786a5da941e4b42c9c905ce3704936bbcd460dea44463521c8) | 781,978 | 4,981,975 | 6.37 |
| 5 | [ConsolidationAdapter creation](https://sepolia.etherscan.io/tx/0xc3b3ff0dab523ef041507dcad9ec718bf67fa1caaf776423e8209dda44ece76c) | 748,405 | 4,825,117 | 6.45 |
| 6 | [ArtistRegistry creation](https://sepolia.etherscan.io/tx/0x1996c3033b3553f9b198e71228c904db07876e54dcfcdb2d1a009de82a765301) | 4,271,160 | 26,670,757 | 6.24 |
| 7 | [ReleaseVerifier creation](https://sepolia.etherscan.io/tx/0x736670100450313679632110190076d20cfcc086159ab430e4dc836e96cd9433) | 900,821 | 5,841,996 | 6.49 |
| 8 | [SplitFactory creation](https://sepolia.etherscan.io/tx/0x7d21c7675cc043d74a63eb399300bdbca4639548cbd21fefbe9be759841e6d46) | 2,303,524 | 14,412,179 | 6.26 |
| 9 | [ClaimRouter creation](https://sepolia.etherscan.io/tx/0x2b49af1fa9dcf38e6c6ba5413826a9f122ee38e45486cbcbba749774ccf8b446) | 664,748 | 4,294,944 | 6.46 |
| 10 | [AssetAllowlist creation](https://sepolia.etherscan.io/tx/0x554487b780f7f9860221be6668e97a74864c821dc27b4d2a0b923c89c6cce55b) | 1,140,474 | 6,802,727 | 5.96 |
| 11 | [EconomicsResolver creation](https://sepolia.etherscan.io/tx/0x29a4a4979b268ff6ee5bfce6f7c390a5c980915ed1435597e293523d049cc4e6) | 2,115,962 | 12,947,427 | 6.12 |
| 12 | [RevenueEscrow creation](https://sepolia.etherscan.io/tx/0x198c631dba63d9124544dbf581742c306bf32a134bcd66cc0196d05482d43afd) | 1,163,775 | 7,537,555 | 6.48 |
| 13 | [Eip712CurationVerifier creation](https://sepolia.etherscan.io/tx/0x83c1b39e6d4eb425813ed92cf00e68db443d87fc074d6784582dcb9d73c33ab7) | 1,334,017 | 8,179,457 | 6.13 |
| 14 | [PackageRegistry creation](https://sepolia.etherscan.io/tx/0xe6e0e0c6f90215e4cefd50d2c24c4612ab3f2039588414ecd3d97013419f95f0) | 3,428,352 | 22,553,948 | 6.58 |
| 15 | [StatementLog creation](https://sepolia.etherscan.io/tx/0x0e42e48f597ea682b2eb8740d2d41998a3115f3912693d92e0248b53f60103d5) | 2,731,330 | 16,884,691 | 6.18 |
| 16 | [VrfEntropyModule creation](https://sepolia.etherscan.io/tx/0xf2c09050650589703f53784563bd485bd8c364a1383c7639d8429117df44ba54) | 1,968,827 | 12,511,926 | 6.36 |
| 17 | [Renderer creation](https://sepolia.etherscan.io/tx/0xa1e3c196af9958071cbd424e458bbf988818a5edd9ddb94a1ef4fbb35dd5ae75) | 6,035,598 | 38,118,823 | 6.32 |
| 18 | [Stream creation](https://sepolia.etherscan.io/tx/0x2f8c631ba59de9ec12de8da5f1b8ff51034548d6c9c4e8a9e36b8485623db824) | 4,963,231 | 30,693,665 | 6.18 |
| 19 | [WorkRecords creation](https://sepolia.etherscan.io/tx/0x4835b17dbe0b752433fbbb1fe2b6c320c2d589b17ffc56097104a3fab9c5a68a) | 5,162,207 | 34,046,486 | 6.60 |
| 20 | [Editions creation](https://sepolia.etherscan.io/tx/0x23127052a8b1b1b2edf4d0422b92e9182a4e71f2f2fa341dc5627221305d1394) | 4,732,131 | 29,526,821 | 6.24 |
| 21 | [EnglishAuction creation](https://sepolia.etherscan.io/tx/0x20e7ec8fd712e33aad621b306054f35cf325bf55c4ef94223fd94a2d6569031c) | 5,476,811 | 36,233,984 | 6.62 |
| 22 | [FixedPriceSale creation](https://sepolia.etherscan.io/tx/0x751aadc91e75f4441bcb1cf518695395370d8ebfe933f13d64625f96c2765774) | 4,882,888 | 32,342,905 | 6.62 |
| 23 | [DutchSale creation](https://sepolia.etherscan.io/tx/0x5ed8e5bf0684a57b93afb642361af7d94b8aa34c8b8b53895b73fe2e69297bac) | 3,593,727 | 23,719,102 | 6.60 |
| 24 | [GovernanceConfigurator `configure`](https://sepolia.etherscan.io/tx/0xd67c5e6e2f532751c6eb7942e5e535f29a33cd193e4f2f515dc4ab0e50a98c7b) | 4,527,287 | 15,281,560 | 3.38 |
| | **Total** | **71,872,850** | **445,176,878** | **6.19** |

**What this changes.**
- **Writing state.** Anything that writes state costs more on Glamsterdam than the Prague
  numbers in the gas reports. Examples:
  - `start` and `settle`;
  - `createEdition` and `mint`;
  - the content store's chunk uploads, which pay for every byte as contract code. The
    7,048-byte CC0 text cost 11.2M gas to store, against 1.7M on Prague.
- **What to measure on Sepolia.** The ADR 0001 and ADR 0003 budgets, the storage cost
  guidance for artists and the `tokenURI` matrix.
- **Foundry.** Until Foundry supports Amsterdam, its gas reports and `forge script`
  estimates understate these costs.

