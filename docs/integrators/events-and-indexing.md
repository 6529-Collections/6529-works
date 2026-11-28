# Events and indexing

What each contract logs and how to rebuild state from logs alone. Every permanent contract
emits an event for every state change, enough to rebuild its state from its own logs
([ADR 0010](../adr/0010-plain-permanent-core.md)). Modules log their own changes.

> Pre-audit. See the [project status](../../README.md#status).

## How to read this page

- **Key every log by emitter address and topic0.** Stream and Editions share `RoyaltySet`,
  the module and minter events, `OwnershipTransferred`, `ContractURIUpdated`, `ContractURISet` and the ERC-4906
  events; `StreamDirectory6529` shares the module events. `Transfer(address,address,uint256)` is
  also ERC-20's (the ERC-721 log has four topics).
- **Topics.** `indexed` parameters are topics 1 to 3. Structs, strings, bytes and arrays are in
  the data. Struct names below (`MintFacts`, `Outcome`, `License`, `PackageItem`, `MediaFile`)
  are encoded as tuples or `uint8` in the canonical signature; topic0 is computed from that.
- **Module slots** (`bytes32 slot`) are ASCII names left-aligned: `"TERMS"`, `"RENDERER"`,
  `"RECORDS"`, `"ACCOUNTS"`, `"INDEPENDENT_STREAM"`, `"INDEPENDENT_TERMS"`, `"INDEPENDENT_RECORDS"`.
- **Where to start.** Scan from the deployment record's `startBlock` in
  [`deployments/11155111/`](../../deployments/11155111). Four Sepolia instances run this design: r9,
  the current instance (`core-1795840548.json`, `startBlock` 12,227,835), r8
  (`core-1795440624.json`, `startBlock` 12,196,001), r7, the reference
  instance (`core-1795423896.json`, `startBlock` 12,194,636), and r6
  (`core-1795412520.json`, `startBlock` 12,193,722); earlier rounds ran an earlier design. r6
  and r7 run the modules as they were before 23 November 2026: their `auctionClock` answers
  three values, r8's and r9's four.
- **Module events** are listed below with their topics, generated from the build.

## The permanent core

Topics are the full 32 bytes, from the compiled interfaces.

### Stream

`IStream` and `IModules`; each Independent Stream 1/1 token emits the same.

| Event | topic0 | When |
| --- | --- | --- |
| `Transfer(address indexed from, address indexed to, uint256 indexed tokenId)` | `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | ERC-721; a mint from zero, a burn to zero |
| `WorkMinted(uint256 indexed tokenId, uint256 indexed collectionId, uint256 indexed artistId, address minter, uint32 serial, MintFacts facts)` | `0xcd68913783d22c6ac5aa99ac78ee918f220587f0e31f1a6c34e2779b4cd16766` | `mint`; carries every fact, stored or not (content hash, package root, media hash, record file, seller) |
| `PrimarySale(uint256 indexed tokenId, Outcome outcome, address indexed buyer, uint256 price)` | `0xdab3433b107eccad74f51c88fb8f34052a6e9ddea138cea44f51f483cdd84791` | `recordPrimarySale`; the price is only here |
| `WorkRescued(uint256 indexed tokenId, address indexed from, address to)` | `0x77ac3c6455fa9305b1c12dc5c6cefeb7417b9d5ed5009a19a6bb464e41428ea8` | `rescue`; outcome becomes `RESCUED` |
| `RoyaltySet(uint256 indexed tokenId, address receiver, uint24 rate)` | `0x95019fbde998daec25616fe98bcbb03ae176b511150b8c5930d4c0b1c287f5df` | `mint` and the TERMS module's `setRoyalty` |
| `RoyaltyRateLocked(uint256 indexed tokenId)` | `0x10f30d67237f019693a7756fd9e01091b8acf081f3cca0eea2aa23ef568ad775` | the TERMS module's `lockRoyaltyRate` |
| `CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash)` | `0x8966ba956c90c682e7629fa1eff72812e2a5d54259d1e684285c761439588057` | `createCollection` |
| `RescueDelaySet(uint48 previous, uint48 next)` | `0x329b9d8b22e5399b02553a22d24cbdd5f73e805fd198b83e827953a7fa564bbd` | `setRescueDelay` |
| `MinterAdded(address indexed minter, uint48 activeFrom)` | `0x496a0c955fc4acb0b3d3d396b62936b1d5b09ee24a0c387ac3117741a399a128` | constructor (genesis minters) and `addMinter` |
| `MinterRemoved(address indexed minter)` | `0xe94479a9f7e1952cc78f2d6baab678adc1b772d936c6583def489e524cb66692` | `removeMinter` |
| `ModuleProposed(bytes32 indexed slot, address module, uint48 readyAt)` | `0x230c42ee34613ec831fa45f3254d06dd923ae04ee5ddbeb6dc9c371f516aaf8c` | `proposeModule` |
| `ModuleSet(bytes32 indexed slot, address previous, address module)` | `0x805f6cfd1882ecfb5ba14cc1b701b7242cf95893badde12b29ffd0236bef0422` | constructor (genesis modules), `activateModule`, `removeModule` (module zero) |
| `ModuleDelaySet(uint48 previous, uint48 next)` | `0x4269f60ea01fb342018e13abcba2ff1e41cf055d5d3fca5a8c044196a0b48662` | `setModuleDelay` |
| `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | constructor, `setOwner` (marketplace owner only; not authority) |
| `ContractURIUpdated()` | `0xa5d4097edda6d87cb9329af83fb3712ef77eeb13738ffe43cc35a4ce305ad962` | `setContractURI` (ERC-7572) |
| `ContractURISet(string uri)` | `0xaf497693a87db12ca89131a31edbb3db4bb5702dfb284e8ae7427d185f09112d` | `setContractURI`, with the new value |
| `Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)` | `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | ERC-721 |
| `ApprovalForAll(address indexed owner, address indexed operator, bool approved)` | `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` | ERC-721 |
| `MetadataUpdate(uint256)` | `0xf8e1a15aba9398e019f0b49df1a4fde98ee17ae345cb5f6b5e2c27f5033e8ce7` | ERC-4906, from `emitMetadataUpdate` (WorkFacts, RECORDS, TERMS) |
| `BatchMetadataUpdate(uint256,uint256)` | `0x6bd5c950a8d8df17f772f5af37cb3655737899cbf903264b9795592da439661c` | ERC-4906 |

An Independent Stream token has no minter list: its minters are the Independent Stream module's
answer, so `MinterAdded` and `MinterRemoved` come from that module, not the token.

### Editions

`IEditions`; each Independent Stream Editions token emits the same.

| Event | topic0 | When |
| --- | --- | --- |
| `TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)` | `0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62` | ERC-1155 |
| `TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)` | `0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb` | ERC-1155 |
| `ApprovalForAll(address indexed account, address indexed operator, bool approved)` | `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` | ERC-1155 |
| `URI(string value, uint256 indexed id)` | `0x6bb7ff708619ba0610cba295a58592e0451dee2622938c8755667688daf3529b` | ERC-1155 |
| `EditionCreated(uint256 indexed editionId, address indexed minter, uint40 maxSupply, address royaltyReceiver, uint24 royaltyRate)` | `0xaf291dbb8a8a6559eeef23b8207c336a6a43ed327b858d04a4bd0968a811a571` | `create` by the sale contract |
| `EditionMinted(uint256 indexed editionId, address indexed to, uint256 amount, uint256 unitPrice)` | `0x2525f1c59f45d123089be811400f55744de110480bc112beb610091b3e19b98b` | `mint`; precedes its `TransferSingle` |
| `EditionSupplySealed(uint256 indexed editionId, uint256 supply)` | `0xbf26eb1fb29573bf3ae0bba9e4607e51bbe158ec8720aaee88bc9f1d83abf356` | `seal` |
| `EditionRebound(uint256 indexed editionId, address indexed previous, address indexed minter)` | `0xfae5f534a1d8ad1378852156c102769f74d5ce61652202e83af9c953e71d93cd` | `rebind` |
| `RebindDelaySet(uint48 previous, uint48 next)` | `0xf0258e3cf75e4109d4976fba77ef26ac166571b541f608b43cf1d5ce4a3fc655` | `setRebindDelay` |
| `RoyaltySet`, module and minter events, `OwnershipTransferred`, `ContractURIUpdated`, `ContractURISet`, ERC-4906 | as for Stream | |

### Directory

| Event | topic0 | When |
| --- | --- | --- |
| `UnclaimedPeriodSet(uint48 previous, uint48 next)` | `0x675bb988a9e92cf64b105c329cfef3c29dcb2475b43701d44ba80b5d5277657c` | `setUnclaimedPeriod` |
| `ModuleProposed`, `ModuleSet`, `ModuleDelaySet` | as for Stream | slots `ACCOUNTS`, `INDEPENDENT_STREAM`, `INDEPENDENT_TERMS`, `INDEPENDENT_RECORDS` |

### WorkFacts

Every event is keyed by `(token, tokenId)`.

| Event | topic0 | When |
| --- | --- | --- |
| `RecordOpened(address indexed token, uint256 indexed tokenId, PackageItem item, MediaFile[] media)` | `0x2e1741d38953f812a26b7c727db87f67db827c4eaae1fa6ac4dfd2a3bf0405d7` | `open` (anyone) |
| `RecordSet(address indexed token, uint256 indexed tokenId, bytes32 recordFileId)` | `0xe2ab84ae980dead14dd785fc1a3aa7e3a4db245c79f4e29aa25b6fe11b38271e` | `setRecord` (RECORDS module) |
| `LicenseSet(address indexed token, uint256 indexed tokenId, License license)` | `0xdbeaa1306eb467d078313c1869eb964231f71ed9791f543bd2f423fe9854fa74` | `setLicense` |
| `Finalized(address indexed token, uint256 indexed tokenId, address renderer, bytes32 codeHash)` | `0x8538d96f513764912daed2eb6771c4a3df868fb8da04037f4a54bbee3cb9a318` | `finalize` |
| `RendererRepinned(address indexed token, uint256 indexed tokenId, address renderer, bytes32 codeHash)` | `0xe1aba5ab1fdafb57d79519ce3d65820f89a34f37b223b28536d2c2653bff5c83` | `repin` |
| `Locked(address indexed token, uint256 indexed tokenId, bool license, bool repin)` | `0x9a26d7aa8d0b0885c3a5cce1b95072a26bc415306c652f20e7b507c07a3914d5` | `lock` |
| `OnChainComplete(address indexed token, uint256 indexed tokenId)` | `0x3ffaeac88d7480b689b75b72fe9d967909eec8dba4ba385433cae1abb9a9893a` | `markOnChainComplete` (anyone) |

### Module interfaces frozen with the core

| Contract | Event | topic0 |
| --- | --- | --- |
| RECORDS (`IWorkRules`) | `FinalizeNoticeRecorded(address indexed token, uint256 indexed tokenId, uint256 dueAt)` | `0xc2333be19fc2214b40c22ecb199512c11bde20cec926c9cc45d84b1f2edb925c` |
| RECORDS | `PowersRenounced(address indexed token, uint256 indexed tokenId, uint16 powers)` | `0x134c17fd149ea45174ca8d4d33d06a7a06e7380cb026e6168b42f249522d696d` |
| RECORDS | `DeliverySet(address previous, address next)` | `0x113e2022127f41af1670206bb33d2c69486d7f4f382e9284c2c974fea2fbd666` |
| TERMS (`ITerms`) | `FeeShareLowered(address,uint256,uint32,uint32,address)` | `0x49e5ebea2aa2c1872dee48dfdae2fd7748c45f330b1b62140e5f1ac969b50c39` |
| Mint policy (`IMintPolicy`) | `ContentReleased(address,uint256,bytes32,uint256)` | `0x3148787f9c7b59535c75e7f202ad401ad0a5747807bcbba3a776fd1eb84f8776` |

## Modules

Generated from the build (`out/`). Every governed contract also emits OpenZeppelin
`AuthorityUpdated(address)` (`0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad`).
The exported ABIs are in [`abi/`](../../abi).

### EnglishAuction

The 1/1 sale contract. Sale IDs are `uint256(keccak256(abi.encode(token, tokenId)))`.

| Event | topic0 |
| --- | --- |
| `AuctionCancelled(uint256 indexed saleId, bytes32 outcomeRef)` | `0x49d6765465d68d3195fe23b8994c157a73a07cf3732ab9d094d1d5fe2f896880` |
| `AuctionPaused(uint256 indexed saleId, bytes32 disputeRef)` | `0xc5ebe7699a677eb954ea6988e36b511bab70d7e1ade4318cdafac5206db27f79` |
| `AuctionResumed(uint256 indexed saleId, uint64 endTime)` | `0xd6998361646975076830fd22deba76d0ebb862929692ac6a7c878737e9ab430d` |
| `BidPlaced(uint256 indexed saleId, address indexed bidder, address recipient, uint256 amount, uint64 endTime)` | `0x6dcc6bb7f6ff492d5dd3fff00632c3b14d65ad4465c1b4f44685d8ac094ef16c` |
| `BidWithdrawn(uint256 indexed saleId, address indexed bidder, uint256 amount)` | `0x8f8619524e8d462cead34604bd2247ede24175801481e4d0b8059ac8aa41c301` |
| `Claimed(address indexed account, address indexed currency, address indexed to, uint256 amount)` | `0x913c992353dc81b7a8ba31496c484e9b6306bd2f6c509a649a38fdf5e1c953b2` |
| `ConfigSet(AuctionConfig previous, AuctionConfig next)` | `0x025b824563463f0ba9863c8fdb5ff2a80996d3d6625a22c1c94ed01c5e866e5b` |
| `CreditExpired(address indexed account, address indexed currency, address indexed to, uint256 amount)` | `0xf9ca24059cdd86b3607573ff5bb441a41b3469f47964d6d58b6330ec91964d23` |
| `Credited(address indexed account, address indexed currency, uint256 indexed saleId, uint256 amount)` | `0xdd0ef63b44a932361273bab95d6e9bfcea5c7850c43844f540314e89899b970c` |
| `DeliveryClaimed(uint256 indexed saleId, address indexed recipient, address to)` | `0x97b1d318557d1873c3d7a8a9ef7fb4b4c83f2bb976bb53525208ed7712543748` |
| `DeliveryPending(uint256 indexed saleId, address indexed recipient)` | `0x96b5b68e86af123b788e4434fa8a32249a60a4f022f6bb2451d03055a8dfcb26` |
| `Paused(address account)` | `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` |
| `RescuedSaleClosed(uint256 indexed saleId)` | `0xbab3719d55f70261b89020b4298a74439ac35d304dad421a736479cab6f1d7a8` |
| `SaleSettled(uint256 indexed saleId, address indexed token, uint256 indexed tokenId, address buyer, address recipient, uint256 quantity, address currency, uint256 price, address seller, uint256 sellerProceeds, address feeRecipient, uint256 fee)` | `0x16010625338e58299cd56c138533827e742865fde105b0c14272c707dd971b20` |
| `SaleStarted(uint256 indexed saleId, address indexed token, uint256 indexed tokenId, bytes32 saleKind, address currency, uint256 price, uint64 startTime, uint64 endTime)` | `0x36e87edc6a9768b0cbf62a7a844b6d147adee3701d9778029ef463c3cf2df954` |
| `SettlementRefused(uint256 indexed saleId)` | `0x682bf7cea42c85fae76f5d2f0ff51745ffe27dd355f679d2c694a455504bc859` |
| `StreamPolicySet(address previous, address next)` | `0x2a7be3a62b0c2331c9f1d0308cd72ec5570b4ff99f952ddbf9686c4b3dd68efe` |
| `Unpaused(address account)` | `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` |

### UniformEditionAuction

The edition sale contract; `IndependentEditionAuction` emits the same. Key a bid by
`(saleId, bidId)`.

| Event | topic0 |
| --- | --- |
| `AuctionCleared(uint256 indexed saleId, uint256 count, uint256 step, uint256 price, uint256 revenue, bool rationed, uint256 cutUnits)` | `0x0740a60eb3f6ff14f93d8845e29a302ed3d41894039224c85155e9de357ee68e` |
| `AuctionOpened(uint256 indexed saleId, address indexed token, uint256 indexed id, address master, uint32 maxCount, AuctionConfig terms, uint64 closeAt)` | `0xd52319ce76092792a3f633b842a462edad02133112beef5fa79f3f35a3903695` |
| `AuctionSettled(uint256 indexed saleId, uint256 count, uint256 cutoff)` | `0x449bedd35ef4d34030a7128545897ef9f6410285965aa60a74992094336d6851` |
| `AuctionVoided(uint256 indexed saleId)` | `0x5b7201342ffb4a6650d6108ed4e2b82dac9e7efc56b5f0e5a8d0757dc186b1c6` |
| `BidClaimed(uint256 indexed saleId, uint256 indexed bidId, address indexed bidder, address to, uint256 unitsWon, uint256 refund)` | `0x0c081c9a607de4b30ffc3e1b07522571ea711571a743f683fd01470124cd84d6` |
| `BidPlaced(uint256 indexed saleId, uint256 indexed bidId, address indexed bidder, uint256 step, uint256 quantity, uint256 position, uint64 endTime)` | `0xea05b7c068c31a357fabd033340f7742c722f9491acac9bef1f500ab6049976e` |
| `BidRaised(uint256 indexed saleId, uint256 indexed bidId, address indexed bidder, uint256 fromStep, uint256 toStep, uint256 position, uint256 paid, uint64 endTime)` | `0x147e61d6f7ae34d614677da9caeca4f1607dad8a974ce9713980887341d7f677` |
| `Claimed(address indexed account, address indexed currency, address indexed to, uint256 amount)` | `0x913c992353dc81b7a8ba31496c484e9b6306bd2f6c509a649a38fdf5e1c953b2` |
| `ConfigSet(AuctionConfig previous, AuctionConfig next)` | `0xfb9b971e8d5d17ae15a88f6bb9c0cca5b551b15393093171d0ae29aa9e33f2d7` |
| `CreditExpired(address indexed account, address indexed currency, address indexed to, uint256 amount)` | `0xf9ca24059cdd86b3607573ff5bb441a41b3469f47964d6d58b6330ec91964d23` |
| `Credited(address indexed account, address indexed currency, uint256 indexed saleId, uint256 amount)` | `0xdd0ef63b44a932361273bab95d6e9bfcea5c7850c43844f540314e89899b970c` |
| `DeparturesSwept(uint256 indexed saleId, uint256 swept, uint256 total, uint256 cutoff)` | `0xcd2f0b03cb6f968ada1bbdaff91cc336fb6973b27da2abf27ce51dae3bfa057e` |
| `EditionAdopted(uint256 indexed saleId, address indexed token, uint256 indexed id, bool runsOnItsOwn)` | `0x5e2c9651e7abdb68cf247374efb1c467424e2bdced9b578b44016895638e920b` |
| `LimitsSet(uint256 previous, uint256 next)` | `0x2a00ae88790916c355d74c47251101f6daa7fe1b163c26b2add418af558d8080` |
| `Paused(address account)` | `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` |
| `SaleSettled(uint256 indexed saleId, address indexed token, uint256 indexed tokenId, address buyer, address recipient, uint256 quantity, address currency, uint256 price, address seller, uint256 sellerProceeds, address feeRecipient, uint256 fee)` | `0x16010625338e58299cd56c138533827e742865fde105b0c14272c707dd971b20` |
| `SaleStarted(uint256 indexed saleId, address indexed token, uint256 indexed tokenId, bytes32 saleKind, address currency, uint256 price, uint64 startTime, uint64 endTime)` | `0x36e87edc6a9768b0cbf62a7a844b6d147adee3701d9778029ef463c3cf2df954` |
| `SettlementScanned(uint256 indexed saleId, uint256 wordsLeft)` | `0x5ba31e1bbb69e573c0a45536d92c79905d779f65b3b09f73ac88014db70b9429` |
| `TargetSet(address indexed token, bool listed)` | `0xd79dab7c1ad9be25388690df227462ca1accba2033dbdbd3011ff0eb30c25088` |
| `Unpaused(address account)` | `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` |

### PackageRegistry

The mint policy.

| Event | topic0 |
| --- | --- |
| `Bound(bytes32 indexed name, address target)` | `0xd18d9295537e6da9cdfc3a07c1de8a8d8eb30fd42853acff19f097e2969f4784` |
| `ContentReleased(address indexed token, uint256 indexed tokenId, bytes32 contentHash, uint256 beneficiary)` | `0x3148787f9c7b59535c75e7f202ad401ad0a5747807bcbba3a776fd1eb84f8776` |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` |
| `EntropyModuleSet(address previous, address next)` | `0xc2b63c3a530182bad21e5faaf67c6b3ffc1a8a10399bf37b73052324ae3a642b` |
| `MoveRevoked(uint256 indexed artistId, uint256 indexed nonce)` | `0x7cfb514923d27af9b82a4a821fe5a0bcd7ec408a9eb63cb78d0938a49b32e66e` |
| `PackageAccepted(bytes32 indexed packageRoot, uint256 indexed artistId, address indexed account)` | `0x49639e3178859abe27d1fabf424f120e3144b903fbc59fb7a6d5666da877907d` |
| `PackageRegistered(bytes32 indexed packageRoot, bytes32 evidenceHash, address indexed verifier, address indexed signer)` | `0x0c1aff273f69c590d79d6ec4500fbec709412c9d6f5aca50140d6f1e72d8b821` |
| `PackageRevoked(bytes32 indexed packageRoot, bytes32 reasonHash)` | `0x6d695ea27d607e410f90e6b81ed7be5aacde025347b8885f0eef8a60c796dd90` |
| `SignerApprovalsKilled(address indexed signer, uint64 epoch)` | `0xa47a0634e02a05e52cc39c37f9df593b8762d20283cb2f37446af19bf094b767` |
| `VerifierSet(address previous, address next, bytes32 codeHash)` | `0xa3fb3ba52a3f33a4d15ad313aff346c928cc1b2b39194ec69d2b7785d362a0ea` |

