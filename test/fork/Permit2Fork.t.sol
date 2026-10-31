// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { WorksForkBase } from "./WorksForkBase.sol";

/// @dev The two reads of the canonical Permit2 these tests use.
interface IPermit2Reads {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonceBitmap(address owner, uint256 word) external view returns (uint256);
}

/// @notice The English auction's Permit2 path against the canonical Permit2 bytecode: relayed,
///         witness-bound payment intents signed with test keys, for an ERC-20 auction's start
///         with a bid and a later bid, and an expired intent. The digests are computed here from
///         the EIP-712 definitions, not read from any mock, so the tests also check the sales
///         lane's Permit2 reproduction against the real contract. (The edition auction is
///         ETH-only and takes no Permit2 payment.)
abstract contract Permit2ForkTests is WorksForkBase {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

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
        Work[] memory works = new Work[](1);
        works[0] = _work(artist, collectionId);
        works[0].item.sale.currency = address(usd);
        root = _publish(works);
        _keep(root, works);
        usd.mint(buyer, 10_000e18);
        vm.prank(buyer);
        usd.approve(PERMIT2, type(uint256).max);
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
        // The code (and so its hash) embeds the chain ID: the pin is mainnet's (Verify, DEPS-3).
        if (block.chainid == DeployGuards.MAINNET_CHAIN_ID) {
            assertEq(PERMIT2.codehash, DeployGuards.CANONICAL_PERMIT2_CODEHASH, "the pinned code");
        }
        assertEq(auction.permit2(), PERMIT2);
    }

    /// @dev An ERC-20 auction: the start and its first bid by one relayed intent
    ///      (`START_BID_WITNESS`), then an outbid by another (`BID_WITNESS`); the first bid is
    ///      credited back and the winner's payment settles to the seller and the network.
    function test_AuctionStartAndBidByRelayedIntents() public onFork {
        Work[] memory works = _package(root);
        bytes memory mintData = _mintData(root, works, 0);
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
        Work[] memory works = _package(root);
        bytes memory mintData = _mintData(root, works, 0);
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
            address(auction), amount, 9, deadline, witness, Typehashes.START_BID_WITNESS_TYPE
        );
        Payment memory pay =
            Payment(PaymentMethod.PERMIT2, buyer, amount, deadline, 9, _sign(buyer, digest));
        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, deadline));
        auction.startWithBid(address(stream), mintData, buyer, pay);
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
