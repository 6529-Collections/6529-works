// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Stream } from "src/core/Stream.sol";
import { Core, Minter, MintFacts, Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockRenderer, MockSale, MockTerms } from "../mocks/core/CoreMocks.sol";

/// @dev A stub AccessManager: the harness may call every restricted function at once; nobody
///      else may call any.
contract CoreGate {
    address public immutable governor;

    constructor(address governor_) {
        governor = governor_;
    }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32) {
        return (caller == governor, 0);
    }
}

/// @dev A record contract with no pinned renderer for any work.
contract CoreNoPins {
    function rendererOf(address, uint256) external pure returns (address) {
        return address(0);
    }
}

/// @dev A collector the harness moves tokens for.
contract CoreCollector {
    address internal immutable _keeper;

    constructor() {
        _keeper = msg.sender;
    }

    function transfer(address token, address to, uint256 id) external returns (bool ok) {
        require(msg.sender == _keeper, "not keeper");
        (ok,) = token.call(abi.encodeCall(IERC721.transferFrom, (address(this), to, id)));
    }
}

/// @notice The permanent ERC-721 under Medusa (and Forge, `StreamCoreMedusa.t.sol`): no
///         cheatcodes. The harness is the network; three sale contracts mint and settle; three
///         collectors hold and move tokens; the TERMS module sets royalties. A model predicts
///         every call's success; Medusa's `property_*` functions check the model and the
///         contract's invariants after every call.
contract StreamCoreMedusa {
    uint256 internal constant CONTENTS = 5;

    Stream public immutable stream;
    MockTerms public immutable terms;
    MockSale[3] public sales;
    CoreCollector[3] public collectors;
    address public constant MUSEUM = address(0x5EE);

    bool public outcomeMismatch;
    string public lastMismatch;
    uint256 public mints;
    uint256 public burns;
    mapping(uint256 id => uint256) public contentIdx;
    mapping(uint256 id => bytes32) public factsHash;
    mapping(uint256 id => Outcome) public outcome;
    mapping(uint256 id => address) public holder;
    mapping(uint256 id => bool) public rateLocked;
    mapping(uint256 id => uint24) public lockedRate;

    /// Marks the harness as a test contract, so `forge build --sizes` leaves it out.
    function IS_TEST() external pure returns (bool) {
        return true;
    }

    constructor() {
        CoreGate gate = new CoreGate(address(this));
        terms = new MockTerms();
        for (uint256 i; i < 3; ++i) {
            sales[i] = new MockSale();
            collectors[i] = new CoreCollector();
        }
        address[] memory minters = new address[](3);
        for (uint256 i; i < 3; ++i) {
            minters[i] = address(sales[i]);
        }
        stream = new Stream(
            address(gate),
            address(new CoreNoPins()),
            address(this),
            address(new MockRenderer()),
            address(terms),
            address(0),
            minters
        );
        stream.createCollection("Genesis", 0);
    }

    // ----------------------------------------------------------------------------- helpers

    function contentHash(uint256 i) public pure returns (bytes32) {
        return keccak256(abi.encode("medusa content", i));
    }

    function _hash(Work memory w) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                w.itemHash, w.artistId, w.collectionId, w.serial, w.kind, w.seedPolicy, w.seed
            )
        );
    }

    function _record(bool ok, bool expected, string memory what) internal {
        if (ok != expected && !outcomeMismatch) {
            outcomeMismatch = true;
            lastMismatch = string(abi.encodePacked(what, ok ? " succeeded" : " reverted"));
        }
    }

    function _token(uint256 seed) internal view returns (uint256) {
        uint256 n = stream.totalMinted();
        return n == 0 ? 0 : 1 + seed % n;
    }

    function _isSale(address a) internal view returns (bool) {
        return a == address(sales[0]) || a == address(sales[1]) || a == address(sales[2]);
    }

    function _wasActive(address a) internal view returns (bool) {
        Minter memory m = stream.minterOf(a);
        return m.activeFrom != 0 && block.timestamp >= m.activeFrom;
    }

    function _liveWith(uint256 c) internal view returns (bool) {
        uint256 t = stream.tokenOfContent(contentHash(c));
        return t != 0 && holder[t] != address(0);
    }

    // ----------------------------------------------------------------------------- actions

    function mint(uint8 saleSeed, uint8 contentSeed, uint256 seed, bool toCollector) external {
        MockSale s = sales[saleSeed % 3];
        uint256 c = contentSeed % CONTENTS;
        MintFacts memory f;
        f.itemHash = keccak256(abi.encode("item", mints, seed));
        f.contentHash = contentHash(c);
        f.artistId = 1 + seed % type(uint160).max;
        f.collectionId = 1;
        f.seed = seed % 2 == 0 ? bytes32(0) : keccak256(abi.encode(seed));
        f.royaltyReceiver = address(uint160(seed));
        f.royaltyRate = uint24(seed % (Core.DENOMINATOR + 1));
        address to = toCollector ? address(collectors[seed % 3]) : address(s);
        bool expected = stream.isMinter(address(s)) && !_liveWith(c);
        (bool ok, bytes memory ret) =
            address(s).call(abi.encodeCall(MockSale.mintTo, (address(stream), to, f)));
        _record(ok, expected, "mint");
        if (!ok) return;
        uint256 id = abi.decode(ret, (uint256));
        ++mints;
        _record(id == mints, true, "sequential id");
        contentIdx[id] = c;
        factsHash[id] = _hash(stream.workOf(id));
        holder[id] = to;
    }

    function record(uint256 tokenSeed, uint8 saleSeed, bool sold) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        MockSale s = sales[saleSeed % 3];
        bool expected =
            holder[id] == address(s) && _wasActive(address(s)) && outcome[id] == Outcome.NONE;
        (bool ok,) = address(s)
            .call(abi.encodeCall(MockSale.record, (address(stream), id, sold, address(0xB), 1)));
        _record(ok, expected, "record");
        if (ok) outcome[id] = sold ? Outcome.SOLD : Outcome.UNSOLD;
    }

    function burn(uint256 tokenSeed, uint8 saleSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        MockSale s = sales[saleSeed % 3];
        bool expected =
            holder[id] == address(s) && _wasActive(address(s)) && outcome[id] == Outcome.NONE;
        (bool ok,) = address(s).call(abi.encodeCall(MockSale.burn, (address(stream), id)));
        _record(ok, expected, "burn");
        if (ok) {
            holder[id] = address(0);
            ++burns;
        }
    }

    function deliver(uint256 tokenSeed, uint8 collectorSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0 || !_isSale(holder[id])) return;
        address to = address(collectors[collectorSeed % 3]);
        (bool ok,) = holder[id].call(abi.encodeCall(MockSale.send, (address(stream), id, to)));
        _record(ok, true, "deliver");
        if (ok) holder[id] = to;
    }

    function transfer(uint256 tokenSeed, uint8 fromSeed, uint8 toSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        CoreCollector from = collectors[fromSeed % 3];
        address to = address(collectors[toSeed % 3]);
        bool ok = from.transfer(address(stream), to, id);
        _record(ok, holder[id] == address(from), "collector transfer");
        if (ok) holder[id] = to;
    }

    function removeMinter(uint8 saleSeed) external {
        address s = address(sales[saleSeed % 3]);
        Minter memory m = stream.minterOf(s);
        (bool ok,) = address(stream).call(abi.encodeCall(stream.removeMinter, (s)));
        _record(ok, m.activeFrom != 0 && m.removedAt == 0, "removeMinter");
    }

    function addMinter(uint8 saleSeed) external {
        address s = address(sales[saleSeed % 3]);
        Minter memory m = stream.minterOf(s);
        (bool ok,) = address(stream).call(abi.encodeCall(stream.addMinter, (s)));
        _record(ok, m.removedAt != 0, "addMinter");
    }

    function setDelays(uint32 rescueDelay, uint32 moduleDelay) external {
        stream.setRescueDelay(rescueDelay % 30 days);
        stream.setModuleDelay(moduleDelay % 30 days);
    }

    function rescue(uint256 tokenSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        uint256 removedAt = h == address(0) ? 0 : stream.minterOf(h).removedAt;
        bool expected = h != address(0) && removedAt != 0 && outcome[id] == Outcome.NONE
            && block.timestamp >= removedAt + stream.rescueDelay();
        (bool ok,) = address(stream).call(abi.encodeCall(IStream.rescue, (id, MUSEUM)));
        _record(ok, expected, "rescue");
        if (ok) {
            outcome[id] = Outcome.RESCUED;
            holder[id] = MUSEUM;
        }
    }

    function setRoyalty(uint256 tokenSeed, address receiver, uint24 rate) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        bool expected = holder[id] != address(0) && rate <= Core.DENOMINATOR
            && (!rateLocked[id] || rate == lockedRate[id]);
        (bool ok,) = address(terms)
            .call(abi.encodeCall(MockTerms.setRoyalty, (address(stream), id, receiver, rate)));
        _record(ok, expected, "setRoyalty");
    }

    function lockRate(uint256 tokenSeed) external {
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        (bool ok,) =
            address(terms).call(abi.encodeCall(MockTerms.lockRoyaltyRate, (address(stream), id)));
        _record(ok, holder[id] != address(0), "lockRate");
        if (ok && !rateLocked[id]) {
            rateLocked[id] = true;
            lockedRate[id] = stream.workOf(id).royaltyRate;
        }
    }

    // -------------------------------------------------------------------------- properties

    function property_ModelPredictsEveryOutcome() external view returns (bool) {
        return !outcomeMismatch;
    }

    function property_SupplyIsMintedMinusBurned() external view returns (bool) {
        return stream.totalMinted() == mints && stream.totalBurned() == burns
            && stream.totalSupply() == mints - burns;
    }

    function property_OneLiveTokenPerContent() external view returns (bool) {
        for (uint256 c; c < CONTENTS; ++c) {
            uint256 live;
            for (uint256 id = 1; id <= mints; ++id) {
                if (contentIdx[id] == c && holder[id] != address(0)) ++live;
            }
            if (live > 1) return false;
        }
        return true;
    }

    function property_OutcomesAndOwnersMatchTheModel() external view returns (bool) {
        for (uint256 id = 1; id <= mints; ++id) {
            if (stream.workOf(id).outcome != outcome[id]) return false;
            if (holder[id] != address(0) && stream.ownerOf(id) != holder[id]) return false;
        }
        return true;
    }

    function property_FactsNeverChange() external view returns (bool) {
        for (uint256 id = 1; id <= mints; ++id) {
            if (_hash(stream.workOf(id)) != factsHash[id]) return false;
        }
        return true;
    }

    function property_LockedRateHolds() external view returns (bool) {
        for (uint256 id = 1; id <= mints; ++id) {
            if (!rateLocked[id]) continue;
            Work memory w = stream.workOf(id);
            if (!w.royaltyRateLocked || w.royaltyRate != lockedRate[id]) return false;
        }
        return true;
    }
}
