// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import {
    Collection,
    Core,
    Minter,
    MintFacts,
    Outcome,
    PendingModule,
    Slots,
    Work
} from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";
import { Actor, Gate, MedusaBase } from "./MedusaBase.sol";

/// @dev A record contract with no pinned renderer for any work.
contract CoreNoPins {
    function rendererOf(address, uint256) external pure returns (address) {
        return address(0);
    }
}

/// @notice The permanent ERC-721 under Medusa (and Forge, `StreamCoreMedusa.t.sol`): no
///         cheatcodes. The network is an `Actor` behind a stub authority; a stranger tries the
///         network's functions too. Three sale contracts mint, record and burn; three collector
///         actors hold and move tokens; two TERMS modules take turns in the slot through the
///         announce, wait and install path. The harness keeps its own model, written from
///         `docs/spec/stream-and-auctions.md` and the core's NatSpec (ADR 0010): every token's
///         holder, outcome, facts, royalty and lock; every minter's activation and removal;
///         the TERMS slot and its pending module; both delays; each collection's serials. It
///         predicts every call's success, and the `property_*` functions compare the model with
///         the contract after every call.
contract StreamCoreMedusa is MedusaBase {
    uint256 internal constant CONTENTS = 5;
    uint256 internal constant SALES = 3;
    address public constant MUSEUM = address(0x5EE);

    Stream6529 public immutable stream;
    MockTerms public immutable termsA;
    MockTerms public immutable termsB;
    Gate public immutable gate;
    MockSale[SALES] public sales;
    Actor[3] public collectors;
    Actor public immutable governor;
    Actor public immutable stranger;

    // The model.
    uint256 public mints;
    uint256 public burns;
    uint256 public mCollections;
    uint256 public mRescueDelay = 14 days;
    uint256 public mModuleDelay = 7 days;
    address public mTerms;
    address public mPendingTerms;
    uint256 public mPendingAt;
    mapping(uint256 sale => uint256) public mActiveFrom;
    mapping(uint256 sale => uint256) public mRemovedAt;
    mapping(uint256 collectionId => uint256) public mSerials;
    mapping(uint256 content => uint256) public mContentToken;
    mapping(uint256 id => uint256) public contentIdx;
    mapping(uint256 id => bytes32) public factsHash;
    mapping(uint256 id => Outcome) public outcome;
    mapping(uint256 id => address) public holder;
    mapping(uint256 id => address) public royaltyReceiver;
    mapping(uint256 id => uint24) public royaltyRate;
    mapping(uint256 id => bool) public rateLocked;
    bool public unauthorizedSucceeded;

    constructor() payable {
        governor = new Actor();
        stranger = new Actor();
        gate = new Gate(address(governor));
        termsA = new MockTerms();
        termsB = new MockTerms();
        address[] memory minters = new address[](SALES);
        for (uint256 i; i < SALES; ++i) {
            sales[i] = new MockSale();
            minters[i] = address(sales[i]);
            collectors[i] = new Actor();
            mActiveFrom[i] = block.timestamp;
        }
        stream = new Stream6529(
            address(gate),
            address(new CoreNoPins()),
            address(governor),
            address(new MockRenderer()),
            address(termsA),
            address(0),
            minters
        );
        mTerms = address(termsA);
        _must(governor, address(stream), abi.encodeCall(stream.createCollection, ("Genesis", 0)));
        mCollections = 1;
    }

    // ----------------------------------------------------------------------------- helpers

    function contentHash(uint256 i) public pure returns (bytes32) {
        return keccak256(abi.encode("medusa content", i));
    }

    function _hash(
        bytes32 itemHash,
        uint256 artistId,
        uint256 collectionId,
        uint256 serial,
        uint8 kind,
        uint8 seedPolicy,
        bytes32 seed
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(itemHash, artistId, collectionId, serial, kind, seedPolicy, seed)
        );
    }

    function _workHash(Work memory w) internal pure returns (bytes32) {
        return _hash(w.itemHash, w.artistId, w.collectionId, w.serial, w.kind, w.seedPolicy, w.seed);
    }

    function _token(uint256 seed) internal view returns (uint256) {
        return mints == 0 ? 0 : 1 + seed % mints;
    }

    function _isSale(address a) internal view returns (bool) {
        return a == address(sales[0]) || a == address(sales[1]) || a == address(sales[2]);
    }

    function _saleIndex(address a) internal view returns (uint256) {
        for (uint256 i; i < SALES; ++i) {
            if (a == address(sales[i])) return i;
        }
        return type(uint256).max;
    }

    /// May mint now: added, active, not removed.
    function _canMint(uint256 s) internal view returns (bool) {
        return mActiveFrom[s] != 0 && block.timestamp >= mActiveFrom[s] && mRemovedAt[s] == 0;
    }

    /// Is or was an active minter: settles the sales it holds even after removal. Every sale
    /// contract here was active from genesis, so a removed one always was active, also when it
    /// was added again and removed before that addition took effect.
    function _wasActive(uint256 s) internal view returns (bool) {
        return mRemovedAt[s] != 0 || (mActiveFrom[s] != 0 && block.timestamp >= mActiveFrom[s]);
    }

    function _liveWith(uint256 c) internal view returns (bool) {
        uint256 t = mContentToken[c];
        return t != 0 && holder[t] != address(0);
    }

    function _who(bool asGovernor) internal view returns (Actor) {
        return asGovernor ? governor : stranger;
    }

    function _flag(bool ok, bool asGovernor) internal {
        if (ok && !asGovernor) unauthorizedSucceeded = true;
    }

    function _receiver(uint8 sel) internal pure returns (address) {
        uint256 k = sel % 3;
        return k == 0 ? address(0) : k == 1 ? address(0xFEE) : address(0xBEEF);
    }

    // ----------------------------------------------------------------------------- actions

    /// A mint by a sale contract. `shape` breaks one fact in one of six ways, or names the
    /// second collection; only an active minter mints valid facts into an existing collection,
    /// and a content mints again only once its token is burned.
    function mint(uint8 saleSeed, uint8 contentSeed, uint256 seed, bool toCollector, uint8 shape)
        external
    {
        uint256 s = saleSeed % SALES;
        uint256 c = contentSeed % CONTENTS;
        uint256 form = shape % 10;
        MintFacts memory f;
        f.itemHash = keccak256(abi.encode("item", mints, seed));
        f.contentHash = contentHash(c);
        f.artistId = 1 + seed % type(uint160).max;
        f.collectionId = form == 7 ? 2 : form == 6 ? mCollections + 1 : 1;
        f.kind = uint8(seed >> 8);
        f.seedPolicy = uint8(seed >> 16);
        f.seed = seed % 2 == 0 ? bytes32(0) : keccak256(abi.encode(seed));
        f.royaltyReceiver = _receiver(uint8(seed >> 24));
        f.royaltyRate =
            f.royaltyReceiver == address(0) ? 0 : uint24((seed >> 32) % (Core.DENOMINATOR + 1));
        if (form == 1) f.itemHash = 0;
        if (form == 2) f.artistId = 0;
        if (form == 3) f.artistId = uint256(type(uint160).max) + 1;
        if (form == 4) f.royaltyRate = uint24(Core.DENOMINATOR + 1);
        if (form == 5) (f.royaltyReceiver, f.royaltyRate) = (address(0), 1);
        bool valid = form == 0 || form > 6;
        if (form == 7) valid = mCollections >= 2;
        address to = toCollector ? address(collectors[seed % 3]) : address(sales[s]);
        bool expected = _canMint(s) && valid && !_liveWith(c);
        (bool ok, bytes memory ret) =
            address(sales[s]).call(abi.encodeCall(MockSale.mintTo, (address(stream), to, f)));
        _record(ok, expected, "mint");
        if (!ok) return;
        uint256 id = abi.decode(ret, (uint256));
        ++mints;
        _record(id == mints, true, "sequential id");
        uint256 serial = ++mSerials[f.collectionId];
        contentIdx[id] = c;
        mContentToken[c] = id;
        factsHash[id] =
            _hash(f.itemHash, f.artistId, f.collectionId, serial, f.kind, f.seedPolicy, f.seed);
        holder[id] = to;
        royaltyReceiver[id] = f.royaltyReceiver;
        royaltyRate[id] = f.royaltyRate;
    }

    /// The outcome, once, by the sale contract holding the token, active or removed.
    function record(uint256 tokenSeed, uint8 saleSeed, bool sold) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        uint256 s = saleSeed % SALES;
        MockSale sale = sales[s];
        bool expected = holder[id] == address(sale) && _wasActive(s) && outcome[id] == Outcome.NONE;
        (bool ok,) = address(sale)
            .call(abi.encodeCall(MockSale.record, (address(stream), id, sold, address(0xB), 1)));
        _record(ok, expected, "record");
        if (ok) outcome[id] = sold ? Outcome.SOLD : Outcome.UNSOLD;
    }

    /// A burn, under the same rule as a record.
    function burn(uint256 tokenSeed, uint8 saleSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        uint256 s = saleSeed % SALES;
        MockSale sale = sales[s];
        bool expected = holder[id] == address(sale) && _wasActive(s) && outcome[id] == Outcome.NONE;
        (bool ok,) = address(sale).call(abi.encodeCall(MockSale.burn, (address(stream), id)));
        _record(ok, expected, "burn");
        if (ok) {
            holder[id] = address(0);
            ++burns;
        }
    }

    /// The sale contract holding a token hands it to a collector (OpenZeppelin's transfer).
    function deliver(uint256 tokenSeed, uint8 collectorSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0 || !_isSale(holder[id])) return;
        address to = address(collectors[collectorSeed % 3]);
        (bool ok,) = holder[id].call(abi.encodeCall(MockSale.send, (address(stream), id, to)));
        _record(ok, true, "deliver");
        if (ok) holder[id] = to;
    }

    /// A collector moves a token: only its holder can.
    function transfer(uint256 tokenSeed, uint8 fromSeed, uint8 toSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        Actor from = collectors[fromSeed % 3];
        address to = address(collectors[toSeed % 3]);
        bytes memory data = abi.encodeCall(IERC721.transferFrom, (address(from), to, id));
        (bool ok,) = _expect(from, address(stream), data, holder[id] == address(from), "transfer");
        if (ok) holder[id] = to;
    }

    function removeMinter(uint8 saleSeed, bool asGovernor) external {
        uint256 s = saleSeed % SALES;
        bytes memory data = abi.encodeCall(stream.removeMinter, (address(sales[s])));
        bool expected = asGovernor && mActiveFrom[s] != 0 && mRemovedAt[s] == 0;
        (bool ok,) = _expect(_who(asGovernor), address(stream), data, expected, "removeMinter");
        _flag(ok, asGovernor);
        if (ok) mRemovedAt[s] = block.timestamp;
    }

    /// A minter added again waits the module delay in force now; it is no longer removed.
    function addMinter(uint8 saleSeed, bool asGovernor) external {
        uint256 s = saleSeed % SALES;
        bytes memory data = abi.encodeCall(stream.addMinter, (address(sales[s])));
        bool expected = asGovernor && (mActiveFrom[s] == 0 || mRemovedAt[s] != 0);
        (bool ok,) = _expect(_who(asGovernor), address(stream), data, expected, "addMinter");
        _flag(ok, asGovernor);
        if (ok) {
            mActiveFrom[s] = block.timestamp + mModuleDelay;
            mRemovedAt[s] = 0;
        }
    }

    function setDelays(uint32 rescueDelay, uint32 moduleDelay, bool asGovernor) external {
        uint48 r = uint48(rescueDelay % 30 days);
        uint48 m = uint48(moduleDelay % 30 days);
        Actor who = _who(asGovernor);
        (bool ok,) = _expect(
            who, address(stream), abi.encodeCall(stream.setRescueDelay, (r)), asGovernor, "rescue"
        );
        _flag(ok, asGovernor);
        if (ok) mRescueDelay = r;
        (ok,) = _expect(
            who, address(stream), abi.encodeCall(stream.setModuleDelay, (m)), asGovernor, "module"
        );
        _flag(ok, asGovernor);
        if (ok) mModuleDelay = m;
    }

    /// The network takes a token a removed minter still holds unsold, once the rescue delay in
    /// force now has passed since the removal.
    function rescue(uint256 tokenSeed, bool asGovernor) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        uint256 s = _saleIndex(holder[id]);
        bool expected = asGovernor && s != type(uint256).max && mRemovedAt[s] != 0
            && outcome[id] == Outcome.NONE && block.timestamp >= mRemovedAt[s] + mRescueDelay;
        bytes memory data = abi.encodeCall(IStream.rescue, (id, MUSEUM));
        (bool ok,) = _expect(_who(asGovernor), address(stream), data, expected, "rescue");
        _flag(ok, asGovernor);
        if (ok) {
            outcome[id] = Outcome.RESCUED;
            holder[id] = MUSEUM;
        }
    }

    /// Through TERMS module A or B: only the installed one; a live token; a valid rate; a locked
    /// rate never changes.
    function setRoyalty(uint256 tokenSeed, uint8 receiverSel, uint24 rate, bool viaB) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        MockTerms t = viaB ? termsB : termsA;
        address receiver = _receiver(receiverSel);
        rate = uint24(rate % (Core.DENOMINATOR + 2));
        bool expected = mTerms == address(t) && holder[id] != address(0) && rate <= Core.DENOMINATOR
            && (receiver != address(0) || rate == 0) && (!rateLocked[id] || rate == royaltyRate[id]);
        (bool ok,) = address(t)
            .call(abi.encodeCall(MockTerms.setRoyalty, (address(stream), id, receiver, rate)));
        _record(ok, expected, "setRoyalty");
        if (ok) {
            royaltyReceiver[id] = receiver;
            royaltyRate[id] = rate;
        }
    }

    function lockRate(uint256 tokenSeed, bool viaB) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        MockTerms t = viaB ? termsB : termsA;
        (bool ok,) =
            address(t).call(abi.encodeCall(MockTerms.lockRoyaltyRate, (address(stream), id)));
        _record(ok, mTerms == address(t) && holder[id] != address(0), "lockRate");
        if (ok) rateLocked[id] = true;
    }

    /// ERC-4906 updates: from the installed TERMS module (the record contract and the empty
    /// RECORDS slot never call here).
    function refresh(uint256 from, uint256 to, bool viaB) external {
        MockTerms t = viaB ? termsB : termsA;
        (bool ok,) = address(t).call(abi.encodeCall(MockTerms.refresh, (address(stream), from, to)));
        _record(ok, mTerms == address(t), "refresh");
    }

    /// The network announces a TERMS module (one with code), ready after the module delay in
    /// force now; a module without code is refused.
    function proposeTerms(bool viaB, bool noCode, bool asGovernor) external {
        address module = noCode ? address(0xC0DE) : viaB ? address(termsB) : address(termsA);
        bytes memory data = abi.encodeCall(stream.proposeModule, (Slots.TERMS, module));
        bool expected = asGovernor && !noCode;
        (bool ok,) = _expect(_who(asGovernor), address(stream), data, expected, "proposeModule");
        _flag(ok, asGovernor);
        if (ok) {
            mPendingTerms = module;
            mPendingAt = block.timestamp + mModuleDelay;
        }
    }

    /// Anyone installs the announced module once its time has come.
    function activateTerms() external {
        bytes memory data = abi.encodeCall(stream.activateModule, (Slots.TERMS));
        bool expected = mPendingAt != 0 && block.timestamp >= mPendingAt;
        (bool ok,) = _expect(stranger, address(stream), data, expected, "activateModule");
        if (ok) {
            mTerms = mPendingTerms;
            (mPendingTerms, mPendingAt) = (address(0), 0);
        }
    }

    /// The network empties the slot at once, dropping any announcement.
    function removeTerms(bool asGovernor) external {
        bytes memory data = abi.encodeCall(stream.removeModule, (Slots.TERMS));
        (bool ok,) = _expect(_who(asGovernor), address(stream), data, asGovernor, "removeModule");
        _flag(ok, asGovernor);
        if (ok) (mTerms, mPendingTerms, mPendingAt) = (address(0), address(0), 0);
    }

    function createCollection(bool asGovernor) external {
        if (mCollections >= 3) return;
        bytes memory data = abi.encodeCall(stream.createCollection, ("More", bytes32(mCollections)));
        (bool ok, bytes memory ret) =
            _expect(_who(asGovernor), address(stream), data, asGovernor, "createCollection");
        _flag(ok, asGovernor);
        if (ok) _record(abi.decode(ret, (uint256)) == ++mCollections, true, "collection id");
    }

    // -------------------------------------------------------------------------- properties

    function property_ModelPredictsEveryOutcome() external view returns (bool) {
        return !outcomeMismatch;
    }

    /// No call of the network's succeeded for anyone but the network.
    function property_OnlyTheNetworkGoverns() external view returns (bool) {
        return !unauthorizedSucceeded;
    }

    function property_SupplyIsMintedMinusBurned() external view returns (bool) {
        uint256 held = stream.balanceOf(MUSEUM);
        for (uint256 i; i < 3; ++i) {
            held += stream.balanceOf(address(sales[i])) + stream.balanceOf(address(collectors[i]));
        }
        return stream.totalMinted() == mints && stream.totalBurned() == burns
            && stream.totalSupply() == mints - burns && held == mints - burns;
    }

    function property_OneLiveTokenPerContent() external view returns (bool) {
        for (uint256 c; c < CONTENTS; ++c) {
            uint256 live;
            for (uint256 id = 1; id <= mints; ++id) {
                if (contentIdx[id] == c && holder[id] != address(0)) ++live;
            }
            if (live > 1 || stream.tokenOfContent(contentHash(c)) != mContentToken[c]) {
                return false;
            }
        }
        return true;
    }

    /// Every ID's outcome and holder, a burned or unminted ID owned by nobody.
    function property_OutcomesAndOwnersMatchTheModel() external view returns (bool) {
        for (uint256 id = 1; id <= mints + 1; ++id) {
            if (stream.workOf(id).outcome != outcome[id]) return false;
            (bool ok, bytes memory ret) =
                address(stream).staticcall(abi.encodeCall(IERC721.ownerOf, (id)));
            if (ok != (holder[id] != address(0))) return false;
            if (ok && abi.decode(ret, (address)) != holder[id]) return false;
        }
        return true;
    }

    /// The facts are the ones minted, with the serial the model counted, and never change.
    function property_FactsNeverChange() external view returns (bool) {
        for (uint256 id = 1; id <= mints; ++id) {
            if (_workHash(stream.workOf(id)) != factsHash[id]) return false;
        }
        for (uint256 c = 1; c <= mCollections + 1; ++c) {
            Collection memory col = stream.collectionOf(c);
            if (col.exists != (c <= mCollections) || col.minted != mSerials[c]) return false;
        }
        return stream.collectionCount() == mCollections;
    }

    /// Royalties are the model's, `royaltyInfo` exact, and a locked rate holds.
    function property_RoyaltiesMatchTheModel() external view returns (bool) {
        for (uint256 id = 1; id <= mints; ++id) {
            Work memory w = stream.workOf(id);
            if (
                w.royaltyReceiver != royaltyReceiver[id] || w.royaltyRate != royaltyRate[id]
                    || w.royaltyRateLocked != rateLocked[id]
            ) return false;
            (address r, uint256 amount) = stream.royaltyInfo(id, 1e18 + id);
            if (r != royaltyReceiver[id] || amount != (1e18 + id) * royaltyRate[id] / 100_000) {
                return false;
            }
        }
        return true;
    }

    /// The minters, the TERMS slot and its announcement, and both delays.
    function property_ModulesAndMintersMatchTheModel() external view returns (bool) {
        for (uint256 s; s < SALES; ++s) {
            Minter memory m = stream.minterOf(address(sales[s]));
            if (m.activeFrom != mActiveFrom[s] || m.removedAt != mRemovedAt[s]) return false;
            if (stream.isMinter(address(sales[s])) != _canMint(s)) return false;
        }
        PendingModule memory p = stream.pendingModule(Slots.TERMS);
        return stream.moduleOf(Slots.TERMS) == mTerms && p.module == mPendingTerms
            && p.readyAt == mPendingAt && stream.rescueDelay() == mRescueDelay
            && stream.moduleDelay() == mModuleDelay;
    }
}
