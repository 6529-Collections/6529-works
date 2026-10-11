# Sepolia (chain 11155111)

Deployment records for 6529 Works on Sepolia. Each record is written by
[`script/Deploy.s.sol`](../../script/Deploy.s.sol) and confirmed by
[`script/Verify.s.sol`](../../script/Verify.s.sol); the runbook is
[`script/README.md`](../../script/README.md).

These are testnet rehearsals with throwaway signers. The code is pre-audit and nothing
here is a mainnet deployment.

## sepolia-r2: 11 October 2026 (current)

r2 is the full v1 scope on `main`, including the contested-override recovery and the Editions
gas changes. It uses the same Safes and keys as r1 (see [r1's holders](#holders)), a new
namespace and its own VRF subscription.

| | |
| --- | --- |
| Status | Deployed and configured in blocks 11,894,139 to 11,894,163. Live Verify is due after the 5-day `minSetback`: from 16 October 2026, about 20:30 UTC. |
| Verify so far | `Verify.s.sol` passes on a Sepolia fork advanced five days: 15 targets, 19 wiring calls and 17 holders. It also checked every address and code hash, the CC0 text and the manifest. |
| Source | `main` at `400f96d` ([#44](https://github.com/6529-Collections/6529-works/pull/44)), solc 0.8.37, `prague` |
| Not included | [#46](https://github.com/6529-Collections/6529-works/pull/46): a bounded read in `ArtistRegistry.bindStatementLog`. It is a one-shot genesis binding; r2's genesis already bound its own statement log, and Verify reads that back. |
| Record | [`1791750816.json`](1791750816.json). Here `delegationMock` is `false`: since [#42](https://github.com/6529-Collections/6529-works/pull/42) the script compares the delegation's code hash with mainnet's and records it. |
| Genesis | [`config/sepolia-r2/genesis.json`](../../config/sepolia-r2/genesis.json): the current committed policy with r1's holders |
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

r1 stays deployed as a rehearsal record; new work targets r2.

| | |
| --- | --- |
| Status | Deployed and configured in blocks 11,893,778 to 11,893,802. Live Verify is due after the manager's 5-day `minSetback`: from 16 October 2026, 19:21 UTC. |
| Verify so far | `Verify.s.sol` passes on a Sepolia fork advanced five days. It checked the 15 targets, 18 wiring calls and 17 holders, every address and code hash, the CC0 text and the manifest. On the live chain today it stops at the first role delay, which is still pending (`RoleMismatch(0)`), as expected. |
| Source | `main` at `60edd9b` ([#40](https://github.com/6529-Collections/6529-works/pull/40)), solc 0.8.37, `prague` |
| Not included | The Editions gas changes ([#41](https://github.com/6529-Collections/6529-works/pull/41), merged after this run) and the contested-override recovery (ADR 0003, decision 1, in progress). A later rehearsal redeploys under a new namespace. |
| Record | [`1791746472.json`](1791746472.json) (`"confirmed": false` until the live Verify) |
| Live Verify | Run it from r1's source commit, because later policy changes (new governed selectors or wiring) make the current committed policy differ: `git worktree add ../works-r1 60edd9b`, copy this record and `config/sepolia-r1/` into it, then run the Verify command in the runbook (step 11) there. |
| Flows | [`flows-r1.md`](flows-r1.md): the v1 flows run on r1 and their gas under Glamsterdam (11 October 2026; settlement and editions pending) |
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

