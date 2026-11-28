// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { console2 } from "forge-std/console2.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";
import { Roles } from "src/governance/Roles.sol";
import { Work } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import {
    MoveAuthorization,
    PackageItem,
    PartyAcceptance,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SaleStarter } from "src/sales/SaleStarter.sol";
import { CurationHelpers } from "test/curation/CurationBase.sol";
import { CurationArtistRegistryMock } from "test/mocks/curation/CurationArtistRegistryMock.sol";
import { AuctionFixture } from "./AuctionFixture.sol";

/// @notice The auction with the real package registry as 6529 Stream's policy, the real
///         economics resolver and split ledger: a whole sale, the vaults `SaleStarter` deploys,
///         and the gas of `start`, `startWithBid`, `bid` and `settle` (execution gas of the
///         call in a Foundry test: no 21,000 base or calldata; the integration step measures
///         whole transactions).
contract EnglishAuctionEndToEndTest is AuctionFixture, CurationHelpers {
    PackageRegistry internal registry;
    Eip712CurationVerifier internal verifier;
    CurationArtistRegistryMock internal artists;
    uint256 internal constant SIGNER_KEY = 0xC1;
    uint256 internal constant LEAD_KEY = 0xA1;
    address internal lead;
    bytes32 internal root;
    bytes32[][] internal proofs;

    function setUp() public override {
        super.setUp();
        lead = vm.addr(LEAD_KEY);
        artists = new CurationArtistRegistryMock();
        verifier = new Eip712CurationVerifier(address(manager));
        registry = new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(
                new StreamDirectory6529(
                    address(manager), address(artists), address(0), address(0), address(0)
                )
            ),
            IEconomicsResolver(address(economics)),
            address(0),
            IWorkFacts(address(facts)).cc0TextFileId(),
            address(0)
        );
        artists.bindPackageRegistry(address(registry));
        registry.bindStream(address(stream));
        manager.grantRole(Roles.CURATION_SIGNER, vm.addr(SIGNER_KEY), 0);
        auction.setStreamPolicy(address(policy), address(registry));

        PackageItem[] memory list = new PackageItem[](4);
        for (uint256 i; i < 4; ++i) {
            list[i] = _item(lead, keccak256(abi.encode("sha", i)));
        }
        bytes32[][] memory p;
        (root, p) = _tree(list);
        for (uint256 i; i < 4; ++i) {
            proofs.push(p[i]);
        }
        bytes32 digest = verifier.approvalDigest(
            root, keccak256("evidence"), verifier.signerEpoch(vm.addr(SIGNER_KEY))
        );
        registry.registerPackage(
            root, keccak256("evidence"), abi.encode(vm.addr(SIGNER_KEY), _sig(SIGNER_KEY, digest))
        );
        PartyAcceptance memory a = PartyAcceptance(
            lead, keccak256(abi.encode("profile", lead)), 0, uint64(block.timestamp + 1 days)
        );
        registry.acceptPackage(
            root, a, _pf(LEAD_KEY, _sig(LEAD_KEY, registry.acceptanceDigest(root, a)))
        );
    }

    function _itemOf(uint256 i) internal view returns (PackageItem memory) {
        return _item(lead, keccak256(abi.encode("sha", i)));
    }

    function _request(uint256 i) internal view returns (bytes memory) {
        PackageItem memory item = _itemOf(i);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 h = WorksHashing.itemHash(item);
        MoveAuthorization memory move = MoveAuthorization(
            i, deadline, _pf(LEAD_KEY, _sig(LEAD_KEY, registry.moveDigest(root, h, i, deadline)))
        );
        return abi.encode(StreamMintRequest(root, item, proofs[i], move));
    }

    function test_EndToEnd_AWholeSaleThroughThePackageRegistry() public {
        uint256 saleId = auction.start(address(stream), _request(0));
        uint256 tokenId = _tokenId(saleId);
        Work memory w = stream.workOf(tokenId);
        assertEq(w.itemHash, WorksHashing.itemHash(_itemOf(0)));
        assertEq(w.artistId, uint160(lead));
        assertEq(w.royaltyRate, 6_529);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.feeShare, 25_000);
        assertEq(a.seller, ledger.walletFor(_itemOf(0).payees, bytes32(0)));
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(tokenId), alice);
        assertEq(a.seller.balance, 0.75 ether);
        assertEq(feeRecipient.balance, 0.25 ether);
        // The same item can never start again.
        bytes memory again = _request(0);
        vm.expectRevert();
        auction.start(address(stream), again);
    }

    function test_SaleStarter_DeploysBothVaultsAndOpensTheRecord() public {
        SaleStarter starter = new SaleStarter();
        vm.mockCall(address(facts), abi.encodeWithSelector(IWorkFacts.open.selector), "");
        bytes memory request = _request(0);
        vm.expectCall(address(facts), abi.encodeWithSelector(IWorkFacts.open.selector));
        uint256 saleId = starter.start(
            IEnglishAuction(address(auction)), address(stream), request, new MediaFile[](0)
        );
        Work memory w = stream.workOf(_tokenId(saleId));
        address sellerVault = auction.auction(saleId).seller;
        assertGt(sellerVault.code.length, 0, "seller vault deployed");
        assertGt(w.royaltyReceiver.code.length, 0, "royalty vault deployed");
        assertTrue(w.royaltyReceiver != sellerVault);
    }

    function _distinct(bytes32[] memory slots) internal pure returns (uint256 n) {
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (slots[j] == slots[i]) seen = true;
            }
            if (!seen) ++n;
        }
    }

    function test_Gas_StartStartWithBidBidSettle() public {
        // First start ever warms nothing of this auction: measure the steady state after it.
        auction.start(address(stream), _request(0));
        bytes memory r1 = _request(1);
        uint256 g = gasleft();
        uint256 saleId = auction.start(address(stream), r1);
        uint256 startGas = g - gasleft();
        bytes memory r2 = _request(2);
        vm.prank(alice);
        g = gasleft();
        uint256 withBid = auction.startWithBid{ value: 1 ether }(address(stream), r2, address(0));
        uint256 startWithBidGas = g - gasleft();
        vm.prank(bob);
        g = gasleft();
        auction.bid{ value: 2 ether }(withBid, address(0));
        uint256 bidGas = g - gasleft();
        _end(withBid);
        g = gasleft();
        auction.settle(withBid);
        uint256 settleGas = g - gasleft();
        g = gasleft();
        auction.settle(saleId);
        uint256 settleUnsoldGas = g - gasleft();
        console2.log("start (steady)", startGas);
        console2.log("startWithBid (steady)", startWithBidGas);
        console2.log("bid (outbids, credits)", bidGas);
        console2.log("settle (sold)", settleGas);
        console2.log("settle (unsold, museum)", settleUnsoldGas);
        // New storage slots of a steady start: Stream's five and the sale's two (token; seller,
        // share, end, status); a first bid adds the bid slot.
        vm.record();
        auction.start(address(stream), _request(3));
        (, bytes32[] memory auctionWrites) = vm.accesses(address(auction));
        (, bytes32[] memory streamWrites) = vm.accesses(address(stream));
        console2.log("auction slots written", _distinct(auctionWrites));
        console2.log("stream slots written", _distinct(streamWrites));
        assertLt(startWithBidGas, 370_000);
    }
}