### Eip712CurationVerifier

| Event | topic0 |
| --- | --- |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` |
| `SignerDisabled(address indexed signer)` | `0xcd7d415743afbe3da9a397922c4a1d3f20efecad669641a0665b8fbd1f62d740` |
| `SignerEnabled(address indexed signer)` | `0x71b97cfbc2b8e475857f737bec1103b6beebaca04b52e11c9f7ecb527e64a6ca` |

### Accounts

The accounts module behind `StreamDirectory6529.ACCOUNTS`. A module that replaces another
(`previous()`) emits nothing for an account until it records it: follow the replaced module's
events for the account until `AccountInherited`, which carries the record the new module
copied (a pending change copied with it follows as `ChangeStaged`), and the new module's
events from then on.

| Event | topic0 |
| --- | --- |
| `AccountFrozen(uint256 indexed artistId, uint48 until)` | `0x983a5942682c78759d32ecfdf88ff04ffd3274f4392eae9115fa650723991cc9` |
| `AccountInherited(uint256 indexed artistId, address indexed from, ArtistIdentity identity, uint48 frozenUntil)` | `0xa6df5e97df70d885aaac414c33e265ea1fcbddcee3a38bda896f46ab997f7db7` |
| `AccountUnfrozen(uint256 indexed artistId)` | `0x5538ed094a81af73ef675d54ae7afcd21726935740de63e8dd6403fbb715eaf4` |
| `ArtistRegistered(uint256 indexed artistId, ArtistIdentity identity)` | `0xd245a084992a93fd6ea576a8978336bc03798bf9ae33d7863f3f5ac2464d2e8e` |
| `ChangeCancelled(uint256 indexed artistId, address indexed by, bool byNetwork)` | `0x88a03d9ccb529a0c33b398ed874de8eb17013d6989134d8ca2bb31d264882ddf` |
| `ChangeContested(uint256 indexed artistId, address indexed by, bytes32 priorOutcome)` | `0xd816e77c80ae4c124434434545964f41df90e44dd453a550fef12460674dbad6` |
| `ChangeExecuted(uint256 indexed artistId, ArtistIdentity previous, ArtistIdentity next)` | `0x8e7ef8fd2a03e7165c8094e3607108b18469eeed2ed508186ffefd3fa6e0488c` |
| `ChangeStaged(uint256 indexed artistId, PendingChange change)` | `0x43a503407545bc966818e02c3e25cab33c7e2478d79741918dcde367f8842d10` |
| `ConsolidationSourceSet(address previous, address next, bytes32 codeHash)` | `0x8d645963c52b8e54544a25d9c9cd4e06057464ce600dd092641fd970f630c37b` |
| `ContestExpired(uint256 indexed artistId)` | `0x7581cc54a135d361750f6124773095c416d451f6b06538f823864a9755ec25df` |
| `ContestResolved(uint256 indexed artistId, bool upheld, bool executed, bytes32 outcomeRef)` | `0x82a368c0e2070f2987a33692517ce1d64696a873b53c7323dbca5a8a998bfb10` |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` |
| `NonceRevoked(uint256 indexed artistId, uint256 nonce)` | `0x7b1a3f30c1ca888cfd6defd5d5df604c39c92f54a37840d7b876254accf0d4d7` |
| `PackageRegistrySet(address previous, address next)` | `0xf602f9bca87ed171d7fdb8fdcbde47a70bb58e7a2029620f431ea07ddb8edb93` |
| `ReplacementAcceptanceConsumed(uint256 indexed artistId, bytes32 digest)` | `0xe1bf6b84e73459c51246c8f5fc3e7f3c0fc2e9bd11eb59219b353501e7975df8` |

