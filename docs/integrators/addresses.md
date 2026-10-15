# Addresses

Where the 6529 Works contracts are deployed, and which source each deployment runs.

> **Status.** Pre-audit. There is no mainnet deployment. The Sepolia instances are testnet
> rehearsals with throwaway signers; do not treat them as production contracts, and do not
> send them value you care about.

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | To be decided after the external audit | None |
| Sepolia | 11155111 | **r2** (current) | `main` at `400f96d` | [`1791750816.json`](../../deployments/11155111/1791750816.json) |
| Sepolia | 11155111 | r1 (superseded) | `main` at `60edd9b` | [`1791746472.json`](../../deployments/11155111/1791746472.json) |

The deployment records are the source of truth for every address below. The
[Sepolia README](../../deployments/11155111/README.md) adds the holders, the VRF
subscription, every deployment transaction and its gas.

## Sepolia r2

Deployed and configured on 11 October 2026 in blocks 11,894,139 to 11,894,163, under the
namespace `keccak256("6529-works/sepolia/r2")`. Every address comes from the record
[`1791750816.json`](../../deployments/11155111/1791750816.json).

**r2 runs `400f96d`, not today's `main`.** The fixes from the October 2026 internal review
(PRs #51 to #57) and later changes are not in r2: its manager, for example, has no Rule 3 and
no `suspend`. Build ABIs for r2 from `400f96d`
([ABIs and interface IDs](abis-and-interface-ids.md)); a later rehearsal will deploy a newer
`main` under a new namespace.

### Products

| Contract | Address |
| --- | --- |
| Stream (ERC-721) | [`0x7Ae459CCC1e8410912743d5FD6f832d1cf1981B4`](https://sepolia.etherscan.io/address/0x7Ae459CCC1e8410912743d5FD6f832d1cf1981B4) |
| WorkRecords | [`0xEEa4093106d5918Bc1D1Fa00369aE81c8EB7cAa2`](https://sepolia.etherscan.io/address/0xEEa4093106d5918Bc1D1Fa00369aE81c8EB7cAa2) |
| Editions (ERC-1155) | [`0xA83ed940684B7B4D706415c4315AD63b6cdD5cfc`](https://sepolia.etherscan.io/address/0xA83ed940684B7B4D706415c4315AD63b6cdD5cfc) |

### Sales

| Contract | Address |
| --- | --- |
| EnglishAuction | [`0xCa4FEFfA995210BcaDE279D74D7AadD824721813`](https://sepolia.etherscan.io/address/0xCa4FEFfA995210BcaDE279D74D7AadD824721813) |
| FixedPriceSale | [`0xbc3ee6DDDb3c117C387049e347573fcFAdEbD6D5`](https://sepolia.etherscan.io/address/0xbc3ee6DDDb3c117C387049e347573fcFAdEbD6D5) |
| DutchSale | [`0x47DCcCA6f5D09A6af747e02F432838091A17A501`](https://sepolia.etherscan.io/address/0x47DCcCA6f5D09A6af747e02F432838091A17A501) |

### Curation and identity

| Contract | Address |
| --- | --- |
| PackageRegistry | [`0x48232794Cb568e068770039d1c4Da69861B2e786`](https://sepolia.etherscan.io/address/0x48232794Cb568e068770039d1c4Da69861B2e786) |
| CurationVerifier (`Eip712CurationVerifier`) | [`0x3033958a90aFa377fCE4b61597F9ec0D8Af6EC9a`](https://sepolia.etherscan.io/address/0x3033958a90aFa377fCE4b61597F9ec0D8Af6EC9a) |
| ArtistRegistry | [`0xd97D8c7492CeD34686C945BE7520aeF537e29F0F`](https://sepolia.etherscan.io/address/0xd97D8c7492CeD34686C945BE7520aeF537e29F0F) |
| ConsolidationAdapter | [`0x058E4c352410D3B0D791a691843755d1A34c3Bb9`](https://sepolia.etherscan.io/address/0x058E4c352410D3B0D791a691843755d1A34c3Bb9) |

### Economics

| Contract | Address |
| --- | --- |
| EconomicsResolver | [`0xA86Dea795D01F49CcDe5c1Dba6541F849511cd45`](https://sepolia.etherscan.io/address/0xA86Dea795D01F49CcDe5c1Dba6541F849511cd45) |
| AssetAllowlist | [`0xf620Ea96cC8f34F9ba21b18447BfC14FD08830ad`](https://sepolia.etherscan.io/address/0xf620Ea96cC8f34F9ba21b18447BfC14FD08830ad) |
| SplitFactory | [`0x848AD949280d99Cc5D26ff2ec1Ffc1764Fd751E3`](https://sepolia.etherscan.io/address/0x848AD949280d99Cc5D26ff2ec1Ffc1764Fd751E3) |
| ReleaseVerifier | [`0x83d98ad388f2FAb6CBA8cBe2BFCFe341cB763FD9`](https://sepolia.etherscan.io/address/0x83d98ad388f2FAb6CBA8cBe2BFCFe341cB763FD9) |
| RevenueEscrow | [`0xFF1Edec521E9F73956C4f58F7C3A3e4208597294`](https://sepolia.etherscan.io/address/0xFF1Edec521E9F73956C4f58F7C3A3e4208597294) |
| ClaimRouter | [`0x290E6A0643a169B59ECD246040062867eB479996`](https://sepolia.etherscan.io/address/0x290E6A0643a169B59ECD246040062867eB479996) |

Split wallets are not listed: each is deployed on demand at its predicted CREATE2 address
(`SplitFactory.walletFor`).

### Content, records and entropy

| Contract | Address |
| --- | --- |
| ContentStore | [`0x3E56048F2aaBEf5251f8e1469FB9979F324b3a11`](https://sepolia.etherscan.io/address/0x3E56048F2aaBEf5251f8e1469FB9979F324b3a11) |
| DependencyRegistry | [`0x4a8ed20fe380e2BB5136cD76c3590571C52dc27D`](https://sepolia.etherscan.io/address/0x4a8ed20fe380e2BB5136cD76c3590571C52dc27D) |
| Renderer | [`0xA7e78e3825D407198790735BB95982679B03DeEF`](https://sepolia.etherscan.io/address/0xA7e78e3825D407198790735BB95982679B03DeEF) |
| StatementLog | [`0x054D783CC94b6c5Df06eDceB6910484D5423a3B5`](https://sepolia.etherscan.io/address/0x054D783CC94b6c5Df06eDceB6910484D5423a3B5) |
| EntropyModule (`VrfEntropyModule`) | [`0x97f20345E6B0A9769733E42a98C6bfDC059De457`](https://sepolia.etherscan.io/address/0x97f20345E6B0A9769733E42a98C6bfDC059De457) |

### Governance

| Contract | Address |
| --- | --- |
| WorksAccessManager | [`0x7Aec16E5c5F9903a38cC8798838A336A9Ce4dB2B`](https://sepolia.etherscan.io/address/0x7Aec16E5c5F9903a38cC8798838A336A9Ce4dB2B) |
| GovernanceConfigurator | [`0x7720Ba52FC54DF9C749B88010BC191dbb0FD0e3E`](https://sepolia.etherscan.io/address/0x7720Ba52FC54DF9C749B88010BC191dbb0FD0e3E) |

The role holders (Safes and keys) are listed in the
[Sepolia README](../../deployments/11155111/README.md#holders); r2 uses r1's holders.

### External contracts

| Contract | Address | Notes |
| --- | --- | --- |
| 6529 delegation contract | [`0x8f86c644f845A077999939C69Bc787662377d915`](https://sepolia.etherscan.io/address/0x8f86c644f845A077999939C69Bc787662377d915) | The official NFTDelegation deployment on Sepolia; its runtime bytecode equals mainnet's `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical address |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | r2 has its own subscription |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Foundry's default factory, used for every deployment |

### Settings at deployment

From the record's `params`. Governed settings can change later through their delay classes;
read the contracts for current values.

| Setting | Value |
| --- | --- |
| Auction duration | 86,400 seconds (24 hours) |
| Anti-snipe window | 900 seconds (15 minutes) |
| Minimum increment share | 5,000 of 100,000 (5%) |
| ETH increment floor | 0.001 ETH (`1000000000000000` wei) |
| Network fee recipient | `0x2588A62384F41bB32412841ab774CD574b427bd5` (the hot admin Safe) |
| Marketplace owner (`owner()`) | `0x0a69CdD0d8De0680779237aFF610C90b61B83b2D` (the platform key) |
| VRF callback gas limit, confirmations, retry delay | 200,000; 3; 259,200 seconds (3 days) |
| CC0 legal text | file ID `0x16f36978…d22b`, SHA-256 `0xa2010f34…0499` |

## Checking an instance yourself

- **Code.** Each record pins every contract's address and code hash.
  [`script/Verify.s.sol`](../../script/Verify.s.sol) recomputes every address from the recorded
  constructor parameters and compares the code, the CC0 text, the manifest, the governance
  configuration and the genesis events with the chain. Run it from the instance's source
  commit: later source changes alter metadata hashes and therefore CREATE2 addresses
  ([script README](../../script/README.md)).
- **Governance.** The genesis policy each instance installed is committed under
  [`config/sepolia-r2/`](../../config/sepolia-r2/genesis.json), and its role map is the
  [role and permission matrix](../audit/roles.md) with the placeholder holders replaced.
- **Live Verify.** The manager's 5-day `minSetback` delays the first full readback; the
  [Sepolia README](../../deployments/11155111/README.md#sepolia-r2-11-october-2026-current)
  records when it is due and its result.

## Mainnet

Not deployed. Mainnet follows the external audit and remediation
([delivery plan](../../ops/DELIVERY_PLAN.md), phase 8). Its addresses will be added here and
under `deployments/1/` when they exist.
