// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Editions } from "../../src/editions/Editions.sol";
import { ISplitWallet } from "../../src/economics/interfaces/ISplitWallet.sol";
import { IArtistRegistry } from "../../src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "../../src/interfaces/IArtistRoleResolver.sol";
import { IEditions } from "../../src/interfaces/IEditions.sol";
import { IStatementLog, HashRef, Role, Statement } from "../../src/interfaces/IStatementLog.sol";
import { IStream } from "../../src/interfaces/IStream.sol";
import { IWorkRecords } from "../../src/interfaces/IWorkRecords.sol";
import { WorkTerms } from "../../src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, PackageItem } from "../../src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "../../src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "../../src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "../../src/interfaces/types/WorksHashing.sol";
import { StatementLog } from "../../src/records/StatementLog.sol";
import { Actor, MedusaBase, SaleAdapter } from "./MedusaBase.sol";

/// @dev The log's authority: the curator may call `appendCurator`, the platform `appendPlatform`,
///      the governor `appendGovernanceManifest` and `setArtistResolver`, all at once; a second
///      platform key holds its role with a delay, so it can never write at once (DSP-3).
contract LogGate {
    address public curator;
    address public platform;
    address public delayedPlatform;
    address public governor;

    constructor(address curator_, address platform_, address delayed_, address governor_) {
        (curator, platform, delayedPlatform, governor) = (curator_, platform_, delayed_, governor_);
    }

    function canCall(address caller, address, bytes4 selector)
        external
        view
        returns (bool, uint32)
    {
        if (selector == StatementLog.appendCurator.selector) {
            return (caller == curator, 0);
        }
        if (selector == StatementLog.appendPlatform.selector) {
            if (caller == delayedPlatform) return (false, 1 days);
            return (caller == platform, 0);
        }
        return (caller == governor, 0);
    }

    /// Nothing is ever scheduled, so a delayed holder's direct call always fails.
    function consumeScheduledOp(address, bytes calldata) external pure returns (uint32) {
        revert("not scheduled");
    }
}