### IndependentStreamRegistry

The Independent Stream module behind `StreamDirectory6529.INDEPENDENT_STREAM`.

| Event | topic0 |
| --- | --- |
| `AccountDelistedSet(uint256 indexed artistId, bool delisted, bytes32 ref)` | `0xc4bd63683e73b2cd76845e0758b6809ffcb127857301e1322616def1b14ce0d3` |
| `ContentReleased(address indexed token, uint256 indexed tokenId, bytes32 contentHash, uint256 beneficiary)` | `0x3148787f9c7b59535c75e7f202ad401ad0a5747807bcbba3a776fd1eb84f8776` |
| `EntropyModuleSet(address previous, address next)` | `0xc2b63c3a530182bad21e5faaf67c6b3ffc1a8a10399bf37b73052324ae3a642b` |
| `FeeShareLowered(address indexed token, uint32 previous, uint32 share)` | `0x5aafd9e830d8c0b0a25ca576ffdffbc69cba6fa6cc47bcd41b655d89829fcc1a` |
| `ItemApproval(address indexed token, bytes32 indexed itemHash, uint24 royaltyRate, bool approved)` | `0xd01003cf110c0f0cbf6849a3da246681724a621912faa8da2385226cfcee46c2` |
| `ItemBarred(bytes32 indexed itemHash)` | `0x9b1016b2ec57e96b6029d244f95758a375ccbb698ae6238c2e395c06e80603e9` |
| `ItemMinted(address indexed token, bytes32 indexed itemHash, address indexed minter, address seller, address royaltyReceiver)` | `0x1f549374b12afd62ac341bae8a6cb1512e73ed29e5961cf1b9b1693eb5989df2` |
| `Registered(address indexed token, uint256 indexed artistId, address deployer, Form form, address partner, uint32 feeShare)` | `0xbebc3e520543205ae63d0f95e7a3b740c09e7ebdd4ef1d5d0c6254387c482f46` |
| `SaleContractSet(address indexed minter, uint48 addedAt, uint48 removedAt)` | `0x884ac7aee6a8b91090c40395002339c7e2b6b5ca06f6389959158e0836461681` |
| `StatusSet(address indexed token, Status previous, Status status, bytes32 ref)` | `0x8341d2d84f9596d820848da5651bb557815048d9abe29c5dcec029579338c585` |
| `TemplateSet(address indexed deployer, bytes32 creationHash, uint32 version, Form form, TemplateStatus status)` | `0x5afcee2db062b23dc1020a5f1c56661da035bcb835fe4638e2688030c4cc74db` |

