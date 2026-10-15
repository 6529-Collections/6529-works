# Addresses

Where the 6529 Works contracts are deployed, and which source each deployment runs.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment. The Sepolia instances are testnet rehearsals with throwaway
signers; do not send them value you care about.

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | To be decided after the external audit | None |
| Sepolia | 11155111 | **r3** (current) | `main` at `e5fe78c` | [`1792095396.json`](../../deployments/11155111/1792095396.json) |
| Sepolia | 11155111 | r2 (superseded) | `main` at `400f96d` | [`1791750816.json`](../../deployments/11155111/1791750816.json) |
| Sepolia | 11155111 | r1 (superseded) | `main` at `60edd9b` | [`1791746472.json`](../../deployments/11155111/1791746472.json) |

The deployment records are the source of truth for every address below. The
[Sepolia README](../../deployments/11155111/README.md) adds the holders, the VRF
subscription, every deployment transaction and its gas, and r3's Sourcify links.

## Sepolia r3

Deployed and configured on 15 October 2026 in blocks 11,922,739 to 11,922,763, under the
namespace `keccak256("6529-works/sepolia/r3")`. Every address comes from the record
[`1792095396.json`](../../deployments/11155111/1792095396.json).

**r3 runs `main` at `e5fe78c`**: every fix from the October 2026 internal review, the
state-growth gas diet and the source-quality pass. Build its ABIs from `e5fe78c`
([ABIs and interface IDs](abis-and-interface-ids.md)), or read them from Sourcify, where every
r3 contract is verified with an exact match (links in the
[Sepolia README](../../deployments/11155111/README.md#contracts-r3)).

### Products

| Contract | Address |
| --- | --- |
| Stream (ERC-721) | [`0x7377B99f91c6Ab88B7db41276B75e8ef8b1AEE2F`](https://sepolia.etherscan.io/address/0x7377B99f91c6Ab88B7db41276B75e8ef8b1AEE2F) |
| WorkRecords | [`0xb5dd70dE6522f5bAfEba0af1D300B2c71b75aD3E`](https://sepolia.etherscan.io/address/0xb5dd70dE6522f5bAfEba0af1D300B2c71b75aD3E) |
| Editions (ERC-1155) | [`0x3213D06f6906E2F4B6959c52dEac138006A86f2f`](https://sepolia.etherscan.io/address/0x3213D06f6906E2F4B6959c52dEac138006A86f2f) |

### Sales

| Contract | Address |
| --- | --- |
| EnglishAuction | [`0x429f5011e2c8706c7Cfe066678084874e6DfB4e9`](https://sepolia.etherscan.io/address/0x429f5011e2c8706c7Cfe066678084874e6DfB4e9) |
| FixedPriceSale | [`0xC703f43E9E24eDF0c5FBbFf7A22ea2dbF145D505`](https://sepolia.etherscan.io/address/0xC703f43E9E24eDF0c5FBbFf7A22ea2dbF145D505) |
| DutchSale | [`0x605c312fb42c643C17892E25b2d77bC7C8eC674A`](https://sepolia.etherscan.io/address/0x605c312fb42c643C17892E25b2d77bC7C8eC674A) |

### Curation and identity

| Contract | Address |
| --- | --- |
| PackageRegistry | [`0xB5f86498E01a4B197F1b8403075A45aD8b796FE9`](https://sepolia.etherscan.io/address/0xB5f86498E01a4B197F1b8403075A45aD8b796FE9) |
| CurationVerifier (`Eip712CurationVerifier`) | [`0xdA2B89D3aF0563e8a2C3BD744b70B36f1AFA9B55`](https://sepolia.etherscan.io/address/0xdA2B89D3aF0563e8a2C3BD744b70B36f1AFA9B55) |
| ArtistRegistry | [`0x69617D97A6186F1b84591C741B42E6432A50ee00`](https://sepolia.etherscan.io/address/0x69617D97A6186F1b84591C741B42E6432A50ee00) |
| ConsolidationAdapter | [`0x98D0c5A504047BF20c13cd534E58cd1F6E5bF85C`](https://sepolia.etherscan.io/address/0x98D0c5A504047BF20c13cd534E58cd1F6E5bF85C) |

### Economics

| Contract | Address |
| --- | --- |
| EconomicsResolver | [`0xeF46fed48bECC91be66716872c3Cca8dF312863c`](https://sepolia.etherscan.io/address/0xeF46fed48bECC91be66716872c3Cca8dF312863c) |
| AssetAllowlist | [`0xf639F666075Ffa068c9c5a652933A2D93436DEa7`](https://sepolia.etherscan.io/address/0xf639F666075Ffa068c9c5a652933A2D93436DEa7) |
| SplitFactory | [`0x9f016127Ea06AC90ac0E5d2D938e6f9761B2C4a7`](https://sepolia.etherscan.io/address/0x9f016127Ea06AC90ac0E5d2D938e6f9761B2C4a7) |
| ReleaseVerifier | [`0x7a8b7A34Ac1A3A823C6463576FCe2C970C7C5fa9`](https://sepolia.etherscan.io/address/0x7a8b7A34Ac1A3A823C6463576FCe2C970C7C5fa9) |
| RevenueEscrow | [`0x41bb809F592518a27057b45227D22207E63b1D30`](https://sepolia.etherscan.io/address/0x41bb809F592518a27057b45227D22207E63b1D30) |
| ClaimRouter | [`0x512fE15d72E3001C97688a4DC87dd33C8FA0d1fa`](https://sepolia.etherscan.io/address/0x512fE15d72E3001C97688a4DC87dd33C8FA0d1fa) |

Split wallets are not listed: each is deployed on demand at its predicted CREATE2 address
(`SplitFactory.walletFor`).

### Content, records and entropy

| Contract | Address |
| --- | --- |
| ContentStore | [`0x102Fa07952733593036181bce6EA68Eacb288f08`](https://sepolia.etherscan.io/address/0x102Fa07952733593036181bce6EA68Eacb288f08) |
| DependencyRegistry | [`0x48D7dB75981Be98041013151767322e335d24537`](https://sepolia.etherscan.io/address/0x48D7dB75981Be98041013151767322e335d24537) |
| Renderer | [`0xf35E84765bad1CEF10Cf782125F4614Aa20B513F`](https://sepolia.etherscan.io/address/0xf35E84765bad1CEF10Cf782125F4614Aa20B513F) |
| StatementLog | [`0x38d4C76be1864aCF5A4cD8517F5b855706BDF3ec`](https://sepolia.etherscan.io/address/0x38d4C76be1864aCF5A4cD8517F5b855706BDF3ec) |
| EntropyModule (`VrfEntropyModule`) | [`0x7CD0F20950975620c3A718871619ca89b26DC66F`](https://sepolia.etherscan.io/address/0x7CD0F20950975620c3A718871619ca89b26DC66F) |

### Governance

| Contract | Address |
| --- | --- |
| WorksAccessManager | [`0x1bD0d448B5B030d1b0bFE1A7A1BBA21ED3d18745`](https://sepolia.etherscan.io/address/0x1bD0d448B5B030d1b0bFE1A7A1BBA21ED3d18745) |
| GovernanceConfigurator | [`0xFbffd423a8CEADab85767985f281b16720a3A8a4`](https://sepolia.etherscan.io/address/0xFbffd423a8CEADab85767985f281b16720a3A8a4) |

The role holders (Safes and keys) are listed in the
[Sepolia README](../../deployments/11155111/README.md#holders); r3 uses r1's holders, as r2 did.

### External contracts

| Contract | Address | Notes |
| --- | --- | --- |
| 6529 delegation contract | [`0x8f86c644f845A077999939C69Bc787662377d915`](https://sepolia.etherscan.io/address/0x8f86c644f845A077999939C69Bc787662377d915) | The official NFTDelegation deployment on Sepolia; its runtime bytecode equals mainnet's `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical address |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | r3 has its own subscription |
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

## Sepolia r2 (superseded)

Deployed on 11 October 2026 from `main` at `400f96d`, under the namespace
`keccak256("6529-works/sepolia/r2")`; the record is
[`1791750816.json`](../../deployments/11155111/1791750816.json) and its addresses are in the
[Sepolia README](../../deployments/11155111/README.md#contracts-r2). r2 predates the fixes from
the October 2026 internal review (PRs #51 to #57) and later changes: its manager, for example,
has no Rule 3 and no `suspend`. Build ABIs for r2 from `400f96d`
([ABIs and interface IDs](abis-and-interface-ids.md)).

## Checking an instance yourself

- **Code.** Each record pins every contract's address and code hash.
  [`script/Verify.s.sol`](../../script/Verify.s.sol) recomputes every address from the recorded
  constructor parameters and compares the code, the CC0 text, the manifest, the governance
  configuration and the genesis events with the chain. Run it from the instance's source
  commit: later source changes alter metadata hashes and therefore CREATE2 addresses
  ([script README](../../script/README.md)).
- **Governance.** The genesis policy each instance installed is committed under
  [`config/sepolia-r3/`](../../config/sepolia-r3/genesis.json), and its role map is the
  [role and permission matrix](../audit/roles.md) with the placeholder holders replaced.
- **Live Verify.** The manager's 5-day `minSetback` delays the first full readback; the
  [Sepolia README](../../deployments/11155111/README.md#sepolia-r3-15-october-2026-current)
  records when it is due and its result.

## Mainnet

Not deployed. Mainnet follows the external audit and remediation
([delivery plan](../../ops/DELIVERY_PLAN.md), phase 8). Its addresses will be added here and
under `deployments/1/` when they exist.
