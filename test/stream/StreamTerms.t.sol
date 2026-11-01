// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStream } from "src/interfaces/IStream.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind, PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @notice QUALITY-6: a token keeps two words, and the terms its works share (the lead artist,
///         royalty rate, fee share, fee-recipient index and minting adapter's index) are one
///         interned word, at the position its hash names or in the overflow range. These tests
///         pin every view to the values the old three-word record returned.
contract StreamTermsTest is StreamFixture {
    /// @dev `Stream._terms`'s storage slot (`forge inspect Stream storageLayout`), checked by
    ///      `_termsSlot` against a minted token before any test relies on it.
    uint256 internal constant TERMS_SLOT = 19;
    uint24 internal constant HASHED = 0x7fffff;
    uint24 internal constant OVERFLOW = 0x800000;

    /// @dev The packed terms word and the hash `Stream._termsId` keys them by.
    function _key(uint256 artistId, uint32 rate, uint32 feeShare, uint16 fee, uint16 minter)
        internal
        pure
        returns (bytes32 key, uint256 word)
    {
        key = keccak256(abi.encode(uint160(artistId), rate, feeShare, fee, minter));
        word = artistId | uint256(rate) << 160 | uint256(feeShare) << 192 | uint256(fee) << 224
            | uint256(minter) << 240;
    }

    function _termsSlot(uint24 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(id), TERMS_SLOT));
    }

    /// @dev The default terms of `artist`'s works in this fixture: fee recipient 1, minter 1.
    function _defaultKey() internal view returns (bytes32 key, uint256 word) {
        return _key(uint160(artist), 6_529, 25_000, 1, 1);
    }

    function test_Terms_LayoutGuard() public {
        _mint(1);
        (bytes32 key, uint256 word) = _defaultKey();
        assertEq(uint256(vm.load(address(stream), _termsSlot(uint24(uint256(key)) & HASHED))), word);
    }

    /// @dev Every view of a work reads its shared terms, and works of one artist share them.
    function test_Terms_ViewsMatchTheLockedTerms() public {
        _bindMocks();
        uint256 a = _mint(1);
        uint256 b = _mint(2);
        for (uint256 id = a; id <= b; ++id) {
            IStream.WorkCore memory w = stream.work(id);
            assertEq(w.artistId, uint160(artist));
            assertEq(w.seller, seller);
            assertEq(w.royaltyReceiver, _defaultRoyaltyWallet());
            assertEq(w.royaltyRate, 6_529);
            assertEq(uint8(w.kind), uint8(ItemKind.ORIGINAL));
            assertEq(uint8(w.seedPolicy), uint8(SeedPolicy.NONE));
            assertEq(stream.artistOf(id), uint160(artist));
            PrimaryTerms memory t = stream.primaryTerms(id, "");
            assertEq(t.seller, seller);
            assertEq(t.feeRecipient, feeRecipient);
            assertEq(t.feeShare, 25_000);
            assertEq(t.creator, artist);
            (address receiver, uint256 amount) = stream.royaltyInfo(id, 1 ether);
            assertEq(receiver, _defaultRoyaltyWallet());
            assertEq(amount, 0.06529 ether);
        }
    }

    /// @dev A second work under the same terms writes no terms word; new terms write one.
    function test_Terms_InternedOncePerTerms() public {
        vm.record();
        _mint(1);
        (, bytes32[] memory first) = vm.accesses(address(stream));
        vm.record();
        _mint(2);
        (, bytes32[] memory second) = vm.accesses(address(stream));
        (bytes32 key,) = _defaultKey();
        bytes32 slot = _termsSlot(uint24(uint256(key)) & HASHED);
        assertTrue(_contains(first, slot), "the first work writes the terms");
        assertFalse(_contains(second, slot), "a later work reuses them");
    }

    /// @dev A re-rate moves only that token to the terms with its new rate: the artist's other
    ///      works keep theirs, and re-rating back finds the original terms again.
    function test_Terms_ReRateMovesOnlyThatToken() public {
        _bindMocks();
        uint256 a = _mint(1);
        uint256 b = _mint(2);
        recordsMock.setRoyaltyRate(stream, a, 10_000);
        assertEq(stream.work(a).royaltyRate, 10_000);
        assertEq(stream.work(b).royaltyRate, 6_529, "the shared terms did not change");
        (, uint256 amountB) = stream.royaltyInfo(b, 1 ether);
        assertEq(amountB, 0.06529 ether);
        (bytes32 key, uint256 word) = _key(uint160(artist), 10_000, 25_000, 1, 1);
        assertEq(uint256(vm.load(address(stream), _termsSlot(uint24(uint256(key)) & HASHED))), word);
        recordsMock.setRoyaltyRate(stream, a, 6_529);
        assertEq(stream.work(a).royaltyRate, 6_529);
        assertEq(stream.work(a).royaltyReceiver, _defaultRoyaltyWallet());
    }

    /// @dev Terms locked at mint survive a later economics change; new works lock the new ones.
    function test_Terms_EconomicsChangeAffectsOnlyNewWorks() public {
        uint256 a = _mint(1);
        address otherFee = makeAddr("otherFee");
        econ.setTerms(WorkTerms(seller, otherFee, 10_000, address(0), 2_000));
        uint256 b = _mint(2);
        PrimaryTerms memory ta = stream.primaryTerms(a, "");
        PrimaryTerms memory tb = stream.primaryTerms(b, "");
        assertEq(ta.feeRecipient, feeRecipient);
        assertEq(ta.feeShare, 25_000);
        assertEq(stream.work(a).royaltyRate, 6_529);
        assertEq(tb.feeRecipient, otherFee);
        assertEq(tb.feeShare, 10_000);
        assertEq(stream.work(b).royaltyRate, 2_000);
        assertEq(stream.work(b).royaltyReceiver, _royaltyWallet(seller, otherFee, 10_000));
    }

    /// @dev Different artists' works keep their own artist and creator.
    function test_Terms_PerArtist() public {
        address other = makeAddr("otherArtist");
        artists.register(other);
        uint256 a = _mint(1);
        PackageItem memory item = _item(2);
        item.parties[0].account = other;
        uint256 b = _mint(item);
        assertEq(stream.artistOf(a), uint160(artist));
        assertEq(stream.artistOf(b), uint160(other));
        assertEq(stream.primaryTerms(a, "").creator, artist);
        assertEq(stream.primaryTerms(b, "").creator, other);
    }

    /// @dev When other terms already hold the hashed position, the terms go to the overflow
    ///      range, found again by their full hash: the next work under them writes no terms word.
    function test_Terms_CollisionUsesTheOverflowRange() public {
        _bindMocks();
        (bytes32 key, uint256 word) = _defaultKey();
        uint24 position = uint24(uint256(key)) & HASHED;
        // Another artist's terms at the same position (a 23-bit collision).
        (, uint256 squatter) = _key(uint160(makeAddr("squatter")), 1, 1, 1, 1);
        vm.store(address(stream), _termsSlot(position), bytes32(squatter));
        uint256 a = _mint(1);
        assertEq(uint256(vm.load(address(stream), _termsSlot(position))), squatter, "untouched");
        assertEq(uint256(vm.load(address(stream), _termsSlot(OVERFLOW | 1))), word);
        assertEq(stream.artistOf(a), uint160(artist));
        assertEq(stream.work(a).royaltyRate, 6_529);
        assertEq(stream.primaryTerms(a, "").feeRecipient, feeRecipient);
        vm.record();
        uint256 b = _mint(2);
        (, bytes32[] memory writes) = vm.accesses(address(stream));
        assertFalse(_contains(writes, _termsSlot(OVERFLOW | 2)), "no second overflow entry");
        assertEq(stream.artistOf(b), uint160(artist));
        // A re-rate reaches the overflow range the same way.
        recordsMock.setRoyaltyRate(stream, b, 7_000);
        assertEq(stream.work(b).royaltyRate, 7_000);
        assertEq(stream.work(a).royaltyRate, 6_529);
    }

    /// @dev The packed flags: kind, seed policy, the settled sale and the edition link.
    function test_Terms_FlagsRoundTrip() public {
        _bindMocks();
        PackageItem memory item = _item(1);
        item.kind = ItemKind.EDITION_MASTER;
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        uint256 id = _mint(item);
        (,,, ItemKind kind, SeedPolicy policy,) = stream.coreOf(id);
        assertEq(uint8(kind), uint8(ItemKind.EDITION_MASTER));
        assertEq(uint8(policy), uint8(SeedPolicy.ARTIST));
        assertFalse(stream.primarySaleSettled(id));
        auction.settle(stream, id);
        assertTrue(stream.primarySaleSettled(id));
        (address linked,) = stream.editionOf(id);
        assertEq(linked, address(0));
        editionsMock.link(stream, id, id);
        (linked,) = stream.editionOf(id);
        assertEq(linked, address(editionsMock));
        IStream.WorkCore memory w = stream.work(id);
        assertEq(uint8(w.kind), uint8(ItemKind.EDITION_MASTER));
        assertEq(uint8(w.seedPolicy), uint8(SeedPolicy.ARTIST));
        assertEq(w.serial, 1);
        assertEq(w.collectionId, collectionId);

        PackageItem memory vrf = _item(2);
        vrf.seedPolicy = SeedPolicy.VRF;
        entropy.deliver(vrf, keccak256("vrf"));
        uint256 vrfId = _mint(vrf);
        (,,, kind, policy,) = stream.coreOf(vrfId);
        assertEq(uint8(kind), uint8(ItemKind.ORIGINAL));
        assertEq(uint8(policy), uint8(SeedPolicy.VRF));
        assertEq(stream.work(vrfId).serial, 2);
    }

    function _contains(bytes32[] memory list, bytes32 value) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }
}