### IndependentStreamDeployer

| Event | topic0 |
| --- | --- |
| `CreationCodeStored(bytes32 indexed creationHash, address[] pointers)` | `0x87b99061ecbd89753d1b3526110e824d217ba03d46d34772dbc2fcb290f43fba` |
| `Deployed(address indexed token, address indexed caller, bytes32 salt, bytes config)` | `0xe51cd6598376a15fc5313375fb7622c135e466c5a071e795afc7e99214282fb5` |

### StreamTerms

The TERMS module.

| Event | topic0 |
| --- | --- |
| `EditionsSet(address indexed token, address editions)` | `0x13d4a5549a80baa8324606bc90162adbf093ce50fa2503562674f0922e5d8fe8` |
| `FeeShareLowered(address indexed token, uint256 indexed tokenId, uint32 previous, uint32 share, address receiver)` | `0x49e5ebea2aa2c1872dee48dfdae2fd7748c45f330b1b62140e5f1ac969b50c39` |

### WorkRules

The RECORDS module.

| Event | topic0 |
| --- | --- |
| `DeliverySet(address previous, address next)` | `0x113e2022127f41af1670206bb33d2c69486d7f4f382e9284c2c974fea2fbd666` |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` |
| `FileStoreSet(address indexed token, uint256 indexed tokenId, bytes32 indexed fileId, uint256 storeId)` | `0xac6e63dad0d81eeedb2ae2e671f0f6a461a8d25f978baab218ce117b26c76050` |
| `FinalizeNoticeRecorded(address indexed token, uint256 indexed tokenId, uint256 dueAt)` | `0xc2333be19fc2214b40c22ecb199512c11bde20cec926c9cc45d84b1f2edb925c` |
| `PowersRenounced(address indexed token, uint256 indexed tokenId, uint16 powers)` | `0x134c17fd149ea45174ca8d4d33d06a7a06e7380cb026e6168b42f249522d696d` |
| `StoreAdded(uint256 indexed storeId, address source, bytes32 codeHash)` | `0x33a0067382509bd225121e0df109204fa1c0f3a77159dd2cfe964663410d72d7` |
| `StoreRetired(uint256 indexed storeId)` | `0xc7b2b3897c4390e52536d6aa48ff4740f04bd1a90ac2ba6202dee15611febfb9` |
| `VersionBumped(address indexed token, uint256 indexed tokenId, uint32 version)` | `0x8929d3ca711e455d2d4c3df32f007d7f8b664263a2e393484e2774077eef9518` |

### WorkDelivery

| Event | topic0 |
| --- | --- |
| `CollectionPreferredKindSet(address indexed token, uint256 indexed collectionId, LocatorKind previous, LocatorKind next)` | `0xb5d4d95ff9549784d3d61566eaae61808ad2b59bf9f30b61aa9850506342c13d` |
| `FilePreferenceSet(address indexed token, uint256 indexed tokenId, bytes32 indexed fileId, uint256 previous, uint256 next)` | `0x2be2d40d1e3e2acf8adbff5a51d1dd97f0cf0eea5ff40475c540b61daa6799ce` |
| `LocatorAdded(address indexed token, uint256 indexed tokenId, bytes32 indexed fileId, uint256 index, Locator locator, address addedBy, bool byArtist)` | `0x79bd2095ea832d3b4216661e3eebdcdc6b8bb450bff582ddfc2acb8441568e10` |
| `LocatorDead(address indexed token, uint256 indexed tokenId, bytes32 indexed fileId, uint256 index)` | `0xeee30dfba1ae5bba90f3ebdab8b22be714b40a651b5d65fab3650c2f7e442fa8` |
| `PreferredKindSet(address indexed token, LocatorKind previous, LocatorKind next)` | `0x62c03a611a79d750e9d6aff5dfdcb962020ced95e244bc267aee7b52bf11aef9` |

### SplitLedger

Permanent. `WalletCreated` carries the whole payee list.

| Event | topic0 |
| --- | --- |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` |
| `Forfeited(address indexed wallet, address indexed asset, uint256 indexed payee, uint256 amount)` | `0x0442f04792766e07062ce8326d55602839c8446474241c3142c422143d63b877` |
| `Marked(address indexed wallet, address indexed asset, uint256 indexed payee, uint256 target, uint256 markedAt)` | `0x1b7ef417e104a7de7d3eada7ae1d9dd6aaf812a0f7490141c66d7ae502b50614` |
| `NonceUsed(address indexed account, uint256 indexed nonce, bool revoked)` | `0x4efdf80e1ee210a464536b94135bd8ee19bc4cfe4f456dee6baa71426721a82b` |
| `Released(address indexed wallet, address indexed asset, address indexed recipient, uint256 payee, address account, uint256 amount, uint256 observed)` | `0x6f6357cde2444cd0595d716c6d2f41683d4bcbc3792451a714a1f8e6e7dcabd1` |
| `WalletCreated(address indexed wallet, bytes32 indexed configHash, bytes32 salt, Payee[] payees)` | `0x140f5f9969cb7742e82b483caead38e16ee71968d0c0147939e24b8cc251372f` |

