// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "src/interfaces/IEnglishAuctionClock.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Payment } from "src/interfaces/types/SaleTypes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { EnglishAuctionLens } from "src/sales/EnglishAuctionLens.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";
import { HostileActor, MockMintTarget } from "../../mocks/sales/AuctionMocks.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";
import { EnglishAuctionPreLens } from "./legacy/EnglishAuctionPreLens.sol";

/// @notice The lens refactor changes no answer. The same random sequence of actions runs twice
///         from the same state, once against the auction as it was before the lens
///         (`legacy/EnglishAuctionPreLens.sol`, `main` at 075428f) and once against
///         `EnglishAuction` with `EnglishAuctionLens`, both deployed at the same address with the
///         same arguments. After every action every view that moved to the lens is called on both
///         over a varied state (live, paused, lapsed, ended, settled, cancelled and frozen sales;
///         ETH and ERC-20; 6529 Stream, another listed token and a federated token; pending
///         deliveries, reserves, credits, governance changes, an unknown sale ID, an unknown
///         selector), and the raw returned bytes, revert data included, must be identical.
contract EnglishAuctionLensDifferentialTest is AuctionBase {
    /// @dev Where both builds are installed, one per pass (set by the first).
    address internal AT;
    uint256 internal constant STEPS = 40;

    uint256[] internal sales;
    MockMintTarget internal other;
    MockMintTarget internal fed;
    MockFederationRegistry internal registry;
    HostileActor internal hostile;
    address[] internal actors;

    // ------------------------------------------------------------------ the two builds

    function _install(bool lensBuild) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(stream);
        // The same deployer nonce in both passes, so both builds land at the same address: the
        // lens is deployed in both (the pre-lens build ignores it).
        address lens_ = _lens(address(permit2));
        address deployed = lensBuild
            ? address(
                new EnglishAuction(
                    address(manager),
                    address(escrow),
                    resolver,
                    address(statements),
                    address(permit2),
                    lens_,
                    lens_.codehash,
                    _config(),
                    targets
                )
            )
            : address(
                new EnglishAuctionPreLens(
                    address(manager),
                    address(escrow),
                    resolver,
                    address(statements),
                    address(permit2),
                    _config(),
                    targets
                )
            );
        AT = deployed;
        auction = IEnglishAuctionFull(AT);
        stream.setAdmittedMinter(AT, true);
        _map(AT, DISPUTE_PAUSE, GUARDIAN);
        _map(AT, START_PAUSE, PAUSER);
        _map(AT, START_UNPAUSE, UNPAUSER);
        _map(AT, IEnglishAuction.resume.selector, UNPAUSER);
        _map(AT, IEnglishAuction.cancel.selector, PARAMETER_SETTER);
        _map(AT, IEnglishAuction.setConfig.selector, PARAMETER_SETTER);
        _map(AT, IEnglishAuction.setOpeningBid.selector, PARAMETER_SETTER);
        _map(AT, ISaleAdapter.setTarget.selector, SUCCESSOR_SETTER);
        _map(AT, EnglishAuction.setFederationRegistry.selector, SUCCESSOR_SETTER);
        hostile = new HostileActor();
        address[7] memory list = [alice, bob, carol, address(hostile), seller, network, museum];
        for (uint256 i; i < list.length; ++i) {
            actors.push(list[i]);
        }
    }

    /// @dev States the sequences reach (bit `uint8(state)` for each auction state, then the
    ///      flags below), so the comparison is known to cover them.
    uint256 internal constant SEEN_PENDING = 1 << 8;
    uint256 internal constant SEEN_START_PAUSE = 1 << 9;
    uint256 internal constant SEEN_FROZEN = 1 << 10;
    uint256 internal constant SEEN_RESERVE = 1 << 11;
    uint256 internal constant SEEN_FEDERATED = 1 << 12;
    /// @dev A dispute pause past `MAX_PAUSE` that no call has written down yet.
    uint256 internal constant SEEN_LAPSED = 1 << 13;
    /// @dev A claimable credit.
    uint256 internal constant SEEN_CREDIT = 1 << 14;
    /// @dev A high bid for another recipient.
    uint256 internal constant SEEN_RECIPIENT = 1 << 15;
    /// @dev ACTIVE, PAUSED, ENDED, SETTLED and CANCELLED (bits 1 to 5), and every flag.
    uint256 internal constant SEEN_ALL = 0x3E | SEEN_PENDING | SEEN_START_PAUSE | SEEN_FROZEN
        | SEEN_RESERVE | SEEN_FEDERATED | SEEN_LAPSED | SEEN_CREDIT | SEEN_RECIPIENT;

    /// @dev Runs the sequence for `seed` on one build. Returns, per step, one hash over every
    ///      view's raw answer in order (entry 0 is before the first action), and the states the
    ///      sequence reached.
    function _run(uint256 seed, bool lensBuild, uint256 steps)
        internal
        returns (bytes32[] memory hashes, uint256 seen)
    {
        _install(lensBuild);
        hashes = new bytes32[](steps + 1);
        hashes[0] = _observe();
        if (lensBuild) _checkClock();
        for (uint256 step; step < steps; ++step) {
            uint256 free = _freeMemory();
            _act(uint256(keccak256(abi.encode(seed, step))));
            seen |= _seen();
            _reuseMemory(free);
            hashes[step + 1] = _observe();
            if (lensBuild) _checkClock();
        }
    }

    /// @dev The lens build's `auctionClock`, which the pre-lens build lacks, against its own
    ///      `auction` after every step: the same state and end, or the same revert.
    function _checkClock() internal view {
        uint256 unknown = uint256(keccak256("no such sale"));
        for (uint256 i; i <= sales.length; ++i) {
            uint256 saleId = i < sales.length ? sales[i] : unknown;
            uint256 free = _freeMemory();
            (bool okA, bytes memory a) =
                AT.staticcall(abi.encodeCall(IEnglishAuction.auction, (saleId)));
            (bool okC, bytes memory c) =
                AT.staticcall(abi.encodeCall(IEnglishAuctionClock.auctionClock, (saleId)));
            assertEq(okC, okA, "auctionClock reverts exactly when auction does");
            if (okA) {
                IEnglishAuction.Auction memory x = abi.decode(a, (IEnglishAuction.Auction));
                assertEq(c, abi.encode(x.state, x.endTime), "auction's state and end");
            } else {
                assertEq(c, a, "with the same revert data");
            }
            _reuseMemory(free);
        }
    }

    function _seen() internal view returns (uint256 seen) {
        for (uint256 i; i < sales.length; ++i) {
            IEnglishAuction.Auction memory x = auction.auction(sales[i]);
            // The state's bit in the mask (a literal shifted by the state, as intended).
            // forge-lint: disable-next-line(incorrect-shift)
            seen |= 1 << uint8(x.state);
            if (auction.pendingDelivery(sales[i]) != address(0)) seen |= SEEN_PENDING;
            if (x.bidder == address(0) && x.bid != 0) seen |= SEEN_RESERVE;
            if (x.token == address(fed) && address(fed) != address(0)) seen |= SEEN_FEDERATED;
            if (x.bidder != address(0) && x.recipient != x.bidder) seen |= SEEN_RECIPIENT;
            // Reported resumed (`pausedAt` zero) while the sale's third word still holds the
            // pause (`pausedAt`, bytes 20 to 23; `_sales` is slot 8): a lapse no call wrote down.
            uint256 slot = uint256(keccak256(abi.encode(sales[i], uint256(8)))) + 2;
            if (x.pausedAt == 0 && uint32(uint256(vm.load(AT, bytes32(slot))) >> 160) != 0) {
                seen |= SEEN_LAPSED;
            }
        }
        for (uint256 j; j < actors.length; ++j) {
            if (auction.claimable(actors[j], ETH) + auction.claimable(actors[j], address(usd)) != 0)
            {
                seen |= SEEN_CREDIT;
            }
        }
        if (auction.paused()) seen |= SEEN_START_PAUSE;
        if (!allowlist.isActive(address(usd)) || !allowlist.isActive(ETH)) seen |= SEEN_FROZEN;
    }

    /// @dev Both passes from the same state; returns the states the lens pass reached.
    function _compare(uint256 seed, uint256 steps) internal returns (uint256 reached) {
        uint256 snapshot = vm.snapshotState();
        (bytes32[] memory before,) = _run(seed, false, steps);
        address legacyAt = AT;
        vm.revertToState(snapshot);
        bytes32[] memory after_;
        (after_, reached) = _run(seed, true, steps);
        assertEq(AT, legacyAt, "both builds at one address");
        assertTrue(auction.lens().code.length != 0, "the lens build ran second");
        vm.revertToStateAndDelete(snapshot);
        for (uint256 i; i < after_.length; ++i) {
            assertEq(after_[i], before[i], string.concat("answers after step ", vm.toString(i)));
        }
    }

    function _freeMemory() internal pure returns (uint256 free) {
        assembly ("memory-safe") {
            free := mload(0x40)
        }
    }

    /// @dev Nothing allocated since `free` is used again: reuse the memory, so long runs stay
    ///      cheap.
    function _reuseMemory(uint256 free) internal pure {
        assembly ("memory-safe") {
            mstore(0x40, free)
        }
    }

    /// @notice A random sequence of actions per run; every moved view matches after each.
    function testFuzz_EveryMovedViewMatchesThePreLensBuild(uint256 seed) public {
        _compare(seed, STEPS);
    }

    /// @notice Longer fixed sequences, so the deep states (a lapsed pause, a cancel, a frozen
    ///         sale's exit) are reached on every run.
    function test_EveryMovedViewMatchesThePreLensBuild_LongSequences() public {
        uint256 reached;
        for (uint256 seed; seed < 4; ++seed) {
            reached |= _compare(seed, 120);
        }
        assertEq(reached & SEEN_ALL, SEEN_ALL, "every state and flag was compared");
    }

    // ------------------------------------------------------------------ observation

    function _record(bytes32 acc, bytes memory data) internal view returns (bytes32) {
        uint256 free = _freeMemory();
        (bool ok, bytes memory ret) = AT.staticcall(data);
        acc = keccak256(abi.encode(acc, ok, ret));
        _reuseMemory(free);
        return acc;
    }

    function _observe() internal view returns (bytes32 n) {
        uint256 unknown = uint256(keccak256("no such sale"));
        for (uint256 i; i <= sales.length; ++i) {
            uint256 saleId = i < sales.length ? sales[i] : unknown;
            n = _record(n, abi.encodeCall(IEnglishAuction.auction, (saleId)));
            n = _record(n, abi.encodeCall(IEnglishAuction.lockedTerms, (saleId)));
            n = _record(n, abi.encodeCall(IEnglishAuction.minimumBid, (saleId)));
            n = _record(n, abi.encodeCall(IEnglishAuction.pendingDelivery, (saleId)));
        }
        n = _record(n, abi.encodeCall(IEnglishAuction.config, ()));
        n = _record(n, abi.encodeCall(ISaleAdapter.paused, ()));
        n = _record(n, abi.encodeCall(ISaleAdapter.federationRegistry, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.federationRegistryCodeHash, ()));
        n = _record(n, abi.encodeCall(IEnglishAuction.escrow, ()));
        n = _record(n, abi.encodeCall(IEnglishAuction.statementLog, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.allowlist, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.economicsResolver, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.permit2, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.MAX_PAUSE, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.OPENING_BID_FLOORS, ()));
        n = _record(n, abi.encodeCall(IEnglishAuctionFull.PAYOUT_GAS, ()));
        address[4] memory currencies = [ETH, address(usd), address(0xC0FFEE), address(stream)];
        for (uint256 i; i < currencies.length; ++i) {
            n = _record(n, abi.encodeCall(IEnglishAuction.openingBid, (currencies[i])));
            for (uint256 j; j < actors.length; ++j) {
                n = _record(n, abi.encodeCall(ISaleAdapter.claimable, (actors[j], currencies[i])));
            }
        }
        address[4] memory tokens = [address(stream), address(other), address(fed), address(usd)];
        for (uint256 i; i < tokens.length; ++i) {
            n = _record(n, abi.encodeCall(ISaleAdapter.isTarget, (tokens[i])));
            n = _record(n, abi.encodeCall(IEnglishAuction.saleIdOf, (tokens[i], i * 7 + 1)));
        }
        bytes4[8] memory ids = [
            type(IEnglishAuction).interfaceId,
            type(IEnglishAuctionClock).interfaceId,
            type(ISaleAdapter).interfaceId,
            type(IERC721Receiver).interfaceId,
            type(IERC165).interfaceId,
            bytes4(0xffffffff),
            bytes4(0),
            type(IFederationRegistry).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            n = _record(n, abi.encodeCall(IERC165.supportsInterface, (ids[i])));
        }
        // Calls neither build answers: an unknown selector, short and empty calldata.
        n = _record(n, abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1)));
        n = _record(n, hex"12");
        n = _record(n, "");
        return n;
    }

    // ------------------------------------------------------------------ actions

    function _pick(uint256 r) internal view returns (bool, uint256) {
        if (sales.length == 0) return (false, 0);
        return (true, sales[r % sales.length]);
    }

    function _act(uint256 r) internal {
        uint256 op = r % 24;
        uint256 a = r >> 8;
        if (op == 0) {
            _tryStart(address(stream), ETH, false, a);
        } else if (op == 1) {
            _tryStart(address(stream), address(usd), false, a);
        } else if (op == 2) {
            _tryStart(address(stream), ETH, true, a);
        } else if (op == 3 || op == 4 || op == 5) {
            _tryBid(a);
        } else if (op == 6 || op == 7) {
            vm.warp(block.timestamp + 1 + a % 2 days);
        } else if (op == 8) {
            vm.warp(block.timestamp + 1 + a % 9 days);
        } else if (op == 9) {
            (bool found, uint256 saleId) = _pick(a);
            if (found) try auction.settle(saleId) { } catch { }
        } else if (op == 10) {
            (bool found, uint256 saleId) = _pick(a);
            vm.prank(guardian);
            if (found) try auction.pause(saleId, keccak256("dispute")) { } catch { }
        } else if (op == 11) {
            _tryResumeOrCancel(a);
        } else if (op == 12) {
            (bool found, uint256 saleId) = _pick(a);
            if (!found) return;
            address bidder = auction.auction(saleId).bidder;
            vm.prank(bidder == address(0) ? alice : bidder);
            try auction.withdrawBid(saleId) { } catch { }
        } else if (op == 13) {
            _tryClaimDelivery(a);
        } else if (op == 14) {
            address actor = actors[a % actors.length];
            vm.prank(actor);
            try auction.claim(a % 2 == 0 ? ETH : address(usd), actor) { } catch { }
        } else if (op == 15) {
            // Each value is reduced below 2^32 before its cast.
            // forge-lint: disable-start(unsafe-typecast)
            IEnglishAuction.AuctionConfig memory next = IEnglishAuction.AuctionConfig(
                uint32(1 hours + a % 3 days),
                uint32(1 minutes + (a >> 32) % 1 hours),
                1_000 + uint32((a >> 64) % 99_000)
            );
            // forge-lint: disable-end(unsafe-typecast)
            IEnglishAuction.AuctionConfig memory current = auction.config();
            vm.prank(setter);
            try auction.setConfig(current, next) { } catch { }
        } else if (op == 16) {
            address currency = a % 2 == 0 ? ETH : address(usd);
            uint256 current = auction.openingBid(currency);
            vm.prank(setter);
            try auction.setOpeningBid(currency, current, (a >> 8) % 2 ether) { } catch { }
        } else if (op == 17) {
            if (address(other) == address(0)) {
                other = _listedToken(a % 2 == 0 ? ETH : address(usd));
            }
            _tryStart(address(other), address(0), false, a);
        } else if (op == 18) {
            if (address(fed) == address(0)) {
                fed = _federated();
                registry = MockFederationRegistry(auction.federationRegistry());
            }
            _tryStart(address(fed), address(0), false, a);
        } else if (op == 19) {
            if (address(fed) == address(0)) return;
            registry.setStatus(
                address(fed),
                a % 2 == 0
                    ? IFederationRegistry.Status.DELISTED
                    : IFederationRegistry.Status.ACTIVE,
                bytes32(0)
            );
        } else if (op == 20) {
            address asset = a % 4 == 0 ? ETH : address(usd);
            if (a % 3 == 0) {
                (,, uint64 revision) = allowlist.assetConfig(asset);
                try allowlist.admitAsset(asset, revision, asset == ETH ? ETH_FLOOR : USD_FLOOR) { }
                    catch { }
            } else {
                try allowlist.deprecateAsset(asset) { } catch { }
            }
        } else if (op == 21) {
            vm.prank(a % 2 == 0 ? pauser : unpauser);
            if (a % 2 == 0) {
                try auction.pause() { } catch { }
            } else {
                try auction.unpause() { } catch { }
            }
        } else if (op == 22) {
            stream.setCreatorNow(a % 3 == 0 ? address(0) : actors[a % actors.length]);
            if (sales.length != 0) stream.setLockedCreator(1 + a % 4, address(0));
            resolver.setMuseumAccount(a % 5 == 0 ? address(hostile) : museum);
        } else {
            stream.setMode(
                a % 2 == 0 ? MockMintTarget.Mode.REJECT_TRANSFERS : MockMintTarget.Mode.NORMAL
            );
            hostile.configure(HostileActor.Behaviour(a % 3), HostileActor.Behaviour((a >> 4) % 5));
        }
    }

    function _tryStart(address token, address currency, bool withBid, uint256 a) internal {
        if (token == address(stream)) stream.setTerms(_terms(currency));
        if (!withBid) {
            try auction.start(token, "") returns (uint256 saleId) {
                sales.push(saleId);
            } catch { }
            return;
        }
        uint256 amount = 1 + a % 3 ether;
        address payer = actors[a % 3];
        vm.deal(payer, amount);
        vm.prank(payer);
        try auction.startWithBid{ value: amount }(
            token, "", a % 2 == 0 ? address(0) : address(hostile), _direct(payer, amount)
        ) returns (
            uint256 saleId
        ) {
            sales.push(saleId);
        } catch { }
    }

    function _tryBid(uint256 a) internal {
        (bool found, uint256 saleId) = _pick(a);
        if (!found) return;
        try auction.minimumBid(saleId) returns (uint256 minimum) {
            uint256 amount = minimum + (a >> 16) % 1 ether;
            if (amount > type(uint96).max) return;
            address payer = actors[(a >> 8) % 3];
            address recipient = (a >> 12) % 2 == 0 ? address(hostile) : address(0);
            Payment memory p = _direct(payer, amount);
            if (auction.auction(saleId).currency == ETH) {
                vm.deal(payer, amount);
                vm.prank(payer);
                try auction.bid{ value: amount }(saleId, recipient, p) { } catch { }
            } else {
                usd.mint(payer, amount);
                vm.startPrank(payer);
                usd.approve(AT, amount);
                try auction.bid(saleId, recipient, p) { } catch { }
                vm.stopPrank();
            }
        } catch { }
    }

    function _tryResumeOrCancel(uint256 a) internal {
        (bool found, uint256 saleId) = _pick(a);
        if (!found) return;
        if (a % 2 == 0) {
            vm.prank(unpauser);
            try auction.resume(saleId) { } catch { }
            return;
        }
        IEnglishAuction.Auction memory x = auction.auction(saleId);
        if (x.token != address(stream) || x.state != IEnglishAuction.AuctionState.PAUSED) return;
        bytes32 outcome = _recordOutcome(x.tokenId);
        vm.prank(setter);
        try auction.cancel(saleId, outcome) { } catch { }
    }

    function _tryClaimDelivery(uint256 a) internal {
        (bool found, uint256 saleId) = _pick(a);
        if (!found) return;
        address pending = auction.pendingDelivery(saleId);
        if (pending == address(0)) return;
        address to = actors[a % 3];
        if (pending == address(hostile)) {
            try hostile.execute(
                AT, 0, abi.encodeCall(IEnglishAuction.claimDelivery, (saleId, to))
            ) { }
                catch { }
        } else {
            vm.prank(pending);
            try auction.claimDelivery(saleId, to) { } catch { }
        }
    }
}
