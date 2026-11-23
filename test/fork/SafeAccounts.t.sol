// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import {
    MoveAuthorization,
    PartyAcceptance,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { ISafe, SafeForkBase } from "./SafeForkBase.sol";

/// @notice Real Safe v1.4.1 wallets as the accounts artists and collectors use, on a mainnet
///         fork, against the deployed plain-core stack:
///         - an artist whose account's root is a 2-of-3 Safe, signing by ERC-1271 through
///           Safe's `CompatibilityFallbackHandler`: its package acceptance (which creates the
///           account) and its move (wallet-prefixed proofs), and its consent to a royalty-rate
///           change the network Safe executes through the manager; a proof below the threshold
///           or by keys that are not owners is refused;
///         - the artist Safe paid: it releases its share by a Safe transaction (nobody else can)
///           and by a signed release anyone relays, which stops verifying after an owner swap;
///         - a Safe as bidder, credited when outbid and claiming its credit, then receiving the
///           721 at settlement within the auction's delivery gas;
///         - the fee and museum vaults forwarding ETH and an unbid work to their Safes.
/// @dev Gated by `FORK_MAINNET_RPC` (see `CoreForkBase`).
contract SafeAccountsForkTest is SafeForkBase {
    ISafe internal artistSafe;
    ISafe internal collectorSafe;
    address internal artist;
    address internal collector;

    function setUp() public override {
        super.setUp();
        artistSafe = _newSafe("artist");
        collectorSafe = _newSafe("collector");
        artist = _actor("safeForkEoaArtist");
        collector = _actor("safeForkEoaCollector");
        vm.deal(address(collectorSafe), 10 ether);
    }

    // ------------------------------------------------------------------ the Safe as an artist

    /// @notice The Safe accepts the package with a wallet-prefixed ERC-1271 proof, which
    ///         creates its account (artist ID `uint160(safe)`, root the Safe), and its signed
    ///         move starts the work.
    function test_SafeArtist_AcceptsAndAuthorizesTheMove() public {
        (bytes32 root, Work[] memory works) = _safePackage();
        uint256 artistId = uint256(uint160(address(artistSafe)));
        assertEq(accounts.artistIdOf(address(artistSafe)), artistId);
        assertEq(accounts.authorityOf(artistId), address(artistSafe));
        assertEq(registry.acceptedAs(root, address(artistSafe)), artistId);

        uint256 tokenId = _startBySafe(root, works);
        assertEq(stream.workOf(tokenId).artistId, artistId);
        assertEq(stream.ownerOf(tokenId), address(auction));
    }

    /// @notice Planted fault: an acceptance signed by one owner, or by two keys that are not
    ///         owners, is refused with the Safe named, and no account is created.
    function test_SafeArtist_ProofBelowThresholdOrByStrangersIsRefused() public {
        Work[] memory works = _one(_work(address(artistSafe), collectionId));
        bytes32 root = _rootOf(works);
        _approve(root);
        PartyAcceptance memory a = _acceptance(address(artistSafe));
        bytes32 digest = registry.acceptanceDigest(root, a);

        bytes memory one = abi.encodePacked(
            address(artistSafe), _safeSignatureBy(artistSafe, digest, _firstKeys(artistSafe, 1))
        );
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(artistSafe))
        );
        registry.acceptPackage(root, a, one);

        uint256[] memory strangers = new uint256[](2);
        strangers[0] = uint256(keccak256("not an owner 1"));
        strangers[1] = uint256(keccak256("not an owner 2"));
        bytes memory foreign = abi.encodePacked(
            address(artistSafe), _safeSignatureBy(artistSafe, digest, strangers)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(artistSafe))
        );
        registry.acceptPackage(root, a, foreign);
        assertEq(accounts.artistIdOf(address(artistSafe)), 0, "no account was created");

        registry.acceptPackage(root, a, _safeProof(artistSafe, digest));
        assertEq(accounts.artistIdOf(address(artistSafe)), uint160(address(artistSafe)));
    }

    /// @notice A royalty-rate change consented by the artist Safe (a wallet-prefixed ERC-1271
    ///         proof) and executed by the network Safe through the manager after its delay.
    function test_SafeArtist_ConsentsAndTheNetworkSafeChangesTheRoyaltyRate() public {
        (bytes32 root, Work[] memory works) = _safePackage();
        uint256 tokenId = _startBySafe(root, works);
        _open(tokenId, works[0]);

        uint24 rate = 10_000;
        assertTrue(stream.workOf(tokenId).royaltyRate != rate);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.ROYALTY_RATE_TYPEHASH(), address(stream), tokenId, rate, state, deadline
                )
            )
        );
        bytes[] memory consents = new bytes[](1);
        consents[0] = _safeProof(artistSafe, digest);
        _safeGovern(
            networkSafe,
            address(rules),
            abi.encodeCall(
                rules.setRoyaltyRate,
                (address(stream), tokenId, rate, works[0].item, state, deadline, consents)
            )
        );
        assertEq(stream.workOf(tokenId).royaltyRate, rate);
    }

    /// @notice The artist Safe releases its share by a Safe transaction; an artist payee must
    ///         call from its payout address, so nobody else can release it.
    function test_SafeArtist_ReleasesItsShareByATransaction() public {
        _soldSafeWork();
        (address wallet, ISplitWallet.Payee[] memory payees) = _sellerWallet();
        uint256 due = ledger.releasable(payees, bytes32(0), CURRENCY_ETH, 0);
        assertGt(due, 0, "the sale paid the seller wallet");
        bytes memory call =
            abi.encodeCall(ISplitWallet.release, (payees, bytes32(0), CURRENCY_ETH, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitWallet.NotPayoutAddress.selector, collector, address(artistSafe)
            )
        );
        vm.prank(collector);
        ledger.release(payees, bytes32(0), CURRENCY_ETH, 0);

        uint256 before = address(artistSafe).balance;
        _safeCall(artistSafe, address(ledger), call);
        assertEq(address(artistSafe).balance - before, due);
        assertEq(ledger.releasable(payees, bytes32(0), CURRENCY_ETH, 0), 0);
        wallet;
    }

    /// @notice A release signed by the artist Safe (ERC-1271, no prefix: the ledger checks the
    ///         payout address itself), relayed by anyone, pays the Safe and spends the nonce;
    ///         a signature made before an owner swap no longer verifies, and the new owners
    ///         sign again.
    function test_SafeArtist_SignedReleasePaysTheSafeUntilAnOwnerSwap() public {
        _soldSafeWork();
        (address wallet, ISplitWallet.Payee[] memory payees) = _sellerWallet();
        IReleaseVerifier.Authorization memory a = _authorization(wallet, 1, 0.1 ether);
        bytes memory signature = _safeSignature(artistSafe, ledger.releaseDigest(a));
        uint256 before = address(artistSafe).balance;
        vm.prank(relayer);
        ledger.releaseWithAuthorization(payees, bytes32(0), a, signature);
        assertEq(address(artistSafe).balance - before, 0.1 ether);
        assertTrue(ledger.nonceUsed(address(artistSafe), 1));

        IReleaseVerifier.Authorization memory b = _authorization(wallet, 2, type(uint256).max);
        bytes32 digest = ledger.releaseDigest(b);
        bytes memory signedBefore = _safeSignature(artistSafe, digest);
        _swapOwner(artistSafe, 1, "artist replacement owner");
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(artistSafe))
        );
        ledger.releaseWithAuthorization(payees, bytes32(0), b, signedBefore);

        before = address(artistSafe).balance;
        ledger.releaseWithAuthorization(payees, bytes32(0), b, _safeSignature(artistSafe, digest));
        assertGt(address(artistSafe).balance, before);
        assertEq(ledger.releasable(payees, bytes32(0), CURRENCY_ETH, 0), 0);
    }

    // ------------------------------------------------------------------ the Safe as a holder

    /// @notice A Safe bids with its own ETH, is outbid and claims its credit back to itself,
    ///         bids again, wins, and receives the 721 at settlement (the fallback handler
    ///         answers `onERC721Received` within the auction's delivery gas).
    function test_SafeCollector_BidsWinsAndReceivesThe721() public {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);

        uint256 start = address(collectorSafe).balance;
        _safeBid(saleId, 1 ether);
        _ethBid(saleId, collector, auction.minimumBid(saleId));
        assertEq(auction.claimable(address(collectorSafe)), 1 ether, "credited");
        _safeCall(
            collectorSafe, address(auction), abi.encodeCall(auction.claim, (address(collectorSafe)))
        );
        assertEq(address(collectorSafe).balance, start, "the credit came back to the Safe");

        uint256 top = auction.minimumBid(saleId);
        _safeBid(saleId, top);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), address(collectorSafe), "delivered at settlement");
        assertEq(address(collectorSafe).balance, start - top);
    }

    /// @notice An unbid work goes to the museum's vault, which forwards it to the museum Safe
    ///         (an ERC-721 receiver); the network fee of a sale reaches the fee Safe through
    ///         the fee vault.
    function test_SafeVaults_ForwardToTheirSafes() public {
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 unbid) = _start(root, works, 0);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(unbid), museum);
        museumVault.forwardERC721(address(stream), unbid);
        assertEq(stream.ownerOf(unbid), address(museumDestination));

        _sell(root, works, 1, collector, 1 ether);
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](1);
        payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 100_000);
        ledger.createWallet(payees, bytes32(0));
        vm.prank(artist);
        ledger.release(payees, bytes32(0), CURRENCY_ETH, 0);
        uint256 fee = networkFee.balance;
        assertGt(fee, 0, "the sale paid the network fee");
        uint256 before = address(feeDestination).balance;
        feeVault.forward(CURRENCY_ETH, type(uint256).max);
        assertEq(address(feeDestination).balance - before, fee);
        assertEq(networkFee.balance, 0);
    }

    // ------------------------------------------------------------------ helpers

    function _acceptance(address account) internal view returns (PartyAcceptance memory) {
        return PartyAcceptance(
            account, _profileId(account), _profileDoc(account), uint64(block.timestamp + 1 days)
        );
    }

    /// @dev A one-work package led by the artist Safe, approved and accepted by the Safe.
    function _safePackage() internal returns (bytes32 root, Work[] memory works) {
        works = _one(_work(address(artistSafe), collectionId));
        root = _rootOf(works);
        _approve(root);
        PartyAcceptance memory a = _acceptance(address(artistSafe));
        registry.acceptPackage(root, a, _safeProof(artistSafe, registry.acceptanceDigest(root, a)));
    }

    /// @dev Starts the artist Safe's work with a move the Safe signed; returns the token ID.
    function _startBySafe(bytes32 root, Work[] memory works) internal returns (uint256 tokenId) {
        uint256 artistId = uint256(uint160(address(artistSafe)));
        uint256 nonce = nextMoveNonce[artistId]++;
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest =
            registry.moveDigest(root, WorksHashing.itemHash(works[0].item), nonce, deadline);
        MoveAuthorization memory move =
            MoveAuthorization(nonce, deadline, _safeProof(artistSafe, digest));
        auction.start(
            address(stream),
            abi.encode(StreamMintRequest(root, works[0].item, _proofOf(works, 0), move))
        );
        tokenId = stream.totalMinted();
    }

    /// @dev The artist Safe's work, sold to the EOA collector for 1 ETH.
    function _soldSafeWork() internal returns (uint256 tokenId) {
        (bytes32 root, Work[] memory works) = _safePackage();
        tokenId = _startBySafe(root, works);
        uint256 saleId = auction.saleIdOf(address(stream), tokenId);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
    }

    /// @dev The artist Safe's seller wallet (sole payee, artist-resolved).
    function _sellerWallet() internal returns (address wallet, ISplitWallet.Payee[] memory payees) {
        payees = new ISplitWallet.Payee[](1);
        payees[0] = ISplitWallet.Payee(uint256(uint160(address(artistSafe))), address(0), 100_000);
        wallet = ledger.createWallet(payees, bytes32(0));
        assertEq(wallet, economics.newWorkTerms(PRODUCT_STREAM, payees).seller);
    }

    function _authorization(address wallet, uint256 nonce, uint256 amount)
        internal
        view
        returns (IReleaseVerifier.Authorization memory)
    {
        return IReleaseVerifier.Authorization(
            wallet,
            CURRENCY_ETH,
            0,
            address(artistSafe),
            address(artistSafe),
            amount,
            nonce,
            block.timestamp + 1 days
        );
    }

    /// @dev Replaces owner `index` of `safe` by a new key, by a Safe transaction to itself
    ///      signed by the current threshold.
    function _swapOwner(ISafe safe, uint256 index, string memory label) internal {
        address[] memory owners = safe.getOwners();
        address oldOwner = _ownerOf(safe, index);
        address prev = address(1); // the Safe owner list's sentinel
        for (uint256 i; i < owners.length && owners[i] != oldOwner; ++i) {
            prev = owners[i];
        }
        (address newOwner, uint256 newKey) = makeAddrAndKey(label);
        _safeCall(safe, address(safe), abi.encodeCall(ISafe.swapOwner, (prev, oldOwner, newOwner)));
        safeKeys[address(safe)][index] = newKey;
    }

    function _safeBid(uint256 saleId, uint256 amount) internal {
        _safeCallValue(
            collectorSafe,
            address(auction),
            amount,
            abi.encodeCall(auction.bid, (saleId, address(collectorSafe)))
        );
    }
}
