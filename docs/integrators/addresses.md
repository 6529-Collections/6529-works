# Addresses

Where the 6529 Works contracts are deployed, and which source each deployment runs.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment. The Sepolia instances are testnet rehearsals with throwaway
signers; do not send them value you care about.

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | To be decided after the external audit | None |
| Sepolia | 11155111 | **r4** (current) | `main` at `1e7022b` | [`1793536584.json`](../../deployments/11155111/1793536584.json) |
| Sepolia | 11155111 | r3 (superseded) | `main` at `e5fe78c` (`v1.0.0-rc.1`) | [`1792095396.json`](../../deployments/11155111/1792095396.json) |
| Sepolia | 11155111 | r2 (superseded) | `main` at `400f96d` | [`1791750816.json`](../../deployments/11155111/1791750816.json) |
| Sepolia | 11155111 | r1 (superseded) | `main` at `60edd9b` | [`1791746472.json`](../../deployments/11155111/1791746472.json) |

The deployment records are the source of truth for every address below. The
[Sepolia README](../../deployments/11155111/README.md) adds the holders, the VRF
subscription, every deployment transaction and its gas, and r4's Sourcify links.

## Sepolia r4

Deployed and configured on 1 November 2026 in blocks 12,041,046 to 12,041,071, under the
namespace `keccak256("6529-works/sepolia/r4")`. Every address comes from the record
[`1793536584.json`](../../deployments/11155111/1793536584.json).