### RevenueEscrow

Permanent.

| Event | topic0 |
| --- | --- |
| `Credited(address indexed wallet, address indexed asset, address indexed payer, uint256 amount, uint256 owed)` | `0x2a56c0b8b56559d2047c27729efa9ad0bba3ad9f14cbab37251e3008934dbdb0` |
| `ExcessSwept(address indexed asset, address indexed recipient, uint256 amount)` | `0xb3c71476dfd272eb50cc448234b60ee937ab332f54e7eaab71159ca6eb677440` |
| `Expired(address indexed wallet, address indexed asset, address indexed network, uint256 amount, uint256 owed)` | `0x077a06ed25a672da3d2c8553e96ab0dded8e77c8fc9e1c4b2a9b2ed86ff42d0c` |
| `Flushed(address indexed wallet, address indexed asset, address indexed caller, uint256 amount)` | `0xf5c342afbc0fd5497d66d2246a8208902c06a969755b7f7c415041a67d222caf` |
| `Recovered(address indexed wallet, address indexed replacement, address indexed asset, uint256 amount, uint256 owed, bool consentUsed)` | `0x68a926f9ac3012213c7c910c9ab35da7a4435bad8108a53996843598e6d9f8a2` |
| `RecoveryConsentSet(address indexed account, address indexed replacement)` | `0x4d47077de11627502b9cf0f9e550c82b6776030b1e996a5688440f97717726b7` |

