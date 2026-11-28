// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { Edition, Minter, MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";
import { HashRef, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";
import { Actor, MedusaBase } from "./MedusaBase.sol";
import { CoreNoPins } from "./StreamCoreMedusa.sol";

/// @dev The one authority of the log, 6529 Stream and Editions: the curator may call
///      `appendCurator` and the platform `appendPlatform`, at once; a second platform key holds
///      its role with a delay, so it can never write at once (DSP-3); the governor may call
///      everything else, at once.
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

/// @dev Stateful harness for Medusa (docs/testing/README.md, second fuzzer) over the real
///      `StatementLog`, the real core `Stream6529` as the subject token (works minted, moved and
///      burned by a sale contract) and the real core `StreamEditions6529` of those works, with
///      stand-ins for the authority, the artist resolver, the record contract, the renderer and
///      TERMS.
///
///      The model is written from docs/spec/disputes-and-statements.md (DSP-1, DSP-3 to DSP-5,
///      DSP-9, DSP-10, INV-DSP-7), the log's NatSpec on dispute subjects and the item fallback,
///      and the core Editions guarantees (ADR 0010; ED-5, ED-25, INV-ED-2, INV-ED-6), not from
///      the code or from the Forge handlers: it predicts every call's outcome, recomputes each
///      subject's head with the spec's entry-hash formula, tracks every nonce, which works are
///      live and who holds them, and every edition's minter, count, maximum, seal and holders.
contract LogMedusa is MedusaBase {
    uint256 internal constant SUBJECTS = 6;
    uint256 internal constant WORKS = 3;
    uint256 internal constant ED_SALES = 3;
    uint256 internal constant HOLDERS = 2;
    uint256 internal constant UNCAPPED = type(uint40).max;
    bytes32 internal constant KIND = keccak256("NOTE");
    bytes32 internal constant ENTRY_DOMAIN = keccak256("6529.works.StatementLog.entry.v1");
    bytes32 internal constant HEAD_DOMAIN = keccak256("6529.works.StatementLog.head.v1");

    StatementLog public log;
    Stream6529 public stream;
    StreamEditions6529 public editions;
    LogGate public gate;
    ArtistBook public artists;
    MockSale public workSale;
    MockTerms public terms;
    MockSale[ED_SALES] public edSales;

    Actor public artist;
    Actor public owner;
    Actor public curator;
    Actor public platform;
    Actor public delayed;
    Actor public governor;
    Actor public stranger;
    Actor public buyer;
    uint256[4] internal _nonces = [uint256(0), 1, 255, 256];
    uint40[3] internal _caps = [uint40(5), 12, 0];

    // The statement model.
    mapping(uint256 subject => uint64) public mCount;
    mapping(uint256 subject => bytes32) public mHead;
    mapping(uint256 subject => bytes32) public mDispute;
    mapping(uint256 subject => uint64) public mDisputeIndex;
    mapping(address signer => mapping(uint256 nonce => bool)) public mNonce;
    uint64 public mGovernanceCount;
    bytes32 public mGovernanceHead;
    bool public roleViolation;

    // The works model: work `k` (1..3) is minted from item `itemOf(k)`; 0 none, 1 live, 2 burned.
    mapping(uint256 work => uint8) public mWork;
    mapping(uint256 work => address) public mHolder;

    // The editions model.
    uint256 public mRebindDelay = 14 days;
    uint256 public mModuleDelay = 7 days;
    mapping(uint256 sale => uint256) public mActiveFrom;
    mapping(uint256 sale => uint256) public mRemovedAt;
    mapping(uint256 id => uint256) public mMinter; // sale index + 1, zero while not created
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
        artists = new ArtistBook(address(artist));
        log = new StatementLog(address(gate), address(artists), address(artists).codehash);

        workSale = new MockSale();
        terms = new MockTerms();
        address[] memory minters = new address[](1);
        minters[0] = address(workSale);
        stream = new Stream6529(
            address(gate),
            address(new CoreNoPins()),
            address(governor),
            address(new MockRenderer()),
            address(terms),
            address(0),
            minters
        );
        _must(governor, address(stream), abi.encodeCall(stream.createCollection, ("Works", 0)));

        minters = new address[](ED_SALES);
        for (uint256 a; a < ED_SALES; ++a) {
            edSales[a] = new MockSale();
            minters[a] = address(edSales[a]);
            mActiveFrom[a] = block.timestamp;
        }
        editions = new StreamEditions6529(
            address(gate), address(stream), address(governor), address(terms), minters
        );
    }

    // ---------------------------------------------------------------------------------------
    // Actions: the works (subjects of the log, masters of the editions)
    // ---------------------------------------------------------------------------------------

    /// The next work, minted by the sale contract to the owner (works 1 to 3 only).
    function mintWork() public {
        uint256 k = stream.totalMinted() + 1;
        if (k > WORKS) return;
        MintFacts memory f;
        f.itemHash = itemOf(k);
        f.contentHash = keccak256(abi.encode("content", k));
        f.artistId = 1;
        f.collectionId = 1;
        (bool ok,) = address(workSale)
            .call(abi.encodeCall(MockSale.mintTo, (address(stream), address(owner), f)));
        _record(ok, true, "mintWork");
        if (!ok) return;
        mWork[k] = 1;
        mHolder[k] = address(owner);
    }

    /// The holder moves a work between the owner and the stranger, so OWNER authority follows
    /// the current holder.
    function moveWork(uint8 workSel) public {
        uint256 k = 1 + workSel % WORKS;
        if (mWork[k] != 1) return;
        Actor from = mHolder[k] == address(owner) ? owner : stranger;
        address to = address(from) == address(owner) ? address(stranger) : address(owner);
        bytes memory data = abi.encodeCall(IERC721.transferFrom, (address(from), to, k));
        (bool ok,) = _expect(from, address(stream), data, true, "moveWork");
        if (ok) mHolder[k] = to;
    }

    /// The owner gives a work back to the sale contract, which burns it: its ID is gone for
    /// good, and the log's item fallback for it answers nothing.
    function burnWork(uint8 workSel) public {
        uint256 k = 1 + workSel % WORKS;
        if (mWork[k] != 1) return;
        Actor from = mHolder[k] == address(owner) ? owner : stranger;
        bytes memory data =
            abi.encodeCall(IERC721.transferFrom, (address(from), address(workSale), k));
        _must(from, address(stream), data);
        (bool ok,) = address(workSale).call(abi.encodeCall(MockSale.burn, (address(stream), k)));
        _record(ok, true, "burnWork");
        if (ok) mWork[k] = 2;
        mHolder[k] = address(0);
    }

    // ---------------------------------------------------------------------------------------
    // Actions: the statement log
    // ---------------------------------------------------------------------------------------

    /// `append`: only ARTIST (the resolver's artist) and OWNER (the subject's holder) (DSP-3);
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

    // ---------------------------------------------------------------------------------------
    // Actions: editions
    // ---------------------------------------------------------------------------------------

    /// `create` by an edition sale contract: an active minter, once, for a live master, with a
    /// valid royalty; it becomes the edition's only minter. A cap of zero means none.
    function createEdition(uint8 saleSel, uint8 idSel, bool badRoyalty) public {
        uint256 a = saleSel % ED_SALES;
        uint256 id = 1 + idSel % WORKS;
        uint40 cap = _caps[id - 1];
        uint24 rate = badRoyalty ? 1 : 5_000;
        address receiver = badRoyalty ? address(0) : address(0xFEE);
        bool expected = _canMint(a) && mWork[id] == 1 && mMinter[id] == 0 && !badRoyalty;
        (bool ok,) = address(edSales[a])
            .call(
                abi.encodeCall(MockSale.createEdition, (address(editions), id, cap, receiver, rate))
            );
        _record(ok, expected, "createEdition");
        if (!ok) return;
        mMinter[id] = a + 1;
        mLimit[id] = cap == 0 ? UNCAPPED : cap;
    }

    /// `mint` by an edition sale contract: only the edition's minter, while it may mint or once
    /// it sealed, never past the maximum (ED-5, ED-25, INV-ED-2).
    function mint(uint8 saleSel, uint8 idSel, uint8 amount, bool toBuyer) public {
        uint256 a = saleSel % ED_SALES;
        uint256 id = 1 + idSel % WORKS;
        address to = toBuyer ? address(buyer) : address(owner);
        bool allowed = mMinter[id] == a + 1 && (mSealed[id] || _canMint(a))
            && amount <= mLimit[id] - mMinted[id];
        (bool ok,) = address(edSales[a])
            .call(abi.encodeCall(MockSale.mintEdition, (address(editions), to, id, amount, 1)));
        _record(ok, allowed, "edition mint");
        if (!ok) return;
        mMinted[id] += amount;
        mCopies[id][to] += amount;
    }

    /// `seal`: the edition's minter, while it is active, once, between the copies minted and
    /// the current maximum (ED-25). A removed minter no longer seals, nor one added again that
    /// is still waiting.
    function seal(uint8 saleSel, uint8 idSel, uint8 countSel) public {
        uint256 a = saleSel % ED_SALES;
        uint256 id = 1 + idSel % WORKS;
        uint256 minted = mMinted[id];
        uint256 limit = mLimit[id];
        uint256 k = countSel % 5;
        uint256 count = k == 0
            ? minted
            : k == 1
                ? limit
                : k == 2 ? minted + (limit - minted) / 2 : k == 3 ? minted + 1 : limit + 1;
        if (k == 3 && minted != 0) count = minted - 1;
        if (count > type(uint40).max) count = type(uint40).max;
        bool allowed = mMinter[id] == a + 1 && _canMint(a) && !mSealed[id] && count >= minted
            && count <= limit;
        (bool ok,) = address(edSales[a])
            .call(abi.encodeCall(MockSale.seal, (address(editions), id, uint40(count))));
        _record(ok, allowed, "seal");
        if (!ok) return;
        if (mSealed[id]) sealReopened = true;
        mSealed[id] = true;
        mLimit[id] = count;
    }

    /// `burn` by a holder, of its own copies.
    function burnCopies(bool buyerSel, uint8 idSel, uint8 amount) public {
        uint256 id = 1 + idSel % WORKS;
        Actor holder = buyerSel ? buyer : owner;
        bool allowed = amount <= mCopies[id][address(holder)];
        bytes memory data = abi.encodeCall(editions.burn, (id, uint256(amount)));
        (bool ok,) = _expect(holder, address(editions), data, allowed, "edition burn");
        if (ok) mCopies[id][address(holder)] -= amount;
    }

    /// `removeMinter` and `addMinter` on Editions: governed; a minter added again waits the
    /// module delay in force now.
    function setMinter(uint8 saleSel, bool add, bool asGovernor) public {
        uint256 a = saleSel % ED_SALES;
        address sale = address(edSales[a]);
        Actor who = asGovernor ? governor : stranger;
        if (add) {
            bool expected = asGovernor && mRemovedAt[a] != 0;
            (bool ok,) = _expect(
                who, address(editions), abi.encodeCall(editions.addMinter, (sale)), expected, "add"
            );
            if (ok) (mActiveFrom[a], mRemovedAt[a]) = (block.timestamp + mModuleDelay, 0);
        } else {
            bool expected = asGovernor && mRemovedAt[a] == 0;
            (bool ok,) = _expect(
                who,
                address(editions),
                abi.encodeCall(editions.removeMinter, (sale)),
                expected,
                "remove"
            );
            if (ok) mRemovedAt[a] = block.timestamp;
        }
    }

    /// The network's delays on Editions: the rebind delay and the module delay.
    function setDelays(uint32 rebindDelay, uint32 moduleDelay, bool asGovernor) public {
        uint48 r = uint48(rebindDelay % 30 days);
        uint48 m = uint48(moduleDelay % 30 days);
        Actor who = asGovernor ? governor : stranger;
        bytes memory data = abi.encodeCall(editions.setRebindDelay, (r));
        (bool ok,) = _expect(who, address(editions), data, asGovernor, "setRebindDelay");
        if (ok) mRebindDelay = r;
        data = abi.encodeCall(editions.setModuleDelay, (m));
        (ok,) = _expect(who, address(editions), data, asGovernor, "setModuleDelay");
        if (ok) mModuleDelay = m;
    }

    /// `rebind`: the network moves an edition with no seal, whose minter was
    /// removed at least the rebind delay ago, to an active minter.
    function rebind(uint8 idSel, uint8 toSel, bool asGovernor) public {
        uint256 id = 1 + idSel % WORKS;
        uint256 to = toSel % ED_SALES;
        uint256 prev = mMinter[id];
        bool expected = asGovernor && prev != 0 && !mSealed[id] && mRemovedAt[prev - 1] != 0
            && block.timestamp >= mRemovedAt[prev - 1] + mRebindDelay && _canMint(to);
        bytes memory data = abi.encodeCall(editions.rebind, (id, address(edSales[to])));
        (bool ok,) =
            _expect(asGovernor ? governor : stranger, address(editions), data, expected, "rebind");
        if (ok) mMinter[id] = to + 1;
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

    /// The latest outcome about a work is its own, or, while it has none and is live, the one
    /// about the item it was minted from (read through `IStream.itemHashOf`); a burned or
    /// unminted work has only its own. Editions and work-ID subjects answer their own.
    function property_DisputeOutcomesFollowTheWork() public view returns (bool) {
        for (uint256 s; s < SUBJECTS; ++s) {
            (address token, uint256 id) = _subject(s);
            bytes32 expected = mDispute[s];
            if (expected == 0 && token == address(stream) && mWork[id] == 1) {
                expected = _itemDispute(id);
            }
            if (log.latestDisputeOutcome(token, id) != expected) return false;
        }
        return true;
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

    /// INV-ED-2: each edition's minter, count and maximum are the model's, the count never past
    /// the cap or the maximum, and the holders' balances are what the model minted and burned.
    function property_EditionSupplyAccounting() public view returns (bool) {
        for (uint256 id = 1; id <= WORKS; ++id) {
            Edition memory e = editions.editionOf(id);
            address minter = mMinter[id] == 0 ? address(0) : address(edSales[mMinter[id] - 1]);
            if (e.minter != minter) return false;
            if (minter == address(0)) continue;
            if (e.minted != mMinted[id] || e.maxSupply != mLimit[id] || e.minted > e.maxSupply) {
                return false;
            }
            uint40 cap = _caps[id - 1];
            if (cap != 0 && e.minted > cap) return false;
            if (editions.balanceOf(address(buyer), id) != mCopies[id][address(buyer)]) {
                return false;
            }
            if (editions.balanceOf(address(owner), id) != mCopies[id][address(owner)]) {
                return false;
            }
        }
        for (uint256 a; a < ED_SALES; ++a) {
            Minter memory m = editions.minterOf(address(edSales[a]));
            if (m.activeFrom != mActiveFrom[a] || m.removedAt != mRemovedAt[a]) return false;
        }
        return editions.rebindDelay() == mRebindDelay && editions.moduleDelay() == mModuleDelay;
    }

    /// INV-ED-6, ED-25: a sealed edition stays sealed at its count and never mints past it.
    function property_SealedSupplyHolds() public view returns (bool) {
        if (sealReopened) return false;
        for (uint256 id = 1; id <= WORKS; ++id) {
            if (mMinter[id] == 0) continue;
            Edition memory e = editions.editionOf(id);
            if (e.supplySealed != mSealed[id]) return false;
            if (mSealed[id] && (e.maxSupply != mLimit[id] || e.minted > mLimit[id])) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------
    // Model helpers: statements
    // ---------------------------------------------------------------------------------------

    /// The item work `k` is minted from.
    function itemOf(uint256 k) public pure returns (bytes32) {
        return keccak256(abi.encode("item", k));
    }

    /// The model's latest outcome about work `k`'s item: subject 4 is work 1's item.
    function _itemDispute(uint256 k) internal view returns (bytes32) {
        return k == 1 ? mDispute[4] : bytes32(0);
    }

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

    /// Who may speak as `role` about subject `s` (DSP-3): the resolver's artist, the holder of
    /// a live work or of a copy of the edition (none for a work-ID subject), or the role's
    /// zero-delay holder.
    function _authorized(Role role, address who, uint256 s) internal view returns (bool) {
        if (role == Role.ARTIST) return who == address(artist);
        if (role == Role.OWNER) {
            (address token, uint256 id) = _subject(s);
            if (token == address(stream)) return mWork[id] == 1 && mHolder[id] == who;
            if (token == address(editions)) return mCopies[id][who] != 0;
            return false;
        }
        if (role == Role.CURATOR) return who == address(curator);
        if (role == Role.PLATFORM) return who == address(platform);
        return false;
    }

    /// Whether the statement may be written as `role` (DSP-4 and the validity rules): a real
    /// subject, a kind, a schema, a tagged digest, exactly one locator, and the reserved kinds
    /// only for their role, the manifest kind never. A dispute outcome about a work needs it
    /// live; one about an edition is refused (its master carries it).
    function _writable(Role role, Statement memory st) internal view returns (bool) {
        if (st.token == address(0) && st.id == 0) return false;
        if (st.kind == StatementKinds.GOVERNANCE_MANIFEST) return false;
        if (st.kind == StatementKinds.DISPUTE_OUTCOME) {
            if (role != Role.PLATFORM) return false;
            if (st.token == address(editions)) return false;
            if (st.token == address(stream) && mWork[st.id] != 1) return false;
        }
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

    /// Subjects: works 1 to 3 of 6529 Stream; edition 1; work 1's item (a work-ID subject);
    /// and the invalid empty subject.
    function _subject(uint256 s) internal view returns (address token, uint256 id) {
        if (s < 3) return (address(stream), s + 1);
        if (s == 3) return (address(editions), 1);
        if (s == 4) return (address(0), uint256(itemOf(1)));
        return (address(0), 0);
    }

    function _speaker(uint8 sel) internal view returns (Actor) {
        uint256 k = sel % 8;
        if (k == 0) return artist;
        if (k == 1) return owner;
        if (k == 2) return curator;
        if (k == 3) return platform;
        if (k == 4) return delayed;
        if (k == 5) return governor;
        if (k == 6) return buyer;
        return stranger;
    }

    /// Edition minter `a` may mint now: added, active, not removed.
    function _canMint(uint256 a) internal view returns (bool) {
        return mActiveFrom[a] != 0 && block.timestamp >= mActiveFrom[a] && mRemovedAt[a] == 0;
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
}
