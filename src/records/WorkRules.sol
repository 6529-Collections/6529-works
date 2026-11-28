// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IDeliveryHost, IWorkDelivery } from "../interfaces/IWorkDelivery.sol";
import { IWorkPowers, WorkPowers } from "../interfaces/IWorkPowers.sol";
import { Facts, Outcome, Slots, Work } from "../interfaces/core/CoreTypes.sol";
import { IAccounts } from "../interfaces/core/IAccounts.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { ITerms } from "../interfaces/core/ITerms.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "../interfaces/core/IWorkRules.sol";
import { License, PackageItem } from "../interfaces/types/PackageTypes.sol";
import { StreamHashing } from "../interfaces/types/StreamHashing.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title WorkRules
/// @notice The RECORDS module (replaceable): who may change a work's record in `IWorkFacts`,
///         and when, for every token whose RECORDS slot names it (6529 Stream, and Independent
///         Stream tokens through the directory's `INDEPENDENT_RECORDS` slot). Keyed by token
///         contract.
///         - The lead artist (any wallet of the account `IStream.workOf(id).artistId`) replaces
///           the descriptive record until finalize, and finalizes at any time.
///         - Once the first sale has an outcome, anyone records a finalize notice, and finalizes
///           `FINALIZE_NOTICE` after it.
///         - Relicensing and a royalty-rate change need every party's consent (counted by
///           account) and the network's call.
///         - The network alone repins a finalized work's renderer.
///         - The lead artist renounces powers for good; renouncing the royalty or license power
///           also needs the network's call. Each power maps to a permanent one-way lock: the
///           token's royalty-rate lock (through the TERMS module), the license and pin locks in
///           `IWorkFacts`.
///         - It holds the delivery contract (locators) and the list of added stores, with the
///           artist's choice of store per media file.
/// @dev Consents are EIP-712 signatures in this contract's own domain, bound to
///      `workStateHash`, which commits to this contract's address and a version that every
///      applied change bumps, so no consent applies twice and none carries over to a successor.
///      What can never change (media, the record after finalize, leaving CC0, a lock) is
///      enforced by `IWorkFacts` and the token, whatever this module does.
contract WorkRules is AccessManaged, EIP712, IWorkRules, IWorkPowers, IDeliveryHost {
    /// @inheritdoc IWorkRules
    uint256 public constant FINALIZE_NOTICE = 14 days;
    /// @notice The most added stores: a bound on the list, not a policy.
    uint256 public constant MAX_STORES = 15;
    /// @notice The EIP-712 domain name.
    string public constant NAME = "6529 Stream Rules";
    /// @notice Every party agrees to relicense a work.
    bytes32 public constant RELICENSE_TYPEHASH = keccak256(
        "Relicense(address token,uint256 tokenId,bytes32 licenseKey,bytes32 textFileId,"
        "bytes32 stateHash,uint64 deadline)"
    );
    /// @notice Every party agrees to change a work's royalty rate.
    bytes32 public constant ROYALTY_RATE_TYPEHASH = keccak256(
        "RoyaltyRateChange(address token,uint256 tokenId,uint24 rate,bytes32 stateHash,"
        "uint64 deadline)"
    );
    /// @notice The lead artist renounces powers over a work (`WorkPowers` bits).
    bytes32 public constant RENOUNCE_POWERS_TYPEHASH = keccak256(
        "RenouncePowers(address token,uint256 tokenId,uint16 powers,bytes32 stateHash,"
        "uint64 deadline)"
    );

    bytes32 private constant STATE_DOMAIN = keccak256("6529STREAM_WORK_STATE_V2");
    /// @dev The powers whose renunciation also needs the network's call.
    uint16 private constant NETWORK_POWERS = WorkPowers.ROYALTY_RATE | WorkPowers.RELICENSE;

    /// @notice A store beside the content store, pinned by code hash.
    /// @param source The store (`IChunkStore`).
    /// @param retired True once the network retired it: no file can choose it any more.
    /// @param codeHash The code hash it was added with.
    struct Store {
        address source;
        bool retired;
        bytes32 codeHash;
    }

    /// @notice A work's version moved: a change was applied, so every earlier state hash, and
    ///         every consent bound to one, is spent.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param version The version now.
    event VersionBumped(address indexed token, uint256 indexed tokenId, uint32 version);
    /// @notice A store was added.
    /// @param storeId Its ID, from 1.
    /// @param source The store.
    /// @param codeHash Its code hash.
    event StoreAdded(uint256 indexed storeId, address source, bytes32 codeHash);
    /// @notice A store was retired.
    /// @param storeId The store.
    event StoreRetired(uint256 indexed storeId);
    /// @notice A media file's chosen store changed (zero: the content store).
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param fileId The media file.
    /// @param storeId The store now.
    event FileStoreSet(
        address indexed token, uint256 indexed tokenId, bytes32 indexed fileId, uint256 storeId
    );

    /// @notice The expected delivery contract is not the current one.
    error DeliveryMismatch();
    /// @notice The new delivery contract has no code, or does not name this module or the
    ///         record contract.
    error InvalidDelivery(address delivery);
    /// @notice The record file is not a registered, complete, one-chunk file stored as it is.
    error InvalidRecordFile(bytes32 fileId);
    /// @notice No store has this ID, or it is retired or its code changed.
    error UnknownStore(uint256 storeId);
    /// @notice The store list is full, or the store has no code or another code hash.
    error InvalidStore(address source);
    /// @notice The file is not one of the work's media files, or the store does not serve all
    ///         of its chunks.
    error FileNotServed(bytes32 fileId, uint256 storeId);

    /// @notice The permanent record contract (`IWorkFacts`).
    address public immutable facts;
    /// @notice The directory, through which the accounts module is found.
    address public immutable directory;
    /// @inheritdoc IWorkRules
    address public delivery;

    /// @notice A work's version: bumped by every change this module applies.
    mapping(address token => mapping(uint256 tokenId => uint32)) public versionOf;
    /// @inheritdoc IWorkRules
    mapping(address token => mapping(uint256 tokenId => uint48)) public finalizeNoticeAt;
    /// @notice The store each media file is complete in, chosen by the artist (zero: the
    ///         content store).
    mapping(address token => mapping(uint256 tokenId => mapping(bytes32 fileId => uint256))) public
        fileStore;
    Store[] private _stores;

    /// @param authority_ The AccessManager (the network).
    /// @param facts_ The permanent record contract.
    /// @param directory_ The directory.
    /// @param delivery_ The first delivery contract (it may be predicted), or zero.
    constructor(address authority_, address facts_, address directory_, address delivery_)
        AccessManaged(authority_)
        EIP712(NAME, "1")
    {
        facts = facts_;
        directory = directory_;
        delivery = delivery_;
        emit DeliverySet(address(0), delivery_);
    }

    // ------------------------------------------------------------------- the lead artist

    /// @inheritdoc IWorkRules
    /// @dev Setting the current record file again is a no-op. The new file must be a
    ///      registered, complete, one-chunk file stored as it is (`InvalidRecordFile`).
    function setRecord(
        address token,
        uint256 tokenId,
        bytes32 recordFileId,
        bytes32 expectedStateHash
    ) external {
        Facts memory f = _open(token, tokenId);
        if (f.finalized) revert IWorkFacts.WorkIsFinalized(token, tokenId);
        _onlyArtist(token, tokenId);
        if (recordFileId == f.recordFileId) return;
        _checkState(token, tokenId, expectedStateHash);
        _checkRecordFile(recordFileId);
        IWorkFacts(facts).setRecord(token, tokenId, recordFileId);
        _bump(token, tokenId);
        _refresh(token, tokenId);
    }

    /// @inheritdoc IWorkRules
    /// @dev A wallet of the lead artist's account finalizes at any time, at the state it saw.
    ///      Anyone else, once the first sale has an outcome (`NotWorkArtist` before): the first
    ///      call records a notice and returns; from `FINALIZE_NOTICE` after it, a call
    ///      finalizes the record as it then stands, without checking `expectedStateHash`, so no
    ///      change to the record can make it fail.
    function finalize(address token, uint256 tokenId, bytes32 expectedStateHash) external {
        Facts memory f = _open(token, tokenId);
        if (f.finalized) revert IWorkFacts.WorkIsFinalized(token, tokenId);
        Work memory w = _work(token, tokenId);
        if (_isWallet(w.artistId, msg.sender)) {
            _checkState(token, tokenId, expectedStateHash);
        } else {
            if (w.outcome == Outcome.NONE) revert NotWorkArtist(token, tokenId, msg.sender);
            uint256 notice = finalizeNoticeAt[token][tokenId];
            if (notice == 0) {
                finalizeNoticeAt[token][tokenId] = uint48(block.timestamp);
                emit FinalizeNoticeRecorded(token, tokenId, block.timestamp + FINALIZE_NOTICE);
                return;
            }
            if (block.timestamp < notice + FINALIZE_NOTICE) {
                revert FinalizeNotDue(token, tokenId, notice + FINALIZE_NOTICE);
            }
        }
        IWorkFacts(facts).finalize(token, tokenId);
        _bump(token, tokenId);
        _refresh(token, tokenId);
    }

    /// @inheritdoc IWorkRules
    /// @dev Signed by a wallet of the lead artist's account; anyone relays it. When a newly
    ///      renounced bit is the royalty or license power, the call must also pass the network's
    ///      role for this selector. Renouncing only bits already renounced is a no-op. The
    ///      renounced powers are read back from the permanent locks (`renouncedPowers`).
    function renounce(
        address token,
        uint256 tokenId,
        uint16 powers,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external {
        if (powers & ~WorkPowers.ALL != 0) revert UnknownPower(powers);
        Facts memory f = _open(token, tokenId);
        Work memory w = _work(token, tokenId);
        uint16 fresh = powers & ~_renounced(w, f);
        if (fresh == 0) return;
        if (fresh & NETWORK_POWERS != 0) _checkCanCall(msg.sender, _msgData());
        bytes32 structHash = keccak256(
            abi.encode(
                RENOUNCE_POWERS_TYPEHASH,
                token,
                tokenId,
                powers,
                _checkState(token, tokenId, expectedStateHash),
                deadline
            )
        );
        SignatureVerifier.checkDeadline(deadline);
        _accounts().requireSigned(w.artistId, _hashTypedDataV4(structHash), artistSignature);
        _bump(token, tokenId);
        if (fresh & WorkPowers.ROYALTY_RATE != 0) _terms(token).lockRoyaltyRate(token, tokenId);
        bool license = fresh & WorkPowers.RELICENSE != 0;
        bool pin = fresh & WorkPowers.RENDERER_REPIN != 0;
        if (license || pin) IWorkFacts(facts).lock(token, tokenId, license, pin);
        emit PowersRenounced(token, tokenId, fresh);
    }

    // --------------------------------------------------------------------- the network

    /// @inheritdoc IWorkRules
    /// @dev A license with the current key and text is a no-op. `IWorkFacts` refuses to leave
    ///      CC0, a CC0 license naming another text, an invalid identifier and an unusable text.
    function relicense(
        address token,
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        bytes32 structHash = _relicenseHash(token, tokenId, next, expectedStateHash, deadline);
        if (structHash == 0) return;
        _checkConsents(token, tokenId, item, structHash, deadline, partySignatures);
        IWorkFacts(facts).setLicense(token, tokenId, next);
        _bump(token, tokenId);
        _refresh(token, tokenId);
    }

    /// @inheritdoc IWorkRules
    /// @dev Up or down, at most 100,000 (the token refuses more). The current rate is a
    ///      no-op. The TERMS module writes the rate to the work and to its edition.
    function setRoyaltyRate(
        address token,
        uint256 tokenId,
        uint24 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        _open(token, tokenId);
        Work memory w = _work(token, tokenId);
        if (w.royaltyRateLocked) revert PowerRenounced(token, tokenId, WorkPowers.ROYALTY_RATE);
        if (rate == w.royaltyRate) return;
        bytes32 state = _checkState(token, tokenId, expectedStateHash);
        _checkConsents(
            token,
            tokenId,
            item,
            keccak256(abi.encode(ROYALTY_RATE_TYPEHASH, token, tokenId, rate, state, deadline)),
            deadline,
            partySignatures
        );
        _bump(token, tokenId);
        _terms(token).setRoyaltyRate(token, tokenId, rate);
    }

    /// @inheritdoc IWorkRules
    /// @dev The network's call alone: no artist signature. Pinning the current renderer again
    ///      is a no-op. `IWorkFacts` refuses a renderer without code.
    function repinRenderer(
        address token,
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash
    ) external restricted {
        Facts memory f = _open(token, tokenId);
        if (!f.finalized) revert IWorkFacts.WorkNotFinalized(token, tokenId);
        if (f.repinLocked) revert PowerRenounced(token, tokenId, WorkPowers.RENDERER_REPIN);
        if (renderer == f.renderer) return;
        _checkState(token, tokenId, expectedStateHash);
        IWorkFacts(facts).repin(token, tokenId, renderer);
        _bump(token, tokenId);
        _refresh(token, tokenId);
    }

    /// @inheritdoc IWorkRules
    function setDelivery(address expected, address next) external restricted {
        address current = delivery;
        if (current != expected) revert DeliveryMismatch();
        if (
            next.code.length == 0 || IWorkDelivery(next).records() != address(this)
                || IWorkDelivery(next).facts() != facts
        ) revert InvalidDelivery(next);
        delivery = next;
        emit DeliverySet(current, next);
    }

    /// @notice Adds a store beside the content store, pinned by its code hash. The network
    ///         only.
    /// @param source The store (`IChunkStore`).
    /// @param codeHash Its code hash.
    function addStore(address source, bytes32 codeHash) external restricted {
        uint256 id = _stores.length + 1;
        if (id > MAX_STORES || source.code.length == 0 || source.codehash != codeHash) {
            revert InvalidStore(source);
        }
        _stores.push(Store(source, false, codeHash));
        emit StoreAdded(id, source, codeHash);
    }

    /// @notice Retires a store: no file can choose it any more. Files that chose it keep their
    ///         record. The network only.
    /// @param storeId The store, from 1.
    function retireStore(uint256 storeId) external restricted {
        _store(storeId).retired = true;
        emit StoreRetired(storeId);
    }

    // ------------------------------------------------------------------------ stores

    /// @notice Records the store a media file is complete in: an added store that is not
    ///         retired and whose code is unchanged, checked chunk by chunk against the content
    ///         store's manifest in this call, or zero for the content store. A wallet of the
    ///         lead artist's account, or the role mapped to this selector (the storage
    ///         operator).
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param fileId One of the work's media files.
    /// @param storeId The store, or zero.
    function setFileStore(address token, uint256 tokenId, bytes32 fileId, uint256 storeId)
        external
    {
        Facts memory f = _open(token, tokenId);
        if (!_isWallet(_work(token, tokenId).artistId, msg.sender)) {
            _checkCanCall(msg.sender, _msgData());
        }
        bool inWork;
        for (uint256 i; i < f.media.length; ++i) {
            if (f.media[i].fileId == fileId) inWork = true;
        }
        if (!inWork) revert FileNotServed(fileId, storeId);
        if (storeId != 0) {
            Store storage s = _store(storeId);
            if (s.retired || s.source.codehash != s.codeHash) revert UnknownStore(storeId);
            address content = IWorkFacts(facts).contentStore();
            uint256 chunks = IContentStore(content).fileInfo(fileId).chunkCount;
            if (IContentStore(content).firstMissing(fileId, 0, chunks, s.source) != chunks) {
                revert FileNotServed(fileId, storeId);
            }
        }
        fileStore[token][tokenId][fileId] = storeId;
        emit FileStoreSet(token, tokenId, fileId, storeId);
        _refresh(token, tokenId);
    }

    /// @notice An added store.
    /// @param storeId The store, from 1.
    /// @return The store.
    function store(uint256 storeId) external view returns (Store memory) {
        return _store(storeId);
    }

    /// @notice How many stores were added.
    /// @return The count.
    function storeCount() external view returns (uint256) {
        return _stores.length;
    }

    // ---------------------------------------------------------------------- delivery

    /// @inheritdoc IDeliveryHost
    function refreshMetadata(address token, uint256 tokenId) external {
        if (msg.sender != delivery) revert NotDelivery(msg.sender);
        _refresh(token, tokenId);
    }

    /// @inheritdoc IDeliveryHost
    function refreshAllMetadata(address token) external {
        if (msg.sender != delivery) revert NotDelivery(msg.sender);
        uint256 minted = IStream(token).totalMinted();
        if (minted == 0) return;
        IStream(token).emitMetadataUpdate(1, minted);
        address editions = _editionsOf(token);
        if (editions != address(0)) IEditions(editions).emitMetadataUpdate(1, minted);
    }

    // --------------------------------------------------------------------------- views

    /// @inheritdoc IWorkRules
    /// @dev `keccak256(abi.encode(domain, this module, token, tokenId, version, recordFileId,
    ///      licenseKey, textFileId, royaltyRate, renderer))`, with the token's RENDERER module
    ///      before finalize and the pinned renderer after.
    function workStateHash(address token, uint256 tokenId) public view returns (bytes32) {
        Facts memory f = _open(token, tokenId);
        address renderer = f.finalized ? f.renderer : IModuleSlots(token).moduleOf(Slots.RENDERER);
        return keccak256(
            abi.encode(
                STATE_DOMAIN,
                address(this),
                token,
                tokenId,
                versionOf[token][tokenId],
                f.recordFileId,
                StreamHashing.licenseKey(f.licenseId),
                f.licenseTextFileId,
                IStream(token).workOf(tokenId).royaltyRate,
                renderer
            )
        );
    }

    /// @inheritdoc IWorkPowers
    function renouncedPowers(address token, uint256 tokenId) external view returns (uint16) {
        return _renounced(IStream(token).workOf(tokenId), IWorkFacts(facts).factsOf(token, tokenId));
    }

    /// @notice The EIP-712 domain separator of this module.
    /// @return The separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------------------ internal

    /// @dev The consent hash of a relicense, or zero when `next` has the current key and text
    ///      (a no-op). Reverts once the license is locked or the state is not the one expected.
    function _relicenseHash(
        address token,
        uint256 tokenId,
        License calldata next,
        bytes32 expectedStateHash,
        uint64 deadline
    ) private view returns (bytes32) {
        Facts memory f = _open(token, tokenId);
        if (f.licenseLocked) revert PowerRenounced(token, tokenId, WorkPowers.RELICENSE);
        bytes32 nextKey = StreamHashing.licenseKey(next.spdxId);
        if (
            nextKey == StreamHashing.licenseKey(f.licenseId)
                && next.textFileId == f.licenseTextFileId
        ) return 0;
        bytes32 state = _checkState(token, tokenId, expectedStateHash);
        return keccak256(
            abi.encode(
                RELICENSE_TYPEHASH, token, tokenId, nextKey, next.textFileId, state, deadline
            )
        );
    }

    /// @dev A work's facts, with an open record.
    function _open(address token, uint256 tokenId) private view returns (Facts memory f) {
        f = IWorkFacts(facts).factsOf(token, tokenId);
        if (!f.opened) revert IWorkFacts.RecordNotOpen(token, tokenId);
    }

    /// @dev A live token's work (`ownerOf` reverts for a burned or unminted token).
    function _work(address token, uint256 tokenId) private view returns (Work memory) {
        IStream(token).ownerOf(tokenId);
        return IStream(token).workOf(tokenId);
    }

    function _accounts() private view returns (IAccounts) {
        return IAccounts(IModuleSlots(directory).moduleOf(Slots.ACCOUNTS));
    }

    function _isWallet(uint256 accountId, address wallet) private view returns (bool) {
        return _accounts().isWallet(accountId, wallet);
    }

    function _onlyArtist(address token, uint256 tokenId) private view {
        if (!_isWallet(_work(token, tokenId).artistId, msg.sender)) {
            revert NotWorkArtist(token, tokenId, msg.sender);
        }
    }

    function _terms(address token) private view returns (ITerms) {
        return ITerms(IModuleSlots(token).moduleOf(Slots.TERMS));
    }

    /// @dev The editions contract paired with `token`, as its TERMS module answers, or zero
    ///      when the token has no TERMS module.
    function _editionsOf(address token) private view returns (address) {
        address terms = IModuleSlots(token).moduleOf(Slots.TERMS);
        if (terms == address(0)) return address(0);
        return ITerms(terms).editionsOf(token);
    }

    /// @dev The powers renounced, from the permanent locks.
    function _renounced(Work memory w, Facts memory f) private pure returns (uint16 powers) {
        if (w.royaltyRateLocked) powers |= WorkPowers.ROYALTY_RATE;
        if (f.licenseLocked) powers |= WorkPowers.RELICENSE;
        if (f.repinLocked) powers |= WorkPowers.RENDERER_REPIN;
    }

    function _checkState(address token, uint256 tokenId, bytes32 expected)
        private
        view
        returns (bytes32 state)
    {
        state = workStateHash(token, tokenId);
        if (state != expected) revert StateHashMismatch(expected, state);
    }

    /// @dev Every party of the token's item consents, in order: each proof is a wallet of the
    ///      party's account followed by its signature of the digest (`IAccounts.requireSigned`,
    ///      whose revert is passed on). Unanimity, counted by account.
    function _checkConsents(
        address token,
        uint256 tokenId,
        PackageItem calldata item,
        bytes32 structHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) private view {
        if (StreamHashing.itemHashCalldata(item) != IStream(token).itemHashOf(tokenId)) {
            revert InvalidConsent(token, tokenId);
        }
        SignatureVerifier.checkDeadline(deadline);
        uint256 parties = item.parties.length;
        if (signatures.length != parties) revert InvalidConsent(token, tokenId);
        bytes32 digest = _hashTypedDataV4(structHash);
        IAccounts accounts = _accounts();
        for (uint256 i; i < parties; ++i) {
            accounts.requireSigned(uint160(item.parties[i].account), digest, signatures[i]);
        }
    }

    /// @dev A record file is registered, one complete chunk, stored as it is, with a SHA-256
    ///      digest (the store reverts for an unknown file).
    function _checkRecordFile(bytes32 fileId) private view {
        address contentStore = IWorkFacts(facts).contentStore();
        IContentStore.FileInfo memory info = IContentStore(contentStore).fileInfo(fileId);
        if (
            info.chunkCount != 1 || info.digestKind != 0 || info.encoding != 0
                || !IContentStore(contentStore).isComplete(fileId)
        ) revert InvalidRecordFile(fileId);
    }

    function _store(uint256 storeId) private view returns (Store storage) {
        if (storeId == 0 || storeId > _stores.length) revert UnknownStore(storeId);
        return _stores[storeId - 1];
    }

    function _bump(address token, uint256 tokenId) private {
        uint32 version = ++versionOf[token][tokenId];
        emit VersionBumped(token, tokenId, version);
    }

    /// @dev ERC-4906 through the token, and through its editions contract if it has one.
    function _refresh(address token, uint256 tokenId) private {
        IStream(token).emitMetadataUpdate(tokenId, tokenId);
        address editions = _editionsOf(token);
        if (editions != address(0)) IEditions(editions).emitMetadataUpdate(tokenId, tokenId);
    }
}
