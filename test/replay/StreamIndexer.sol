// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IStreamViews } from "src/interfaces/IStreamViews.sol";
import { IWorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds 6529 Stream from its own logs (WS-44, WS-23, AUC-43): every work's owner,
///         approval, core record, terms, primary-sale outcome, edition link and burn; the
///         collections, admitted adapters, fee recipients, content claims and releases; the
///         default renderer, the replaced dependencies and the marketplace fields.
/// @dev Written from `docs/integrators/events-and-indexing.md` (Stream). The royalty receiver is
///      derived, never logged (ECO-7): the indexer computes it with the split ledger's CREATE2
///      formula. Stream's constructor logs a `DependencySet` for each of its four mutable genesis
///      dependencies, so every dependency is known from the logs from deployment on.
contract StreamIndexer is ReplayIndexer {
    struct Token {
        bool burned;
        address owner;
        address approved;
        bytes32 itemHash;
        uint256 artistId;
        uint256 collectionId;
        uint64 serial;
        uint8 flags;
        bytes32 contentHash;
        address seller;
        uint32 royaltyRate;
        uint32 feeShare;
        uint24 feeRecipientId;
        uint24 minterId;
        PrimaryOutcome outcome;
        address currency;
        uint256 price;
        bool linked;
    }

    struct Terms {
        uint32 royaltyRate;
        uint32 feeShare;
        uint24 feeRecipientId;
        uint24 minterId;
    }

    struct Minter {
        bool admitted;
        uint24 id;
        bytes32 saleKind;
    }

    struct Collection {
        string name;
        bytes32 metadataHash;
        uint64 minted;
    }

    struct Claim {
        uint256 tokenId;
        bool released;
        uint256 beneficiary;
    }

    /// @dev `WorkMinted`'s data: its fields are all static, so a struct decodes them in order.
    struct Minted {
        bytes32 itemHash;
        uint64 serial;
        uint8 flags;
        bytes32 packageRoot;
        bytes32 contentHash;
        bytes32 mediaHash;
        bytes32 recordFileId;
        address seller;
        uint24 termsId;
    }

    bytes32 private constant ENTROPY_MODULE = "ENTROPY_MODULE";
    bytes32[4] private _kinds =
        [bytes32("PACKAGE_REGISTRY"), "ECONOMICS", ENTROPY_MODULE, "EXTENSION"];

    /// @notice The split ledger whose wallets receive royalties (a deployment constant).
    address public immutable ledger;

    address public authority;
    address public marketOwner;
    string public contractURI;
    address public defaultRenderer;
    bytes32 public defaultRendererCodeHash;
    address public workRecords;
    address public editions;
    uint256 public minted;
    uint256 public burned;

    mapping(bytes32 kind => address) internal _deps;
    uint256[] internal _eras;
    Collection[] internal _collections;
    address[] internal _feeRecipients;
    mapping(uint24 termsId => Terms) internal _terms;
    address[] internal _adapters;
    mapping(address adapter => Minter) internal _minters;
    mapping(uint256 tokenId => Token) internal _tokens;
    address[] internal _holders;
    mapping(address holder => bool) internal _isHolder;
    mapping(address holder => uint256) internal _balances;
    address[] internal _opOwners;
    address[] internal _opOperators;
    mapping(address owner => mapping(address operator => bool)) internal _operators;
    bytes32[] internal _contents;
    mapping(bytes32 contentHash => Claim) internal _claims;
    mapping(bytes32 itemHash => bool) internal _tombstoned;

    constructor(address stream_, address ledger_) ReplayIndexer(stream_) {
        ledger = ledger_;
    }

    // ------------------------------------------------------------------ reads for other indexers

    /// @notice A dependency as the logs name it: zero until a `DependencySet` of its kind.
    function dependency(bytes32 kind) external view returns (address) {
        return _deps[kind];
    }

    function royaltyRateOf(uint256 tokenId) external view returns (uint32) {
        return _tokens[tokenId].royaltyRate;
    }

    function seedPolicyOf(uint256 tokenId) external view returns (uint8) {
        return (_tokens[tokenId].flags >> 2) & 3;
    }

    function artistOf(uint256 tokenId) external view returns (uint256) {
        return _tokens[tokenId].artistId;
    }

    function linked(uint256 tokenId) external view returns (bool) {
        return _tokens[tokenId].linked;
    }

    // ------------------------------------------------------------------ the logs

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == IStream.WorkMinted.selector) {
            _minted(log);
        } else if (sig == IERC721.Transfer.selector) {
            _transfer(_addr(log.topics[1]), _addr(log.topics[2]), uint256(log.topics[3]));
        } else if (sig == IERC721.Approval.selector) {
            _tokens[uint256(log.topics[3])].approved = _addr(log.topics[2]);
        } else if (sig == IERC721.ApprovalForAll.selector) {
            address owner = _addr(log.topics[1]);
            address operator = _addr(log.topics[2]);
            _opOwners.push(owner);
            _opOperators.push(operator);
            _operators[owner][operator] = abi.decode(log.data, (bool));
        } else if (sig == IStream.TermsInterned.selector) {
            Terms storage t = _terms[uint24(uint256(log.topics[1]))];
            (t.royaltyRate, t.feeShare, t.feeRecipientId, t.minterId) =
                abi.decode(log.data, (uint32, uint32, uint24, uint24));
        } else if (sig == IStream.FeeRecipientRegistered.selector) {
            assertEq(uint256(log.topics[1]), _feeRecipients.length + 1, "indexer: fee recipient id");
            _feeRecipients.push(abi.decode(log.data, (address)));
        } else if (sig == IStream.PrimarySaleSettled.selector) {
            Token storage t = _tokens[uint256(log.topics[1])];
            assertEq(uint8(t.outcome), 0, "indexer: settled twice");
            (PrimaryOutcome outcome, address currency, uint256 price) =
                abi.decode(log.data, (PrimaryOutcome, address, uint256));
            t.outcome = outcome;
            if (outcome == PrimaryOutcome.SOLD) {
                // Stream keeps the price in 96 bits (`primarySale`); the log has it in full.
                (t.currency, t.price) =
                (currency, price < type(uint96).max ? price : type(uint96).max);
            }
        } else if (sig == IStream.RoyaltyRateChanged.selector) {
            Token storage t = _tokens[uint256(log.topics[1])];
            (uint32 previous, uint32 next) = abi.decode(log.data, (uint32, uint32));
            assertEq(previous, t.royaltyRate, "indexer: previous royalty rate");
            t.royaltyRate = next;
        } else if (sig == IStream.FeeShareLowered.selector) {
            Token storage t = _tokens[uint256(log.topics[1])];
            (uint32 previous, uint32 share) = abi.decode(log.data, (uint32, uint32));
            assertEq(previous, t.feeShare, "indexer: previous fee share");
            t.feeShare = share;
        } else if (sig == IStream.ContentReleased.selector) {
            uint256 tokenId = uint256(log.topics[1]);
            (bytes32 content, uint256 beneficiary) = abi.decode(log.data, (bytes32, uint256));
            _claims[content] = Claim(tokenId, true, beneficiary);
            _tombstoned[_tokens[tokenId].itemHash] = true;
        } else if (sig == IStream.CollectionCreated.selector) {
            assertEq(uint256(log.topics[1]), _collections.length + 1, "indexer: collection id");
            (string memory name, bytes32 metadataHash) = abi.decode(log.data, (string, bytes32));
            _collections.push(Collection(name, metadataHash, 0));
        } else if (sig == IMintTarget.AdmittedMinterSet.selector) {
            address adapter = _addr(log.topics[1]);
            Minter storage m = _minters[adapter];
            if (m.id == 0) _adapters.push(adapter);
            m.id = uint24(uint256(log.topics[2]));
            (m.admitted, m.saleKind) = abi.decode(log.data, (bool, bytes32));
        } else if (sig == IStream.DependencySet.selector) {
            bytes32 kind = log.topics[1];
            (address previous, address next) = abi.decode(log.data, (address, address));
            if (kind == ENTROPY_MODULE) _eras.push(minted << 160 | uint160(previous));
            _deps[kind] = next;
        } else if (sig == IStream.DefaultRendererSet.selector) {
            (, defaultRenderer, defaultRendererCodeHash) =
                abi.decode(log.data, (address, address, bytes32));
        } else if (sig == IStream.EditionLinked.selector) {
            _tokens[uint256(log.topics[1])].linked = true;
        } else if (sig == IStream.Bound.selector) {
            address bound = abi.decode(log.data, (address));
            if (log.topics[1] == bytes32("WORK_RECORDS")) workRecords = bound;
            else if (log.topics[1] == bytes32("EDITIONS")) editions = bound;
            else revert("indexer: unknown binding");
        } else if (sig == IStream.OwnershipTransferred.selector) {
            marketOwner = _addr(log.topics[2]);
        } else if (sig == IStream.ContractURISet.selector) {
            (, contractURI) = abi.decode(log.data, (string, string));
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else if (sig == IERC4906.BatchMetadataUpdate.selector) {
            (uint256 from, uint256 to) = abi.decode(log.data, (uint256, uint256));
            assertEq(from, 1, "indexer: batch refresh from 1");
            assertEq(to, minted, "indexer: batch refresh to totalMinted");
        } else if (
            sig != IStream.WorkRescued.selector && sig != IStream.ContractURIUpdated.selector
                && sig != IERC4906.MetadataUpdate.selector
        ) {
            _unknown(sig);
        }
    }

    function _minted(Vm.Log memory log) private {
        uint256 tokenId = uint256(log.topics[1]);
        assertEq(tokenId, minted + 1, "indexer: token id gap");
        minted = tokenId;
        Token storage t = _tokens[tokenId];
        t.collectionId = uint256(log.topics[2]);
        t.artistId = uint256(log.topics[3]);
        Minted memory m = abi.decode(log.data, (Minted));
        (t.itemHash, t.serial, t.flags, t.contentHash, t.seller) =
        (m.itemHash, m.serial, m.flags, m.contentHash, m.seller);
        Collection storage c = _collections[t.collectionId - 1];
        assertEq(t.serial, ++c.minted, "indexer: serial gap");
        Terms memory terms = _terms[m.termsId];
        require(terms.minterId != 0, "indexer: WorkMinted names unknown terms");
        (t.royaltyRate, t.feeShare, t.feeRecipientId, t.minterId) =
        (terms.royaltyRate, terms.feeShare, terms.feeRecipientId, terms.minterId);
        Claim storage claim = _claims[t.contentHash];
        if (claim.tokenId == 0) _contents.push(t.contentHash);
        // A released claim keeps its beneficiary when the beneficiary's item consumes it.
        (claim.tokenId, claim.released) = (tokenId, false);
    }

    function _transfer(address from, address to, uint256 tokenId) private {
        Token storage t = _tokens[tokenId];
        if (from != address(0)) --_balances[from];
        t.approved = address(0);
        t.owner = to;
        if (to == address(0)) {
            t.burned = true;
            ++burned;
            return;
        }
        if (!_isHolder[to]) {
            _isHolder[to] = true;
            _holders.push(to);
        }
        ++_balances[to];
    }

    // ------------------------------------------------------------------ the comparison

    function assertMatches() external view override {
        IStream s = IStream(target);
        assertEq(IAccessManaged(target).authority(), authority, "authority");
        assertEq(s.owner(), marketOwner, "owner");
        assertEq(s.contractURI(), contractURI, "contractURI");
        assertEq(s.defaultRenderer(), defaultRenderer, "defaultRenderer");
        assertEq(s.workRecords(), workRecords, "workRecords");
        assertEq(s.editions(), editions, "editions");
        assertEq(s.totalMinted(), minted, "totalMinted");
        assertEq(IStreamViews(target).totalSupply(), minted - burned, "totalSupply");
        _checkDependencies(s);
        assertEq(s.collectionCount(), _collections.length, "collectionCount");
        for (uint256 i; i < _collections.length; ++i) {
            IStreamViews.Collection memory c = IStreamViews(target).collection(i + 1);
            assertEq(c.name, _collections[i].name, "collection name");
            assertEq(c.metadataHash, _collections[i].metadataHash, "collection metadataHash");
            assertEq(c.minted, _collections[i].minted, "collection minted");
        }
        for (uint256 i; i < _adapters.length; ++i) {
            assertEq(s.isAdmittedMinter(_adapters[i]), _minters[_adapters[i]].admitted, "admitted");
        }
        for (uint256 id = 1; id <= minted; ++id) {
            _checkToken(s, id);
        }
        for (uint256 i; i < _holders.length; ++i) {
            assertEq(IERC721(target).balanceOf(_holders[i]), _balances[_holders[i]], "balanceOf");
        }
        for (uint256 i; i < _opOwners.length; ++i) {
            assertEq(
                IERC721(target).isApprovedForAll(_opOwners[i], _opOperators[i]),
                _operators[_opOwners[i]][_opOperators[i]],
                "isApprovedForAll"
            );
        }
        for (uint256 i; i < _contents.length; ++i) {
            bytes32 content = _contents[i];
            Claim memory claim = _claims[content];
            bytes32 consumed = claim.released ? bytes32(0) : _tokens[claim.tokenId].itemHash;
            assertEq(s.consumedItemOf(content), consumed, "consumedItemOf");
            assertEq(s.releasedTo(content), claim.beneficiary, "releasedTo");
        }
    }

    function _checkDependencies(IStream s) private view {
        address[4] memory live =
            [s.packageRegistry(), s.economics(), s.entropyModule(), s.extension()];
        for (uint256 i; i < 4; ++i) {
            assertEq(live[i], _deps[_kinds[i]], "dependency");
        }
        for (uint256 id = 1; id <= minted; ++id) {
            for (uint256 e; e < _eras.length; ++e) {
                if (id <= _eras[e] >> 160) {
                    assertEq(s.entropyModuleOf(id), address(uint160(_eras[e])), "entropyModuleOf");
                    break;
                }
                if (e + 1 == _eras.length) {
                    assertEq(s.entropyModuleOf(id), _deps[ENTROPY_MODULE], "entropyModuleOf");
                }
            }
        }
    }

    function _checkToken(IStream s, uint256 id) private view {
        Token memory t = _tokens[id];
        assertEq(s.isReleased(t.itemHash), _tombstoned[t.itemHash], "isReleased");
        (PrimaryOutcome outcome, address currency, uint256 price) = s.primarySale(id);
        assertEq(uint8(outcome), uint8(t.outcome), "primarySale outcome");
        assertEq(currency, t.currency, "primarySale currency");
        assertEq(price, t.price, "primarySale price");
        (address linkedTo, uint256 editionId) = s.editionOf(id);
        assertEq(linkedTo, t.linked ? editions : address(0), "editionOf");
        assertEq(editionId, t.linked ? id : 0, "editionOf id");
        if (t.burned) {
            try IERC721(target).ownerOf(id) returns (address) {
                revert("ownerOf: a burned work still answers");
            } catch { }
            assertFalse(s.primarySaleSettled(id), "burned: primarySaleSettled");
            return;
        }
        assertEq(IERC721(target).ownerOf(id), t.owner, "ownerOf");
        assertEq(IERC721(target).getApproved(id), t.approved, "getApproved");
        assertEq(s.primarySaleSettled(id), t.outcome != PrimaryOutcome.NONE, "primarySaleSettled");
        _checkCore(s, id, t);
        _checkTerms(s, id, t);
    }

    function _checkCore(IStream s, uint256 id, Token memory t) private view {
        (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collectionId,
            uint8 kind,
            uint8 seedPolicy,
            uint32 rate
        ) = s.coreOf(id);
        assertEq(itemHash, t.itemHash, "coreOf itemHash");
        assertEq(artistId, t.artistId, "coreOf artistId");
        assertEq(collectionId, t.collectionId, "coreOf collectionId");
        assertEq(kind, t.flags & 3, "coreOf kind");
        assertEq(seedPolicy, (t.flags >> 2) & 3, "coreOf seedPolicy");
        assertEq(rate, t.royaltyRate, "coreOf royaltyRate");
    }

    function _checkTerms(IStream s, uint256 id, Token memory t) private view {
        IStreamViews.WorkCore memory w = IStreamViews(target).work(id);
        assertEq(w.serial, t.serial, "work serial");
        assertEq(w.seller, t.seller, "work seller");
        address receiver =
            _royaltyReceiver(ledger, t.seller, _feeRecipients[t.feeRecipientId - 1], t.feeShare);
        assertEq(w.royaltyReceiver, receiver, "work royaltyReceiver");
        (address royaltyTo, uint256 amount) = s.royaltyInfo(id, 1 ether);
        assertEq(royaltyTo, receiver, "royaltyInfo receiver");
        assertEq(amount, uint256(1 ether) * t.royaltyRate / 100_000, "royaltyInfo amount");
    }
}

