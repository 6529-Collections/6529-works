// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { EnglishAuctionLens, IEnglishAuctionStorage } from "src/sales/EnglishAuctionLens.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @notice The lens the English auction creates for its views (EIP-170 headroom): the auction
///         forwards every call it does not declare to it with a read-only `staticcall`, refuses
///         ETH, reverts on a selector the lens does not know either, and can never point
///         anywhere else. The answers themselves are compared with the pre-lens build in
///         `EnglishAuctionLensDifferential.t.sol`.
contract EnglishAuctionLensTest is AuctionBase {
    /// @dev The lens is the auction's first creation, fixed in an immutable, and knows its
    ///      auction and dependencies.
    function test_Lens_IsTheAuctionsOwnFixedCreation() public view {
        address lens = auction.lens();
        assertEq(lens, vm.computeCreateAddress(address(auction), 1), "the auction's first CREATE");
        assertGt(lens.code.length, 0);
        EnglishAuctionLens l = EnglishAuctionLens(lens);
        assertEq(l.adapter(), address(auction));
        assertEq(l.escrow(), address(escrow));
        assertEq(l.statementLog(), address(statements));
        assertEq(address(l.allowlist()), address(allowlist));
        assertEq(address(l.economicsResolver()), address(resolver));
        assertEq(l.permit2(), address(permit2));
    }

    /// @dev No function of the auction changes its lens: every governed setter and every sale
    ///      action leaves `lens()` and the lens's code as they were.
    function test_Lens_CannotBeSwapped() public {
        address lens = auction.lens();
        bytes32 codehash = lens.codehash;
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        vm.prank(setter);
        auction.setConfig(_config(), IEnglishAuction.AuctionConfig(2 hours, WINDOW, SHARE));
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, 0.1 ether);
        vm.prank(pauser);
        auction.pause();
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.lens(), lens);
        assertEq(lens.codehash, codehash);
    }

    /// @dev The fallback refuses ETH: with calldata a lens view answers, with an unknown
    ///      selector, and with none at all. The auction has no `receive`.
    function test_Fallback_RefusesEth() public {
        vm.deal(alice, 1 ether);
        bytes[3] memory calls = [
            abi.encodeCall(IEnglishAuction.config, ()),
            abi.encodeWithSelector(bytes4(0xdeadbeef)),
            bytes("")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory ret) = address(auction).call{ value: 1 }(calls[i]);
            assertFalse(ok, "ETH refused");
            assertEq(ret.length, 0, "a plain revert");
        }
        assertEq(address(auction).balance, 0);
    }

    /// @dev A selector neither the auction nor its lens declares reverts with no data, as it did
    ///      before the lens; so do short calldata and none.
    function test_Fallback_RevertsOnUnknownSelectors() public {
        bytes[4] memory calls = [
            abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1)),
            abi.encodeWithSignature("sweep(address)", alice),
            hex"01",
            bytes("")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(auction).call(calls[i]);
            assertFalse(ok);
            assertEq(ret.length, 0);
            (ok, ret) = address(auction).staticcall(calls[i]);
            assertFalse(ok);
            assertEq(ret.length, 0);
        }
    }

    /// @dev The fallback is read-only: a view answered through it works inside a `staticcall`,
    ///      and the lens's revert data comes back unchanged.
    function test_Fallback_IsAReadOnlyForwarder() public {
        uint256 saleId = _start();
        (bool ok, bytes memory ret) =
            address(auction).staticcall(abi.encodeCall(IEnglishAuction.minimumBid, (saleId)));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 1);
        uint256 unknown = 42;
        (ok, ret) = address(auction).staticcall(abi.encodeCall(IEnglishAuction.auction, (unknown)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, unknown));
    }

    /// @dev Called directly, the lens answers exactly what the auction answers for it.
    function test_Lens_AnswersTheSameCalledDirectly() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        bytes[6] memory calls = [
            abi.encodeCall(IEnglishAuction.auction, (saleId)),
            abi.encodeCall(IEnglishAuction.lockedTerms, (saleId)),
            abi.encodeCall(IEnglishAuction.minimumBid, (saleId)),
            abi.encodeCall(IEnglishAuction.config, ()),
            abi.encodeCall(ISaleAdapter.isTarget, (address(stream))),
            abi.encodeCall(ISaleAdapter.claimable, (alice, ETH))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool viaAuction, bytes memory a) = address(auction).staticcall(calls[i]);
            (bool direct, bytes memory b) = auction.lens().staticcall(calls[i]);
            assertTrue(viaAuction && direct);
            assertEq(a, b);
        }
    }

    /// @dev `storageWords` returns the auction's raw words at the slots asked, in order, and
    ///      nothing for none.
    function test_StorageWords_ReturnsTheWordsAtTheSlots() public {
        bytes32[] memory slots = new bytes32[](4);
        slots[0] = bytes32(uint256(0)); // the AccessManager authority
        slots[1] = bytes32(uint256(3)); // the settings
        slots[2] = keccak256(abi.encode(address(stream), uint256(5))); // listed
        slots[3] = keccak256("an empty slot");
        bytes32[] memory words = IEnglishAuctionStorage(address(auction)).storageWords(slots);
        assertEq(words.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(words[i], vm.load(address(auction), slots[i]));
        }
        assertEq(address(uint160(uint256(words[0]))), address(manager));
        assertEq(uint256(words[2]), 1, "Stream is listed");
        assertEq(IEnglishAuctionStorage(address(auction)).storageWords(new bytes32[](0)).length, 0);
    }

    /// @dev The lens decodes the auction's layout: its slot numbers are the compiler's.
    function test_Lens_ReadsTheAuctionsLayout() public {
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, 0.25 ether);
        assertEq(auction.openingBid(ETH), 0.25 ether);
        assertEq(
            uint256(vm.load(address(auction), keccak256(abi.encode(ETH, uint256(9))))), 0.25 ether
        );
        IEnglishAuction.AuctionConfig memory c = auction.config();
        uint256 word = uint256(vm.load(address(auction), bytes32(uint256(3))));
        // The settings word packs three 32-bit fields: each cast keeps one.
        // forge-lint: disable-start(unsafe-typecast)
        assertEq(c.duration, uint32(word));
        assertEq(c.extensionWindow, uint32(word >> 32));
        assertEq(c.incrementShare, uint32(word >> 64));
        // forge-lint: disable-end(unsafe-typecast)
        // The selector of `storageWords` is not one of the views the fallback forwards.
        assertTrue(IEnglishAuctionStorage.storageWords.selector != IEnglishAuction.auction.selector);
        assertEq(EnglishAuction.storageWords.selector, IEnglishAuctionStorage.storageWords.selector);
    }
}
