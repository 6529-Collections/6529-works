// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { CoreFixture } from "test/mocks/core/CoreFixture.sol";
import {
    MockIndependentToken,
    MockIndependentStreamPolicy,
    MockMintPolicy,
    MockStatementLog
} from "./AuctionMocks.sol";

/// @notice The English auction on the real core (`CoreFixture`: the real `Stream6529`,
///         `StreamDirectory6529` and `StreamWorkFacts6529`), the real economics resolver, asset
///         allowlist, split ledger and revenue escrow, a mock mint policy for 6529 Stream and a
///         mock Independent Stream module with one Independent Stream token. The test contract is
///         the network.
abstract contract AuctionFixture is CoreFixture {
    SplitLedger internal ledger;
    RevenueEscrow internal escrow;
    AssetAllowlist internal allowlist;
    EconomicsResolver internal economics;
    MockStatementLog internal statements;
    MockMintPolicy internal policy;
    MockIndependentStreamPolicy internal independentStream;
    MockIndependentToken internal ind;
    EnglishAuction internal auction;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal museum = makeAddr("museum");
    address internal seller = makeAddr("seller");
    address internal indSeller = makeAddr("indSeller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint32 internal constant DURATION = 1 days;
    uint32 internal constant WINDOW = 15 minutes;
    uint32 internal constant SHARE = 5_000;
    uint32 internal constant REFUSAL_GAS = 3_000_000;
    uint32 internal constant FEE_SHARE = 10_000;
    uint32 internal constant IND_FEE_SHARE = 5_000;
    uint256 internal constant FLOOR = 0.001 ether;

    function setUp() public virtual override {
        super.setUp();
        ledger = new SplitLedger(IArtistPayoutResolver(address(directory)), address(this));
        escrow = new RevenueEscrow(address(manager), ISplitFactory(address(ledger)));
        allowlist = new AssetAllowlist(address(manager), FLOOR);
        economics = new EconomicsResolver(
            address(manager),
            allowlist,
            ISplitFactory(address(ledger)),
            feeRecipient,
            museum,
            CC0_TEXT
        );
        statements = new MockStatementLog();
        policy = new MockMintPolicy(seller, feeRecipient, FEE_SHARE);
        auction = new EnglishAuction(
            address(manager),
            address(stream),
            IDirectory(address(directory)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(statements)),
            address(policy),
            IEnglishAuction.AuctionConfig(DURATION, WINDOW, SHARE, REFUSAL_GAS)
        );
        stream.setModuleDelay(0);
        stream.addMinter(address(auction));

        // The Independent Stream module: the directory's INDEPENDENT_STREAM slot, one Independent
        // Stream token.
        independentStream = new MockIndependentStreamPolicy(indSeller, feeRecipient, IND_FEE_SHARE);
        directory.setModuleDelay(0);
        directory.proposeModule(Slots.INDEPENDENT_STREAM, address(independentStream));
        directory.activateModule(Slots.INDEPENDENT_STREAM);
        ind = new MockIndependentToken(address(facts), IDirectory(address(directory)));
        independentStream.setMinter(address(ind), address(auction), true);

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    // ------------------------------------------------------------------------- helpers

    function _start(uint256 n) internal returns (uint256 saleId) {
        return auction.start(address(stream), abi.encode(n));
    }

    function _startInd(uint256 n) internal returns (uint256 saleId) {
        return auction.start(address(ind), abi.encode(n));
    }

    function _bid(address who, uint256 saleId, uint256 amount) internal {
        vm.prank(who);
        auction.bid{ value: amount }(saleId, address(0));
    }

    function _end(uint256 saleId) internal {
        vm.warp(auction.auction(saleId).endTime);
    }

    function _tokenId(uint256 saleId) internal view returns (uint256) {
        return auction.auction(saleId).tokenId;
    }

    function _state(uint256 saleId) internal view returns (IEnglishAuction.AuctionState) {
        return auction.auction(saleId).state;
    }

    /// @dev Standing bids of unsettled sales plus credits: what the auction must hold.
    function _owed(uint256[] memory saleIds, address[] memory accounts)
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i; i < saleIds.length; ++i) {
            IEnglishAuction.Auction memory a = auction.auction(saleIds[i]);
            if (
                a.bidder != address(0) && a.state != IEnglishAuction.AuctionState.SETTLED
                    && a.state != IEnglishAuction.AuctionState.CANCELLED
            ) total += a.bid;
        }
        for (uint256 i; i < accounts.length; ++i) {
            total += auction.claimable(accounts[i]);
        }
    }

    function _setOpeningBid(uint256 bid) internal {
        (,, uint64 revision) = allowlist.assetConfig(address(0));
        allowlist.setOpeningBid(address(0), revision, bid);
    }
}