/// @notice Rebuilds `WorkRecords` from its own logs (WS-1, WS-9, WS-11, WS-37, WS-41 to WS-44):
///         each work's record file, media list and roles, license, seed, version, finalized
///         flag and pinned renderer, renounced powers, on-chain sync cursors and per-file stores,
///         finalize notice; the delivery contract and the added stores.
/// @dev The work state hash also covers the royalty rate and, for an unfinalized work, Stream's
///      default renderer; those come from the Stream indexer (Stream's own logs). Every state
///      hash an event carries is checked against the hash the indexer computes.
contract WorkRecordsIndexer is ReplayIndexer {
    struct Record {
        bool open;
        bytes32 recordFileId;
        bytes32 mediaHash;
        string spdxId;
        bytes32 textFileId;
        uint32 version;
        bool finalized;
        bool onChain;
        address renderer;
        uint16 renounced;
        bytes32 seed;
        bytes32[] media;
        uint8[] roles;
        uint8[] storeOf;
        uint256 syncedFiles;
        uint256 notice;
    }

    struct Store {
        address source;
        bytes32 codeHash;
        bool retired;
    }

    bytes32 private constant STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1");

    StreamIndexer public immutable streamIndexer;
    address public delivery;
    address public authority;
    Store[] internal _stores;
    uint256[] internal _opened;
    mapping(uint256 tokenId => Record) internal _records;
    mapping(address renderer => bytes32) public pinnedCodeHash;

    constructor(address records_, StreamIndexer streamIndexer_) ReplayIndexer(records_) {
        streamIndexer = streamIndexer_;
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        uint256 tokenId = log.topics.length > 1 ? uint256(log.topics[1]) : 0;
        Record storage r = _records[tokenId];
        bytes32 stateHash;
        if (sig == IWorkRecords.RecordOpened.selector) {
            _opened.push(tokenId);
            _open(r, log.data);
            return;
        } else if (sig == IWorkRecords.RecordSet.selector) {
            (r.recordFileId, stateHash) = abi.decode(log.data, (bytes32, bytes32));
        } else if (sig == IWorkRecords.WorkFinalized.selector) {
            bytes32 codeHash;
            (r.renderer, codeHash, stateHash) = abi.decode(log.data, (address, bytes32, bytes32));
            r.finalized = true;
            if (pinnedCodeHash[r.renderer] == 0) pinnedCodeHash[r.renderer] = codeHash;
        } else if (sig == IWorkRecords.LicenseChanged.selector) {
            License memory next;
            (, next, stateHash) = abi.decode(log.data, (License, License, bytes32));
            (r.spdxId, r.textFileId) = (next.spdxId, next.textFileId);
        } else if (sig == IWorkRecords.RoyaltyRateSet.selector) {
            uint32 next;
            (, next, stateHash) = abi.decode(log.data, (uint32, uint32, bytes32));
            assertEq(
                next, streamIndexer.royaltyRateOf(tokenId), "indexer: rate set before Stream's"
            );
        } else if (sig == IWorkRecords.RendererRepinned.selector) {
            bytes32 codeHash;
            (, r.renderer, codeHash, stateHash) =
                abi.decode(log.data, (address, address, bytes32, bytes32));
            if (pinnedCodeHash[r.renderer] == 0) pinnedCodeHash[r.renderer] = codeHash;
        } else if (sig == IWorkPowers.PowersRenounced.selector) {
            (, r.renounced, stateHash) = abi.decode(log.data, (uint16, uint16, bytes32));
        } else {
            _other(sig, tokenId, r, log);
            return;
        }
        // Each of these six events bumps the record version (WS-11) and carries the new hash.
        ++r.version;
        assertEq(stateHash, _stateHash(tokenId, r), "indexer: event state hash");
    }

    function _other(bytes32 sig, uint256 tokenId, Record storage r, Vm.Log memory log) private {
        if (sig == IWorkRecords.MediaFileComplete.selector) {
            (uint256 index, uint256 storeId) = abi.decode(log.data, (uint256, uint256));
            r.storeOf[index] = uint8(storeId);
        } else if (sig == IWorkRecords.OnChainSyncProgress.selector) {
            (uint256 files,, uint256 storeId) = abi.decode(log.data, (uint256, uint256, uint256));
            if (storeId == 0) r.syncedFiles = files;
        } else if (sig == IWorkRecords.WorkOnChainComplete.selector) {
            r.onChain = true;
        } else if (sig == IWorkRecords.FinalizeNoticeRecorded.selector) {
            r.notice = abi.decode(log.data, (uint256)) - 14 days;
        } else if (sig == IWorkRecords.DeliverySet.selector) {
            assertEq(_addr(log.topics[1]), delivery, "indexer: delivery predecessor");
            delivery = _addr(log.topics[2]);
        } else if (sig == IWorkRecords.StoreAdded.selector) {
            assertEq(tokenId, _stores.length + 1, "indexer: store id");
            (address source, bytes32 codeHash) = abi.decode(log.data, (address, bytes32));
            _stores.push(Store(source, codeHash, false));
        } else if (sig == IWorkRecords.StoreRetired.selector) {
            _stores[tokenId - 1].retired = true;
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else {
            _unknown(sig);
        }
    }

    function _open(Record storage r, bytes memory data) private {
        (PackageItem memory item, MediaFile[] memory media,, bytes32 seed) =
            abi.decode(data, (PackageItem, MediaFile[], bytes32, bytes32));
        r.open = true;
        r.recordFileId = item.recordFileId;
        r.mediaHash = item.mediaHash;
        (r.spdxId, r.textFileId) = (item.license.spdxId, item.license.textFileId);
        r.seed = seed;
        for (uint256 i; i < media.length; ++i) {
            r.media.push(media[i].fileId);
            r.roles.push(media[i].role);
            r.storeOf.push(0);
        }
    }

    function _stateHash(uint256 tokenId, Record storage r) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                STATE_DOMAIN,
                tokenId,
                r.version,
                r.recordFileId,
                WorksHashing.licenseKey(r.spdxId),
                r.textFileId,
                streamIndexer.royaltyRateOf(tokenId),
                r.finalized ? r.renderer : streamIndexer.defaultRenderer()
            )
        );
    }

    function assertMatches() external view override {
        IWorkRecords w = IWorkRecords(target);
        assertEq(IAccessManaged(target).authority(), authority, "authority");
        assertEq(w.delivery(), delivery, "delivery");
        for (uint256 i; i < _stores.length; ++i) {
            assertEq(w.store(i + 1), _stores[i].source, "store");
            assertEq(w.storeRetired(i + 1), _stores[i].retired, "storeRetired");
        }
        for (uint256 id = 1; id <= streamIndexer.minted(); ++id) {
            Record storage r = _records[id];
            assertEq(w.isOpen(id), r.open, "isOpen");
            if (r.open) _checkRecord(w, id, r);
        }
    }

    function _checkRecord(IWorkRecords w, uint256 id, Record storage r) private view {
        IWorkRecords.RecordInfo memory info = w.record(id);
        assertEq(info.recordFileId, r.recordFileId, "record file");
        assertEq(info.mediaHash, r.mediaHash, "record mediaHash");
        assertEq(info.licenseKey, WorksHashing.licenseKey(r.spdxId), "record licenseKey");
        assertEq(info.version, r.version, "record version");
        assertEq(info.finalized, r.finalized, "record finalized");
        assertEq(info.onChainComplete, r.onChain, "record onChainComplete");
        assertEq(info.renderer, r.renderer, "record renderer");
        assertEq(w.pinnedRenderer(id), r.renderer, "pinnedRenderer");
        assertEq(
            IStream(streamIndexer.target()).rendererOf(id),
            r.finalized ? r.renderer : streamIndexer.defaultRenderer(),
            "Stream rendererOf"
        );
        License memory license = w.licenseOf(id);
        assertEq(license.spdxId, r.spdxId, "licenseOf spdxId");
        assertEq(license.textFileId, r.textFileId, "licenseOf textFileId");
        assertEq(w.workStateHash(id), _stateHash(id, r), "workStateHash");
        assertEq(IWorkPowers(target).renouncedPowers(id), r.renounced, "renouncedPowers");
        assertEq(w.finalizeNoticeAt(id), r.notice, "finalizeNoticeAt");
        (uint8 policy, bytes32 seed) = w.seedOf(id);
        assertEq(policy, streamIndexer.seedPolicyOf(id), "seedOf policy");
        assertEq(seed, r.seed, "seedOf seed");
        MediaFile[] memory media = w.mediaOf(id);
        assertEq(media.length, r.media.length, "mediaOf length");
        for (uint256 i; i < media.length; ++i) {
            assertEq(media[i].fileId, r.media[i], "mediaOf fileId");
            assertEq(media[i].role, r.roles[i], "mediaOf role");
            assertEq(w.mediaIndex(id, r.media[i]), i, "mediaIndex");
            (uint256 storeId, bool complete) = w.mediaStore(id, i);
            assertEq(storeId, r.storeOf[i], "mediaStore storeId");
            assertEq(
                complete, r.onChain || i < r.syncedFiles || storeId != 0, "mediaStore complete"
            );
        }
    }
}
