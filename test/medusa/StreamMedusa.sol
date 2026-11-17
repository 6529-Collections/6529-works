// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ContentStore } from "../../src/content/ContentStore.sol";
import { IArtistRegistry } from "../../src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "../../src/interfaces/IContentStore.sol";
import { IEconomicsResolver } from "../../src/interfaces/IEconomicsResolver.sol";
import { IMintPolicy } from "../../src/interfaces/IMintPolicy.sol";
import { IRenderer } from "../../src/interfaces/IRenderer.sol";
import { IStreamViews } from "../../src/interfaces/IStreamViews.sol";
import { MediaFile } from "../../src/interfaces/types/ContentTypes.sol";
import { License, PackageItem, Party } from "../../src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimaryTerms } from "../../src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "../../src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "../../src/interfaces/types/WorksHashing.sol";
import { Stream } from "../../src/stream/Stream.sol";
import { IWorkRecords } from "../../src/interfaces/IWorkRecords.sol";
import { WorkRecords } from "../../src/stream/WorkRecords.sol";
import { Actor, Gate, MedusaBase, SaleAdapter } from "./MedusaBase.sol";

/// @dev The artist registry as the harness sets it: two artists with one wallet each, and a
///      signature check that accepts exactly the digests the harness approved for an artist.
contract StubAccounts {
    address internal immutable _keeper;
    mapping(uint256 artistId => address) public authorityOf;
    mapping(bytes32 digest => bool) public approved;

    constructor() payable {
        _keeper = msg.sender;
    }

    function register(uint256 artistId, address wallet) external {
        require(msg.sender == _keeper, "not keeper");
        authorityOf[artistId] = wallet;
    }

    function approve(bytes32 digest) external {
        require(msg.sender == _keeper, "not keeper");
        approved[digest] = true;
    }

    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        return authorityOf[artistId];
    }

    function isWallet(uint256 artistId, address wallet) external view returns (bool) {
        return wallet != address(0) && authorityOf[artistId] == wallet;
    }

    function requireSigned(uint256 artistId, bytes32 digest, bytes calldata)
        external
        view
        returns (address)
    {
        require(approved[digest], "not signed");
        return authorityOf[artistId];
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IArtistRegistry).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev The mint policy as the harness sets it: it answers each mint with the record the harness
///      prepared, and enforces nothing, so content uniqueness rests on Stream alone (AUC-44).
contract StubPolicy {
    address internal immutable _keeper;
    address public artistRegistry;
    IMintPolicy.MintRecord internal _next;

    constructor(address accounts) {
        _keeper = msg.sender;
        artistRegistry = accounts;
    }

    function prepare(IMintPolicy.MintRecord memory next) external {
        require(msg.sender == _keeper, "not keeper");
        _next = next;
    }

    function authorize(IMintPolicy.MintContext calldata, bytes calldata)
        external
        view
        returns (IMintPolicy.MintRecord memory)
    {
        return _next;
    }

    function preview(IMintPolicy.MintContext calldata, bytes calldata)
        external
        pure
        returns (PrimaryTerms memory terms)
    {
        return terms;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IMintPolicy).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev The economics resolver as Stream reads it here: a split factory with code, and the museum.
contract StubEconomics {
    address public museum;

    constructor(address museum_) {
        museum = museum_;
    }

    function splitFactory() external view returns (address) {
        return address(this);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IEconomicsResolver).interfaceId || id == type(IERC165).interfaceId;
    }
}