### ClaimRouter

| Event | topic0 |
| --- | --- |
| `ClaimFailed(address indexed wallet, address indexed asset, uint256 indexed payee, uint256 index, uint256 size, bytes reason)` | `0xdaabf7a59b4eba4a2596b828b3ea851d5c37ae2de75087cf6d2c2bdd159d7070` |

### GovernedVault

Deployed twice: `FeeRecipientVault` and `MuseumVault`.

| Event | topic0 |
| --- | --- |
| `DestinationSet(address indexed previous, address indexed next, uint64 revision)` | `0x7d092768b36924d875a609cceff41f2f080e2e26b997ff2dfe602459fe066d22` |
| `Forwarded(address indexed asset, address indexed destination, uint256 amount)` | `0x0571d85fc9cce8d2ebf18e983becef6cc884e37503f377f9b6383d65850f96d2` |
| `TokenForwarded(address indexed token, uint256 indexed id, address indexed destination, uint256 amount)` | `0x6d58ff684d44243032dd67f713e8663a4a1b0233564136db7cea1a16f19aac5e` |

### EconomicsResolver

| Event | topic0 |
| --- | --- |
| `DefaultLicenseSet(bytes32 indexed product, License previous, License next, uint64 revision)` | `0x45967214951395edfaed913e180d66f46dc20f884611341e05657335090698b1` |
| `EconomicsSet(bytes32 indexed product, ProductEconomics previous, ProductEconomics next, uint64 revision)` | `0x7b619472492d3cc46abfe0e47b5d8d9cda2fc6d6d600c6419416f2216b2ae7d3` |
| `MuseumSet(address previous, address next, uint64 revision)` | `0x2a1c096078cbb1875dbcbf421f3c0f318e9bed496c866d5b4c3b234470ce684f` |

