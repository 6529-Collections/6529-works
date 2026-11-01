// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "src/interfaces/IEnglishAuctionClock.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { LockedTerms, PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { EnglishAuctionLens, IEnglishAuctionStorage } from "src/sales/EnglishAuctionLens.sol";
import { Roles } from "src/governance/Roles.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { MockMintTarget } from "../../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev A contract that calls the lens directly and answers `storageWords` with zero words: the
///      lens reads its caller, so it is answered from these, never from an auction.
contract ZeroWordsCaller {
    function storageWords(bytes32[] calldata slots) external pure returns (bytes32[] memory) {
        return new bytes32[](slots.length);
    }

    function configOf(EnglishAuctionLens lens) external view returns (uint32, uint32, uint32) {
        IEnglishAuction.AuctionConfig memory c = lens.config();
        return (c.duration, c.extensionWindow, c.incrementShare);
    }

    function claimableOf(EnglishAuctionLens lens, address account, address currency)
        external
        view
        returns (uint256)
    {
        return lens.claimable(account, currency);
    }

    function auctionOf(EnglishAuctionLens lens, uint256 saleId) external view {
        lens.auction(saleId);
    }
}

/// @notice The lens that answers the English auction's views (EIP-170 headroom), deployed on its
///         own and pinned by the auction's constructor (F8): the auction forwards every call it
///         does not declare to it with a read-only `staticcall`, refuses ETH, reverts on a
///         selector the lens does not know either, and can never point anywhere else. The
///         answers themselves are compared with the pre-lens build in
///         `EnglishAuctionLensDifferential.t.sol`.
contract EnglishAuctionLensTest is AuctionBase {
    /// @dev The lens is fixed in an immutable and holds the auction's dependencies.
    function test_Lens_IsPinnedWithTheAuctionsDependencies() public view {
        address lens = auction.lens();
        assertGt(lens.code.length, 0);
        EnglishAuctionLens l = EnglishAuctionLens(lens);
        assertEq(l.escrow(), address(escrow));
        assertEq(l.statementLog(), address(statements));
        assertEq(address(l.allowlist()), address(allowlist));
        assertEq(address(l.economicsResolver()), address(resolver));
        assertEq(l.permit2(), address(permit2));
    }

    /// @dev F8 (the rc.2 review's GAS M-2): the constructor takes a lens deployed beforehand and
    ///      checks it has code, no EIP-7702 delegation, the code hash it was given and each of
    ///      the auction's own dependencies; anything else is refused with
    ///      `Dependency.InvalidDependency(lens)`. The matching lens is installed.
    function test_Constructor_PinsTheLens() public {
        address[] memory none = new address[](0);
        address good = _lens(address(0));
        IAssetAllowlist al = IAssetAllowlist(address(allowlist));
        address eoa = makeAddr("eoa");
        address[6] memory bad = [
            eoa,
            address(
                new EnglishAuctionLens(
                    address(statements), address(statements), al, resolver, address(0)
                )
            ),
            address(
                new EnglishAuctionLens(address(escrow), address(escrow), al, resolver, address(0))
            ),
            address(
                new EnglishAuctionLens(
                    address(escrow),
                    address(statements),
                    IAssetAllowlist(address(usd)),
                    resolver,
                    address(0)
                )
            ),
            address(
                new EnglishAuctionLens(
                    address(escrow),
                    address(statements),
                    al,
                    IEconomicsResolver(address(escrow)),
                    address(0)
                )
            ),
            address(
                new EnglishAuctionLens(
                    address(escrow), address(statements), al, resolver, address(permit2)
                )
            )
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, bad[i]));
            new EnglishAuction(
                address(manager),
                address(escrow),
                resolver,
                address(statements),
                address(0),
                bad[i],
                bad[i].codehash,
                _config(),
                none
            );
        }
        // The right lens under the wrong code hash: another build would be refused.
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, good));
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            address(0),
            good,
            keccak256("another build"),
            _config(),
            none
        );
        EnglishAuction a = new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            address(0),
            good,
            good.codehash,
            _config(),
            none
        );
        assertEq(a.lens(), good);
    }

    /// @dev F8: the lens is stateless and reads its caller, so a third party calling it directly
    ///      changes nothing. An account gets a revert from every view that reads storage (it
    ///      answers no `storageWords`) and the constants as they are; a contract that answers
    ///      `storageWords` is answered from its own words, not the auction's. No call writes to
    ///      the lens or the auction, the lens holds no storage, and the auction answers as before.
    function test_Lens_ADirectCallFromAThirdPartyChangesNothing() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        EnglishAuctionLens l = EnglishAuctionLens(auction.lens());
        bytes memory before = abi.encode(
            auction.auction(saleId),
            auction.config(),
            auction.claimable(alice, ETH),
            auction.paused()
        );
        ZeroWordsCaller caller = new ZeroWordsCaller();
        address stranger = makeAddr("stranger");

        vm.record();
        vm.startPrank(stranger);
        vm.expectRevert(bytes(""));
        l.auction(saleId);
        vm.expectRevert(bytes(""));
        l.config();
        vm.expectRevert(bytes(""));
        l.claimable(alice, ETH);
        assertEq(l.escrow(), address(escrow), "a constant answers");
        assertEq(l.saleIdOf(address(stream), 1), saleId, "so does a pure view");
        vm.stopPrank();
        // From a contract, the caller's own (zero) words: no sale, no config, no credit.
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, saleId));
        caller.auctionOf(l, saleId);
        (uint32 duration,,) = caller.configOf(l);
        assertEq(duration, 0, "the caller's words, not the auction's");
        assertEq(caller.claimableOf(l, alice, ETH), 0);
        (, bytes32[] memory lensWrites) = vm.accesses(address(l));
        (, bytes32[] memory auctionWrites) = vm.accesses(address(auction));
        assertEq(lensWrites.length, 0, "the lens writes nothing");
        assertEq(auctionWrites.length, 0, "nor does the auction");

        for (uint256 slot; slot < 16; ++slot) {
            assertEq(vm.load(address(l), bytes32(slot)), bytes32(0), "the lens has no storage");
        }
        assertEq(
            abi.encode(
                auction.auction(saleId),
                auction.config(),
                auction.claimable(alice, ETH),
                auction.paused()
            ),
            before
        );
        assertEq(auction.claimable(alice, ETH), 1 ether, "the outbid credit is still there");
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

    /// @dev Called directly with the auction as its caller (the lens reads its caller), the lens
    ///      answers exactly what the auction answers for it: every function the lens declares, so
    ///      none is shadowed by one the auction declares.
    function test_Lens_AnswersTheSameCalledDirectly() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        bytes[21] memory calls = [
            abi.encodeCall(IEnglishAuction.auction, (saleId)),
            abi.encodeCall(IEnglishAuction.lockedTerms, (saleId)),
            abi.encodeCall(IEnglishAuction.minimumBid, (saleId)),
            abi.encodeCall(IEnglishAuction.pendingDelivery, (saleId)),
            abi.encodeCall(IEnglishAuction.config, ()),
            abi.encodeCall(IEnglishAuction.openingBid, (ETH)),
            abi.encodeCall(ISaleAdapter.claimable, (alice, ETH)),
            abi.encodeCall(ISaleAdapter.paused, ()),
            abi.encodeCall(ISaleAdapter.isTarget, (address(stream))),
            abi.encodeCall(ISaleAdapter.federationRegistry, ()),
            abi.encodeCall(IEnglishAuctionFull.federationRegistryCodeHash, ()),
            abi.encodeCall(IEnglishAuction.saleIdOf, (address(stream), 1)),
            abi.encodeCall(
                EnglishAuctionLens.supportsInterface, (type(IEnglishAuction).interfaceId)
            ),
            abi.encodeCall(IEnglishAuctionFull.MAX_PAUSE, ()),
            abi.encodeCall(IEnglishAuctionFull.OPENING_BID_FLOORS, ()),
            abi.encodeCall(IEnglishAuctionFull.PAYOUT_GAS, ()),
            abi.encodeCall(IEnglishAuction.escrow, ()),
            abi.encodeCall(IEnglishAuction.statementLog, ()),
            abi.encodeCall(IEnglishAuctionFull.allowlist, ()),
            abi.encodeCall(IEnglishAuctionFull.economicsResolver, ()),
            abi.encodeCall(IEnglishAuctionFull.permit2, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool viaAuction, bytes memory a) = address(auction).staticcall(calls[i]);
            address lens = auction.lens();
            vm.prank(address(auction));
            (bool direct, bytes memory b) = lens.staticcall(calls[i]);
            assertTrue(viaAuction && direct);
            assertEq(a, b);
        }
    }

    /// @dev `storageWords` returns the auction's raw words at the slots asked, in order, and
    ///      nothing for none.
    function test_StorageWords_ReturnsTheWordsAtTheSlots() public view {
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

    /// @dev `auctionClock` is answered by the auction itself, for contracts that read an
    ///      auction on their hot paths: the lens does not declare it, it is outside the ERC-165
    ///      surface, and an unknown sale reverts as `auction` does.
    function test_AuctionClock_IsAnsweredByTheCoreOutsideErc165() public {
        uint256 saleId = _start();
        _assertClockIsAuctions(saleId);
        (bool ok, bytes memory ret) =
            auction.lens().staticcall(abi.encodeCall(IEnglishAuctionClock.auctionClock, (saleId)));
        assertFalse(ok, "the lens does not answer it");
        assertEq(ret.length, 0);
        assertFalse(auction.supportsInterface(type(IEnglishAuctionClock).interfaceId));
        assertTrue(auction.supportsInterface(type(IEnglishAuction).interfaceId));
        uint256 unknown = 42;
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, unknown));
        auction.auctionClock(unknown);
        assertEq(EnglishAuction.auctionClock.selector, IEnglishAuctionClock.auctionClock.selector);
    }

    /// @dev Through a dispute pause and its resumption, and through a pause left to run past
    ///      `MAX_PAUSE`, `auctionClock` stays `auction`'s state, end and pause start at every
    ///      point: the pause start while the pause is live, zero after `resume` and once it has
    ///      run past `MAX_PAUSE`.
    function test_AuctionClock_MatchesAuctionThroughAPauseAndResume() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _assertClockIsAuctions(saleId);
        _pause(saleId);
        assertEq(uint8(_assertClockIsAuctions(saleId)), uint8(IEnglishAuction.AuctionState.PAUSED));
        (,, uint64 pausedAt) = auction.auctionClock(saleId);
        assertEq(pausedAt, block.timestamp, "the pause start");
        vm.warp(block.timestamp + Roles.STANDARD);
        _assertClockIsAuctions(saleId);
        vm.prank(unpauser);
        auction.resume(saleId);
        assertEq(uint8(_assertClockIsAuctions(saleId)), uint8(IEnglishAuction.AuctionState.ACTIVE));
        (,, pausedAt) = auction.auctionClock(saleId);
        assertEq(pausedAt, 0, "cleared by resume");
        _end(saleId);
        assertEq(uint8(_assertClockIsAuctions(saleId)), uint8(IEnglishAuction.AuctionState.ENDED));
        auction.settle(saleId);
        assertEq(uint8(_assertClockIsAuctions(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED));

        // A pause nobody resumes: the end it resumes to is reported before anyone writes it.
        uint256 lapsed = _start();
        _bidEth(lapsed, bob, 1 ether);
        _pause(lapsed);
        uint64 maxPause = auction.MAX_PAUSE();
        vm.warp(block.timestamp + maxPause);
        assertEq(uint8(_assertClockIsAuctions(lapsed)), uint8(IEnglishAuction.AuctionState.PAUSED));
        (,, pausedAt) = auction.auctionClock(lapsed);
        assertTrue(pausedAt != 0, "still live at MAX_PAUSE");
        vm.warp(block.timestamp + 1);
        assertEq(uint8(_assertClockIsAuctions(lapsed)), uint8(IEnglishAuction.AuctionState.ACTIVE));
        (,, pausedAt) = auction.auctionClock(lapsed);
        assertEq(pausedAt, 0, "shown resumed past MAX_PAUSE");
        assertEq(auction.auction(lapsed).pausedTotal, maxPause, "shown resumed");
        _end(lapsed);
        assertEq(uint8(_assertClockIsAuctions(lapsed)), uint8(IEnglishAuction.AuctionState.ENDED));
        auction.settle(lapsed);
        _assertClockIsAuctions(lapsed);
    }

    /// @dev Asserts `auctionClock(saleId)` is `auction(saleId)`'s state, end and pause start;
    ///      returns the state.
    function _assertClockIsAuctions(uint256 saleId)
        internal
        view
        returns (IEnglishAuction.AuctionState state)
    {
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        uint64 endTime;
        uint64 pausedAt;
        (state, endTime, pausedAt) = auction.auctionClock(saleId);
        assertEq(uint8(state), uint8(a.state), "state");
        assertEq(endTime, a.endTime, "end");
        assertEq(pausedAt, a.pausedAt, "pause start");
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

/// @notice The lens against an auction this test plays: the paths the real auction never
///         takes (its `storageWords` reverting or answering the wrong length) and a token
///         whose fee share is out of range, which `lockedTerms` refuses as the auction did.
contract EnglishAuctionLensEdgesTest is Test {
    EnglishAuctionLens internal lens;
    /// @dev 0: answer from `words`; 1: revert with `Boom`; 2: answer one word too many.
    uint256 internal mode;
    mapping(bytes32 slot => bytes32 word) internal words;
    uint32 internal feeShare;

    error Boom(uint256 code);

    function setUp() public {
        // The lens reads its caller: this test plays the auction.
        lens = new EnglishAuctionLens(
            address(0xE5C),
            address(0x106),
            IAssetAllowlist(address(0xA11)),
            IEconomicsResolver(address(0xEC0)),
            address(0)
        );
    }

    /// @dev The auction's `storageWords`, as this test plays it.
    function storageWords(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        if (mode == 1) revert Boom(7);
        out = new bytes32[](slots.length + (mode == 2 ? 1 : 0));
        for (uint256 i; i < slots.length; ++i) {
            out[i] = words[slots[i]];
        }
    }

    /// @dev The token's `primaryTerms`, as this test plays it: only the fee share matters.
    function primaryTerms(uint256, bytes calldata) external view returns (PrimaryTerms memory p) {
        p.seller = address(0x5E11);
        p.feeRecipient = address(0xFEE);
        p.feeShare = feeShare;
    }

    /// @dev An auction that reverts in `storageWords` makes the view revert with its data.
    function test_Lens_PassesOnTheAuctionsRevert() public {
        mode = 1;
        vm.expectRevert(abi.encodeWithSelector(Boom.selector, 7));
        lens.config();
    }

    /// @dev An answer of any length but one word per slot is refused, with no data.
    function test_Lens_RefusesAnAnswerOfTheWrongLength() public {
        mode = 2;
        vm.expectRevert(bytes(""));
        lens.config();
    }

    /// @dev A fee share above 100% reverts `lockedTerms` with `InvalidSaleTerms`, as the
    ///      auction's own `lockedTerms` did; at 100% it answers.
    function test_LockedTerms_RefusesAFeeShareAboveTheDenominator() public {
        uint256 saleId = 1;
        bytes32 base = keccak256(abi.encode(saleId, uint256(8)));
        // An ACTIVE sale (status 1 at bit 240) of token ID 3 on this "token", terms record 0.
        words[base] =
            bytes32(uint256(uint160(address(this))) | (uint256(3) << 160) | (uint256(1) << 240));
        feeShare = 100_001;
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(this), 3)
        );
        lens.lockedTerms(saleId);
        feeShare = 100_000;
        LockedTerms memory lt = lens.lockedTerms(saleId);
        assertEq(lt.feeShare, 100_000);
        assertEq(lt.seller, address(0x5E11));
    }
}

