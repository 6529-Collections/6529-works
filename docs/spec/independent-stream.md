# Independent Stream

An Independent Stream artist has their own pair of token contracts: a 1/1 contract
(`IndependentStream6529`) and an editions contract (`IndependentStreamEditions6529`). They are **the
same plain token code as 6529 Stream and 6529 Stream Editions** (`StreamBase`, `EditionsBase`) with
a different gate. They are full contracts (no proxy, no clone), deployed by an ownerless deployer,
and permanent. The rules of Independent Stream (who may mint, the network's fee share, item
approval, consent, delisting) live in the replaceable Independent Stream module,
`IndependentStreamRegistry`, which the permanent `StreamDirectory6529` points to (slot
`INDEPENDENT_STREAM`).

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`IndependentStream6529`](../../src/independent/IndependentStream6529.sol), [`IndependentStreamEditions6529`](../../src/independent/IndependentStreamEditions6529.sol) | permanent (per artist) | The plain token bases. One collection, created in the constructor. |
| [`IndependentStreamDeployer`](../../src/independent/IndependentStreamDeployer.sol) | permanent, ownerless | Deploys copies of the approved token code and records each copy. |
| [`IndependentStreamRegistry`](../../src/independent/IndependentStreamRegistry.sol) ([`IIndependentStreamGate`](../../src/interfaces/core/IIndependentStreamGate.sol), [`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol)) | module (`StreamDirectory6529.INDEPENDENT_STREAM`) | The per-token directory, delisting, fee shares, the list of Independent Stream sale contracts, item approval with the royalty rate, collaborator consent, and `authorize` for Independent Stream mints (vaults deployed there). |
| `EnglishAuction`, [`IndependentEditionAuction`](../../src/independent/IndependentEditionAuction.sol) | modules (Independent Stream sale contracts) | Sell Independent Stream 1/1s and editions. |

## How an Independent Stream token differs from 6529 Stream

| | 6529 Stream / Editions | Independent Stream copy |
| --- | --- | --- |
| Who may mint | The contract's own minter list, set by the network | Whoever the current Independent Stream module says may mint for this contract (`canMint`). Delisting stops minting at once. |
| Removed minters (for `rescue`) | The contract's own list | The Independent Stream module's answer (`wasMinter`, `minterRemovedAt`) |
| Who administers the collection page and the RENDERER slot | The network | Any wallet of the artist's account, asked from the accounts module through `StreamDirectory6529` |
| TERMS and RECORDS modules | The contract's own slots | The network's shared Independent Stream modules, read from `StreamDirectory6529` (`INDEPENDENT_TERMS`, `INDEPENDENT_RECORDS`) |
| Records | `StreamWorkFacts6529` | The same `StreamWorkFacts6529` |

The token itself has no records, items, locators, vaults, custody or fee terms. Installing a new
Independent Stream module in `StreamDirectory6529` waits `moduleDelay` (7 days at launch), so that
is the wait that applies to a change of who may mint Independent Stream tokens.

## How an Independent Stream sale flows

1. The artist approves an item in the Independent Stream module and sets its royalty rate. Each
   collaborator consents to `Core.independentConsent(itemHash, royaltyRate)`, so a collaborator
   signs the rate their income depends on.
2. Anyone starts the sale. The auction asks the Independent Stream module (`authorize`), which
   checks the listing, the approval and the consents, deploys the vaults, and answers the mint facts
   and the fee share recorded for the token.
3. The auction mints into its own custody. At settlement the network receives its share at the
   share stored in the sale.
4. **An unsold Independent Stream work stays in the network's sale contract** and can be offered
   again there for the same item. The artist cannot take it out without a sale. If the token refuses
   to settle, `settleOrRefund` closes the sale with refunds from 2 days after the end.

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| IND-1 | A copy is genuine only if the approved deployer recorded it (IND-64); its code is the approved code. | |
| IND-2 | Retired: the token holds no fee terms; the fee share is the Independent Stream module's (IND-73). | |
| IND-3 | Every artist power on the token asks the accounts module, through `StreamDirectory6529`, whether the caller is a wallet of the artist's account now; none while frozen. | |
| IND-4 | The network reaches an Independent Stream token only through `StreamDirectory6529` (its authority and modules) and the Independent Stream module. | |
| IND-5 | Retired: the token has no minters of its own (IND-7). | |
| IND-6 | A token is listed through the Independent Stream module with a wallet of the artist's account consenting to its facts. | |
| IND-7 | A mint needs the Independent Stream module's `canMint` for the caller; a delisted contract, or one of a suspended or revoked template, mints nothing. | |
| IND-8 | There is no exit: nothing leaves Independent Stream. | |
| IND-9 | (Removed in the second pass: there are no minters of the artist's own.) | |
| IND-10 | A work is a `PackageItem` with its media list; `itemHash` is `WorksHashing.itemHash`. | |
| IND-11 | The artist approves one mint per approval in the Independent Stream module and sets the work's royalty rate (at most 100,000); a revoke withdraws it. | |
| IND-12 | Retired: the mint request is the Independent Stream module's `authorize` input. | |
| IND-13 | Retired: the record opens in `StreamWorkFacts6529` (WS-2). | |
| IND-14 | The Independent Stream module deploys the seller and royalty vaults before the mint. | |
| IND-15 | Retired: the sale contract stores each sale's terms. | |
| IND-16 | Retired: the same token code as Stream (AUC-8). | |
| IND-17 | An unsold Independent Stream work stays in the sale contract's custody and can be started again there for the same item; the artist cannot take it out without a sale. | |
| IND-18 | Retired: a restart is a new start in the sale contract (IND-17). | |
| IND-19 | Retired: a refused settlement leaves the work in the sale contract (IND-17). | |
| IND-20 | Retired: the token holds no custody. | |
| IND-21 | Retired: the same token code as Stream (AUC-37). | |
| IND-22 | Retired: the same token code as Stream (AUC-9). | |
| IND-23 | Retired: the same token code as Stream (AUC-7). | |
| IND-24 | Retired: rate changes follow the Independent Stream TERMS and RECORDS modules (WS-14). | |
| IND-25 | Retired: records live in `StreamWorkFacts6529` (WS rules). | |
| IND-26 | Retired: the renderer reads plain views (rendering page). | |
| IND-27 | Retired: locators live in the delivery module (WS-18 to WS-22). | |
| IND-28 | Retired: on-chain completeness is `StreamWorkFacts6529` (WS-17). | |
| IND-29 | Retired: an editions contract names its partner at construction. | |
| IND-30 | A missing or failing Independent Stream module stops minting only; ownership, transfers and existing works never call it. | |
| IND-31 | Retired: the edition sale contract creates the edition (ED-1). | |
| IND-32 | Retired: the same token code as Editions (ED-5). | |
| IND-33 | Retired: the same token code as Editions (ED-25). | |
| IND-34 | Retired: the same token code as Editions (ED-25, ED-26). | |
| IND-35 | Retired: the edition sale contract pays as EA-12 and IND-54 say. | |
| IND-36 | Retired: the same token code as Editions. | |
| IND-41 | The Independent Stream module holds the per-token directory: listing, status, fee share and the Independent Stream sale contracts. | |
| IND-42 | `isActive`: listed ACTIVE, template approved or suspended. `canMint`: a listed sale contract, the token listed ACTIVE, template approved, and for editions the partner listed ACTIVE. | |
| IND-43 | Retired: listing is IND-6. | |
| IND-44 | A template code hash is approved once, bound to its deployer, only by the network. | |
| IND-45 | Suspension stops new joins, works and sales; running sales finish. | |
| IND-46 | Revocation stops serving the contracts; running sales end unsold with refunds; the network can reverse it. | |
| IND-47 | (Removed by the review fixes of the second pass: no revocation propagation call.) | |
| IND-48 | The network delists and relists by contract or by account, in bounded batches. | |
| IND-49 | The network lists Independent Stream sale contracts; removal stops new works; the module answers which were minters and when they were removed. | |
| IND-50 | A delisting or revocation never touches tokens, ownership, records, vaults or credits. | |
| IND-51 | Independent Stream never changes 6529 Stream or a curated artist's identity. | |
| IND-52 | On every sold Independent Stream sale the network receives exactly its share at the stored share, and nothing on any other outcome. | |
| IND-53 | The Independent Stream edition auction sells any contract the Independent Stream module serves; its master is the contract's partner. | |
| IND-54 | Its fee is the Independent Stream module's share, stored at open, never the token's answer. | |
| IND-55 | A sale of a contract the module stops serving is void with full refunds; bidding closes at the delisting. | |
| IND-56 | `abandon` of an Independent Stream edition sale needs its 1/1 closed, then 21 days after the edition close; it seals at zero. | |
| IND-57 | Every other rule of the edition auction is the shared base's (EA-1 onward). | |
| IND-58 | A delisted sale's views show its 1/1 as it is, while bids and settlement treat it as cancelled. | |
| IND-59 | (Removed in the second pass: there is no exit, so no left contract.) | |
| IND-60 | An item's first party is the contract's artist; every artist-resolved payee has a payout address now. | |
| IND-61 | Retired: no raw storage reads; the renderer reads plain views. | |
| IND-62 | (Removed in the second pass: the abandonment wait is a fixed 21 days.) | |
| IND-63 | Genesis installs the Independent Stream module in `StreamDirectory6529`, lists both shared sale contracts in it and approves the two token versions. | |
| IND-64 | A copy joins only if the approved, ownerless deployer recorded it. | |
| IND-65 | A listing needs a consent to its facts signed by a wallet of the artist's account. | |
| IND-66 | (Removed in the second pass: no LEFT or LEFT_DELISTED status.) | |
| IND-67 | The pair as one: the 1/1 contract joins only after its editions are listed; an editions contract mints only while its partner is listed ACTIVE. | |
| IND-68 | Retired: content checks are `StreamWorkFacts6529`' (WS-2). | |
| IND-69 | Retired: `StreamDirectory6529` names the one current Independent Stream module. | |
| IND-70 | Each genesis setter reaches only a target declaring its interface. | |
| IND-71 | Each collaborator after the first consents to `Core.independentConsent(itemHash, royaltyRate)`, through the accounts module's `requireConsent`. | |
| IND-72 | A VRF item mints only once its seed is delivered; the seed is stored in the token at mint. | |
| IND-73 | The share in force is the Independent Stream module's `feeShareOf(token)`, recorded at listing and only ever lowered. | |
| IND-74 | The network may reinstate a revoked template. | |
| IND-75 | An account delisting reports every contract of the account DELISTED, with no batch. | |
| IND-76 | A hostile Independent Stream module can mint junk into an Independent Stream token but cannot move, burn or re-record a sold token. | |
| IND-77 | An Independent Stream token's RENDERER slot is set by the artist with the same announce-and-wait as other module slots. | |
| ID-12 | A directory entry is written once per token by the Independent Stream module, with a wallet of the account's consent to its facts, never for a delisted account; status changes need no signature. | `test_List_*` |
| ID-13 | An account delisting covers every contract of the account and blocks new listings; identity and payout are untouched. | |
| ID-14 | A listing's recorded fee share only lowers. | |

## The nine template guarantees, as met

A genuine copy is recorded by the approved, ownerless deployer (IND-64) and runs the approved
code (IND-1). It has no restricted function and no exit (IND-4, IND-8); minting needs the
Independent Stream module's answer (IND-7); delisting and revocation never touch tokens, records,
vaults or credits (IND-50); the network's fee is the module's share, stored in each sale (IND-52,
IND-54).

## Residual leakage (accepted)

Marketplaces that ignore ERC-2981, a 0% royalty rate, and private sales outside the sale
contracts pay the network nothing. The Independent Stream module cannot see them.

## Numbers

| Value | Launch | Kind |
| --- | --- | --- |
| Installing a new Independent Stream module in `StreamDirectory6529` | 7 days | network setting (`moduleDelay`) |
| Refusal exit | 2 days after the 1/1's end | compiled in the auction |
| Edition abandon | 21 days after the edition close | compiled in the auction |
| Delisting batch | 256 per call | compiled in the module |

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| The Independent Stream module is missing or fails | Independent Stream tokens mint nothing; everything else works | The network installs a module (after `moduleDelay`). |
| An Independent Stream token refuses to settle | `settle` reverts | `settleOrRefund` from 2 days after the end. |
| An account is delisted | Its contracts mint nothing new; running sales end with refunds | The network relists. |
