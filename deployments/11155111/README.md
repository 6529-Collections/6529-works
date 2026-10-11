# Sepolia (chain 11155111)

Deployment records for 6529 Works on Sepolia. Each record is written by
[`script/Deploy.s.sol`](../../script/Deploy.s.sol) and confirmed by
[`script/Verify.s.sol`](../../script/Verify.s.sol); the runbook is
[`script/README.md`](../../script/README.md).

These are testnet rehearsals with throwaway signers. The code is pre-audit and nothing
here is a mainnet deployment.

## sepolia-r1: 11 October 2026

| | |
| --- | --- |
| Status | Deployed and configured in blocks 11,893,778 to 11,893,802. Live Verify is due after the manager's 5-day `minSetback`: from 16 October 2026, 19:21 UTC. |
| Verify so far | `Verify.s.sol` passes on a Sepolia fork advanced five days. It checked the 15 targets, 18 wiring calls and 17 holders, every address and code hash, the CC0 text and the manifest. On the live chain today it stops at the first role delay, which is still pending (`RoleMismatch(0)`), as expected. |
| Source | `main` at `60edd9b` ([#40](https://github.com/6529-Collections/6529-works/pull/40)), solc 0.8.37, `prague` |
| Not included | The Editions gas changes ([#41](https://github.com/6529-Collections/6529-works/pull/41), merged after this run) and the contested-override recovery (ADR 0003, decision 1, in progress). A later rehearsal redeploys under a new namespace. |
| Record | [`1791746472.json`](1791746472.json) (`"confirmed": false` until the live Verify) |
| Live Verify | Run it from r1's source commit, because later policy changes (new governed selectors or wiring) make the current committed policy differ: `git worktree add ../works-r1 60edd9b`, copy this record and `config/sepolia-r1/` into it, then run the Verify command in the runbook (step 11) there. |
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

**The record's `delegationMock` is `true`.** The script compares the address with the
mainnet one, so any other address counts as a mock. Here it is the official contract with
the mainnet bytecode. The record will compare code hashes once the deploy-lane change lands;
this record is left as generated.

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

