# Addresses

Where the 6529 Works contracts are deployed, and which source each deployment runs.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment. The Sepolia instances are testnet rehearsals with throwaway
signers; do not send them value you care about.

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | To be decided after the external audit | None |
| Sepolia | 11155111 | **r5** (current) | `main` at `ca02473` | [`1795338612.json`](../../deployments/11155111/1795338612.json) |
| Sepolia | 11155111 | r4 (superseded) | `main` at `1e7022b` | [`1793536584.json`](../../deployments/11155111/1793536584.json) |
| Sepolia | 11155111 | r3 (superseded) | `main` at `e5fe78c` (`v1.0.0-rc.1`) | [`1792095396.json`](../../deployments/11155111/1792095396.json) |
| Sepolia | 11155111 | r2 (superseded) | `main` at `400f96d` | [`1791750816.json`](../../deployments/11155111/1791750816.json) |
| Sepolia | 11155111 | r1 (superseded) | `main` at `60edd9b` | [`1791746472.json`](../../deployments/11155111/1791746472.json) |

The deployment records are the source of truth for every address below. The
[Sepolia README](../../deployments/11155111/README.md) adds the holders, the VRF
subscription, every deployment transaction and its gas, and the Sourcify links.

## Sepolia r5

Deployed and configured on 22 November 2026 in blocks 12,187,802 to 12,187,849, under the
namespace `keccak256("6529-works/sepolia/r5")`; the network Safe accepted in block 12,187,852.
Every address comes from the record
[`1795338612.json`](../../deployments/11155111/1795338612.json).

