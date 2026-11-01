// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Payment, PaymentMethod, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { Roles } from "src/governance/Roles.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { MockArtistResolver } from "../../mocks/economics/EconomicsMocks.sol";
import { MockMintTarget } from "../../mocks/sales/AuctionMocks.sol";
import {
    MockAssetAllowlist,
    MockEconomicsResolver,
    MockFederationRegistry,
    MockPermit2,
    PermitToken
} from "../../mocks/sales/SaleMocks.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";

/// @dev Deploys the auction against the real AccessManager, asset allowlist, revenue escrow and
///      statement log, with mocks for the token and Permit2. Unit tests use
///      zero-delay roles; the dispute tests that need the 48-hour class set it explicitly.
abstract contract AuctionBase is Test {
    uint64 internal constant GUARDIAN = Roles.GUARDIAN;
    uint64 internal constant UNPAUSER = Roles.UNPAUSER;
    uint64 internal constant PLATFORM = Roles.PLATFORM;
    uint64 internal constant PARAMETER_SETTER = Roles.PARAMETER_SETTER;
    uint64 internal constant SUCCESSOR_SETTER = Roles.SUCCESSOR_SETTER;
    uint64 internal constant PAUSER = Roles.PAUSER;
    /// @dev `pause` is overloaded: the per-auction dispute pause and the emergency start pause.
    bytes4 internal constant DISPUTE_PAUSE = bytes4(keccak256("pause(uint256,bytes32)"));
    bytes4 internal constant START_PAUSE = bytes4(keccak256("pause()"));
    bytes4 internal constant START_UNPAUSE = bytes4(keccak256("unpause()"));

    uint32 internal constant DURATION = 24 hours;
    uint32 internal constant WINDOW = 15 minutes;
    uint32 internal constant SHARE = 5_000;
    uint32 internal constant FEE = 25_000;
    uint256 internal constant ETH_FLOOR = 0.001 ether;
    uint256 internal constant USD_FLOOR = 1e18;
    address internal constant ETH = address(0);

    AccessManager internal manager;
    AssetAllowlist internal allowlist;
    /// @dev The auction's economics resolver: the real allowlist, and the federated network fee
    ///      recipient (MARKET-3).
    MockEconomicsResolver internal resolver;
    RevenueEscrow internal escrow;
    StatementLog internal statements;
    MockPermit2 internal permit2;
    MockMintTarget internal stream;
    PermitToken internal usd;
    IEnglishAuctionFull internal auction;

    address internal guardian = makeAddr("guardian");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal setter = makeAddr("setter");
    address internal successor = makeAddr("successor");
    address internal platform = makeAddr("platform");
    address internal seller = makeAddr("sellerWallet");
    address internal network = makeAddr("network");
    address internal federatedNetwork = makeAddr("federatedNetwork");
    address internal artist = makeAddr("artist");
    address internal relayer = makeAddr("relayer");
    /// @dev The 6529 Network Museum the resolver names (D140): an unbid canonical work goes here.
    address internal museum = makeAddr("museum");

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    uint256 internal carolPk = 0xCA201;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public virtual {
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        carol = vm.addr(carolPk);
        manager = new AccessManager(address(this));
        allowlist = new AssetAllowlist(address(manager), ETH_FLOOR);
        escrow = new RevenueEscrow(
            address(manager), new SplitFactory(new MockArtistResolver(), new ReleaseVerifier())
        );
        statements = new StatementLog(address(manager), address(0), bytes32(0));
        permit2 = new MockPermit2();
        stream = new MockMintTarget();
        usd = new PermitToken();
        allowlist.admitAsset(address(usd), 0, USD_FLOOR);
        resolver = new MockEconomicsResolver(MockAssetAllowlist(address(0)));
        resolver.setAllowlistOverride(address(allowlist));
        resolver.set(PRODUCT_FEDERATED, federatedNetwork, 10_000);
        resolver.setMuseumAccount(museum);
        auction = _deploy(address(permit2));
        stream.setTerms(_terms(ETH));
        _grant(GUARDIAN, guardian);
        _grant(PAUSER, pauser);
        _grant(UNPAUSER, unpauser);
        _grant(PARAMETER_SETTER, setter);
        _grant(SUCCESSOR_SETTER, successor);
        _grant(PLATFORM, platform);
        _map(address(statements), statements.appendPlatform.selector, PLATFORM);
    }

    // ------------------------------------------------------------------------ deployment

    function _config() internal pure returns (IEnglishAuction.AuctionConfig memory) {
        return IEnglishAuction.AuctionConfig(DURATION, WINDOW, SHARE);
    }

    function _deploy(address permit2_) internal returns (IEnglishAuctionFull a) {
        address[] memory targets = new address[](1);
        targets[0] = address(stream);
        a = IEnglishAuctionFull(
            address(
                new EnglishAuction(
                    address(manager),
                    address(escrow),
                    resolver,
                    address(statements),
                    permit2_,
                    _config(),
                    targets,
                    address(stream)
                )
            )
        );
        stream.setAdmittedMinter(address(a), true);
        _map(address(a), DISPUTE_PAUSE, GUARDIAN);
        _map(address(a), START_PAUSE, PAUSER);
        _map(address(a), START_UNPAUSE, UNPAUSER);
        _map(address(a), IEnglishAuction.resume.selector, UNPAUSER);
        _map(address(a), IEnglishAuction.cancel.selector, PARAMETER_SETTER);
        _map(address(a), IEnglishAuction.setConfig.selector, PARAMETER_SETTER);
        _map(address(a), IEnglishAuction.setOpeningBid.selector, PARAMETER_SETTER);
        _map(address(a), ISaleAdapter.setTarget.selector, SUCCESSOR_SETTER);
        _map(address(a), EnglishAuction.setFederationRegistry.selector, SUCCESSOR_SETTER);
    }

    function _map(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    function _grant(uint64 role, address account) internal {
        manager.grantRole(role, account, 0);
    }

    function _terms(address currency) internal view returns (PrimaryTerms memory) {
        return PrimaryTerms(SaleKind.ENGLISH_AUCTION, currency, 0, "", seller, network, FEE, artist);
    }

    /// @dev Another ERC-721 that governance lists on the auction (`setTarget`), on `currency`'s
    ///      terms. It is not 6529 Stream, the token the auction was deployed with, so its unbid
    ///      works go to their artist (owner decision 9), as a federated token's do.
    function _listedToken(address currency) internal returns (MockMintTarget token) {
        token = new MockMintTarget();
        token.setAdmittedMinter(address(auction), true);
        token.setTerms(_terms(currency));
        vm.prank(successor);
        auction.setTarget(address(token), true);
    }

    /// @dev A federated ERC-721 (D21) on `_terms(ETH)`, registered ACTIVE with a 10% fee in a
    ///      federation registry installed on the auction: its unbid works stay with their artist
    ///      (owner decision 9), not the museum.
    function _federated() internal returns (MockMintTarget fed) {
        MockFederationRegistry registry = new MockFederationRegistry();
        fed = new MockMintTarget();
        fed.setAdmittedMinter(address(auction), true);
        fed.setTerms(_terms(ETH));
        address installed = auction.federationRegistry();
        vm.prank(successor);
        auction.setFederationRegistry(installed, address(registry));
        registry.register(
            address(fed),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                uint160(artist),
                1,
                address(fed).codehash,
                10_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
    }

    // --------------------------------------------------------------------------- actions

    function _start() internal returns (uint256) {
        return auction.start(address(stream), "");
    }

    function _startUsd() internal returns (uint256) {
        stream.setTerms(_terms(address(usd)));
        return auction.start(address(stream), "");
    }

    function _direct(address payer, uint256 amount) internal pure returns (Payment memory) {
        return Payment(PaymentMethod.DIRECT, payer, amount, 0, 0, "");
    }

    function _bidEth(uint256 saleId, address bidder, uint256 amount) internal {
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        auction.bid{ value: amount }(saleId, address(0), _direct(bidder, amount));
    }

    function _bidUsd(uint256 saleId, address bidder, uint256 amount) internal {
        usd.mint(bidder, amount);
        vm.startPrank(bidder);
        usd.approve(address(auction), amount);
        auction.bid(saleId, address(0), _direct(bidder, amount));
        vm.stopPrank();
    }

    function _end(uint256 saleId) internal {
        vm.warp(auction.auction(saleId).endTime);
    }

    function _pause(uint256 saleId) internal {
        vm.prank(guardian);
        auction.pause(saleId, keccak256("dispute"));
    }

    function _recordOutcome(uint256 tokenId) internal returns (bytes32) {
        Statement memory s = Statement({
            token: address(stream),
            id: tokenId,
            kind: StatementKinds.DISPUTE_OUTCOME,
            schema: keccak256("dispute-outcome/v1"),
            content: HashRef(HASH_SHA256, keccak256("upheld")),
            uri: "ipfs://outcome",
            fileId: bytes32(0),
            supersedes: bytes32(0)
        });
        vm.prank(platform);
        return statements.appendPlatform(s);
    }

    function _permit2Payment(
        uint256 pk,
        uint256 saleId,
        address recipient,
        uint256 amount,
        uint256 nonce
    ) internal view returns (Payment memory p) {
        address payer = vm.addr(pk);
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(address(usd), amount),
            nonce,
            block.timestamp + 1 hours
        );
        bytes32 witness = keccak256(
            abi.encode(Typehashes.BID_WITNESS, saleId, recipient, amount, permit.deadline)
        );
        bytes32 digest =
            permit2.witnessDigest(address(auction), permit, witness, Typehashes.BID_WITNESS_TYPE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        p = Payment(
            PaymentMethod.PERMIT2, payer, amount, permit.deadline, nonce, abi.encodePacked(r, s, v)
        );
    }

    function _startBidPayment(
        uint256 pk,
        bytes memory mintData,
        address recipient,
        uint256 amount,
        uint256 nonce
    ) internal view returns (Payment memory p) {
        ISignatureTransfer.PermitTransferFrom memory permit =
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), amount),
                nonce,
                block.timestamp + 1 hours
            );
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.START_BID_WITNESS,
                address(stream),
                keccak256(mintData),
                recipient,
                amount,
                permit.deadline
            )
        );
        bytes32 digest = permit2.witnessDigest(
            address(auction), permit, witness, Typehashes.START_BID_WITNESS_TYPE
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        p = Payment(
            PaymentMethod.PERMIT2,
            vm.addr(pk),
            amount,
            permit.deadline,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    function _permitPayment(uint256 pk, uint256 amount, uint256 deadline)
        internal
        view
        returns (Payment memory)
    {
        address owner = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                address(auction),
                amount,
                usd.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usd.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Payment(PaymentMethod.PERMIT, owner, amount, deadline, 0, abi.encodePacked(r, s, v));
    }

    function _setFloor(address asset, uint256 floor) internal {
        (,, uint64 revision) = allowlist.assetConfig(asset);
        allowlist.setIncrementFloor(asset, revision, floor);
    }

    function _setDefault(bytes32 product, address asset) internal {
        (,, uint64 revision) = allowlist.defaultCurrencyConfig(product);
        allowlist.setDefaultCurrency(product, revision, asset);
    }

    function _saleIdOf(uint256 tokenId) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(address(stream), tokenId)));
    }

    function _tokenIdOf(uint256 saleId) internal view returns (uint256) {
        return auction.auction(saleId).tokenId;
    }

    function _minimumAfter(uint256 high, uint256 floor) internal pure returns (uint256) {
        uint256 step = (high * SHARE + 99_999) / 100_000;
        return high + (step > floor ? step : floor);
    }

    function _state(uint256 saleId) internal view returns (IEnglishAuction.AuctionState) {
        return auction.auction(saleId).state;
    }

    function _bidFor(uint256 saleId, address payer, address recipient, uint256 amount) internal {
        vm.deal(payer, payer.balance + amount);
        vm.prank(payer);
        auction.bid{ value: amount }(saleId, recipient, _direct(payer, amount));
    }
}
