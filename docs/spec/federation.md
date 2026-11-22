# Federation

A federated artist has their own pair of token contracts: a 1/1 contract (`FederatedStream`)
and an editions contract (`FederatedEditions`). They are **the same plain token code as 6529
Stream and 6529 Stream Editions** (`StreamBase`, `EditionsBase`) with a different gate. They are
full contracts (no proxy, no clone), deployed by an ownerless deployer, and permanent. The rules
of federation (who may mint, the network's fee share, item approval, consent, delisting) live in
the replaceable federation module, `FederationRegistry`, which the permanent `Directory` points
to (slot `FEDERATION`).

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`FederatedStream`](../../src/federated/FederatedStream.sol), [`FederatedEditions`](../../src/federated/FederatedEditions.sol) | permanent (per artist) | The plain token bases. One collection, created in the constructor. |
| [`FederatedDeployer`](../../src/federated/FederatedDeployer.sol) | permanent, ownerless | Deploys copies of the approved token code and records each copy. |
| [`FederationRegistry`](../../src/federated/FederationRegistry.sol) ([`IFederationGate`](../../src/interfaces/core/IFederationGate.sol), [`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol)) | module (`Directory.FEDERATION`) | The per-token directory, delisting, fee shares, the list of federated sale contracts, item approval with the royalty rate, collaborator consent, and `authorize` for federated mints (vaults deployed there). |
| `EnglishAuction`, [`FederatedEditionAuction`](../../src/federated/FederatedEditionAuction.sol) | modules (federated sale contracts) | Sell federated 1/1s and editions. |

## How a federated token differs from 6529 Stream

| | 6529 Stream / Editions | Federated copy |
| --- | --- | --- |
| Who may mint | The contract's own minter list, set by the network | Whoever the current federation module says may mint for this contract (`canMint`). Delisting stops minting at once. |
| Removed minters (for `rescue`) | The contract's own list | The federation module's answer (`wasMinter`, `minterRemovedAt`) |
| Who administers the collection page and the RENDERER slot | The network | Any wallet of the artist's account, asked from the accounts module through `Directory` |
| TERMS and RECORDS modules | The contract's own slots | The network's shared federated modules, read from `Directory` (`FEDERATED_TERMS`, `FEDERATED_RECORDS`) |
| Records | `WorkFacts` | The same `WorkFacts` |

The token itself has no records, items, locators, vaults, custody or fee terms. Installing a new
federation module in `Directory` waits `moduleDelay` (7 days at launch), so that is the wait
that applies to a change of who may mint federated tokens.

## How a federated sale flows

1. The artist approves an item in the federation module and sets its royalty rate. Each
   collaborator consents to `Core.federatedConsent(itemHash, royaltyRate)`, so a collaborator
   signs the rate their income depends on.
2. Anyone starts the sale. The auction asks the federation module (`authorize`), which checks
   the listing, the approval and the consents, deploys the vaults, and answers the mint facts and
   the fee share recorded for the token.
3. The auction mints into its own custody. At settlement the network receives its share at the
   share stored in the sale.
4. **An unsold federated work stays in the network's sale contract** and can be offered again
   there for the same item. The artist cannot take it out without a sale. If the token refuses
   to settle, `settleOrRefund` closes the sale with refunds from 2 days after the end.

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| FED-1 | A copy is genuine only if the approved deployer recorded it (FED-64); its code is the approved code. | |
| FED-2 | Retired: the token holds no fee terms; the fee share is the federation module's (FED-73). | |
| FED-3 | Every artist power on the token asks the accounts module, through `Directory`, whether the caller is a wallet of the artist's account now; none while frozen. | |
| FED-4 | The network reaches a federated token only through `Directory` (its authority and modules) and the federation module. | |
| FED-5 | Retired: the token has no minters of its own (FED-7). | |
| FED-6 | A token is listed through the federation module with a wallet of the artist's account consenting to its facts. | |
| FED-7 | A mint needs the federation module's `canMint` for the caller; a delisted contract, or one of a suspended or revoked template, mints nothing. | |
| FED-8 | There is no exit: nothing leaves the federation. | |
| FED-9 | (Removed in the second pass: there are no minters of the artist's own.) | |
| FED-10 | A work is a `PackageItem` with its media list; `itemHash` is `WorksHashing.itemHash`. | |
| FED-11 | The artist approves one mint per approval in the federation module and sets the work's royalty rate (at most 100,000); a revoke withdraws it. | |
| FED-12 | Retired: the mint request is the federation module's `authorize` input. | |
| FED-13 | Retired: the record opens in `WorkFacts` (WS-2). | |
| FED-14 | The federation module deploys the seller and royalty vaults before the mint. | |
| FED-15 | Retired: the sale contract stores each sale's terms. | |
| FED-16 | Retired: the same token code as Stream (AUC-8). | |
| FED-17 | An unsold federated work stays in the sale contract's custody and can be started again there for the same item; the artist cannot take it out without a sale. | |
| FED-18 | Retired: a restart is a new start in the sale contract (FED-17). | |
| FED-19 | Retired: a refused settlement leaves the work in the sale contract (FED-17). | |
| FED-20 | Retired: the token holds no custody. | |
| FED-21 | Retired: the same token code as Stream (AUC-37). | |
| FED-22 | Retired: the same token code as Stream (AUC-9). | |
| FED-23 | Retired: the same token code as Stream (AUC-7). | |
| FED-24 | Retired: rate changes follow the federated TERMS and RECORDS modules (WS-14). | |
| FED-25 | Retired: records live in `WorkFacts` (WS rules). | |
| FED-26 | Retired: the renderer reads plain views (rendering page). | |
| FED-27 | Retired: locators live in the delivery module (WS-18 to WS-22). | |
| FED-28 | Retired: on-chain completeness is `WorkFacts` (WS-17). | |
| FED-29 | Retired: an editions contract names its partner at construction. | |
| FED-30 | A missing or failing federation module stops minting only; ownership, transfers and existing works never call it. | |
| FED-31 | Retired: the edition sale contract creates the edition (ED-1). | |
| FED-32 | Retired: the same token code as Editions (ED-5). | |
| FED-33 | Retired: the same token code as Editions (ED-25). | |
| FED-34 | Retired: the same token code as Editions (ED-25, ED-26). | |
| FED-35 | Retired: the edition sale contract pays as EA-12 and FED-54 say. | |
| FED-36 | Retired: the same token code as Editions. | |
| FED-41 | The federation module holds the per-token directory: listing, status, fee share and the federated sale contracts. | |
| FED-42 | `isActive`: listed ACTIVE, template approved or suspended. `canMint`: a listed sale contract, the token listed ACTIVE, template approved, and for editions the partner listed ACTIVE. | |
| FED-43 | Retired: listing is FED-6. | |
| FED-44 | A template code hash is approved once, bound to its deployer, only by the network. | |
| FED-45 | Suspension stops new joins, works and sales; running sales finish. | |
| FED-46 | Revocation stops serving the contracts; running sales end unsold with refunds; the network can reverse it. | |
| FED-47 | (Removed by the review fixes of the second pass: no revocation propagation call.) | |
| FED-48 | The network delists and relists by contract or by account, in bounded batches. | |
| FED-49 | The network lists federated sale contracts; removal stops new works; the module answers which were minters and when they were removed. | |
| FED-50 | A delisting or revocation never touches tokens, ownership, records, vaults or credits. | |
| FED-51 | Federation never changes 6529 Stream or a curated artist's identity. | |
| FED-52 | On every sold federated sale the network receives exactly its share at the stored share, and nothing on any other outcome. | |
| FED-53 | The federated edition auction sells any contract the federation module serves; its master is the contract's partner. | |
| FED-54 | Its fee is the federation module's share, stored at open, never the token's answer. | |
| FED-55 | A sale of a contract the module stops serving is void with full refunds; bidding closes at the delisting. | |
| FED-56 | `abandon` of a federated edition sale needs its 1/1 closed, then 21 days after the edition close; it seals at zero. | |
| FED-57 | Every other rule of the edition auction is the shared base's (EA-1 onward). | |
| FED-58 | A delisted sale's views show its 1/1 as it is, while bids and settlement treat it as cancelled. | |
| FED-59 | (Removed in the second pass: there is no exit, so no left contract.) | |
| FED-60 | An item's first party is the contract's artist; every artist-resolved payee has a payout address now. | |
| FED-61 | Retired: no raw storage reads; the renderer reads plain views. | |
| FED-62 | (Removed in the second pass: the abandonment wait is a fixed 21 days.) | |
| FED-63 | Genesis installs the federation module in `Directory`, lists both shared sale contracts in it and approves the two token versions. | |
| FED-64 | A copy joins only if the approved, ownerless deployer recorded it. | |
| FED-65 | A listing needs a consent to its facts signed by a wallet of the artist's account. | |
| FED-66 | (Removed in the second pass: no LEFT or LEFT_DELISTED status.) | |
| FED-67 | The pair as one: the 1/1 contract joins only after its editions are listed; an editions contract mints only while its partner is listed ACTIVE. | |
| FED-68 | Retired: content checks are `WorkFacts`' (WS-2). | |
| FED-69 | Retired: `Directory` names the one current federation module. | |
| FED-70 | Each genesis setter reaches only a target declaring its interface. | |
| FED-71 | Each collaborator after the first consents to `Core.federatedConsent(itemHash, royaltyRate)`, through the accounts module's `requireConsent`. | |
| FED-72 | A VRF item mints only once its seed is delivered; the seed is stored in the token at mint. | |
| FED-73 | The share in force is the federation module's `feeShareOf(token)`, recorded at listing and only ever lowered. | |
| FED-74 | The network may reinstate a revoked template. | |
| FED-75 | An account delisting reports every contract of the account DELISTED, with no batch. | |
| FED-76 | A hostile federation module can mint junk into a federated token but cannot move, burn or re-record a sold token. | |
| FED-77 | A federated token's RENDERER slot is set by the artist with the same announce-and-wait as other module slots. | |
| ID-12 | A directory entry is written once per token by the federation module, with a wallet of the account's consent to its facts, never for a delisted account; status changes need no signature. | `test_List_*` |
| ID-13 | An account delisting covers every contract of the account and blocks new listings; identity and payout are untouched. | |
| ID-14 | A listing's recorded fee share only lowers. | |

## The nine template guarantees, as met

A genuine copy is recorded by the approved, ownerless deployer (FED-64) and runs the approved
code (FED-1). It has no restricted function and no exit (FED-4, FED-8); minting needs the
federation module's answer (FED-7); delisting and revocation never touch tokens, records, vaults
or credits (FED-50); the network's fee is the module's share, stored in each sale (FED-52, FED-54).

## Residual leakage (accepted)

Marketplaces that ignore ERC-2981, a 0% royalty rate, and private sales outside the sale
contracts pay the network nothing. The federation module cannot see them.

## Numbers

| Value | Launch | Kind |
| --- | --- | --- |
| Installing a new federation module in `Directory` | 7 days | network setting (`moduleDelay`) |
| Refusal exit | 2 days after the 1/1's end | compiled in the auction |
| Edition abandon | 21 days after the edition close | compiled in the auction |
| Delisting batch | 256 per call | compiled in the module |

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| The federation module is missing or fails | Federated tokens mint nothing; everything else works | The network installs a module (after `moduleDelay`). |
| A federated token refuses to settle | `settle` reverts | `settleOrRefund` from 2 days after the end. |
| An account is delisted | Its contracts mint nothing new; running sales end with refunds | The network relists. |