**r5 runs `main` at `ca02473`**: the second permanence pass, federation
([ADR 0008](../adr/0008-federation.md)), the single network address and `SaleStarter`, so its
ABIs and roles are the ones the other pages describe. Every contract is verified on Sourcify with
an exact match (links in the
[Sepolia README](../../deployments/11155111/README.md#contracts-r5)). Seven works ran through it:
sales, edition sales with a cut step, a dispute, a VRF work, a `SaleStarter` start, a start signed by a
consolidated wallet, payouts, a freeze and an artist's finalize; every transaction is in
[flows.md](../../deployments/11155111/flows.md#r5-the-current-main-22-november-2026).

**r5 is a rehearsal with throwaway keys.** Its live Verify needs the 5-day setback and can run
from 27 November 2026; until then the record is unconfirmed
([status](../../deployments/11155111/README.md#sepolia-r5-22-november-2026-current)).

**r5's 1/1 auctions run 1 hour, not 24** (the governed minimum, a testnet setting); every other
parameter is the mainnet default ([below](#settings-at-deployment)).

### Products

| Contract | Address |
| --- | --- |
| 6529 Stream (ERC-721) | [`0x7c0Cc32805E26e1C9c53A46DEfbC2090345dd784`](https://sepolia.etherscan.io/address/0x7c0Cc32805E26e1C9c53A46DEfbC2090345dd784) |
| WorkRecords | [`0x4DbC423C82b96080A6bc13358D89A8B40C0C72A3`](https://sepolia.etherscan.io/address/0x4DbC423C82b96080A6bc13358D89A8B40C0C72A3) |
| WorkDelivery | [`0xbF6cAaC5e5434a7Dd4deA4bEE0fDB46C0B73aa65`](https://sepolia.etherscan.io/address/0xbF6cAaC5e5434a7Dd4deA4bEE0fDB46C0B73aa65) |
| 6529 Stream Editions (ERC-1155) | [`0xB6520da3c005ba60D1c3e6253a0B37e39748ce31`](https://sepolia.etherscan.io/address/0xB6520da3c005ba60D1c3e6253a0B37e39748ce31) |

### Sales

| Contract | Address |
| --- | --- |
| SaleStarter (the 1/1 start helper) | [`0x7A1091b86f8FBCa97126EE75bb6805EFd80C446D`](https://sepolia.etherscan.io/address/0x7A1091b86f8FBCa97126EE75bb6805EFd80C446D) |
| EnglishAuction (the 1/1) | [`0x73527a07c7F19B153EE32F14bE16e96c4219c67f`](https://sepolia.etherscan.io/address/0x73527a07c7F19B153EE32F14bE16e96c4219c67f) |
| EnglishAuctionLens | [`0x32b032Bb6381625b0842D03BfD011F8a8b05Ccb1`](https://sepolia.etherscan.io/address/0x32b032Bb6381625b0842D03BfD011F8a8b05Ccb1) |
| UniformEditionAuction (the editions) | [`0xFAb695D537d2C441D8Be6a8184c7cbE8646912a2`](https://sepolia.etherscan.io/address/0xFAb695D537d2C441D8Be6a8184c7cbE8646912a2) |
| UniformEditionAuctionLens | [`0x3C2CCe1E80C8d0310D7246a603811dC187527B3B`](https://sepolia.etherscan.io/address/0x3C2CCe1E80C8d0310D7246a603811dC187527B3B) |

Read the edition auction's views (`endTimes`, `clearing`, `quote`, `bidOutcome`,
`settlementOrder`) on the auction itself: its read-only fallback forwards them to the lens.

### Federation

| Contract | Address |
| --- | --- |
| FederationRegistry | [`0xD674C284C89d1B63d7d82ac051a6daB5be4e1Fc4`](https://sepolia.etherscan.io/address/0xD674C284C89d1B63d7d82ac051a6daB5be4e1Fc4) |
| FederatedEditionAuction | [`0x896180534Fc8508894c40634776e914798F7CeDD`](https://sepolia.etherscan.io/address/0x896180534Fc8508894c40634776e914798F7CeDD) |
| FederatedEditionAuctionLens | [`0x7401C865A9cA473C3EFfCcd709311C8aF207De31`](https://sepolia.etherscan.io/address/0x7401C865A9cA473C3EFfCcd709311C8aF207De31) |
| Federated Stream deployer (`FederatedDeployer`) | [`0xb7dA4f98894356c710030A02809BCA98a301ACeD`](https://sepolia.etherscan.io/address/0xb7dA4f98894356c710030A02809BCA98a301ACeD) |
| Federated Editions deployer (`FederatedDeployer`) | [`0x58082Ff7cbC34EC300ee8FE9F9dF835977a2F71B`](https://sepolia.etherscan.io/address/0x58082Ff7cbC34EC300ee8FE9F9dF835977a2F71B) |

### Curation and identity

| Contract | Address |
| --- | --- |
| PackageRegistry | [`0x4d7a7aad13AC4Df31E843C68bDF278d074C0B17D`](https://sepolia.etherscan.io/address/0x4d7a7aad13AC4Df31E843C68bDF278d074C0B17D) |
| CurationVerifier (`Eip712CurationVerifier`) | [`0x81EEa94b0C7BCfFb2F02B41c720C55036895e123`](https://sepolia.etherscan.io/address/0x81EEa94b0C7BCfFb2F02B41c720C55036895e123) |
| ArtistRegistry | [`0xaF9709B45c1F486654158c796B19367780aFcC6e`](https://sepolia.etherscan.io/address/0xaF9709B45c1F486654158c796B19367780aFcC6e) |
| ConsolidationAdapter | [`0xf53334a5800CF6884b6dF8fc58A19A4252d68b29`](https://sepolia.etherscan.io/address/0xf53334a5800CF6884b6dF8fc58A19A4252d68b29) |

### Economics

| Contract | Address |
| --- | --- |
| EconomicsResolver | [`0x904Ef3d7F2B94E45715D2BDdBaEC64125C18bF1F`](https://sepolia.etherscan.io/address/0x904Ef3d7F2B94E45715D2BDdBaEC64125C18bF1F) |
| AssetAllowlist | [`0xE98d7BEBa0018e7a4af6394f4b41e8AD26d81243`](https://sepolia.etherscan.io/address/0xE98d7BEBa0018e7a4af6394f4b41e8AD26d81243) |
| SplitLedger (recorded as `SplitFactory`) | [`0x835D765D5F24A462ca6d9a1caB639BA8559ceA35`](https://sepolia.etherscan.io/address/0x835D765D5F24A462ca6d9a1caB639BA8559ceA35) |
| Fee recipient vault (`GovernedVault`) | [`0xB638C93e47aC281142dcBD69f4aDeDf368a5D517`](https://sepolia.etherscan.io/address/0xB638C93e47aC281142dcBD69f4aDeDf368a5D517) |
| Museum vault (`GovernedVault`) | [`0x8c8FA635cFD6d39d7ec1D520C3B3cb4C36E1Aabe`](https://sepolia.etherscan.io/address/0x8c8FA635cFD6d39d7ec1D520C3B3cb4C36E1Aabe) |
| RevenueEscrow | [`0xCAe1D10F1A7421ee6829FDcbFF79f586F0F26201`](https://sepolia.etherscan.io/address/0xCAe1D10F1A7421ee6829FDcbFF79f586F0F26201) |
| ClaimRouter | [`0xbec5d387CcDE8a50E7Bf7C28a4A3D84EBa645134`](https://sepolia.etherscan.io/address/0xbec5d387CcDE8a50E7Bf7C28a4A3D84EBa645134) |

Split wallets are not listed: each is deployed on demand at its predicted CREATE2 address.

### Content, records and entropy

| Contract | Address |
| --- | --- |
| ContentStore | [`0xc3846eB24293f0F4E3Ba36190562Da1b4707e087`](https://sepolia.etherscan.io/address/0xc3846eB24293f0F4E3Ba36190562Da1b4707e087) |
| DependencyRegistry | [`0xBF6Af0d0652Bd79a3dED957E0543c8FDCabD6d93`](https://sepolia.etherscan.io/address/0xBF6Af0d0652Bd79a3dED957E0543c8FDCabD6d93) |
| Renderer | [`0xE53a7762972783Ac190b5b3a2c9C4049417D452F`](https://sepolia.etherscan.io/address/0xE53a7762972783Ac190b5b3a2c9C4049417D452F) |
| StatementLog | [`0x911030BD0eEd5f659b022932AAF26425ca78B323`](https://sepolia.etherscan.io/address/0x911030BD0eEd5f659b022932AAF26425ca78B323) |
| EntropyModule (`VrfEntropyModule`) | [`0x2b5067dd458c9C01Ab70B5A290E10D185C3ae892`](https://sepolia.etherscan.io/address/0x2b5067dd458c9C01Ab70B5A290E10D185C3ae892) |

### Governance

| Contract | Address |
| --- | --- |
| WorksAccessManager | [`0x0D312D4FC9890aA81BD3D56825716ef3ceE08B76`](https://sepolia.etherscan.io/address/0x0D312D4FC9890aA81BD3D56825716ef3ceE08B76) |
| GovernanceConfigurator | [`0x37610e1b120d68E9E402372D3D86E94751Ec15Dc`](https://sepolia.etherscan.io/address/0x37610e1b120d68E9E402372D3D86E94751Ec15Dc) |

The network is one throwaway 2-of-3 Safe 1.4.1,
[`0x54a769fe591c3F47CF83d30b69e576497CE34454`](https://sepolia.etherscan.io/address/0x54a769fe591c3F47CF83d30b69e576497CE34454),
with no module and no guard. The operational keys (three pausers, two curation signers, storage
operator, platform, curator) are listed in
[`config/sepolia-r5/genesis.json`](../../config/sepolia-r5/genesis.json). No brake is set.

### External contracts and accounts

| Contract | Address | Notes |
| --- | --- | --- |
| 6529 Network Museum (testnet) | [`0xB37A2a265044Ca0cB07839950D208D62B3944D25`](https://sepolia.etherscan.io/address/0xB37A2a265044Ca0cB07839950D208D62B3944D25) | A dedicated EOA the operator holds, with no role: every unsold 6529 Stream work moves here (owner decision 17) |
| 6529 delegation contract | [`0x8f86c644f845A077999939C69Bc787662377d915`](https://sepolia.etherscan.io/address/0x8f86c644f845A077999939C69Bc787662377d915) | The official NFTDelegation deployment on Sepolia; its runtime bytecode equals mainnet's `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical address |
| Chainlink VRF v2.5 coordinator | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | r5 has its own subscription; the module is its only consumer |
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
| Edition auction margin, soft close, backstop | 10,000 of 100,000 (10%); 300 seconds; 86,400 seconds |
| Network fee recipient | `0x54a769fe591c3F47CF83d30b69e576497CE34454` (the network Safe) |
| Museum | `0xB37A2a265044Ca0cB07839950D208D62B3944D25` (the testnet museum) |
| Marketplace owner (`owner()`) | `0x54a769fe591c3F47CF83d30b69e576497CE34454` (the network Safe) |
| VRF subscription, callback gas limit, confirmations, retry delay | `8933…5979` (native payment); 200,000; 3; 259,200 seconds (3 days) |
| CC0 legal text | file ID `0x16f36978…d22b`, SHA-256 `0xa2010f34…0499` |

## Sepolia r4 (superseded)

Deployed on 1 November 2026 from `main` at `1e7022b` (the code of `v1.0.0-rc.2`), under the
namespace `keccak256("6529-works/sepolia/r4")`; the record is
[`1793536584.json`](../../deployments/11155111/1793536584.json) and its addresses, all verified
on Sourcify, are in the [Sepolia README](../../deployments/11155111/README.md#contracts-r4). Its
live Verify passed on 6 November 2026. r4 predates the second permanence pass and federation: its
manager still has guardians and the earlier delay classes, it has no fee-recipient or museum
vault, no `SaleStarter` and no federation contracts. Build ABIs for r4 from `1e7022b`.

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
  [`config/sepolia-r5/`](../../config/sepolia-r5/genesis.json) (and `config/sepolia-r1/` to
  `sepolia-r4/` for the earlier instances). The [role and permission matrix](../audit/roles.md)
  is generated from `main`'s genesis policy, which r5 installed; it does not describe r1 to r4.
- **Live Verify.** A manager's 5-day `minSetback` delays its first full readback (r5: from
  27 November 2026); the
  [Sepolia README](../../deployments/11155111/README.md#sepolia-r5-22-november-2026-current)
  records when it is due and its result.

## Mainnet

Not deployed. Mainnet follows the external audit and remediation
([delivery plan](../../ops/DELIVERY_PLAN.md), phase 8). Its addresses will be added here and
under `deployments/1/` when they exist.
