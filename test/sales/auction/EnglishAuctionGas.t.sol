// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { CURRENCY_DEFAULT, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionFormat,
    EditionTerms,
    ItemKind,
    License,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { MockArtistResolver } from "../../mocks/EconomicsMocks.sol";
import {
    LeanArtistRegistry,
    LeanEconomicsResolver,
    LeanPackageRegistry,
    LeanStream
} from "../../mocks/auction/LeanStartStack.sol";

/// @dev End-to-end `start` gas (PR #10 review decision D5) against the lean model of the decided
///      start path in `LeanStartStack.sol`, over the real AccessManager, asset allowlist and
///      split factory. Items name `CURRENCY_DEFAULT`, so the auction resolves the product default
///      (ETH) at start. The reported figure is the whole transaction: 21,000 intrinsic, the
///      calldata (EIP-2028, with the EIP-7623 floor) and the execution measured with every
///      contract cooled first, including the cold call into the auction (about 2,600 gas a real
///      transaction does not pay, since its target is warm).
contract EnglishAuctionGasTest is Test {
    uint256 internal constant ITEMS = 16;
    /// @dev E1 (ADR 0003): the steady-state gate, amended from 300K.
    uint256 internal constant START_GATE = 350_000;
    uint256 internal constant REDESIGN_THRESHOLD = 400_000;
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev One fresh slot (22,100), the terms lookup, the allowlist reads and the event.
    uint256 internal constant AUCTION_SHARE_BUDGET = 50_000;
    /// @dev The first `startWithBid` after governance changes the config, an opening bid or a
    ///      floor writes up to two new terms records (the start record and the one with the
    ///      floor), once per change: a bound, not the steady-state gate (PR #33 review).
    uint256 internal constant FIRST_AFTER_CHANGE_BOUND = 450_000;

    AccessManager internal manager;
    AssetAllowlist internal allowlist;
    SplitFactory internal factory;
    LeanArtistRegistry internal artists;
    LeanPackageRegistry internal registry;
    LeanEconomicsResolver internal resolver;
    LeanStream internal stream;
    EnglishAuction internal auction;
    address internal network = makeAddr("network");

    uint256 internal artistPk = 0xA27157;
    uint256 internal otherArtistPk = 0x07E2;
    bytes32 internal root;
    bytes32[] internal leaves;
    PackageItem[] internal items;

    function setUp() public {
        manager = new AccessManager(address(this));
        allowlist = new AssetAllowlist(address(manager), 0.001 ether);
        factory = new SplitFactory(new MockArtistResolver(), new ReleaseVerifier());
        artists = new LeanArtistRegistry();
        registry = new LeanPackageRegistry(artists);
        resolver = new LeanEconomicsResolver(factory, network);
        stream = new LeanStream(registry, resolver, artists);
        registry.bind(address(stream));
        address[] memory targets = new address[](1);
        targets[0] = address(stream);
        auction = new EnglishAuction(
            address(manager),
            address(new RevenueEscrow(address(manager), factory)),
            allowlist,
            address(new StatementLog(address(manager), address(0), bytes32(0))),
            address(0),
            IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 5_000),
            targets
        );
        stream.setAdmittedMinter(address(auction), true);
        allowlist.setDefaultCurrency(PRODUCT_STREAM, 0, address(0));

        address artist = vm.addr(artistPk);
        address other = vm.addr(otherArtistPk);
        artists.set(uint160(artist), artist);
        artists.set(uint160(other), other);
        for (uint256 i; i < ITEMS; ++i) {
            items.push();
            _item(items[i], i, i % 2 == 0 ? artist : other, i < 8 ? 1 : 2);
            leaves.push(WorksHashing.leaf(WorksHashing.itemHash(items[i])));
        }
        root = _root(leaves);
        registry.approve(root);
        registry.accept(root, artist);
        registry.accept(root, other);
    }

    /// @dev Steady state: Stream, the collection and the artist's move nonces have been used
    ///      before, and the auction already holds another live token.
    function test_StartGas_SteadyState() public {
        _startItem(0, 1, artistPk);
        _priorBid(_startItem(1, 2, otherArtistPk));
        uint256 total = _measureStart(2, 3, artistPk, "steady state");
        assertLe(total, START_GATE, "steady-state start gate (E1)");
    }

    /// @dev The first work of a new artist in a new collection while custody is empty: the
    ///      artist's nonce word, the collection serial and the auction's ERC-721 balance are all
    ///      written from zero.
    function test_StartGas_FirstWorkOfANewArtistAndCollection() public {
        _startItem(1, 1, otherArtistPk);
        _settleAway(_saleOf(1));
        uint256 total = _measureStart(8, 2, artistPk, "new artist, new collection");
        assertLe(total, REDESIGN_THRESHOLD, "above 400K the start path needs a redesign (D5)");
    }

    /// @dev L-4: the 350K steady-state gate covers `startWithBid` too (a first bid for oneself
    ///      writes one more slot: the bidder with the packed bid).
    function test_StartWithBidGas_SteadyState() public {
        _startItem(0, 1, artistPk);
        _priorBid(_startItem(1, 2, otherArtistPk));
        uint256 total = _measureStartWithBid("startWithBid steady state, whole transaction");
        assertLe(total, START_GATE, "steady-state start gate (E1) covers startWithBid");
    }

    /// @dev PR #33 review: the first `startWithBid` after a real config change writes both a
    ///      new start record and a new floored record.
    function test_StartWithBidGas_FirstAfterAConfigChange() public {
        _startItem(0, 1, artistPk);
        _priorBid(_startItem(1, 2, otherArtistPk));
        auction.setConfig(
            auction.config(), IEnglishAuction.AuctionConfig(24 hours, 15 minutes, 6_000)
        );
        uint256 total = _measureStartWithBid("startWithBid after a config change, whole tx");
        assertLe(total, FIRST_AFTER_CHANGE_BOUND, "one-off cost after a config change");
    }

    /// @dev PR #33 review: the first `startWithBid` after a real floor change reuses the start
    ///      record and writes a new floored record.
    function test_StartWithBidGas_FirstAfterAFloorChange() public {
        _startItem(0, 1, artistPk);
        _priorBid(_startItem(1, 2, otherArtistPk));
        (,, uint64 revision) = allowlist.assetConfig(address(0));
        allowlist.setIncrementFloor(address(0), revision, 0.002 ether);
        uint256 total = _measureStartWithBid("startWithBid after a floor change, whole tx");
        assertLe(total, FIRST_AFTER_CHANGE_BOUND, "one-off cost after a floor change");
    }

    /// @dev The steady state, but with no other token in custody (the adapter's ERC-721 balance
    ///      is written from zero), and the first and second bids of a sale.
    function test_StartAndBidGas_Profile() public {
        _priorBid(_startItem(0, 1, artistPk));
        _settleAway(_saleOf(1));
        _startItem(1, 2, otherArtistPk);
        _settleAway(_saleOf(2));
        _measureStart(2, 3, artistPk, "steady state, idle custody");
        uint256 saleId = _saleOf(3);
        address b1 = makeAddr("b1");
        address b2 = makeAddr("b2");
        vm.deal(b1, 1 ether);
        vm.deal(b2, 2 ether);
        _coolAll();
        vm.prank(b1);
        uint256 before = gasleft();
        auction.bid{ value: 1 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, b1, 1 ether, 0, 0, "")
        );
        console2.log("first bid, execution (cold)", before - gasleft());
        _coolAll();
        vm.prank(b2);
        before = gasleft();
        auction.bid{ value: 2 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, b2, 2 ether, 0, 0, "")
        );
        console2.log("second bid, execution (cold)", before - gasleft());
    }

    /// @dev The auction's own part: everything except the token's `mint`, measured by
    ///      subtracting the mint call's gas reported by a probe on a fresh copy of the state.
    function test_StartGas_AuctionShare() public {
        _startItem(0, 1, artistPk);
        _priorBid(_startItem(1, 2, otherArtistPk));
        bytes memory data = _mintData(2, 3, artistPk);
        uint256 snapshot = vm.snapshotState();
        _coolAll();
        vm.prank(address(auction));
        uint256 before = gasleft();
        stream.mint(address(auction), 0, 1, data);
        uint256 mintGas = before - gasleft();
        vm.revertToState(snapshot);
        _coolAll();
        before = gasleft();
        auction.start(address(stream), data);
        uint256 startGas = before - gasleft();
        console2.log("start execution (cold call into the auction)", startGas);
        console2.log("  token mint, registry, economics", mintGas);
        console2.log("  auction share", startGas - mintGas);
        assertLe(startGas - mintGas, AUCTION_SHARE_BUDGET, "the auction's own share of start");
    }

    /// @dev Settlement with every fallback taken stays far below the EIP-7825 cap.
    function test_SettleGas_FitsTheTransactionCap() public {
        uint256 saleId = _startItem(0, 1, artistPk);
        address bidder = makeAddr("bidder");
        vm.deal(bidder, 1 ether);
        vm.prank(bidder);
        auction.bid{ value: 1 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
        );
        vm.warp(block.timestamp + 1 days);
        bytes memory callData = abi.encodeCall(auction.settle, (saleId));
        _coolAll();
        uint256 before = gasleft();
        (bool ok,) = address(auction).call(callData);
        uint256 used = before - gasleft();
        assertTrue(ok);
        uint256 total = 21_000 + _calldataCost(callData) + used;
        console2.log("settle, whole transaction", total);
        assertLt(total, TX_GAS_CAP / 4);
    }

    // ---------------------------------------------------------------------------- helpers

    function _measureStart(uint256 index, uint256 nonce, uint256 pk, string memory label)
        internal
        returns (uint256 total)
    {
        bytes memory callData =
            abi.encodeCall(auction.start, (address(stream), _mintData(index, nonce, pk)));
        _coolAll();
        uint256 before = gasleft();
        (bool ok, bytes memory result) = address(auction).call(callData);
        uint256 used = before - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        (uint256 standard, uint256 floor) = _calldata(callData);
        total = 21_000 + standard + used;
        if (21_000 + floor > total) total = 21_000 + floor;
        console2.log(label);
        console2.log("  calldata bytes", callData.length);
        console2.log("  execution (incl. a cold call into the auction)", used);
        console2.log("  whole transaction", total);
        console2.log("  steady-state gate", START_GATE);
    }

    /// @dev A bid on an earlier sale: in steady state the terms record with the current
    ///      increment floor exists, since some earlier first bid locked it (E2). The first bid
    ///      after a deployment, a config change or a floor change creates it once
    ///      (`test_FirstBidGas_CreatingItsTermsRecord`, and the bounded `startWithBid` tests).
    function _priorBid(uint256 saleId) internal {
        address bidder = makeAddr("priorBidder");
        vm.deal(bidder, 1 ether);
        vm.prank(bidder);
        auction.bid{ value: 1 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
        );
    }

    /// @dev A first bid on a sale whose terms have no floored record yet (here, the first bid
    ///      after deployment) writes it once: two words, its key and the counter.
    function test_FirstBidGas_CreatingItsTermsRecord() public {
        uint256 saleId = _startItem(0, 1, artistPk);
        address bidder = makeAddr("firstEver");
        vm.deal(bidder, 1 ether);
        _coolAll();
        vm.prank(bidder);
        uint256 before = gasleft();
        auction.bid{ value: 1 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
        );
        console2.log("first bid creating its terms record, execution (cold)", before - gasleft());
    }

    /// @dev Whole-transaction gas of a `startWithBid` of item 2 by a fresh bidder, everything
    ///      cooled first.
    function _measureStartWithBid(string memory label) internal returns (uint256 total) {
        address bidder = makeAddr("gasBidder");
        vm.deal(bidder, 1 ether);
        bytes memory callData = abi.encodeCall(
            auction.startWithBid,
            (
                address(stream),
                _mintData(2, 3, artistPk),
                address(0),
                Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
            )
        );
        _coolAll();
        vm.prank(bidder);
        uint256 before = gasleft();
        (bool ok, bytes memory result) = address(auction).call{ value: 1 ether }(callData);
        uint256 used = before - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        (uint256 standard, uint256 floor) = _calldata(callData);
        total = 21_000 + standard + used;
        if (21_000 + floor > total) total = 21_000 + floor;
        console2.log(label, total);
    }

    function _startItem(uint256 index, uint256 nonce, uint256 pk) internal returns (uint256) {
        return auction.start(address(stream), _mintData(index, nonce, pk));
    }

    function _saleOf(uint256 tokenId) internal view returns (uint256) {
        return auction.saleIdOf(address(stream), tokenId);
    }

    function _settleAway(uint256 saleId) internal {
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
    }

    function _mintData(uint256 index, uint256 nonce, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        PackageItem memory item = items[index];
        bytes32 itemHash = WorksHashing.itemHash(item);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.moveDigest(root, itemHash, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        MoveAuthorization memory move =
            MoveAuthorization(nonce, deadline, abi.encodePacked(r, s, v));
        return abi.encode(StreamMintRequest(root, item, _proof(leaves, index), move));
    }

    function _item(PackageItem storage item, uint256 i, address artist, uint256 collection)
        internal
    {
        item.kind = ItemKind.ORIGINAL;
        item.collectionId = collection;
        item.contentHash = sha256(abi.encode("media", i));
        item.mediaHash = keccak256(abi.encode("media list", i));
        item.recordFileId = keccak256(abi.encode("record", i));
        item.parties.push(Party(artist, PartyRole.ARTIST));
        item.payees.push(ISplitWallet.Payee(uint160(artist), address(0), 100_000));
        item.license = License("CC0-1.0", keccak256("CC0 text"));
        item.seedPolicy = SeedPolicy.NONE;
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_DEFAULT, "");
        item.edition = EditionTerms(EditionFormat.FIXED, 0, 0, 0, address(0), bytes32(0), "");
    }

    function _coolAll() internal {
        vm.cool(address(auction));
        vm.cool(address(stream));
        vm.cool(address(registry));
        vm.cool(address(artists));
        vm.cool(address(resolver));
        vm.cool(address(factory));
        vm.cool(address(allowlist));
        vm.cool(address(manager));
    }

    function _calldata(bytes memory data) internal pure returns (uint256 standard, uint256 floor) {
        uint256 zeros;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        uint256 nonzero = data.length - zeros;
        standard = zeros * 4 + nonzero * 16;
        floor = (zeros + nonzero * 4) * 10;
    }

    function _calldataCost(bytes memory data) internal pure returns (uint256 standard) {
        (standard,) = _calldata(data);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _root(bytes32[] memory level) internal pure returns (bytes32) {
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i; i < next.length; ++i) {
                next[i] = _hashPair(level[2 * i], level[2 * i + 1]);
            }
            level = next;
        }
        return level[0];
    }

    function _proof(bytes32[] memory level, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        proof = new bytes32[](4);
        for (uint256 depth; level.length > 1; ++depth) {
            proof[depth] = level[index ^ 1];
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i; i < next.length; ++i) {
                next[i] = _hashPair(level[2 * i], level[2 * i + 1]);
            }
            level = next;
            index /= 2;
        }
    }
}