### AssetAllowlist

| Event | topic0 |
| --- | --- |
| `AssetStatusChanged(address indexed asset, Status previous, Status current, uint64 revision)` | `0xd5701084de76fb29c872a1a80df02ce3534cfe6bb1437ad174219a1dd3626c0c` |
| `IncrementFloorChanged(address indexed asset, uint256 previous, uint256 current, uint64 revision)` | `0x866085d802dfc753eb059bc39bdea997aaaefc005a15744952a21ae167284f43` |
| `OpeningBidSet(address indexed asset, uint256 previous, uint256 current, uint64 revision)` | `0x1d028eb330db5a5432221d450b43b0c134b8ce8c37f5ee1ee007d67b57690e0d` |

### StatementLog

| Event | topic0 |
| --- | --- |
| `ArtistResolverSet(address indexed previous, address indexed next, bytes32 codeHash)` | `0x0923c8444fde0faa8f8b86ac14170efc9116fa3fc434402baab8c4ef1731c3ff` |
| `EIP712DomainChanged()` | `0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31` |
| `NonceRevoked(address indexed signer, uint256 indexed nonce)` | `0x22cd1acb7e7a306800a1b2c0ca9b0280187bbc00b7fbf55d38ad6cbf73082aec` |
| `StatementAppended(bytes32 indexed subjectKey, bytes32 indexed kind, address indexed signer, Role role, address resolver, uint64 index, uint64 recordedAt, bytes32 entryHash, bytes32 head, Statement statement)` | `0x5cc78d0bb8cba9859acd138dcd052b94f324e46596996fa42262ccee5d1a45a5` |
| `StatementRelayed(bytes32 indexed entryHash, address indexed signer, uint256 nonce)` | `0x080f9921ae00d2f63d13ca84de2d985b72f4a84a0a7b898d568853dc747754fc` |

### VrfEntropyModule

| Event | topic0 |
| --- | --- |
| `ConfigSet(VrfConfig previous, VrfConfig next)` | `0xc5843e7141f604b3110f98ce25e5557fe89b0f64cff0657e5cefc993f00511a9` |
| `CoordinatorSet(address previous, address next, bytes32 codeHash)` | `0x04092dc0da2aa8151ef027969128a1ab74240da2198b35dd3a2118b6043617ff` |
| `IndependentSeedRequested(address indexed token, bytes32 indexed contentHash, bytes32 key, uint256 requestId)` | `0x0cef5942b04d271e4bfb17392ed9c8b3d324991563ba71c4023311fd21d9a8ab` |
| `SeedDelivered(bytes32 indexed contentHash, uint256 requestId, bytes32 seed)` | `0x2a1a98d789f6210c2fb6c327204a52242c65b0c98a164f3fc8bc1c6b0479eb0d` |
| `SeedLinked(bytes32 indexed itemHash, bytes32 indexed contentHash)` | `0xf4e9ac388df032c7aa58c87fffa65eea30eafa553518699548720ef2f6f64f42` |
| `SeedRequested(bytes32 indexed itemHash, uint256 requestId)` | `0x13ccebb8a291fc5c387c182a5403c0aa3e322623fa2b250e1820cf8be4c55b2e` |
| `WrapperSet(address previous, address next, bytes32 codeHash)` | `0x5dc8bc344c7bb07bc94fb2f0e9186093715813ef72067a6f5dbf51a0c58e0ebc` |

### ContentStore

Permanent.

| Event | topic0 |
| --- | --- |
| `Base64Attested(bytes32 indexed fileId)` | `0xde611757905ea5f13eedb7ea4f8e87ddcbc29ce9429073a6a8b0cf12101e563e` |
| `Base64Progress(bytes32 indexed fileId, uint256 chunksValidated)` | `0x02b839e82d6e5c2ec40d13754cce314a887150d421bd3eeb478b03567c686971` |
| `ChunkLinked(bytes32 indexed chunkHash, bytes32[] parts, uint256 length)` | `0x056e8d2d0e279c919bc0abf134aa1cbaa238e1c82e00b6a5824a9cbd4b045425` |
| `ChunkWritten(bytes32 indexed chunkHash, address pointer, uint256 length)` | `0xa720bfe8fb78f1436f460c61e8c1a02410fc148201c63e8e07a8f54a82e5627a` |
| `CompletenessAttested(bytes32 indexed fileId)` | `0x2e1a6e20709fd29e201d8bbca654dc8e2798b38dae8856a0996ea1413a0ee461` |
| `CompletenessProgress(bytes32 indexed fileId, uint256 chunksPresent)` | `0x53b3afaf7bbb300e84a01a90b3649d20b3de9b3f9119e660ca910abe94e62aec` |
| `ManifestRegistered(bytes32 indexed fileId, uint256 length, uint8 encoding, uint8 digestKind, bytes32 digest, string mimeType, bytes32[] chunkHashes)` | `0x9d2280aa98b792abae06fab8602782374ae1ba5da821d3bf33469828424a6fea` |

### DependencyRegistry

| Event | topic0 |
| --- | --- |
| `DependencyDeprecated(bytes32 indexed name, bytes32 indexed version)` | `0x1ec1691a0ca2ee98d4fbcf4e43b0bb0e0a14423b3295cb62e5b0e3ab1f57cae5` |
| `DependencyRegistered(bytes32 indexed name, bytes32 indexed version, bytes32 indexed fileId)` | `0x5e1b96d09ad31255e23f0b0144c328663f9dcfd03600de24ba76bed97f415716` |

