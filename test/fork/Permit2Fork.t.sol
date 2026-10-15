// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { EditionFormat, EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksForkBase } from "./WorksForkBase.sol";

/// @dev The two reads of the canonical Permit2 these tests use.
interface IPermit2Reads {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonceBitmap(address owner, uint256 word) external view returns (uint256);
}

/// @notice The sale adapters' Permit2 path against the canonical Permit2 bytecode: relayed,
///         witness-bound payment intents signed with test keys, for a fixed-price purchase, a
///         Dutch purchase, and an ERC-20 auction's start with a bid and a later bid. The digests
///         are computed here from the EIP-712 definitions, not read from any mock, so the tests
///         also check the sales lane's Permit2 reproduction against the real contract.
abstract contract Permit2ForkTests is WorksForkBase {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    uint256 internal constant FIXED_PRICE = 10e18;
    uint256 internal constant DUTCH_START = 40e18;

    address internal artist;
    address internal buyer;
    address internal relayer = makeAddr("forkRelayer");
    address internal collector = makeAddr("forkCollector");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        artist = _actor("forkPermit2Artist");
        buyer = _actor("forkPermit2Buyer");
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
        Work[] memory works = new Work[](3);
        works[0] = _master(
            _work(artist, collectionId),
            EditionTerms(
                EditionFormat.FIXED, 20, 0, FIXED_PRICE, address(usd), SaleKind.FIXED_PRICE, ""
            )
        );
        works[1] = _master(
            _work(artist, collectionId),
            EditionTerms(
                EditionFormat.FIXED,
                20,
                0,
                DUTCH_START,
                address(usd),
                SaleKind.DUTCH,
                abi.encode(DutchParams(4e18, 4 hours, 0))
            )
        );
        works[2] = _work(artist, collectionId);
        works[2].item.sale.currency = address(usd);
        root = _publish(works);
        _keep(root, works);
        usd.mint(buyer, 10_000e18);
        vm.prank(buyer);
        usd.approve(PERMIT2, type(uint256).max);
    }

    function _master(Work memory w, EditionTerms memory terms) internal pure returns (Work memory) {
        w.item.kind = ItemKind.EDITION_MASTER;
        w.item.edition = terms;
        return w;
    }

    /// @dev Sells master `index` at auction in ETH and creates its edition.
    function _edition(uint256 index) internal returns (uint256 id) {
        Work[] memory works = _package(root);
        id = _sell(root, works, index, collector, 1 ether);
        editions.createEdition(id, works[index].item, root, _proofOf(works, index));
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, PERMIT2));
    }

    /// @dev The canonical `PermitWitnessTransferFrom` digest for `spender`.
    function _digest(
        address spender,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes32 witness,
        string memory witnessType
    ) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(WITNESS_STUB, witnessType));
        bytes32 permissions =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(usd), amount));
        bytes32 structHash =
            keccak256(abi.encode(typeHash, permissions, spender, nonce, deadline, witness));
        return keccak256(abi.encodePacked("\x19\x01", _domain(), structHash));
    }

    function _intent(
        address spender,
        uint256 amount,
        uint256 nonce,
        bytes32 witness,
        string memory witnessType
    ) internal view returns (Payment memory) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(spender, amount, nonce, deadline, witness, witnessType);
        return Payment(PaymentMethod.PERMIT2, buyer, amount, deadline, nonce, _sign(buyer, digest));
    }

    // ------------------------------------------------------------------ the tests

    function test_Permit2IsCanonical() public onFork {
        assertEq(IPermit2Reads(PERMIT2).DOMAIN_SEPARATOR(), _domain(), "the EIP-712 domain");
        assertEq(address(fixedSale.permit2()), PERMIT2);
        assertEq(address(dutchSale.permit2()), PERMIT2);
        assertEq(auction.permit2(), PERMIT2);
    }

    /// @dev A relayer submits the buyer's signed purchase intent: Permit2 moves exactly the
    ///      price from the buyer, the adapter pays the seller and the network. Replaying the
    ///      intent spends a used nonce; an intent for another recipient does not verify.
    function test_FixedPricePurchaseByRelayedIntent() public onFork {
        uint256 id = _edition(0);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 1 days), bytes32(0), 0, false, false
        );
        IFixedPriceSale.ArtistConsent memory none;
        vm.prank(artist);
        uint256 saleId = fixedSale.openSale(address(editions), id, phases, none);
        IFixedPriceSale.Purchase memory p = IFixedPriceSale.Purchase(saleId, 0, buyer, 2, 0, 0);
        uint256 total = 2 * FIXED_PRICE;
        uint256 nonce = uint256(keccak256("fork fixed-price nonce"));
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.PURCHASE_WITNESS, saleId, 0, buyer, 2, total, block.timestamp + 1 hours
            )
        );
        Payment memory pay =
            _intent(address(fixedSale), total, nonce, witness, Typehashes.PURCHASE_WITNESS_TYPE);
        uint256 before = usd.balanceOf(buyer);
        vm.prank(relayer);
        fixedSale.purchase(p, new bytes32[](0), pay);
        assertEq(editions.balanceOf(buyer, id), 2);
        assertEq(before - usd.balanceOf(buyer), total, "exactly the price");
        assertEq(usd.balanceOf(address(fixedSale)), 0, "nothing kept");
        uint256 word = IPermit2Reads(PERMIT2).nonceBitmap(buyer, nonce >> 8);
        assertTrue(word & (1 << (nonce & 0xff)) != 0, "the nonce is spent in Permit2");

        vm.prank(relayer);
        vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
        fixedSale.purchase(p, new bytes32[](0), pay);

        // A fresh intent for the original recipient, presented for another recipient: the
        // witness binds the recipient, so Permit2 recovers another signer.
        Payment memory fresh = _intent(
            address(fixedSale), total, nonce + 1, witness, Typehashes.PURCHASE_WITNESS_TYPE
        );
        p.recipient = relayer;
        vm.prank(relayer);
        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        fixedSale.purchase(p, new bytes32[](0), fresh);
    }

    /// @dev A Dutch purchase pulls exactly the current price, below the intent's maximum.
    function test_DutchPurchaseByRelayedIntent() public onFork {
        uint256 id = _edition(1);
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), id, uint64(block.timestamp));
        vm.warp(block.timestamp + 1 hours);
        uint256 price = dutchSale.currentPrice(saleId);
        uint256 maxUnit = DUTCH_START;
        uint256 nonce = 7;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.DUTCH_PURCHASE_WITNESS,
                saleId,
                address(0),
                1,
                maxUnit,
                block.timestamp + 1 hours
            )
        );
        Payment memory pay = _intent(
            address(dutchSale), maxUnit, nonce, witness, Typehashes.DUTCH_PURCHASE_WITNESS_TYPE
        );
        uint256 before = usd.balanceOf(buyer);
        vm.prank(relayer);
        dutchSale.purchase(saleId, address(0), 1, maxUnit, pay);
        assertEq(editions.balanceOf(buyer, id), 1);
        assertEq(before - usd.balanceOf(buyer), price, "the current price, not the maximum");
        assertLt(price, maxUnit);
        assertEq(dutchSale.claimable(buyer, address(usd)), 0, "an ERC-20 is never over-pulled");
    }

    /// @dev An ERC-20 auction: the start and its first bid by one relayed intent
    ///      (`START_BID_WITNESS`), then an outbid by another (`BID_WITNESS`); the first bid is
    ///      credited back and the winner's payment settles to the seller and the network.
    function test_AuctionStartAndBidByRelayedIntents() public onFork {
        Work[] memory works = _package(root);
        bytes memory mintData = _mintData(root, works, 2);
        uint256 amount = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.START_BID_WITNESS,
                address(stream),
                keccak256(mintData),
                buyer,
                amount,
                deadline
            )
        );
        bytes32 digest = _digest(
            address(auction), amount, 1, deadline, witness, Typehashes.START_BID_WITNESS_TYPE
        );
        Payment memory pay =
            Payment(PaymentMethod.PERMIT2, buyer, amount, deadline, 1, _sign(buyer, digest));
        vm.prank(relayer);
        uint256 saleId = auction.startWithBid(address(stream), mintData, buyer, pay);
        assertEq(auction.auction(saleId).currency, address(usd));
        assertEq(usd.balanceOf(address(auction)), amount);

        uint256 next = auction.minimumBid(saleId);
        witness = keccak256(abi.encode(Typehashes.BID_WITNESS, saleId, buyer, next, deadline));
        digest = _digest(address(auction), next, 2, deadline, witness, Typehashes.BID_WITNESS_TYPE);
        vm.prank(relayer);
        auction.bid(
            saleId,
            buyer,
            Payment(PaymentMethod.PERMIT2, buyer, next, deadline, 2, _sign(buyer, digest))
        );
        assertEq(auction.claimable(buyer, address(usd)), amount, "the outbid is credited");
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(stream.totalMinted()), buyer);
        assertEq(usd.balanceOf(address(auction)), amount, "only the credit stays");
    }

    /// @dev An expired intent is refused by the adapter before Permit2 is called.
    function test_ExpiredIntentIsRefused() public onFork {
        uint256 id = _edition(0);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(
            uint64(block.timestamp), uint64(block.timestamp + 1 days), bytes32(0), 0, false, false
        );
        IFixedPriceSale.ArtistConsent memory none;
        vm.prank(artist);
        uint256 saleId = fixedSale.openSale(address(editions), id, phases, none);
        IFixedPriceSale.Purchase memory p = IFixedPriceSale.Purchase(saleId, 0, buyer, 1, 0, 0);
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.PURCHASE_WITNESS,
                saleId,
                0,
                buyer,
                1,
                FIXED_PRICE,
                block.timestamp + 1 hours
            )
        );
        Payment memory pay =
            _intent(address(fixedSale), FIXED_PRICE, 9, witness, Typehashes.PURCHASE_WITNESS_TYPE);
        vm.warp(pay.deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, pay.deadline));
        fixedSale.purchase(p, new bytes32[](0), pay);
    }
}

contract Permit2MainnetForkTest is Permit2ForkTests {
    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_MAINNET_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return MAINNET;
    }
}

contract Permit2SepoliaForkTest is Permit2ForkTests {
    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_SEPOLIA_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return SEPOLIA;
    }
}