contract StubRenderer {
    function tokenURI(address, uint256) external pure returns (string memory) {
        return "data:,";
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IRenderer).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev Stateful harness for Medusa (docs/testing/README.md, second fuzzer) over the real
///      `Stream` and `WorkRecords`, with the real `ContentStore` and harness-local stand-ins for
///      the mint policy, the artist registry, the economics resolver, the renderers and three
///      sale adapters (two of one sale kind, one of another), behind a stub authority.
///
///      The harness keeps its own model of the token and record rules, written from
///      docs/spec/stream-and-auctions.md and docs/spec/works-and-storage.md (AUC-44, WS-1, WS-37,
///      WS-38, C9) and docs/audit/invariants.md (INV-STR-1, 2, 6, 8, 12, 16), not from the code
///      or from the Forge handlers under test/stream/: which token IDs exist, who minted each,
///      whether it settled, which content each consumed and whether it was released, each
///      record's version, record file, renderer pin and renounced powers. It predicts every
///      call's outcome before making it, and the `property_` functions compare the model with
///      the contracts.
contract StreamMedusa is MedusaBase {
    uint256 internal constant CONTENTS = 4;
    uint256 internal constant RECORDS = 4;
    uint256 internal constant SELLERS = 3;
    uint256 internal constant NOTICE = 14 days;
    bytes32 internal constant KIND = keccak256("ENGLISH_AUCTION");
    bytes32 internal constant OTHER_KIND = keccak256("UNIFORM_EDITION");

    Stream public stream;
    WorkRecords public records;
    ContentStore public store;
    StubAccounts public accounts;
    StubPolicy public policy;
    StubEconomics public economics;
    StubRenderer public rendererA;
    StubRenderer public rendererB;
    SaleAdapter[SELLERS] public sellers;
    Gate public gate;

    Actor public governor;
    Actor public artistOne;
    Actor public artistTwo;
    Actor public stranger;
    Actor public museum;
    Actor public seller;
    Actor public fee;

    bytes32 public cc0Text;
    bytes32[RECORDS] public recordFiles;
    bytes32[CONTENTS] public mediaFiles;
    bytes32[CONTENTS] public contentHashes;

    // The model.
    uint256 public mMinted;
    uint256 public mBurned;
    bool[SELLERS] public mAdmitted;
    address public mDefaultRenderer;
    mapping(uint256 tokenId => bool) public mLive;
    mapping(uint256 tokenId => uint256) public mSeller;
    mapping(uint256 tokenId => uint256) public mArtist;
    mapping(uint256 tokenId => uint256) public mContent;
    mapping(uint256 tokenId => uint256) public mSalt;
    mapping(uint256 tokenId => bytes32) public mItem;
    mapping(uint256 tokenId => bool) public mSettled;
    mapping(uint256 tokenId => bool) public mSold;
    mapping(uint256 tokenId => bool) public mOpen;
    mapping(uint256 tokenId => bool) public mFinalized;
    mapping(uint256 tokenId => uint256) public mVersion;
    mapping(uint256 tokenId => uint256) public mRecord;
    mapping(uint256 tokenId => uint16) public mRenounced;
    mapping(uint256 tokenId => uint256) public mNotice;
    mapping(uint256 tokenId => address) public mPin;
    mapping(uint256 content => uint256) public mClaimToken;
    mapping(uint256 content => bool) public mContentReleased;
    mapping(uint256 content => uint256) public mBeneficiary;
    mapping(bytes32 itemHash => bool) public mTombstoned;

    bool public unauthorizedSettle;
    bool public maskLostABit;

    constructor() payable {
        governor = new Actor();
        artistOne = new Actor();
        artistTwo = new Actor();
        stranger = new Actor();
        museum = new Actor();
        seller = new Actor();
        fee = new Actor();
        gate = new Gate(address(governor));
        accounts = new StubAccounts();
        accounts.register(1, address(artistOne));
        accounts.register(2, address(artistTwo));
        policy = new StubPolicy(address(accounts));
        economics = new StubEconomics(address(museum));
        rendererA = new StubRenderer();
        rendererB = new StubRenderer();
        sellers[0] = new SaleAdapter(KIND);
        sellers[1] = new SaleAdapter(KIND);
        sellers[2] = new SaleAdapter(OTHER_KIND);
        store = new ContentStore();
        _registerFiles();

        stream = new Stream(
            address(gate),
            address(policy),
            address(accounts),
            address(economics),
            address(0),
            address(rendererA),
            address(rendererA).codehash,
            address(governor)
        );
        records = new WorkRecords(
            address(gate), address(stream), address(store), License("CC0-1.0", cc0Text)
        );
        _must(governor, address(stream), abi.encodeCall(stream.bindWorkRecords, (address(records))));
        _must(governor, address(stream), abi.encodeCall(stream.createCollection, ("Works", 0)));
        for (uint256 s; s < 2; ++s) {
            bytes memory data =
                abi.encodeCall(stream.setAdmittedMinter, (address(sellers[s]), true));
            _must(governor, address(stream), data);
            mAdmitted[s] = true;
        }
        mDefaultRenderer = address(rendererA);
    }

    // ---------------------------------------------------------------------------------------
    // Actions: tokens
    // ---------------------------------------------------------------------------------------

    /// A mint by a sale adapter of an item for one of four contents, by one of two artists. Only
    /// an admitted adapter of the item's sale kind mints; a content mints once, again only after
    /// its work was burned and the content released, then only for the beneficiary and never by
    /// the tombstoned item (AUC-44, INV-STR-16).
    function mint(uint8 sellerSel, uint8 contentSel, uint8 salt, bool second) public {
        uint256 s = sellerSel % SELLERS;
        uint256 c = contentSel % CONTENTS;
        uint256 artist = second ? 2 : 1;
        salt = salt % 3;
        bytes32 itemHash = WorksHashing.itemHash(_item(c, salt, artist));
        policy.prepare(_mintRecord(c, salt, artist, itemHash));
        bool contentFree = mClaimToken[c] == 0
            || (mContentReleased[c] && !mTombstoned[itemHash] && mBeneficiary[c] == artist);
        bool expected = mAdmitted[s] && s != 2 && contentFree;
        bytes memory data = abi.encodeCall(stream.mint, (address(sellers[s]), 0, 1, ""));
        (bool ok, bytes memory ret) = sellers[s].act(address(stream), data);
        _record(ok, expected, "mint");
        if (!ok) return;
        uint256 tokenId = ++mMinted;
        uint256 got = abi.decode(ret, (uint256));
        if (got != tokenId) _record(false, true, "token id");
        mLive[tokenId] = true;
        mSeller[tokenId] = s;
        mArtist[tokenId] = artist;
        mContent[tokenId] = c;
        mSalt[tokenId] = salt;
        mItem[tokenId] = itemHash;
        mClaimToken[c] = tokenId;
        mContentReleased[c] = false;
    }

    /// `settlePrimary` by an adapter: only the minting adapter (by its index, even after removal),
    /// once, with a valid outcome; an unsold work goes to the museum (INV-STR-6, INV-STR-11).
    function settle(uint8 sellerSel, uint256 tokenSel, uint8 shape) public {
        uint256 s = sellerSel % SELLERS;
        uint256 t = _token(tokenSel);
        uint8 outcome = shape % 5;
        address buyer = shape & 8 != 0 ? address(0) : address(stranger);
        uint256 price = shape & 16 != 0 ? 1 ether : 0;
        if (outcome != uint8(PrimaryOutcome.SOLD) && shape & 32 == 0) {
            (buyer, price) = (address(0), 0);
        }
        bool valid = outcome == uint8(PrimaryOutcome.SOLD)
            ? buyer != address(0)
            : (outcome == uint8(PrimaryOutcome.UNBID)
                    || outcome == uint8(PrimaryOutcome.FROZEN_OUT)) && buyer == address(0)
                && price == 0;
        bool minting = mLive[t] && mSeller[t] == s;
        bool expected = minting && !mSettled[t] && valid;
        bytes memory data = abi.encodeCall(
            stream.settlePrimary, (t, PrimaryOutcome(outcome), buyer, address(0), price)
        );
        (bool ok,) = sellers[s].act(address(stream), data);
        _record(ok, expected, "settlePrimary");
        if (!ok) return;
        if (!minting) unauthorizedSettle = true;
        mSettled[t] = true;
        mSold[t] = outcome == uint8(PrimaryOutcome.SOLD);
    }

    /// `burn` by an adapter: only the minting adapter, holding it, before settlement.
    function burn(uint8 sellerSel, uint256 tokenSel) public {
        uint256 s = sellerSel % SELLERS;
        uint256 t = _token(tokenSel);
        bool expected = mLive[t] && mSeller[t] == s && !mSettled[t];
        (bool ok,) = sellers[s].act(address(stream), abi.encodeCall(stream.burn, (t, 1)));
        _record(ok, expected, "burn");
        if (!ok) return;
        mLive[t] = false;
        ++mBurned;
    }

    /// `releaseContent`: governed; only a burned token's own, unreleased content, for a
    /// registered artist. The content is reserved for the beneficiary and the item tombstoned.
    function releaseContent(uint256 tokenSel, bool otherContent, uint8 benSel, bool asGovernor)
        public
    {
        uint256 t = _token(tokenSel);
        uint256 c = (mContent[t] + (otherContent ? 1 : 0)) % CONTENTS;
        uint256 ben = 1 + benSel % 3;
        bool expected = asGovernor && t >= 1 && t <= mMinted && !mLive[t] && mClaimToken[c] == t
            && !mContentReleased[c] && ben != 3;
        bytes memory data = abi.encodeCall(stream.releaseContent, (t, contentHashes[c], ben));
        _try(asGovernor ? governor : stranger, address(stream), data, expected, "releaseContent");
        if (!_lastOk) return;
        mContentReleased[c] = true;
        mBeneficiary[c] = ben;
        mTombstoned[mItem[t]] = true;
    }

    /// `setAdmittedMinter`: governed, real transitions only.
    function setAdmitted(uint8 sellerSel, bool admitted, bool asGovernor) public {
        uint256 s = sellerSel % SELLERS;
        bool expected = asGovernor && admitted != mAdmitted[s];
        bytes memory data =
            abi.encodeCall(stream.setAdmittedMinter, (address(sellers[s]), admitted));
        _try(asGovernor ? governor : stranger, address(stream), data, expected, "setAdmittedMinter");
        if (_lastOk) mAdmitted[s] = admitted;
    }

    /// `setDefaultRenderer`: governed; a finalized work keeps its pin (INV-STR-8).
    function swapRenderer(bool asGovernor) public {
        address next =
            mDefaultRenderer == address(rendererA) ? address(rendererB) : address(rendererA);
        bytes memory data =
            abi.encodeCall(stream.setDefaultRenderer, (mDefaultRenderer, next, next.codehash));
        _try(
            asGovernor ? governor : stranger,
            address(stream),
            data,
            asGovernor,
            "setDefaultRenderer"
        );
        if (_lastOk) mDefaultRenderer = next;
    }

    // ---------------------------------------------------------------------------------------
    // Actions: records
    // ---------------------------------------------------------------------------------------

    /// `openRecord`: anyone, once, for a live work, with the item and media its hash commits to.
    function openRecord(uint256 tokenSel, bool wrongMedia) public {
        uint256 t = _token(tokenSel);
        uint256 c = mContent[t];
        PackageItem memory item = _item(c, mSalt[t], mArtist[t] == 0 ? 1 : mArtist[t]);
        MediaFile[] memory media = _media(wrongMedia ? (c + 1) % CONTENTS : c);
        bool expected = mLive[t] && !mOpen[t] && !wrongMedia;
        bytes memory data = abi.encodeCall(records.openRecord, (t, item, media));
        _try(stranger, address(records), data, expected, "openRecord");
        if (_lastOk) mOpen[t] = true;
    }

    /// `setRecord`: a wallet of the lead artist, before finalize, against the current state hash;
    /// the same file is a no-op. The fourth record file is registered but incomplete.
    function setRecord(uint256 tokenSel, uint8 recordSel, uint8 callerSel, bool stale) public {
        uint256 t = _token(tokenSel);
        uint256 r = recordSel % RECORDS;
        Actor caller = _person(callerSel);
        bool artist = mLive[t] && _isArtistWallet(t, caller);
        bool expected = mOpen[t] && !mFinalized[t] && artist
            && (r == mRecord[t] || (!stale && r != RECORDS - 1));
        bytes memory data =
            abi.encodeCall(records.setRecord, (t, recordFiles[r], _stateHash(t, stale)));
        _try(caller, address(records), data, expected, "setRecord");
        if (_lastOk && r != mRecord[t]) {
            mRecord[t] = r;
            ++mVersion[t];
        }
    }

    /// `finalize`: the lead artist at any time; anyone else once the primary sale settled, by a
    /// notice and a second call 14 days later (C9). It pins the default renderer (INV-STR-8).
    function finalize(uint256 tokenSel, uint8 callerSel) public {
        uint256 t = _token(tokenSel);
        Actor caller = _person(callerSel);
        bool base = mOpen[t] && !mFinalized[t] && mLive[t];
        bool artist = base && _isArtistWallet(t, caller);
        bool notice = base && !artist && mSettled[t] && mNotice[t] == 0;
        bool due = base && !artist && mSettled[t] && mNotice[t] != 0
            && block.timestamp >= mNotice[t] + NOTICE;
        bytes memory data = abi.encodeCall(records.finalize, (t, _stateHash(t, false)));
        _try(caller, address(records), data, artist || notice || due, "finalize");
        if (!_lastOk) return;
        if (notice) {
            mNotice[t] = block.timestamp;
            return;
        }
        mFinalized[t] = true;
        mPin[t] = mDefaultRenderer;
        ++mVersion[t];
    }

    /// `renounce`, relayed: the lead artist's signature over the current state, the network's
    /// action too for ROYALTY_RATE and RELICENSE, a finalized work for RENDERER_REPIN; powers
    /// already renounced are a no-op. The mask only gains bits (INV-STR-12, WS-37, WS-38).
    function renounce(uint256 tokenSel, uint8 powersSel, bool asGovernor, bool stale, bool sign)
        public
    {
        uint256 t = _token(tokenSel);
        uint16 powers = uint16(powersSel % 9);
        uint16 held = mRenounced[t];
        uint16 added = powers & ~held;
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 state = _stateHash(t, stale);
        if (sign && mOpen[t]) accounts.approve(_renounceDigest(t, powers, state, deadline));
        bool expected = mOpen[t] && (powers == 0 || powers & 8 == 0)
            && (added == 0
                || (mLive[t]
                    && !stale
                    && sign
                    && (added & 3 == 0 || asGovernor)
                    && (powers & 4 == 0 || mFinalized[t])));
        bytes memory data = abi.encodeCall(records.renounce, (t, powers, state, deadline, ""));
        _try(asGovernor ? governor : stranger, address(records), data, expected, "renounce");
        if (!_lastOk || added == 0) return;
        mRenounced[t] = held | powers;
        ++mVersion[t];
    }

    // ---------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------

    function property_ModelPredictsEveryOutcome() public view returns (bool) {
        return !outcomeMismatch;
    }

    /// INV-STR-1: `totalMinted` counts the mints, `totalSupply` is minted minus burned, and the
    /// holders' balances add up to it.
    function property_SupplyIsMintedMinusBurned() public view returns (bool) {
        uint256 live = mMinted - mBurned;
        uint256 held = stream.balanceOf(address(museum));
        for (uint256 s; s < SELLERS; ++s) {
            held += stream.balanceOf(address(sellers[s]));
        }
        return stream.totalMinted() == mMinted
            && IStreamViews(address(stream)).totalSupply() == live && held == live;
    }

    /// INV-STR-2: every ID up to `totalMinted` is live exactly when the model says, a burned ID
    /// stays gone, and the next ID does not exist.
    function property_IdsNeverReused() public view returns (bool) {
        for (uint256 t = 1; t <= mMinted + 1; ++t) {
            (bool ok, bytes memory ret) =
                address(stream).staticcall(abi.encodeCall(stream.ownerOf, (t)));
            if (ok != mLive[t]) return false;
            if (ok) {
                address holder = abi.decode(ret, (address));
                address expected =
                    mSettled[t] && !mSold[t] ? address(museum) : address(sellers[mSeller[t]]);
                if (holder != expected) return false;
            }
        }
        return true;
    }

    /// INV-STR-6, INV-STR-11: only the minting adapter ever settled a work, and
    /// `primarySaleSettled` is true exactly for the live works the model settled.
    function property_SettledOnlyByTheMintingAdapter() public view returns (bool) {
        if (unauthorizedSettle) return false;
        for (uint256 t = 1; t <= mMinted; ++t) {
            if (stream.primarySaleSettled(t) != (mLive[t] && mSettled[t])) return false;
        }
        return true;
    }

    /// INV-STR-8: a finalized work keeps its record file and its renderer pin, whatever the
    /// default renderer became; every open record's version and file match the model.
    function property_FinalizedRecordsNeverChange() public view returns (bool) {
        for (uint256 t = 1; t <= mMinted; ++t) {
            if (records.isOpen(t) != mOpen[t]) return false;
            if (!mOpen[t]) continue;
            IWorkRecords.RecordInfo memory info = records.record(t);
            if (info.recordFileId != recordFiles[mRecord[t]] || info.version != mVersion[t]) {
                return false;
            }
            if (info.finalized != mFinalized[t] || info.renderer != mPin[t]) return false;
            if (records.finalizeNoticeAt(t) != mNotice[t]) return false;
            if (mLive[t]) {
                address expected = mFinalized[t] ? mPin[t] : mDefaultRenderer;
                if (stream.rendererOf(t) != expected) return false;
            }
        }
        return true;
    }

    /// INV-STR-12: every renounced mask equals the OR of the renunciations applied, and none
    /// ever lost a bit.
    function property_RenouncedMaskOnlyGrows() public view returns (bool) {
        if (maskLostABit) return false;
        for (uint256 t = 1; t <= mMinted; ++t) {
            if (mOpen[t] && records.renouncedPowers(t) != mRenounced[t]) return false;
        }
        return true;
    }

    /// INV-STR-16, AUC-44: each content names the item of the one token that holds it, nothing
    /// while released, the beneficiary it was released to, and the tombstones match.
    function property_NoContentMintsTwice() public view returns (bool) {
        for (uint256 c; c < CONTENTS; ++c) {
            uint256 t = mClaimToken[c];
            bytes32 expected = t != 0 && !mContentReleased[c] ? mItem[t] : bytes32(0);
            if (stream.consumedItemOf(contentHashes[c]) != expected) return false;
            if (stream.releasedTo(contentHashes[c]) != mBeneficiary[c]) return false;
        }
        for (uint256 t = 1; t <= mMinted; ++t) {
            if (stream.isReleased(mItem[t]) != mTombstoned[mItem[t]]) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    bool internal _lastOk;

    /// `_expect`, keeping the outcome in `_lastOk` so callers need no extra stack slot.
    function _try(Actor who, address target, bytes memory data, bool expected, string memory what)
        internal
    {
        (bool ok,) = _expect(who, target, data, expected, what);
        _lastOk = ok;
    }

    function _token(uint256 sel) internal view returns (uint256) {
        return 1 + sel % (mMinted + 1);
    }

    function _person(uint8 sel) internal view returns (Actor) {
        uint256 k = sel % 3;
        return k == 0 ? artistOne : k == 1 ? artistTwo : stranger;
    }

    function _isArtistWallet(uint256 t, Actor who) internal view returns (bool) {
        return (mArtist[t] == 1 && address(who) == address(artistOne))
            || (mArtist[t] == 2 && address(who) == address(artistTwo));
    }

    /// The record's current state hash, or a stale one. Read from the contract: the model checks
    /// that a call against it succeeds and one against any other value fails.
    function _stateHash(uint256 t, bool stale) internal view returns (bytes32) {
        if (stale || !mOpen[t] || !mLive[t]) return keccak256(abi.encode("stale", t));
        return records.workStateHash(t);
    }

    /// The renunciation digest, computed from the spec's EIP-712 domain and type rather than
    /// asked of the contract.
    function _renounceDigest(uint256 t, uint16 powers, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(Typehashes.WORK_RECORDS_NAME)),
                keccak256(bytes(Typehashes.DOMAIN_VERSION)),
                block.chainid,
                address(records)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, t, powers, state, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _media(uint256 c) internal view returns (MediaFile[] memory media) {
        media = new MediaFile[](1);
        media[0] = MediaFile(mediaFiles[c], contentHashes[c], 0);
    }

    function _item(uint256 c, uint256 salt, uint256 artist)
        internal
        view
        returns (PackageItem memory item)
    {
        item.collectionId = 1;
        item.contentHash = contentHashes[c];
        item.mediaHash = WorksHashing.mediaHash(_media(c));
        item.recordFileId = recordFiles[0];
        item.parties = new Party[](1);
        item.parties[0] = Party(artist == 1 ? address(artistOne) : address(artistTwo), 0);
        item.license = License("CC0-1.0", cc0Text);
        item.seed = bytes32(salt);
    }

    function _mintRecord(uint256 c, uint256 salt, uint256 artist, bytes32 itemHash)
        internal
        view
        returns (IMintPolicy.MintRecord memory r)
    {
        r.itemHash = itemHash;
        r.artistId = artist;
        r.collectionId = 1;
        r.royaltyRate = 5_000;
        r.contentHash = contentHashes[c];
        r.mediaHash = WorksHashing.mediaHash(_media(c));
        r.recordFileId = recordFiles[0];
        r.saleKind = KIND;
        r.seller = address(seller);
        r.feeRecipient = address(fee);
        r.feeShare = 10_000;
        r.packageRoot = bytes32(salt);
    }

    function _registerFiles() internal {
        bytes memory cc0 = "CC0 1.0 Universal (harness copy)";
        cc0Text = _register(cc0, "text/plain", keccak256(cc0), true);
        for (uint256 r; r < RECORDS; ++r) {
            bytes memory json = abi.encodePacked('{"name":"work ', bytes1(uint8(48 + r)), '"}');
            recordFiles[r] = _register(json, "application/json", sha256(json), r != RECORDS - 1);
        }
        for (uint256 c; c < CONTENTS; ++c) {
            bytes memory data = abi.encode("media", c);
            contentHashes[c] = sha256(data);
            mediaFiles[c] = _register(data, "image/png", contentHashes[c], false);
        }
    }

    function _register(bytes memory data, string memory mime, bytes32 digest, bool upload)
        internal
        returns (bytes32 fileId)
    {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(data);
        fileId = store.registerManifest(
            hashes, data.length, uint8(IContentStore.Encoding.Identity), mime, digest
        );
        if (upload) store.writeChunk(data);
    }
}
