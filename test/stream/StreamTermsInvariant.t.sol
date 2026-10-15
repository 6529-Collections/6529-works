// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import { StreamFixture } from "./StreamFixture.sol";
import { MockEconomics, MockSaleAdapter, MockWorkRecords } from "../mocks/stream/StreamMocks.sol";

/// @dev Real collisions of Stream's 23-bit terms position (QUALITY-6), found offline from the
///      key `keccak256(abi.encode(uint160 artistId, uint32 rate, uint32 feeShare, uint16
///      feeRecipientId, uint16 minterId)) & 0x7fffff` by brute force over four artist IDs, every
///      rate, two fee shares, two fee-recipient indices and two minter indices: six positions,
///      six terms each. (From the review of PR #63.)
library Pool {
    uint160 internal constant A1 = 0x001000000000000000000000000000000000000A01;
    uint160 internal constant A2 = 0x001000000000000000000000000000000000000A02;
    uint160 internal constant A3 = 0x001000000000000000000000000000000000000A03;
    uint160 internal constant A4 = 0x001000000000000000000000000000000000000A04;

    struct T {
        uint160 a;
        uint32 r;
        uint32 s;
        uint16 f;
        uint16 m;
    }

    function all() internal pure returns (T[] memory p) {
        p = new T[](36);
        // 0x7895bc
        p[0] = T(A1, 47153, 25000, 1, 1);
        p[1] = T(A1, 90055, 25000, 2, 1);
        p[2] = T(A2, 20824, 0, 1, 1);
        p[3] = T(A4, 79605, 25000, 1, 1);
        p[4] = T(A4, 16104, 0, 1, 1);
        p[5] = T(A4, 19125, 0, 1, 1);
        // 0x485f0
        p[6] = T(A1, 83282, 25000, 1, 1);
        p[7] = T(A2, 75804, 0, 2, 2);
        p[8] = T(A3, 9394, 25000, 2, 2);
        p[9] = T(A3, 4161, 0, 2, 1);
        p[10] = T(A4, 22089, 25000, 1, 2);
        p[11] = T(A4, 64700, 25000, 1, 2);
        // 0x14696f
        p[12] = T(A1, 19444, 25000, 1, 2);
        p[13] = T(A2, 12493, 25000, 1, 1);
        p[14] = T(A2, 81627, 25000, 1, 1);
        p[15] = T(A2, 48015, 0, 1, 2);
        p[16] = T(A4, 71937, 25000, 2, 1);
        p[17] = T(A4, 11389, 0, 2, 2);
        // 0x30b749
        p[18] = T(A1, 44731, 25000, 1, 2);
        p[19] = T(A1, 9655, 0, 2, 2);
        p[20] = T(A2, 54508, 0, 2, 2);
        p[21] = T(A3, 70295, 25000, 2, 1);
        p[22] = T(A3, 86481, 25000, 2, 1);
        p[23] = T(A4, 39918, 0, 2, 2);
        // 0x59fec6
        p[24] = T(A1, 69036, 25000, 1, 2);
        p[25] = T(A1, 26919, 25000, 2, 1);
        p[26] = T(A1, 69684, 25000, 2, 1);
        p[27] = T(A1, 30280, 0, 1, 1);
        p[28] = T(A3, 4594, 25000, 2, 2);
        p[29] = T(A4, 97960, 25000, 2, 1);
        // 0xbfed4
        p[30] = T(A1, 2350, 25000, 2, 2);
        p[31] = T(A2, 26075, 25000, 2, 2);
        p[32] = T(A2, 4170, 0, 2, 2);
        p[33] = T(A2, 55333, 0, 2, 2);
        p[34] = T(A4, 87100, 25000, 2, 2);
        p[35] = T(A4, 91636, 0, 1, 2);
    }

    function key(T memory t) internal pure returns (bytes32) {
        return keccak256(abi.encode(t.a, t.r, t.s, t.f, t.m));
    }

    function word(T memory t) internal pure returns (uint256) {
        return uint256(t.a) | uint256(t.r) << 160 | uint256(t.s) << 192 | uint256(t.f) << 224
            | uint256(t.m) << 240;
    }
}

