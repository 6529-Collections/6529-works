// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { PRODUCT_STREAM, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The keeper's start helper on the real stack: one transaction starts the 1/1's
///         auction, deploys the work's seller and royalty vaults and opens its record; if the
///         record cannot open, nothing happens at all (no token, no sale, no vault).
contract SaleStarterTest is IntegrationBase {
    SaleStarter internal starter;

    function setUp() public override {
        super.setUp();
        starter = new SaleStarter();
    }

    function test_StartsDeploysTheVaultsAndOpensTheRecord() public {
        Work[] memory works = _one(_work(_actor("starterArtist"), collectionId));
        bytes32 root = _publish(works);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees);
        assertFalse(splitFactory.isWallet(w.seller), "no seller vault before");
        uint256 saleId = starter.start(
            IEnglishAuction(address(auction)),
            address(stream),
            _mintData(root, works, 0),
            works[0].media
        );
        uint256 tokenId = IStream(address(stream)).totalMinted();
        assertEq(saleId, auction.saleIdOf(address(stream), tokenId));
        assertTrue(splitFactory.isWallet(w.seller), "the seller vault");
        if (w.feeShare != 0) assertTrue(splitFactory.isWallet(w.royaltyReceiver), "the royalty");
        assertTrue(records.isOpen(tokenId), "the record is open");
        assertEq(address(starter).balance, 0, "the helper holds nothing");
    }

    /// @dev Fails without the helper's all-or-nothing call: a start made on its own leaves the
    ///      record unopened. Here the record's media do not match the item, so the whole call,
    ///      the start and the vaults included, reverts.
    function test_RevertsAsAWholeWhenTheRecordCannotOpen() public {
        Work[] memory works = _one(_work(_actor("brokenRecordArtist"), collectionId));
        bytes32 root = _publish(works);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees);
        uint256 before = IStream(address(stream)).totalMinted();
        MediaFile[] memory none = new MediaFile[](0);
        bytes memory mintData = _mintData(root, works, 0);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, before + 1));
        starter.start(IEnglishAuction(address(auction)), address(stream), mintData, none);
        assertEq(IStream(address(stream)).totalMinted(), before, "no token was minted");
        assertFalse(splitFactory.isWallet(w.seller), "no vault was deployed");
    }

    /// @dev C-1: a first bid whose payer is the helper itself is refused: the helper could never
    ///      claim its refund. Fails without the change: the auction accepts the DIRECT bid with
    ///      the helper recorded as bidder.
    function test_StartWithBidRefusesTheHelperAsPayer() public {
        Work[] memory works = _one(_work(_actor("helperPayerArtist"), collectionId));
        bytes32 root = _publish(works);
        bytes memory mintData = _mintData(root, works, 0);
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        Payment memory payment = Payment(PaymentMethod.DIRECT, address(starter), amount, 0, 0, "");
        uint256 before = IStream(address(stream)).totalMinted();
        vm.expectRevert(SaleStarter.HelperAsPayer.selector);
        starter.startWithBid{ value: amount }(
            IEnglishAuction(address(auction)),
            address(stream),
            mintData,
            works[0].media,
            address(0),
            payment
        );
        assertEq(IStream(address(stream)).totalMinted(), before, "nothing started");
    }

    /// @dev A first bid paid by a relayed Permit2 transfer, signed by its payer, starts the sale
    ///      with that payer as bidder, deploys the vaults and opens the record; the helper keeps
    ///      nothing.
    function test_StartWithBidByPermit2StartsDeploysAndOpens() public {
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
        Work memory work = _work(_actor("permit2StarterArtist"), collectionId);
        work.item.sale.currency = address(usd);
        Work[] memory works = _one(work);
        bytes32 root = _publish(works);
        bytes memory mintData = _mintData(root, works, 0);
        WorkTerms memory w = economics.newWorkTerms(PRODUCT_STREAM, works[0].item.payees);
        address payer = _actor("permit2StarterBidder");
        uint256 amount = 100e18;
        usd.mint(payer, amount);
        vm.prank(payer);
        usd.approve(PERMIT2, type(uint256).max);
        Payment memory pay = _permit2StartBid(mintData, payer, amount);

        vm.prank(makeAddr("keeper"));
        uint256 saleId = starter.startWithBid(
            IEnglishAuction(address(auction)), address(stream), mintData, works[0].media, payer, pay
        );
        uint256 tokenId = IStream(address(stream)).totalMinted();
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.tokenId, tokenId);
        assertEq(a.bidder, payer, "the payer bids");
        assertEq(a.currency, address(usd));
        assertEq(usd.balanceOf(address(auction)), amount, "the bid is held by the auction");
        assertTrue(splitFactory.isWallet(w.seller), "the seller vault");
        if (w.feeShare != 0) assertTrue(splitFactory.isWallet(w.royaltyReceiver), "the royalty");
        assertTrue(records.isOpen(tokenId), "the record is open");
        assertEq(usd.balanceOf(address(starter)), 0, "the helper holds nothing");
    }

    /// @dev A factory that returns another wallet than the seller the work's terms name is
    ///      refused, and the whole start reverts.
    function test_RevertsAsAWholeWhenTheSellerVaultIsAnother() public {
        Work[] memory works = _one(_work(_actor("vaultMismatchArtist"), collectionId));
        bytes32 root = _publish(works);
        bytes memory mintData = _mintData(root, works, 0);
        uint256 before = IStream(address(stream)).totalMinted();
        address other = makeAddr("otherVault");
        vm.mockCall(
            address(splitFactory),
            abi.encodeCall(ISplitFactory.createWallet, (works[0].item.payees, bytes32(0))),
            abi.encode(other)
        );
        vm.expectRevert(abi.encodeWithSelector(SaleStarter.VaultMismatch.selector, other));
        starter.start(IEnglishAuction(address(auction)), address(stream), mintData, works[0].media);
        assertEq(IStream(address(stream)).totalMinted(), before, "nothing started");
    }

    /// @dev A Permit2 payment whose witness binds the start: token, mint data, recipient, amount
    ///      (as `CuratedSale.t.sol` signs it).
    function _permit2StartBid(bytes memory mintData, address payer, uint256 amount)
        internal
        view
        returns (Payment memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.START_BID_WITNESS,
                address(stream),
                keccak256(mintData),
                payer,
                amount,
                deadline
            )
        );
        bytes32 digest = permit2.witnessDigest(
            address(auction),
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), amount), 0, deadline
            ),
            witness,
            Typehashes.START_BID_WITNESS_TYPE
        );
        return Payment(PaymentMethod.PERMIT2, payer, amount, deadline, 0, _sign(payer, digest));
    }
}