**r4 runs `main` at `1e7022b`**, the rc.2 candidate: the uniform-price edition auction of
[ADR 0005](../adr/0005-stream-editions-auction.md), 6529 Stream Editions under its new name,
Stream's primary-sale outcomes and museum rule, and no fixed-price or Dutch adapter. Build its
ABIs from `1e7022b` ([ABIs and interface IDs](abis-and-interface-ids.md)), or read them from
Sourcify, where every r4 contract is verified with an exact match (links in the
[Sepolia README](../../deployments/11155111/README.md#contracts-r4)). The flows run on it,
with every transaction and its gas, are in
[flows.md](../../deployments/11155111/flows.md#r4-the-rc2-candidate-1-november-2026).

**r4's 1/1 auctions run 1 hour, not 24** (the governed minimum, a testnet setting); every
other parameter is the mainnet default ([below](#settings-at-deployment)).

### Products

| Contract | Address |
| --- | --- |
| 6529 Stream (ERC-721) | [`0x02617DbDc0b0521124cb4C2a3EF602977e29Bd91`](https://sepolia.etherscan.io/address/0x02617DbDc0b0521124cb4C2a3EF602977e29Bd91) |
| WorkRecords | [`0x99fA71dE184Be2b72cBcDEc660a5E8C881B7A1B2`](https://sepolia.etherscan.io/address/0x99fA71dE184Be2b72cBcDEc660a5E8C881B7A1B2) |
| 6529 Stream Editions (ERC-1155) | [`0xde41652f2f14260Fa4D800fdd7F77A0F9B95207e`](https://sepolia.etherscan.io/address/0xde41652f2f14260Fa4D800fdd7F77A0F9B95207e) |

### Sales

| Contract | Address |
| --- | --- |
| EnglishAuction (the 1/1) | [`0x50aCE619605F8C5093803194B58545aa6C36471d`](https://sepolia.etherscan.io/address/0x50aCE619605F8C5093803194B58545aa6C36471d) |
| EnglishAuctionLens | [`0x42E5c7056bA0646eCBb770E6759aBbd43Ca17EA5`](https://sepolia.etherscan.io/address/0x42E5c7056bA0646eCBb770E6759aBbd43Ca17EA5) |
| UniformEditionAuction (the editions) | [`0x5ffaC5C15BC631Bf928f47669981534cf4A3a3aB`](https://sepolia.etherscan.io/address/0x5ffaC5C15BC631Bf928f47669981534cf4A3a3aB) |
| UniformEditionAuctionLens | [`0xA8F6af72eA5e58b571e551E9414D5430F4b10aCe`](https://sepolia.etherscan.io/address/0xA8F6af72eA5e58b571e551E9414D5430F4b10aCe) |

Read the edition auction's views (`endTimes`, `clearing`, `quote`, `bidOutcome`,
`settlementOrder`) on the auction itself: its read-only fallback forwards them to the lens.

### Curation and identity

| Contract | Address |
| --- | --- |
| PackageRegistry | [`0x1E12085C6001f3193776Ff9aDEc0C71b7c004C9A`](https://sepolia.etherscan.io/address/0x1E12085C6001f3193776Ff9aDEc0C71b7c004C9A) |
| CurationVerifier (`Eip712CurationVerifier`) | [`0x4dfAc76243f62B78034146605D537190F5106064`](https://sepolia.etherscan.io/address/0x4dfAc76243f62B78034146605D537190F5106064) |
| ArtistRegistry | [`0xf54f5465F1C4DB161145DA3C1369f8BF1195Aa91`](https://sepolia.etherscan.io/address/0xf54f5465F1C4DB161145DA3C1369f8BF1195Aa91) |
| ConsolidationAdapter | [`0x4b6e792143bcf7443e4aC5456A8798bFb26CD9D0`](https://sepolia.etherscan.io/address/0x4b6e792143bcf7443e4aC5456A8798bFb26CD9D0) |

### Economics

| Contract | Address |
| --- | --- |
| EconomicsResolver | [`0x34235b15CC7Ac63dedF1577f24a6bC1D4F1D8467`](https://sepolia.etherscan.io/address/0x34235b15CC7Ac63dedF1577f24a6bC1D4F1D8467) |
| AssetAllowlist | [`0x8458D77ff0fc34b3f3296F9aF418B4868afefcbB`](https://sepolia.etherscan.io/address/0x8458D77ff0fc34b3f3296F9aF418B4868afefcbB) |
| SplitFactory | [`0xB2638cfA692B32E39Da326E08d54aF4d539c7BB7`](https://sepolia.etherscan.io/address/0xB2638cfA692B32E39Da326E08d54aF4d539c7BB7) |
| ReleaseVerifier | [`0x8E9dAd1480E0b9EA198DDD3a5EED1221420F7A98`](https://sepolia.etherscan.io/address/0x8E9dAd1480E0b9EA198DDD3a5EED1221420F7A98) |
| RevenueEscrow | [`0x2da453bc5b9028a618613D6BeE489C0121bB57ee`](https://sepolia.etherscan.io/address/0x2da453bc5b9028a618613D6BeE489C0121bB57ee) |
| ClaimRouter | [`0xF7BE40426d2dC4606664625a340fa74b3cB0C4bC`](https://sepolia.etherscan.io/address/0xF7BE40426d2dC4606664625a340fa74b3cB0C4bC) |

Split wallets are not listed: each is deployed on demand at its predicted CREATE2 address
(`SplitFactory.walletFor`).

### Content, records and entropy

| Contract | Address |
| --- | --- |
| ContentStore | [`0x1922aA592CfCC1fdC3037EA7e033EA12D696F466`](https://sepolia.etherscan.io/address/0x1922aA592CfCC1fdC3037EA7e033EA12D696F466) |
| DependencyRegistry | [`0xd74E938444C363Be4152268Eca625ABfA00933E4`](https://sepolia.etherscan.io/address/0xd74E938444C363Be4152268Eca625ABfA00933E4) |
| Renderer | [`0xa4d100C8f6faEd2D7db97a3BC68f9E215A8aEA8f`](https://sepolia.etherscan.io/address/0xa4d100C8f6faEd2D7db97a3BC68f9E215A8aEA8f) |
| StatementLog | [`0x202F193109626416961c5f9642C8f8A7c5cb2e8B`](https://sepolia.etherscan.io/address/0x202F193109626416961c5f9642C8f8A7c5cb2e8B) |
| EntropyModule (`VrfEntropyModule`) | [`0xd8365D17B0C16828F39f5697fd8101796A85A087`](https://sepolia.etherscan.io/address/0xd8365D17B0C16828F39f5697fd8101796A85A087) |

### Governance

| Contract | Address |
| --- | --- |
| WorksAccessManager | [`0x68115bEbdB73Bbe4E6e6D135eF76FbC32097C307`](https://sepolia.etherscan.io/address/0x68115bEbdB73Bbe4E6e6D135eF76FbC32097C307) |
| GovernanceConfigurator | [`0xf3c2750759Da14a411841B82E5eCc6B268138D6f`](https://sepolia.etherscan.io/address/0xf3c2750759Da14a411841B82E5eCc6B268138D6f) |

The role holders (Safes and keys) are listed in the
[Sepolia README](../../deployments/11155111/README.md#holders); r4 uses r1's holders, as r2 and r3
did.

### External contracts and accounts

| Contract | Address | Notes |
| --- | --- | --- |
| 6529 Network Museum (testnet) | [`0xd954e414a216Bc2D3d1fdc8C0e9b258ffDfDD840`](https://sepolia.etherscan.io/address/0xd954e414a216Bc2D3d1fdc8C0e9b258ffDfDD840) | A dedicated EOA the operator holds, with no role: every unsold 6529 Stream work moves here (owner decision 17) |
| 6529 delegation contract | [`0x8f86c644f845A077999939C69Bc787662377d915`](https://sepolia.etherscan.io/address/0x8f86c644f845A077999939C69Bc787662377d915) | The official NFTDelegation deployment on Sepolia; its runtime bytecode equals mainnet's `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical address |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | r4 has its own subscription |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Foundry's default factory, used for every deployment |

### Settings at deployment

From the record's `params`. Governed settings can change later through their delay classes;
read the contracts for current values.

| Setting | Value |
| --- | --- |
| 1/1 auction duration | 3,600 seconds (1 hour; **testnet**, mainnet 24 hours) |
| Anti-snipe window | 900 seconds (15 minutes) |
| Minimum increment share | 5,000 of 100,000 (5%) |
| ETH increment floor | 0.001 ETH (`1000000000000000` wei) |
| ETH opening bid (genesis wiring, owner decision 19) | 0.05 ETH |
| Edition auction ladder | 0.0001 ETH at step 0, 48 steps per decade, 336 steps |
| Edition auction margin, close, soft close, backstop | 10,000 of 100,000 (10%); 900 seconds after the 1/1's end; 300 seconds; 86,400 seconds |
| Network fee recipient | `0x2588A62384F41bB32412841ab774CD574b427bd5` (the hot admin Safe) |
| Museum | `0xd954e414a216Bc2D3d1fdc8C0e9b258ffDfDD840` (the testnet museum) |
| Marketplace owner (`owner()`) | `0x0a69CdD0d8De0680779237aFF610C90b61B83b2D` (the platform key) |
| VRF callback gas limit, confirmations, retry delay | 200,000; 3; 259,200 seconds (3 days) |
| CC0 legal text | file ID `0x16f36978…d22b`, SHA-256 `0xa2010f34…0499` |

## Sepolia r3 (superseded)

Deployed on 15 October 2026 from `main` at `e5fe78c` (`v1.0.0-rc.1`), under the namespace
`keccak256("6529-works/sepolia/r3")`; the record is
[`1792095396.json`](../../deployments/11155111/1792095396.json) and its addresses, all verified
on Sourcify, are in the [Sepolia README](../../deployments/11155111/README.md#contracts-r3). r3
predates ADR 0005: its editions are sold by the fixed-price and Dutch adapters, the edition
token is still named 6529 Editions, and an unbid 1/1 goes to its artist. Build ABIs for r3 from
`e5fe78c` ([changes since r3](abis-and-interface-ids.md#changes-since-the-sepolia-r3-build)).

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
  [`config/sepolia-r4/`](../../config/sepolia-r4/genesis.json) (and `config/sepolia-r1/` to
  `sepolia-r3/` for the earlier instances), and its role map is the
  [role and permission matrix](../audit/roles.md) with the placeholder holders replaced.
- **Live Verify.** The manager's 5-day `minSetback` delays the first full readback; the
  [Sepolia README](../../deployments/11155111/README.md#sepolia-r4-1-november-2026-current)
  records when it is due and its result.

## Mainnet

Not deployed. Mainnet follows the external audit and remediation
([delivery plan](../../ops/DELIVERY_PLAN.md), phase 8). Its addresses will be added here and
under `deployments/1/` when they exist.
