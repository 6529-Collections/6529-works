// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { Core, MintFacts, Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MockIndependentStreamGate, MockSale, MockTerms } from "../../mocks/core/CoreMocks.sol";

/// @notice Drives a real `IndependentStream6529` through sale contracts admitted by an Independent
///         Stream gate the handler controls, the shared TERMS module, collectors and the network,
///         keeping a model of what each call must do. A call the model says succeeds is made
///         directly, so a refusal fails the campaign (`fail_on_revert`); a call the model says
///         fails is made low-level, and a success is recorded as a violation.
contract IndependentStreamHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant CONTENTS = 6;

    IndependentStream6529 public immutable token;
    MockTerms public immutable terms;
    MockIndependentStreamGate public immutable gate;
    MockSale[3] public sales;
    address[3] public collectors;
    address public immutable museum = address(0x5EE);

    uint256 public mints;
    uint256 public burns;
    uint256 public records;
    uint256 public rescues;
    uint256 public locks;
    bool public violation;
    string public violationNote;
    mapping(uint256 id => uint256) public contentIdx;
    mapping(uint256 id => bytes32) public factsHash;
    mapping(uint256 id => Outcome) public outcome;
    mapping(uint256 id => address) public holder;
    mapping(uint256 id => bool) public rateLocked;
    mapping(uint256 id => uint24) public lockedRate;
    mapping(address account => bool) public minted;
    mapping(bytes4 action => uint256) public calls;

    constructor(
        IndependentStream6529 token_,
        MockTerms terms_,
        MockIndependentStreamGate gate_,
        MockSale[3] memory sales_
    ) {
        token = token_;
        terms = terms_;
        gate = gate_;
        sales = sales_;
        collectors = [address(0xC1), address(0xC2), address(0xC3)];
    }

    function contentHash(uint256 i) public pure returns (bytes32) {
        return keccak256(abi.encode("Independent Stream invariant content", i));
    }

    function hashOf(Work memory w) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                w.itemHash, w.artistId, w.collectionId, w.serial, w.kind, w.seedPolicy, w.seed
            )
        );
    }

    function _token(uint256 seed) internal view returns (uint256) {
        uint256 n = token.totalMinted();
        return n == 0 ? 0 : bound(seed, 1, n);
    }

    function _isSale(address account) internal view returns (bool) {
        return account == address(sales[0]) || account == address(sales[1])
            || account == address(sales[2]);
    }

    function _live(uint256 c) internal view returns (uint256 id) {
        uint256 t = token.tokenOfContent(contentHash(c));
        if (t != 0 && holder[t] != address(0)) return t;
    }

    function _fail(bool ok, string memory note) internal {
        if (ok && !violation) {
            violation = true;
            violationNote = note;
        }
    }

    function mint(uint256 saleSeed, uint256 contentSeed, uint256 seed, bool toCollector) external {
        ++calls[this.mint.selector];
        MockSale s = sales[saleSeed % 3];
        uint256 c = contentSeed % CONTENTS;
        MintFacts memory f;
        f.itemHash = keccak256(abi.encode("item", mints, seed));
        f.contentHash = contentHash(c);
        f.artistId = token.artistId(); // an Independent Stream token takes only its own artist
        f.collectionId = 1;
        f.kind = uint8(seed % 2);
        f.seedPolicy = uint8(seed % 3);
        f.seed = seed % 4 == 0 ? bytes32(0) : keccak256(abi.encode(seed));
        f.royaltyReceiver = address(uint160(seed));
        f.royaltyRate = uint24(seed % (Core.DENOMINATOR + 1));
        // A nonzero rate needs a receiver (`InvalidMint`): a zero receiver mints at rate 0.
        if (f.royaltyReceiver == address(0)) f.royaltyRate = 0;
        address to = toCollector ? collectors[seed % 3] : address(s);
        if (!gate.canMint(address(token), address(s)) || _live(c) != 0) {
            (bool ok,) = address(s).call(abi.encodeCall(MockSale.mintTo, (address(token), to, f)));
            _fail(ok, "mint by a contract the gate refuses, or of a live content");
            return;
        }
        uint256 id = s.mintTo(address(token), to, f);
        ++mints;
        if (id != mints) _fail(true, "token ID out of sequence");
        minted[address(s)] = true;
        contentIdx[id] = c;
        factsHash[id] = hashOf(token.workOf(id));
        holder[id] = to;
    }

    function record(uint256 tokenSeed, bool sold, address buyer, uint256 price) external {
        ++calls[this.record.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        bool allowed = h != address(0) && _isSale(h) && minted[h] && outcome[id] == Outcome.NONE;
        if (!allowed) {
            for (uint256 i; i < 3; ++i) {
                (bool ok,) = address(sales[i])
                    .call(abi.encodeCall(MockSale.record, (address(token), id, sold, buyer, price)));
                _fail(ok, "record outside the primary sale");
            }
            return;
        }
        MockSale(h).record(address(token), id, sold, buyer, price);
        outcome[id] = sold ? Outcome.SOLD : Outcome.UNSOLD;
        ++records;
    }

    function burn(uint256 tokenSeed) external {
        ++calls[this.burn.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        bool allowed = h != address(0) && _isSale(h) && minted[h] && outcome[id] == Outcome.NONE;
        if (!allowed) {
            for (uint256 i; i < 3; ++i) {
                (bool ok,) =
                    address(sales[i]).call(abi.encodeCall(MockSale.burn, (address(token), id)));
                _fail(ok, "burn outside the primary sale");
            }
            return;
        }
        MockSale(h).burn(address(token), id);
        holder[id] = address(0);
        ++burns;
    }

    function deliver(uint256 tokenSeed, uint256 collectorSeed) external {
        ++calls[this.deliver.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        if (!_isSale(h)) return;
        address to = collectors[collectorSeed % 3];
        MockSale(h).send(address(token), id, to);
        holder[id] = to;
    }

    function collectorTransfer(uint256 tokenSeed, uint256 toSeed) external {
        ++calls[this.collectorTransfer.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        if (h == address(0) || _isSale(h) || h == museum) return;
        address to = collectors[toSeed % 3];
        vm.prank(h);
        token.transferFrom(h, to, id);
        holder[id] = to;
    }

    /// @dev The Independent Stream module stops a sale contract minting and records its removal.
    function removeMinter(uint256 saleSeed) external {
        ++calls[this.removeMinter.selector];
        address s = address(sales[saleSeed % 3]);
        if (gate.minterRemovedAt(s) != 0) return;
        gate.setMinter(address(token), s, false);
        gate.remove(s, block.timestamp);
    }

    function addMinter(uint256 saleSeed) external {
        ++calls[this.addMinter.selector];
        address s = address(sales[saleSeed % 3]);
        gate.setMinter(address(token), s, true);
        gate.remove(s, 0);
    }

    /// @dev The module lies: it says a collector was a removed sale contract long ago.
    function gateLies(uint256 collectorSeed) external {
        ++calls[this.gateLies.selector];
        gate.remove(collectors[collectorSeed % 3], 1);
    }

    function setRescueDelay(uint48 next) external {
        ++calls[this.setRescueDelay.selector];
        token.setRescueDelay(uint48(bound(next, 0, 30 days)));
    }

    function rescue(uint256 tokenSeed) external {
        ++calls[this.rescue.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        uint256 removedAt = h == address(0) || !minted[h] ? 0 : gate.minterRemovedAt(h);
        bool allowed = removedAt != 0 && outcome[id] == Outcome.NONE
            && block.timestamp >= removedAt + token.rescueDelay();
        if (!allowed) {
            (bool ok,) = address(token).call(abi.encodeCall(IStream.rescue, (id, museum)));
            _fail(ok, "rescue outside its rule");
            return;
        }
        token.rescue(id, museum);
        outcome[id] = Outcome.RESCUED;
        holder[id] = museum;
        ++rescues;
    }

    function setRoyalty(uint256 tokenSeed, address receiver, uint24 rate) external {
        ++calls[this.setRoyalty.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        rate = uint24(bound(rate, 0, Core.DENOMINATOR + 10));
        // A nonzero rate needs a receiver (`InvalidRoyalty`).
        bool allowed = holder[id] != address(0) && rate <= Core.DENOMINATOR
            && (receiver != address(0) || rate == 0) && (!rateLocked[id] || rate == lockedRate[id]);
        if (!allowed) {
            (bool ok,) = address(terms)
                .call(abi.encodeCall(MockTerms.setRoyalty, (address(token), id, receiver, rate)));
            _fail(ok, "a royalty outside its rule");
            return;
        }
        terms.setRoyalty(address(token), id, receiver, rate);
    }

    function lockRate(uint256 tokenSeed) external {
        ++calls[this.lockRate.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0 || holder[id] == address(0)) return;
        terms.lockRoyaltyRate(address(token), id);
        if (!rateLocked[id]) {
            rateLocked[id] = true;
            ++locks;
            lockedRate[id] = token.workOf(id).royaltyRate;
        }
    }

    /// @dev Every sale contract and the TERMS module try to move, burn or re-record a token a
    ///      collector or the museum holds. All must fail.
    function attack(uint256 tokenSeed) external {
        ++calls[this.attack.selector];
        uint256 id = _token(tokenSeed);
        if (id == 0) return;
        address h = holder[id];
        if (h == address(0) || _isSale(h)) return;
        for (uint256 i; i < 3; ++i) {
            address s = address(sales[i]);
            (bool a,) = s.call(abi.encodeCall(MockSale.burn, (address(token), id)));
            (bool b,) = s.call(abi.encodeCall(MockSale.record, (address(token), id, true, s, 1)));
            vm.prank(s);
            (bool c,) = address(token).call(abi.encodeCall(IERC721.transferFrom, (h, s, id)));
            _fail(a || b || c, "a sale contract reached a held token");
        }
        vm.prank(address(terms));
        (bool d,) =
            address(token).call(abi.encodeCall(IERC721.transferFrom, (h, address(terms), id)));
        _fail(d, "TERMS moved a held token");
    }

    function warp(uint32 secondsAhead) external {
        ++calls[this.warp.selector];
        skip(bound(secondsAhead, 0, 10 days));
    }
}