### GovernanceConfigurator

| Event | topic0 |
| --- | --- |
| `GovernanceConfigured(address indexed manager, bytes32 indexed configHash, bytes32 indexed manifestHash, bytes32 wiringHash)` | `0xeb9f30f841bfc2bc2f6aebff0405fc98dd6e152e030304669b0dcb91e6668529` |

### WorksAccessManager

OpenZeppelin `AccessManager`'s events and the network handover and brake.

| Event | topic0 |
| --- | --- |
| `BrakeSet(address indexed previous, address indexed next)` | `0xc17640aa65a242da452f776cfa288d39cc39573edf50ec8b3076c1ce28d76d0d` |
| `NetworkTransferStarted(address indexed network, address indexed next)` | `0x279641c669ad92c10b8262a5b387c5a2889fc75e067b8b195594c306fadeb1eb` |
| `NetworkTransferred(address indexed previous, address indexed next)` | `0xb736c5e31358d4cf3ec0a0d2619f9000ce4cfd6532921d62b3e2ece4fbc34082` |
| `OperationBraked(bytes32 indexed operationId, uint48 notBefore)` | `0x716ba1cd62522b6f676170563aed58e13e760f2ea4cbcda8a8a451f5702d214b` |
| `OperationCanceled(bytes32 indexed operationId, uint32 indexed nonce)` | `0xbd9ac67a6e2f6463b80927326310338bcbb4bdb7936ce1365ea3e01067e7b9f7` |
| `OperationExecuted(bytes32 indexed operationId, uint32 indexed nonce)` | `0x76a2a46953689d4861a5d3f6ed883ad7e6af674a21f8e162707159fc9dde614d` |
| `OperationScheduled(bytes32 indexed operationId, uint32 indexed nonce, uint48 schedule, address caller, address target, bytes data)` | `0x82a2da5dee54ea8021c6545b4444620291e07ee83be6dd57edb175062715f3b4` |
| `RoleAdminChanged(uint64 indexed roleId, uint64 indexed admin)` | `0x1fd6dd7631312dfac2205b52913f99de03b4d7e381d5d27d3dbfe0713e6e6340` |
| `RoleGrantDelayChanged(uint64 indexed roleId, uint32 delay, uint48 since)` | `0xfeb69018ee8b8fd50ea86348f1267d07673379f72cffdeccec63853ee8ce8b48` |
| `RoleGranted(uint64 indexed roleId, address indexed account, uint32 delay, uint48 since, bool newMember)` | `0xf98448b987f1428e0e230e1f3c6e2ce15b5693eaf31827fbd0b1ec4b424ae7cf` |
| `RoleGuardianChanged(uint64 indexed roleId, uint64 indexed guardian)` | `0x7a8059630b897b5de4c08ade69f8b90c3ead1f8596d62d10b6c4d14a0afb4ae2` |
| `RoleLabel(uint64 indexed roleId, string label)` | `0x1256f5b5ecb89caec12db449738f2fbcd1ba5806cf38f35413f4e5c15bf6a450` |
| `RoleRevoked(uint64 indexed roleId, address indexed account)` | `0xf229baa593af28c41b1d16b748cd7688f0c83aaf92d4be41c44005defe84c166` |
| `TargetAdminDelayUpdated(address indexed target, uint32 delay, uint48 since)` | `0xa56b76017453f399ec2327ba00375dbfb1fd070ff854341ad6191e6a2e2de19c` |
| `TargetClosed(address indexed target, bool closed)` | `0x90d4e7bb7e5d933792b3562e1741306f8be94837e1348dacef9b6f1df56eb138` |
| `TargetFunctionRoleUpdated(address indexed target, bytes4 selector, uint64 indexed roleId)` | `0x9ea6790c7dadfd01c9f8b9762b3682607af2c7e79e05a9f9fdf5580dde949151` |

## Rebuilding state from logs

- **A Stream work.** `WorkMinted` gives the token, collection, artist, serial and every fact;
  `RoyaltySet` and `RoyaltyRateLocked` the royalty; `PrimarySale` or `WorkRescued` the outcome;
  `Transfer` the owner. A burn (`Transfer` to zero) frees the content hash `WorkMinted` carried,
  so `tokenOfContent` is rebuilt from the two.
- **Modules and minters.** `ModuleSet` (genesis and activation, zero on removal),
  `ModuleProposed` (pending), `MinterAdded`, `MinterRemoved`, and the `*DelaySet` events give the
  current settings.
- **A record.** The `StreamWorkFacts6529` events for `(token, tokenId)` in order.
- **An edition.** `EditionCreated`, `EditionMinted`, `EditionSupplySealed`, `EditionRebound`,
  `RoyaltySet`.

### Statements

Index `StatementAppended` by `subjectKey`; each chain's indexes are contiguous and its head
matches `chainOf`.

## Caveats

- **Order by log index**, not by contract: a start touches the policy, Stream and the auction.
- **Reorgs.** Keep the block hash with every log; each collection's serials run 1, 2, 3.
- **Burned tokens leave ID gaps.** `totalMinted()` is the highest ID; `totalSupply()` counts
  live tokens.
- **Edition ID equals master token ID.**
- **Lazy events.** An expired auction pause is written down by a later transaction.
- **Not emitted:** content-store completeness before attestation (read `isComplete`), which
  wallets act for an account (read `isWallet`), money arriving in a split vault (read balances).
- **Governed vault forwards.** A `GovernedVault` forward log can be emitted for a token the
  vault never held: key it on the token address and match the token's own `Transfer`.

## ERC-4906 refresh triggers

| Change | Event |
| --- | --- |
| A record opened, set, finalized, relicensed, repinned, marked on-chain complete; a royalty change | `MetadataUpdate(tokenId)` on the token |
| A delivery preference change for many works | `BatchMetadataUpdate` |
| `setContractURI` | `ContractURIUpdated` |

Metadata also changes with no ERC-4906 event when a dispute outcome is recorded, when a record
or preview file completes in the store, and when a base64 file is attested. A burned token's
`tokenURI` reverts; its `Transfer` to zero is the signal.