/// @dev The ERC-721 subjects' token: the harness sets each ID's owner.
contract Deed {
    address internal immutable _keeper;
    mapping(uint256 id => address) internal _owners;

    constructor() {
        _keeper = msg.sender;
    }

    function setOwner(uint256 id, address owner) external {
        require(msg.sender == _keeper, "not keeper");
        _owners[id] = owner;
    }

    function ownerOf(uint256 id) external view returns (address owner) {
        owner = _owners[id];
        require(owner != address(0), "no token");
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC721).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev The artist resolver: one artist account speaks as the artist of every subject.
contract ArtistBook {
    address public artist;

    constructor(address artist_) {
        artist = artist_;
    }

    function isArtist(address, uint256, address account) external view returns (bool) {
        return account == artist;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IArtistRoleResolver).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev What Editions reads of 6529 Stream, set by the harness: three settled EDITION_MASTER
///      works, each having consumed its content, and the link Editions writes back.
contract MasterBook {
    address internal immutable _keeper;
    address public artistRegistry;
    address public economics;
    address public workRecords;
    mapping(uint256 workId => bytes32) public itemHashOf;
    mapping(bytes32 contentHash => bytes32) public consumedItemOf;
    mapping(uint256 workId => address) internal _linked;

    constructor(address registry, address economics_, address records) {
        _keeper = msg.sender;
        (artistRegistry, economics, workRecords) = (registry, economics_, records);
    }

    function setMaster(uint256 workId, bytes32 itemHash, bytes32 contentHash) external {
        require(msg.sender == _keeper, "not keeper");
        itemHashOf[workId] = itemHash;
        consumedItemOf[contentHash] = itemHash;
    }

    function splitFactory() external view returns (address) {
        return address(this);
    }

    function coreOf(uint256 workId)
        external
        view
        returns (bytes32, uint256, uint256, uint8, uint8, uint32)
    {
        return (itemHashOf[workId], 1, 1, 1, 0, 5_000);
    }

    function primarySaleSettled(uint256 workId) external view returns (bool) {
        return itemHashOf[workId] != 0;
    }

    function linkEdition(uint256 workId, uint256) external {
        _linked[workId] = msg.sender;
    }

    function editionOf(uint256 workId) external view returns (address, uint256) {
        return (_linked[workId], workId);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IStream).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev The economics resolver and the records satellite as Editions reads them.
contract EditionsEconomics {
    address public seller;

    constructor(address seller_) {
        seller = seller_;
    }

    function newWorkTerms(bytes32, ISplitWallet.Payee[] calldata)
        external
        view
        returns (WorkTerms memory)
    {
        return WorkTerms(seller, address(0), 0, seller, 0);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkRecords).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev Stateful harness for Medusa (docs/testing/README.md, second fuzzer) over the real
///      `StatementLog` and the real `Editions`, with harness-local stand-ins for the authority,
///      an ERC-721 subject token, the artist resolver, and what Editions reads of 6529 Stream.
///
///      The model is written from docs/spec/disputes-and-statements.md (DSP-1, DSP-3, DSP-4,
///      DSP-9, DSP-10, INV-DSP-7) and docs/spec/editions-and-sales.md (ED-5, ED-25, INV-ED-2,
///      INV-ED-6), not from the code or from the Forge handlers: it predicts every call's
///      outcome, recomputes each subject's head with the spec's entry-hash formula, and tracks
///      every nonce, every edition's count, binding, maximum and seal, and every holder's copies.
contract LogMedusa is MedusaBase {
    uint256 internal constant SUBJECTS = 5;
    uint256 internal constant EDITIONS = 3;
    uint256 internal constant ADAPTERS = 3;
    uint256 internal constant UNCAPPED = type(uint40).max;
    bytes32 internal constant KIND = keccak256("NOTE");
    bytes32 internal constant OTHER_KIND = keccak256("ENGLISH_AUCTION");
    bytes32 internal constant ENTRY_DOMAIN = keccak256("6529.works.StatementLog.entry.v1");
    bytes32 internal constant HEAD_DOMAIN = keccak256("6529.works.StatementLog.head.v1");

    StatementLog public log;
    Editions public editions;
    LogGate public gate;
    Deed public deed;
    ArtistBook public artists;
    MasterBook public masters;
    SaleAdapter[ADAPTERS] public adapters;

    Actor public artist;
    Actor public owner;
    Actor public curator;
    Actor public platform;
    Actor public delayed;
    Actor public governor;
    Actor public stranger;
    Actor public buyer;
    uint256[4] internal _nonces = [uint256(0), 1, 255, 256];
    uint32[EDITIONS] internal _caps = [uint32(5), 12, 0];

    // The statement model.
    mapping(uint256 subject => uint64) public mCount;
    mapping(uint256 subject => bytes32) public mHead;
    mapping(uint256 subject => bytes32) public mDispute;
    mapping(uint256 subject => uint64) public mDisputeIndex;
    mapping(address signer => mapping(uint256 nonce => bool)) public mNonce;
    uint64 public mGovernanceCount;
    bytes32 public mGovernanceHead;
    bool public roleViolation;

    // The edition model.
    mapping(uint256 adapter => uint8) public mStatus; // 0 none, 1 admitted, 2 removed
    mapping(uint256 id => bool) public mExists;
    mapping(uint256 id => uint256) public mBound; // adapter index + 1, zero while unbound
    mapping(uint256 id => uint256) public mMinted;
    mapping(uint256 id => uint256) public mLimit;
    mapping(uint256 id => bool) public mSealed;
    mapping(uint256 id => mapping(address holder => uint256)) public mCopies;
    bool public sealReopened;

    constructor() payable {
        artist = new Actor();
        owner = new Actor();
        curator = new Actor();
        platform = new Actor();
        delayed = new Actor();
        governor = new Actor();
        stranger = new Actor();
        buyer = new Actor();
        gate = new LogGate(address(curator), address(platform), address(delayed), address(governor));
        deed = new Deed();
        for (uint256 id = 1; id <= 3; ++id) {
            deed.setOwner(id, address(owner));
        }
        artists = new ArtistBook(address(artist));
        log = new StatementLog(address(gate), address(artists), address(artists).codehash);
        _setUpEditions();
    }

    // ---------------------------------------------------------------------------------------
    // Actions: the statement log
    // ---------------------------------------------------------------------------------------

    /// `append`: only ARTIST (the resolver's artist) and OWNER (the subject's owner) (DSP-3);
    /// the reserved kinds are refused on this path (DSP-4).
    function append(uint8 roleSel, uint8 whoSel, uint8 subject, uint8 kindSel, uint8 shape) public {
        Role role = Role(roleSel % 5);
        Actor who = _speaker(whoSel);
        uint256 s = subject % SUBJECTS;
        Statement memory st = _statement(s, kindSel, shape);
        bool allowed = (role == Role.ARTIST || role == Role.OWNER)
            && _authorized(role, address(who), s) && _writable(role, st);
        bytes memory data = abi.encodeCall(log.append, (role, st));
        (bool ok,) = _expect(who, address(log), data, allowed, "append");
        if (ok) _applyEntry(s, role, address(who), st, allowed);
    }

    /// `appendCurator` and `appendPlatform`: the role's holder with no delay only.
    function appendRole(bool asPlatform, uint8 whoSel, uint8 subject, uint8 kindSel, uint8 shape)
        public
    {
        Role role = asPlatform ? Role.PLATFORM : Role.CURATOR;
        Actor who = _speaker(whoSel);
        uint256 s = subject % SUBJECTS;
        Statement memory st = _statement(s, kindSel, shape);
        bool allowed = _authorized(role, address(who), s) && _writable(role, st);
        bytes memory data = asPlatform
            ? abi.encodeCall(log.appendPlatform, (st))
            : abi.encodeCall(log.appendCurator, (st));
        (bool ok,) = _expect(who, address(log), data, allowed, "appendRole");
        if (ok) _applyEntry(s, role, address(who), st, allowed);
    }

    /// `appendSigned`, relayed by a stranger: an unexpired authorization, an unused nonce, the
    /// signer's signature, and a signer who could write the entry itself (DSP-3, DSP-9).
    function appendSigned(
        uint8 roleSel,
        uint8 signerSel,
        uint8 subject,
        uint8 kindSel,
        uint8 shape,
        uint8 nonceSel
    ) public {
        Role role = Role(roleSel % 5);
        Actor signer = _speaker(signerSel);
        uint256 s = subject % SUBJECTS;
        Statement memory st = _statement(s, kindSel, shape);
        uint256 nonce = _nonces[nonceSel % _nonces.length];
        bool late = shape & 64 != 0 && block.timestamp > 0;
        uint64 deadline = uint64(late ? block.timestamp - 1 : block.timestamp + 1 days);
        bool signs = shape & 128 == 0;
        if (signs) {
            signer.approve(_authorizationDigest(role, st, address(signer), nonce, deadline));
        }
        bool allowed = !late && signs && !mNonce[address(signer)][nonce]
            && _authorized(role, address(signer), s) && _writable(role, st);
        bytes memory data =
            abi.encodeCall(log.appendSigned, (role, st, address(signer), nonce, deadline, ""));
        (bool ok,) = _expect(stranger, address(log), data, allowed, "appendSigned");
        if (!ok) return;
        mNonce[address(signer)][nonce] = true;
        _applyEntry(s, role, address(signer), st, allowed);
    }

    /// `revokeNonce` spends one of the caller's nonces, once (INV-DSP-7).
    function revokeNonce(uint8 whoSel, uint8 nonceSel) public {
        Actor who = _speaker(whoSel);
        uint256 nonce = _nonces[nonceSel % _nonces.length];
        bytes memory data = abi.encodeCall(log.revokeNonce, (nonce));
        (bool ok,) = _expect(who, address(log), data, !mNonce[address(who)][nonce], "revokeNonce");
        if (ok) mNonce[address(who)][nonce] = true;
    }

    /// `appendGovernanceManifest`: governed, only the manifest kind about `(authority, 0)`, which
    /// it records as signed by the authority (DSP-4, DSP-5).
    function appendManifest(bool asGovernor, bool wrongSubject, uint8 shape) public {
        Statement memory st = _statement(0, 0, shape % 4);
        st.token = address(gate);
        st.id = wrongSubject ? 1 : 0;
        st.kind = StatementKinds.GOVERNANCE_MANIFEST;
        bool allowed = asGovernor && !wrongSubject;
        bytes memory data = abi.encodeCall(log.appendGovernanceManifest, (st));
        (bool ok,) =
            _expect(asGovernor ? governor : stranger, address(log), data, allowed, "manifest");
        if (!ok) return;
        if (!allowed) roleViolation = true;
        bytes32 entry = _entryHash(
            keccak256(abi.encode(address(gate), uint256(0))),
            mGovernanceCount,
            Role.PLATFORM,
            address(gate),
            address(0),
            st
        );
        mGovernanceHead = keccak256(abi.encode(HEAD_DOMAIN, mGovernanceHead, entry));
        ++mGovernanceCount;
    }

    /// The subject token's IDs change hands, so OWNER authority follows the current owner.
    function moveDeed(uint8 idSel, bool toStranger) public {
        deed.setOwner(1 + idSel % 3, toStranger ? address(stranger) : address(owner));
    }

    // ---------------------------------------------------------------------------------------
    // Actions: editions
    // ---------------------------------------------------------------------------------------

    /// `createEdition`: anyone, once, for a settled master with its stored EDITION_MASTER item.
    function createEdition(uint8 idSel) public {
        uint256 id = 1 + idSel % EDITIONS;
        bytes memory data = abi.encodeCall(editions.createEdition, (id, _masterItem(id)));
        (bool ok,) = _expect(stranger, address(editions), data, !mExists[id], "createEdition");
        if (!ok) return;
        mExists[id] = true;
        if (!mSealed[id]) mLimit[id] = _caps[id - 1] == 0 ? UNCAPPED : _caps[id - 1];
    }

    /// `mint` by an adapter: one ever admitted, of the edition's sale kind, the edition's bound
    /// adapter (an unbound edition binds its first admitted minter), a removed one only after
    /// it sealed, and never past the maximum (ED-5, ED-25, INV-ED-2).
    function mint(uint8 adapterSel, uint8 idSel, uint8 amount, bool toBuyer) public {
        uint256 a = adapterSel % ADAPTERS;
        uint256 id = 1 + idSel % EDITIONS;
        address to = toBuyer ? address(buyer) : address(adapters[a]);
        uint256 bound = mBound[id];
        bool allowed = mStatus[a] != 0 && amount != 0 && mExists[id] && a != 2
            && (bound == 0 ? mStatus[a] == 1 : bound == a + 1) && (mStatus[a] != 2 || mSealed[id])
            && amount <= mLimit[id] - mMinted[id];
        bytes memory data = abi.encodeCall(
            editions.mint, (to, id, uint256(amount), abi.encode(address(0), uint256(1)))
        );
        (bool ok,) = adapters[a].act(address(editions), data);
        _record(ok, allowed, "edition mint");
        if (!ok) return;
        if (bound == 0) mBound[id] = a + 1;
        mMinted[id] += amount;
        mCopies[id][to] += amount;
    }

    /// `sealSupply`: the bound adapter, admitted or removed, once, between the copies minted and
    /// the current maximum (ED-25).
    function seal(uint8 adapterSel, uint8 idSel, uint8 countSel) public {
        uint256 a = adapterSel % ADAPTERS;
        uint256 id = 1 + idSel % EDITIONS;
        uint256 minted = mMinted[id];
        uint256 limit = mLimit[id];
        uint256 k = countSel % 5;
        uint256 count = k == 0
            ? minted
            : k == 1
                ? limit
                : k == 2 ? minted + (limit - minted) / 2 : k == 3 ? minted + 1 : limit + 1;
        if (k == 3 && minted != 0) count = minted - 1;
        bool allowed = mStatus[a] != 0 && mBound[id] == a + 1 && !mSealed[id] && count >= minted
            && count <= limit;
        bytes memory data = abi.encodeCall(editions.sealSupply, (id, count));
        (bool ok,) = adapters[a].act(address(editions), data);
        _record(ok, allowed, "sealSupply");
        if (!ok) return;
        if (mSealed[id]) sealReopened = true;
        mSealed[id] = true;
        mLimit[id] = count;
    }

    /// `burn` by an adapter ever admitted, from its own copies.
    function burnCopies(uint8 adapterSel, uint8 idSel, uint8 amount) public {
        uint256 a = adapterSel % ADAPTERS;
        uint256 id = 1 + idSel % EDITIONS;
        address holder = address(adapters[a]);
        bool allowed =
            mStatus[a] != 0 && amount != 0 && mExists[id] && amount <= mCopies[id][holder];
        bytes memory data = abi.encodeCall(editions.burn, (id, uint256(amount)));
        (bool ok,) = adapters[a].act(address(editions), data);
        _record(ok, allowed, "edition burn");
        if (ok) mCopies[id][holder] -= amount;
    }

    /// `setAdmittedMinter`: governed; an unchanged admission is a silent no-op.
    function setAdmitted(uint8 adapterSel, bool admitted, bool asGovernor) public {
        uint256 a = adapterSel % ADAPTERS;
        bytes memory data =
            abi.encodeCall(editions.setAdmittedMinter, (address(adapters[a]), admitted));
        (bool ok,) = _expect(
            asGovernor ? governor : stranger, address(editions), data, asGovernor, "setAdmitted"
        );
        if (!ok) return;
        if (admitted) mStatus[a] = 1;
        else if (mStatus[a] == 1) mStatus[a] = 2;
    }

    // ---------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------

    function property_ModelPredictsEveryOutcome() public view returns (bool) {
        return !outcomeMismatch;
    }

    /// DSP-1, DSP-10: every subject's count and head are what the spec's formula gives for the
    /// entries the model accepted, and the latest dispute outcome matches.
    function property_CountAndHeadMatchTheModel() public view returns (bool) {
        for (uint256 s; s < SUBJECTS; ++s) {
            (address token, uint256 id) = _subject(s);
            (uint64 count, bytes32 head) = log.chainOf(token, id);
            if (count != mCount[s] || head != mHead[s]) return false;
            (bytes32 dispute, uint64 index) = log.disputeOutcomeOf(token, id);
            if (dispute != mDispute[s] || index != mDisputeIndex[s]) return false;
        }
        (uint64 n, bytes32 h) = log.chainOf(address(gate), 0);
        return n == mGovernanceCount && h == mGovernanceHead;
    }

    /// DSP-3, DSP-4: no entry was ever written by a writer the rules refuse, or with a reserved
    /// kind outside its role.
    function property_RolesWriteOnlyTheirKinds() public view returns (bool) {
        return !roleViolation;
    }

    /// INV-DSP-7: a used or revoked nonce stays spent, and nothing else is.
    function property_SpentNoncesStaySpent() public view returns (bool) {
        for (uint256 w; w < 7; ++w) {
            address who = address(_speaker(uint8(w)));
            for (uint256 k; k < _nonces.length; ++k) {
                if (log.nonceUsed(who, _nonces[k]) != mNonce[who][_nonces[k]]) return false;
            }
        }
        return true;
    }

    /// INV-ED-2: each edition's count is every copy minted, never past its maximum, and the
    /// holders' balances are what the model minted and burned.
    function property_EditionSupplyAccounting() public view returns (bool) {
        for (uint256 id = 1; id <= EDITIONS; ++id) {
            if (editions.exists(id) != mExists[id]) return false;
            if (!mExists[id]) continue;
            IEditions.Edition memory e = editions.edition(id);
            if (e.minted != mMinted[id] || e.maxSupply != mLimit[id] || e.minted > e.maxSupply) {
                return false;
            }
            uint32 cap = _caps[id - 1];
            if (cap != 0 && e.minted > cap) return false;
            if (editions.balanceOf(address(buyer), id) != mCopies[id][address(buyer)]) {
                return false;
            }
            for (uint256 a; a < ADAPTERS; ++a) {
                address holder = address(adapters[a]);
                if (editions.balanceOf(holder, id) != mCopies[id][holder]) return false;
            }
        }
        return true;
    }

    /// INV-ED-6, ED-25: a sealed edition stays sealed at its count and never mints past it.
    function property_SealedSupplyHolds() public view returns (bool) {
        if (sealReopened) return false;
        for (uint256 id = 1; id <= EDITIONS; ++id) {
            if (!mExists[id]) continue;
            IEditions.Edition memory e = editions.edition(id);
            if (e.supplySealed != mSealed[id]) return false;
            if (mSealed[id] && (e.maxSupply != mLimit[id] || e.minted > mLimit[id])) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------
    // Model helpers: statements
    // ---------------------------------------------------------------------------------------

    /// Applies an accepted entry to the subject's chain with the spec's formulas (DSP-10).
    function _applyEntry(uint256 s, Role role, address signer, Statement memory st, bool allowed)
        internal
    {
        if (!allowed) roleViolation = true;
        (address token, uint256 id) = _subject(s);
        address resolver = role == Role.ARTIST ? address(artists) : address(0);
        bytes32 entry =
            _entryHash(keccak256(abi.encode(token, id)), mCount[s], role, signer, resolver, st);
        mHead[s] = keccak256(abi.encode(HEAD_DOMAIN, mHead[s], entry));
        if (st.kind == StatementKinds.DISPUTE_OUTCOME) {
            mDispute[s] = entry;
            mDisputeIndex[s] = mCount[s];
        }
        ++mCount[s];
    }

    function _entryHash(
        bytes32 key,
        uint64 index,
        Role role,
        address signer,
        address resolver,
        Statement memory st
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                ENTRY_DOMAIN,
                block.chainid,
                address(log),
                key,
                index,
                role,
                signer,
                resolver,
                uint64(block.timestamp),
                _statementHash(st)
            )
        );
    }

    /// Who may speak as `role` about subject `s` (DSP-3): the resolver's artist, the token's
    /// current owner (none for a work-ID subject), or the role's zero-delay holder.
    function _authorized(Role role, address who, uint256 s) internal view returns (bool) {
        if (role == Role.ARTIST) return who == address(artist);
        if (role == Role.OWNER) {
            (address token, uint256 id) = _subject(s);
            return token == address(deed) && id != 0 && deed.ownerOf(id) == who;
        }
        if (role == Role.CURATOR) return who == address(curator);
        if (role == Role.PLATFORM) return who == address(platform);
        return false;
    }

    /// Whether the statement may be written as `role` (DSP-4 and the validity rules): a real
    /// subject, a kind, a schema, a tagged digest, exactly one locator, and the reserved kinds
    /// only for their role, the manifest kind never.
    function _writable(Role role, Statement memory st) internal pure returns (bool) {
        if (st.token == address(0) && st.id == 0) return false;
        if (st.kind == StatementKinds.GOVERNANCE_MANIFEST) return false;
        if (st.kind == StatementKinds.DISPUTE_OUTCOME && role != Role.PLATFORM) return false;
        if (st.kind == StatementKinds.CURATION_EVIDENCE && role != Role.CURATOR) return false;
        bool hasUri = bytes(st.uri).length != 0;
        return st.schema != 0 && st.content.digest != 0 && st.content.algorithm != 0
            && hasUri != (st.fileId != 0);
    }

    function _statement(uint256 s, uint8 kindSel, uint8 shape)
        internal
        view
        returns (Statement memory st)
    {
        (st.token, st.id) = _subject(s);
        uint256 k = kindSel % 4;
        st.kind = k == 0
            ? KIND
            : k == 1
                ? StatementKinds.DISPUTE_OUTCOME
                : k == 2 ? StatementKinds.CURATION_EVIDENCE : StatementKinds.GOVERNANCE_MANIFEST;
        st.schema = keccak256("schema");
        st.content = HashRef(uint16(1 + shape % 3), keccak256(abi.encode(shape, block.number)));
        uint256 form = shape % 8;
        if (form % 2 == 0) st.uri = "ar://statement";
        else st.fileId = keccak256(abi.encode("file", shape));
        if (form == 4) st.schema = 0;
        if (form == 5) st.content.digest = 0;
        if (form == 6) st.uri = "ipfs://both";
        if (form == 7) st.fileId = 0;
        st.supersedes = bytes32(uint256(shape >> 4));
    }

    function _subject(uint256 s) internal view returns (address token, uint256 id) {
        if (s < 3) return (address(deed), s + 1);
        if (s == 3) return (address(0), 7);
        return (address(0), 0);
    }

    function _speaker(uint8 sel) internal view returns (Actor) {
        uint256 k = sel % 7;
        if (k == 0) return artist;
        if (k == 1) return owner;
        if (k == 2) return curator;
        if (k == 3) return platform;
        if (k == 4) return delayed;
        if (k == 5) return governor;
        return stranger;
    }

    /// The spec's `hashStruct(Statement)` (DSP-10), computed here.
    function _statementHash(Statement memory s) internal pure returns (bytes32) {
        bytes32 content = keccak256(
            abi.encode(
                keccak256("HashRef(uint16 algorithm,bytes32 digest)"),
                s.content.algorithm,
                s.content.digest
            )
        );
        return keccak256(
            abi.encode(
                keccak256(
                    "Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)"
                ),
                s.token,
                s.id,
                s.kind,
                s.schema,
                content,
                keccak256(bytes(s.uri)),
                s.fileId,
                s.supersedes
            )
        );
    }

    /// The spec's relay digest (DSP-9, DSP-10), computed here.
    function _authorizationDigest(
        Role role,
        Statement memory st,
        address signer,
        uint256 nonce,
        uint64 deadline
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("6529 Works Statement Log"),
                keccak256("1"),
                block.chainid,
                address(log)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)HashRef(uint16 algorithm,bytes32 digest)Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)"
                ),
                role,
                signer,
                nonce,
                deadline,
                _statementHash(st)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ---------------------------------------------------------------------------------------
    // Model helpers: editions
    // ---------------------------------------------------------------------------------------

    function _setUpEditions() internal {
        EditionsEconomics econ = new EditionsEconomics(address(buyer));
        masters = new MasterBook(address(this), address(econ), address(econ));
        for (uint256 id = 1; id <= EDITIONS; ++id) {
            PackageItem memory item = _masterItem(id);
            masters.setMaster(id, WorksHashing.itemHash(item), item.contentHash);
        }
        editions = new Editions(
            address(gate), address(masters), address(masters).codehash, address(governor)
        );
        _must(
            governor, address(editions), abi.encodeCall(editions.bindWorkRecords, (address(econ)))
        );
        adapters[0] = new SaleAdapter(SaleKind.UNIFORM_AUCTION);
        adapters[1] = new SaleAdapter(SaleKind.UNIFORM_AUCTION);
        adapters[2] = new SaleAdapter(OTHER_KIND);
        for (uint256 a; a < 2; ++a) {
            bytes memory data =
                abi.encodeCall(editions.setAdmittedMinter, (address(adapters[a]), true));
            _must(governor, address(editions), data);
            mStatus[a] = 1;
        }
    }

    function _masterItem(uint256 id) internal view returns (PackageItem memory item) {
        item.kind = 1;
        item.collectionId = 1;
        item.contentHash = keccak256(abi.encode("master", id));
        item.mediaHash = keccak256(abi.encode("media", id));
        item.edition = EditionTerms(_caps[id - 1], address(0), SaleKind.UNIFORM_AUCTION, "");
    }

    /// The artist registry Editions reads once at deployment (`activeAuthorityOf`).
    function activeAuthorityOf(uint256) external view returns (address) {
        return address(artist);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IArtistRegistry).interfaceId || id == type(IERC165).interfaceId;
    }
}