/// @notice The lens decodes the auction's storage as the compiler lays it out (`forge inspect
///         EnglishAuction storageLayout`, transcribed below), independently of the pre-lens build
///         the differential test compares with. For every datum a lens view decodes: the
///         auction's own write lands at the slot and byte offset below, the lens reads exactly
///         those slots (`vm.accesses` on the auction during the view), and the view answers what
///         the auction wrote, each field set to a distinct value. A change to the auction's
///         layout fails here until this table and the lens move with it.
contract EnglishAuctionLensLayoutTest is AuctionBase {
    // `forge inspect EnglishAuction storageLayout`: slot 0 is AccessManaged's authority (and its
    // schedule flag); slot 4 is `_termsCount` and slot 6 `_termsIds`, which the lens never reads.
    uint256 internal constant FEDERATION_REGISTRY_SLOT = 1;
    uint256 internal constant FEDERATION_CODE_HASH_SLOT = 2;
    /// @dev `Settings`, bytes: duration 0..3, extensionWindow 4..7, incrementShare 8..11,
    ///      pausedAt 12..16.
    uint256 internal constant SETTINGS_SLOT = 3;
    uint256 internal constant LISTED_SLOT = 5;
    /// @dev `Terms`, bytes. Word 0: currency 0..19, incrementFloor 20..31. Word 1: openingBid
    ///      0..11, incrementShare 12..14, extensionWindow 15..17, registryFee 18..21, federated 22.
    uint256 internal constant TERMS_SLOT = 7;
    /// @dev `Sale`, bytes. Word 0: token 0..19, tokenId 20..23, endTime 24..27, termsId 28..29,
    ///      status 30, flags 31. Word 1: bidder 0..19, bid 20..31. Word 2: recipient 0..19,
    ///      pausedAt 20..23, pausedTotal 24..26, outcomeFrom 27..31.
    uint256 internal constant SALES_SLOT = 8;
    uint256 internal constant OPENING_BIDS_SLOT = 9;
    uint256 internal constant CREDITS_SLOT = 10;

    /// @dev Distinct governed parameters, so every settings and terms field differs.
    function _distinct() internal pure returns (IEnglishAuction.AuctionConfig memory) {
        return IEnglishAuction.AuctionConfig(3 days + 7, 23 hours + 13, 12_345);
    }

    /// @dev The governed words: settings, opening bids, listings and the federation registry.
    function test_Layout_GovernedWordsAreTheCompilers() public {
        IEnglishAuction.AuctionConfig memory c = _distinct();
        vm.record();
        vm.prank(setter);
        auction.setConfig(_config(), c);
        _wroteOnly(_s(SETTINGS_SLOT), "setConfig");
        assertEq(_field(SETTINGS_SLOT, 0, 4), c.duration, "Settings.duration");
        assertEq(_field(SETTINGS_SLOT, 4, 4), c.extensionWindow, "Settings.extensionWindow");
        assertEq(_field(SETTINGS_SLOT, 8, 4), c.incrementShare, "Settings.incrementShare");
        vm.record();
        IEnglishAuction.AuctionConfig memory got = auction.config();
        _readExactly(_s(SETTINGS_SLOT), "config");
        assertEq(abi.encode(got), abi.encode(c), "config");

        vm.warp(block.timestamp + 1234);
        vm.record();
        vm.prank(pauser);
        auction.pause();
        _wroteOnly(_s(SETTINGS_SLOT), "pause");
        assertEq(_field(SETTINGS_SLOT, 12, 5), block.timestamp, "Settings.pausedAt");
        vm.record();
        assertTrue(auction.paused(), "paused");
        _readExactly(_s(SETTINGS_SLOT), "paused");
        assertEq(abi.encode(auction.config()), abi.encode(c), "the pause is not the config");

        uint256 opening = 0.123456789 ether;
        uint256 slot = _mapSlot(ETH, OPENING_BIDS_SLOT);
        vm.record();
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, opening);
        _wroteOnly(_s(slot), "setOpeningBid");
        assertEq(uint256(vm.load(address(auction), bytes32(slot))), opening, "_openingBids");
        vm.record();
        assertEq(auction.openingBid(ETH), opening, "openingBid");
        _readExactly(_s(slot), "openingBid");

        MockMintTarget token = new MockMintTarget();
        slot = _mapSlot(address(token), LISTED_SLOT);
        vm.record();
        assertFalse(auction.isTarget(address(token)), "unlisted");
        _readExactly(
            _s(slot, FEDERATION_REGISTRY_SLOT, FEDERATION_CODE_HASH_SLOT), "isTarget, unlisted"
        );
        vm.record();
        vm.prank(successor);
        auction.setTarget(address(token), true);
        _wroteOnly(_s(slot), "setTarget");
        vm.record();
        assertTrue(auction.isTarget(address(token)), "listed");
        _readExactly(_s(slot), "isTarget, listed");

        MockFederationRegistry registry = new MockFederationRegistry();
        vm.record();
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        _wroteOnly(_s(FEDERATION_REGISTRY_SLOT, FEDERATION_CODE_HASH_SLOT), "setFederationRegistry");
        assertEq(_field(FEDERATION_REGISTRY_SLOT, 0, 20), uint160(address(registry)), "registry");
        assertEq(
            vm.load(address(auction), bytes32(FEDERATION_CODE_HASH_SLOT)),
            address(registry).codehash,
            "registry code hash"
        );
        vm.record();
        assertEq(auction.federationRegistry(), address(registry), "federationRegistry");
        _readExactly(_s(FEDERATION_REGISTRY_SLOT), "federationRegistry");
        vm.record();
        assertEq(auction.federationRegistryCodeHash(), address(registry).codehash, "code hash");
        _readExactly(_s(FEDERATION_CODE_HASH_SLOT), "federationRegistryCodeHash");
    }

    /// @dev A sale's three words and its terms records, through a start, a first bid, an outbid
    ///      for another recipient (a credit), a dispute pause and its resumption, and a
    ///      settlement whose delivery stays pending.
    function test_Layout_SaleAndTermsWordsAreTheCompilers() public {
        IEnglishAuction.AuctionConfig memory c = _distinct();
        vm.prank(setter);
        auction.setConfig(_config(), c);
        uint256 opening = 5e18 + 3;
        vm.prank(setter);
        auction.setOpeningBid(address(usd), 0, opening);
        uint256 floor = 2e18 + 11;
        _setFloor(address(usd), floor);
        // The first token, so that this sale's token ID is 2.
        _start();

        stream.setTerms(_terms(address(usd)));
        vm.record();
        uint256 saleId = auction.start(address(stream), "");
        uint256 base = _saleSlot(saleId);
        uint256 tb = _termsSlot(saleId);
        _wrote(_s(base, tb, tb + 1), "start");
        uint256 endTime = block.timestamp + c.duration;
        assertEq(_field(base, 0, 20), uint160(address(stream)), "Sale.token");
        assertEq(_field(base, 20, 4), 2, "Sale.tokenId");
        assertEq(_field(base, 24, 4), endTime, "Sale.endTime");
        assertEq(_field(base, 30, 1), uint8(IEnglishAuction.AuctionState.ACTIVE), "Sale.status");
        assertEq(_field(base, 31, 1), 0, "Sale.flags");
        assertEq(_field(tb, 0, 20), uint160(address(usd)), "Terms.currency");
        assertEq(_field(tb, 20, 12), 0, "Terms.incrementFloor, before the first bid");
        assertEq(_field(tb + 1, 0, 12), opening, "Terms.openingBid");
        assertEq(_field(tb + 1, 12, 3), c.incrementShare, "Terms.incrementShare");
        assertEq(_field(tb + 1, 15, 3), c.extensionWindow, "Terms.extensionWindow");
        vm.record();
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        _readExactly(_s(base, base + 1, base + 2, tb), "auction");
        assertEq(a.token, address(stream), "token");
        assertEq(a.tokenId, 2, "tokenId");
        assertEq(a.endTime, endTime, "endTime");
        assertEq(a.currency, address(usd), "currency");
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "state");
        vm.record();
        assertEq(auction.minimumBid(saleId), opening, "minimumBid: the opening bid");
        _readExactly(_s(base, base + 1, tb + 1), "minimumBid, no bidder");

        // The first bid: the bidder word, and the terms record that locks the floor.
        uint256 high = 500e18 + 13;
        usd.mint(alice, high);
        vm.prank(alice);
        usd.approve(address(auction), high);
        vm.record();
        vm.prank(alice);
        auction.bid(saleId, address(0), _direct(alice, high));
        uint256 tbFloor = _termsSlot(saleId);
        assertTrue(tbFloor != tb, "the first bid moves the sale to the record with the floor");
        _wrote(_s(base, base + 1, tbFloor, tbFloor + 1), "first bid");
        assertEq(_field(base + 1, 0, 20), uint160(alice), "Sale.bidder");
        assertEq(_field(base + 1, 20, 12), high, "Sale.bid");
        assertEq(_field(tbFloor, 20, 12), floor, "Terms.incrementFloor");
        vm.record();
        a = auction.auction(saleId);
        _readExactly(_s(base, base + 1, base + 2, tbFloor), "auction, with a bid");
        assertEq(a.bidder, alice, "bidder");
        assertEq(a.recipient, alice, "recipient");
        assertEq(a.bid, high, "bid");
        assertEq(a.incrementFloor, floor, "incrementFloor");
        uint256 step = (high * c.incrementShare + 99_999) / 100_000;
        assertGt(step, floor, "the share sets the step");
        vm.record();
        uint256 next = auction.minimumBid(saleId);
        _readExactly(_s(base, base + 1, tbFloor, tbFloor + 1), "minimumBid, with a bidder");
        assertEq(next, high + step, "minimumBid: the share");

        // An outbid for another recipient: the outbid bidder's credit, the recipient and its flag.
        usd.mint(bob, next);
        vm.prank(bob);
        usd.approve(address(auction), next);
        vm.record();
        vm.prank(bob);
        auction.bid(saleId, carol, _direct(bob, next));
        uint256 credit = _mapSlot(address(usd), _mapSlot(alice, CREDITS_SLOT));
        _wrote(_s(credit, base, base + 1, base + 2), "outbid");
        assertEq(uint256(vm.load(address(auction), bytes32(credit))), high, "_credits");
        assertEq(_field(base + 2, 0, 20), uint160(carol), "Sale.recipient");
        assertEq(_field(base, 31, 1), 4, "Sale.flags: recipient set");
        vm.record();
        assertEq(auction.claimable(alice, address(usd)), high, "claimable");
        _readExactly(_s(credit), "claimable");
        vm.record();
        a = auction.auction(saleId);
        _readExactly(_s(base, base + 1, base + 2, tbFloor), "auction, outbid");
        assertEq(a.bidder, bob, "bidder");
        assertEq(a.recipient, carol, "recipient");
        assertEq(a.bid, next, "bid");

        // A dispute pause and its resumption: pausedAt, the flag, pausedTotal.
        vm.warp(block.timestamp + 1 hours);
        uint256 pausedAt = block.timestamp;
        vm.record();
        _pause(saleId);
        _wrote(_s(base, base + 2), "pause");
        assertEq(_field(base + 2, 20, 4), pausedAt, "Sale.pausedAt");
        assertEq(_field(base, 31, 1), 4 | 1, "Sale.flags: pause used");
        vm.record();
        a = auction.auction(saleId);
        _readExactly(_s(base, base + 1, base + 2, tbFloor), "auction, paused");
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.PAUSED), "paused");
        assertEq(a.pausedAt, pausedAt, "pausedAt");
        assertEq(a.recipient, carol, "the recipient kept");
        uint256 length = Roles.STANDARD + 17;
        vm.warp(pausedAt + length);
        vm.record();
        vm.prank(unpauser);
        auction.resume(saleId);
        _wrote(_s(base, base + 2), "resume");
        assertEq(_field(base + 2, 24, 3), length, "Sale.pausedTotal");
        assertEq(_field(base + 2, 20, 4), 0, "Sale.pausedAt, cleared");
        a = auction.auction(saleId);
        assertEq(a.pausedTotal, length, "pausedTotal");
        assertEq(a.pausedAt, 0, "pausedAt");
        assertEq(a.endTime, _field(base, 24, 4), "the resumed end");
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "resumed");

        // Settlement with the delivery refused: the status and the pending flag.
        _end(saleId);
        stream.setMode(MockMintTarget.Mode.REJECT_TRANSFERS);
        auction.settle(saleId);
        assertEq(_field(base, 30, 1), uint8(IEnglishAuction.AuctionState.SETTLED), "Sale.status");
        assertEq(_field(base, 31, 1), 4 | 2 | 1, "Sale.flags: delivery pending");
        vm.record();
        assertEq(auction.pendingDelivery(saleId), carol, "pendingDelivery");
        _readExactly(_s(base, base + 2), "pendingDelivery");
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED), "settled");
    }

    /// @dev A pause left to lapse reads the locked window (terms word 1) and the governed
    ///      duration (the settings word), whichever is longer, and `auctionClock` agrees.
    function test_Layout_ALapsedPauseReadsTheWindowAndTheDuration() public {
        IEnglishAuction.AuctionConfig memory c = _distinct();
        vm.prank(setter);
        auction.setConfig(_config(), c);
        uint256 saleId = _start();
        uint256 base = _saleSlot(saleId);
        uint256 tb = _termsSlot(saleId);
        IEnglishAuction.AuctionConfig memory shorter =
            IEnglishAuction.AuctionConfig(2 hours + 5, 1 minutes, 1000);
        vm.prank(setter);
        auction.setConfig(c, shorter);
        vm.warp(_field(base, 24, 4) - 30 minutes);
        uint256 pausedAt = block.timestamp;
        _pause(saleId);
        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        vm.record();
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        _readExactly(
            _s(base, base + 1, base + 2, tb, tb + 1, SETTINGS_SLOT), "auction, lapsed pause"
        );
        assertEq(a.endTime, pausedAt + 7 days + c.extensionWindow, "the locked window");
        _assertClock(saleId, a);

        IEnglishAuction.AuctionConfig memory longer =
            IEnglishAuction.AuctionConfig(2 days + 9, 1 minutes, 1000);
        vm.prank(setter);
        auction.setConfig(shorter, longer);
        a = auction.auction(saleId);
        assertEq(a.endTime, pausedAt + 7 days + longer.duration, "the governed duration");
        _assertClock(saleId, a);
    }

    /// @dev A federated sale's terms: the registry fee share and the federated flag.
    function test_Layout_FederatedTermsAreTheCompilers() public {
        MockMintTarget fed = _federated();
        vm.record();
        uint256 saleId = auction.start(address(fed), "");
        uint256 base = _saleSlot(saleId);
        uint256 tb = _termsSlot(saleId);
        _wrote(_s(base, tb, tb + 1), "start, federated");
        assertEq(_field(tb + 1, 18, 4), 10_000, "Terms.registryFee");
        assertEq(_field(tb + 1, 22, 1), 1, "Terms.federated");
        vm.record();
        LockedTerms memory lt = auction.lockedTerms(saleId);
        _readExactly(_s(base, tb, tb + 1), "lockedTerms");
        assertEq(lt.feeRecipient, federatedNetwork, "the federated network");
        assertEq(lt.feeShare, 10_000, "the registry fee");
        vm.record();
        assertTrue(auction.isTarget(address(fed)), "federated target");
        _readExactly(
            _s(
                _mapSlot(address(fed), LISTED_SLOT),
                FEDERATION_REGISTRY_SLOT,
                FEDERATION_CODE_HASH_SLOT
            ),
            "isTarget, federated"
        );
    }

    // ------------------------------------------------------------------ helpers

    function _assertClock(uint256 saleId, IEnglishAuction.Auction memory a) internal view {
        (IEnglishAuction.AuctionState state, uint64 end, uint64 pausedAt) =
            auction.auctionClock(saleId);
        assertEq(uint8(state), uint8(a.state), "auctionClock state");
        assertEq(end, a.endTime, "auctionClock end");
        assertEq(pausedAt, a.pausedAt, "auctionClock pause start");
    }

    /// @dev The `size`-byte field at byte `offset` of the auction's word at `slot`.
    function _field(uint256 slot, uint256 offset, uint256 size) internal view returns (uint256) {
        uint256 word = uint256(vm.load(address(auction), bytes32(slot)));
        return (word >> (offset * 8)) & ((1 << (size * 8)) - 1);
    }

    function _mapSlot(address key, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _saleSlot(uint256 saleId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(saleId, SALES_SLOT)));
    }

    /// @dev The sale's terms record, through the terms ID the auction stored in the sale.
    function _termsSlot(uint256 saleId) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(_field(_saleSlot(saleId), 28, 2), TERMS_SLOT)));
    }

    /// @dev The auction's reads since `vm.record()` were exactly `want`, in order: the lens's
    ///      `storageWords` requests (the fallback itself reads no storage).
    function _readExactly(bytes32[] memory want, string memory what) internal view {
        (bytes32[] memory reads,) = vm.accesses(address(auction));
        assertEq(reads, want, what);
    }

    /// @dev The auction wrote each of `want` since `vm.record()`.
    function _wrote(bytes32[] memory want, string memory what) internal view {
        (, bytes32[] memory writes) = vm.accesses(address(auction));
        for (uint256 i; i < want.length; ++i) {
            assertTrue(_has(writes, want[i]), string.concat(what, ": a slot not written"));
        }
    }

    /// @dev The auction wrote `want` since `vm.record()`, and nothing else.
    function _wroteOnly(bytes32[] memory want, string memory what) internal view {
        (, bytes32[] memory writes) = vm.accesses(address(auction));
        _wrote(want, what);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(_has(want, writes[i]), string.concat(what, ": another slot written"));
        }
    }

    function _has(bytes32[] memory list, bytes32 x) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == x) return true;
        }
        return false;
    }

    function _s(uint256 a) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = bytes32(a);
    }

    function _s(uint256 a, uint256 b) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        (l[0], l[1]) = (bytes32(a), bytes32(b));
    }

    function _s(uint256 a, uint256 b, uint256 c) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](3);
        (l[0], l[1], l[2]) = (bytes32(a), bytes32(b), bytes32(c));
    }

    function _s(uint256 a, uint256 b, uint256 c, uint256 d)
        internal
        pure
        returns (bytes32[] memory l)
    {
        l = new bytes32[](4);
        (l[0], l[1], l[2], l[3]) = (bytes32(a), bytes32(b), bytes32(c), bytes32(d));
    }

    function _s(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f)
        internal
        pure
        returns (bytes32[] memory l)
    {
        l = new bytes32[](6);
        (l[0], l[1], l[2], l[3], l[4], l[5]) =
        (bytes32(a), bytes32(b), bytes32(c), bytes32(d), bytes32(e), bytes32(f));
    }
}