/// @notice Mints works under the pool's colliding terms through two admitted adapters and two fee
///         recipients, re-rates tokens (preferring rates that collide under the token's other
///         terms), squats empty hashed positions with foreign words so terms must overflow, and
///         settles through the right and the wrong adapter. It keeps the terms each token locked.
contract TermsHandler is Test {
    uint256 internal constant TOKENS_SLOT = 18;
    uint256 internal constant TERMS_SLOT = 19;
    uint256 internal constant OVERFLOW_IDS_SLOT = 20;
    uint24 internal constant HASHED = 0x7fffff;
    uint24 internal constant OVERFLOW = 0x800000;

    Stream internal stream;
    MockEconomics internal econ;
    MockWorkRecords internal records;
    MockSaleAdapter[3] internal adapters; // index 1 and 2 = minter IDs
    address[3] internal fees; // index 1 and 2 = fee-recipient IDs
    address internal seller;
    StreamTermsInvariantTest internal owner;

    Pool.T[] internal pool;
    uint256[] public tokens;
    mapping(uint256 => Pool.T) internal shadow;
    uint256 internal salt = 1000;
    uint256 public squats;
    uint256 public reRates;
    uint256 public overflowHits;
    uint256 public lastTouched;
    mapping(bytes32 key => bool) internal _keySeen;
    mapping(bytes32 key => uint24) internal _idOfKey;
    mapping(uint24 termsId => bool) internal _idSeen;
    mapping(uint24 termsId => bytes32) internal _keyOfId;

    constructor(
        Stream stream_,
        MockEconomics econ_,
        MockWorkRecords records_,
        MockSaleAdapter m1,
        MockSaleAdapter m2,
        address f1,
        address f2,
        address seller_
    ) {
        owner = StreamTermsInvariantTest(msg.sender);
        stream = stream_;
        econ = econ_;
        records = records_;
        adapters[1] = m1;
        adapters[2] = m2;
        fees[1] = f1;
        fees[2] = f2;
        seller = seller_;
        Pool.T[] memory p = Pool.all();
        for (uint256 i; i < p.length; ++i) {
            pool.push(p[i]);
        }
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function expected(uint256 tokenId) external view returns (Pool.T memory) {
        return shadow[tokenId];
    }

    function feeOf(uint16 f) external view returns (address) {
        return fees[f];
    }

    function adapterOf(uint16 m) external view returns (MockSaleAdapter) {
        return adapters[m];
    }

    function mint(uint256 seed) external {
        Pool.T memory t = pool[seed % pool.length];
        econ.setTerms(WorkTerms(seller, fees[t.f], t.s, address(0), t.r));
        ++salt;
        (uint256 tokenId,) = adapters[t.m].start(stream, owner.requestFor(salt, address(t.a)));
        tokens.push(tokenId);
        shadow[tokenId] = t;
        _record(tokenId);
    }

    /// @dev Re-rates a token, preferring a pool rate that collides under the token's other terms.
    function reRate(uint256 tokenSeed, uint256 rateSeed) external {
        if (tokens.length == 0) return;
        uint256 tokenId = tokens[tokenSeed % tokens.length];
        Pool.T memory cur = shadow[tokenId];
        uint32 rate = uint32(rateSeed % 100_001);
        for (uint256 k; k < pool.length; ++k) {
            Pool.T memory c = pool[(rateSeed % pool.length + k) % pool.length];
            if (c.a == cur.a && c.s == cur.s && c.f == cur.f && c.m == cur.m && c.r != cur.r) {
                rate = c.r;
                break;
            }
        }
        records.setRoyaltyRate(stream, tokenId, rate);
        cur.r = rate;
        shadow[tokenId] = cur;
        ++reRates;
        _record(tokenId);
    }

    /// @dev Same terms, same ID; one ID, one terms (dedupe and no aliasing), checked as each
    ///      token takes its terms.
    function _record(uint256 tokenId) internal {
        lastTouched = tokenId;
        bytes32 key = Pool.key(shadow[tokenId]);
        uint24 id = termsIdOf(tokenId);
        if (id >= OVERFLOW) ++overflowHits;
        if (_keySeen[key]) assertEq(_idOfKey[key], id, "same terms, same ID");
        (_keySeen[key], _idOfKey[key]) = (true, id);
        if (_idSeen[id]) assertEq(_keyOfId[id], key, "one ID, one terms");
        (_idSeen[id], _keyOfId[id]) = (true, key);
    }

    /// @dev Adversarial: a foreign terms word at the empty hashed position of pool terms not yet
    ///      interned, so those terms must take the overflow range.
    function squat(uint256 seed) external {
        Pool.T memory t = pool[seed % pool.length];
        uint24 pos = uint24(uint256(Pool.key(t))) & HASHED;
        bytes32 slot = keccak256(abi.encode(uint256(pos), TERMS_SLOT));
        if (vm.load(address(stream), slot) != 0) return;
        uint256 foreign = uint256(uint160(0xdead0000 + seed % 1000)) | uint256(uint32(seed)) << 160;
        vm.store(address(stream), slot, bytes32(foreign));
        ++squats;
    }

    /// @dev Only the minting adapter may settle; any other reverts.
    function settle(uint256 tokenSeed, uint256 minterSeed) external {
        if (tokens.length == 0) return;
        uint256 tokenId = tokens[tokenSeed % tokens.length];
        uint16 m = uint16(1 + minterSeed % 2);
        bool ok;
        try adapters[m].settle(stream, tokenId) {
            ok = true;
        } catch { }
        assertEq(ok, m == shadow[tokenId].m, "settle gated on the minting adapter");
    }

    function termsIdOf(uint256 tokenId) public view returns (uint24) {
        uint256 w = uint256(vm.load(address(stream), keccak256(abi.encode(tokenId, TOKENS_SLOT))));
        return uint24(w >> 232);
    }
}

/// @notice Stateful check of Stream's interned terms under real 23-bit collisions (QUALITY-6): every
///         view of every token returns the terms it locked, its terms ID names exactly those terms
///         at their hashed position or through the overflow index, and terms and IDs map
///         one-to-one.
contract StreamTermsInvariantTest is StreamFixture {
    TermsHandler internal handler;
    address internal feeB = makeAddr("feeB");
    MockSaleAdapter internal second;

    function requestFor(uint256 s, address a) external view returns (bytes memory) {
        PackageItem memory item = _item(s);
        item.parties[0].account = a;
        return _request(item);
    }

    function setUp() public override {
        super.setUp();
        _bindMocks();
        // Fee recipient 1 = feeRecipient, 2 = feeB; minter 1 = auction, 2 = second.
        _mint(1);
        econ.setTerms(WorkTerms(seller, feeB, 25_000, address(0), 6_529));
        _mint(2);
        econ.setTerms(_defaultTerms());
        second = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.prank(governor);
        stream.setAdmittedMinter(address(second), true);
        artists.register(address(Pool.A1));
        artists.register(address(Pool.A2));
        artists.register(address(Pool.A3));
        artists.register(address(Pool.A4));
        handler = new TermsHandler(
            stream, econ, recordsMock, auction, second, feeRecipient, feeB, seller
        );
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = TermsHandler.mint.selector;
        sel[1] = TermsHandler.reRate.selector;
        sel[2] = TermsHandler.squat.selector;
        sel[3] = TermsHandler.settle.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    /// @dev Every token's terms ID names exactly the terms it locked, at their hashed position or
    ///      through the overflow index (cheap storage reads, every token); every view of the token
    ///      the last action touched returns those terms. The handler checks, at each mint and
    ///      re-rate, that terms and IDs map one-to-one.
    function invariant_EveryViewMatchesTheLockedTerms() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i; i < n; ++i) {
            _checkStorage(handler.tokens(i));
        }
        if (n != 0) _checkViews(handler.lastTouched());
    }

    function _checkStorage(uint256 id) internal view {
        Pool.T memory t = handler.expected(id);
        uint24 termsId = handler.termsIdOf(id);
        bytes32 key = Pool.key(t);
        uint256 word = uint256(
            vm.load(address(stream), keccak256(abi.encode(uint256(termsId), uint256(19))))
        );
        assertEq(word, Pool.word(t), "terms word");
        if (termsId < 0x800000) {
            assertEq(termsId, uint24(uint256(key)) & 0x7fffff, "hashed position");
        } else {
            assertEq(
                uint256(vm.load(address(stream), keccak256(abi.encode(key, uint256(20))))),
                termsId,
                "overflow index"
            );
        }
    }

    function _checkViews(uint256 id) internal view {
        Pool.T memory t = handler.expected(id);
        IStream.WorkCore memory w = stream.work(id);
        assertEq(w.artistId, t.a, "artist");
        assertEq(w.royaltyRate, t.r, "rate");
        assertEq(stream.artistOf(id), t.a);
        address fee = handler.feeOf(t.f);
        address receiver = _royaltyWallet(seller, fee, t.s);
        assertEq(w.royaltyReceiver, receiver, "receiver");
        (address r, uint256 amount) = stream.royaltyInfo(id, 1 ether);
        assertEq(r, receiver);
        assertEq(amount, 1 ether * uint256(t.r) / 100_000);
        PrimaryTerms memory p = stream.primaryTerms(id, "");
        assertEq(p.feeRecipient, fee, "fee recipient");
        assertEq(p.feeShare, t.s, "fee share");
        assertEq(p.creator, address(t.a), "creator");
        assertEq(p.seller, seller);
    }

    /// @dev Every pool member, minted in order: the first of each real 23-bit collision takes the
    ///      hashed position, the other five the overflow range; then each again finds its own ID.
    function test_RealCollisionsAllResolve() public {
        Pool.T[] memory p = Pool.all();
        uint256 overflow;
        uint256[] memory ids = new uint256[](p.length);
        for (uint256 i; i < p.length; ++i) {
            handler.mint(i);
            uint256 tokenId = handler.tokens(handler.tokenCount() - 1);
            uint24 termsId = handler.termsIdOf(tokenId);
            ids[i] = termsId;
            if (termsId >= 0x800000) ++overflow;
        }
        assertEq(overflow, 30, "six positions x five overflow terms");
        for (uint256 i; i < p.length; ++i) {
            handler.mint(i);
            uint256 tokenId = handler.tokens(handler.tokenCount() - 1);
            assertEq(handler.termsIdOf(tokenId), ids[i], "found again");
        }
        invariant_EveryViewMatchesTheLockedTerms();
    }
}
