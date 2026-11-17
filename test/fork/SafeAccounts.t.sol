// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { Role, Statement } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { CURRENCY_ETH, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import {
    EditionTerms,
    ItemKind,
    MoveAuthorization,
    PartyAcceptance,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { ISafe, SafeForkBase } from "./SafeForkBase.sol";

/// @notice Real Safe v1.4.1 wallets as the accounts institutions use, on a mainnet fork:
///         - an artist whose account's wallet is a 2-of-3 Safe and which signs by ERC-1271
///           through Safe's `CompatibilityFallbackHandler`: its package acceptance and move
///           (wallet-prefixed proofs), a relayed artist statement, a royalty-rate consent the
///           network Safe executes, and a signed release; the same signature stops verifying
///           after an owner swap;
///         - a Safe as payee (the artist Safe releasing its own share), bidder and receiver of
///           the 721 (with an outbid credit claimed back), receiver of an 1155 edition, the
///           museum's destination for an unbid work, and the network fee vault's destination.
/// @dev Gated by `FORK_MAINNET_RPC` (see `SafeForkBase`).
contract SafeAccountsForkTest is SafeForkBase {
    ISafe internal artistSafe;
    ISafe internal collectorSafe;
    address internal artist;
    address internal collector;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        artistSafe = _newSafe("artist");
        collectorSafe = _newSafe("collector");
        artist = _actor("safeForkEoaArtist");
        collector = _actor("safeForkEoaCollector");
        vm.deal(address(collectorSafe), 10 ether);
    }

    // ------------------------------------------------------------------ the Safe as an artist

    /// @dev CUR-7, CUR-10: the Safe accepts the package with a wallet-prefixed ERC-1271 proof
    ///      (which creates its account, artist ID `uint160(safe)`, root the Safe), and its move
    ///      authorization starts the work.
    function test_SafeArtistAcceptsAndAuthorizesTheMove() public onFork {
        (bytes32 root, Work[] memory works) = _safePackage();
        uint256 artistId = uint256(uint160(address(artistSafe)));
        assertEq(artists.artistIdOf(address(artistSafe)), artistId);
        assertEq(artists.authorityOf(artistId), address(artistSafe));
        assertEq(registry.acceptedAs(root, address(artistSafe)), artistId);

        uint256 tokenId = _startBySafe(root, works);
        assertEq(IStream(address(stream)).artistOf(tokenId), artistId);
        assertEq(stream.ownerOf(tokenId), address(auction));
    }

    /// @dev CUR-7: an acceptance the Safe's owners did not reach the threshold for, or signed
    ///      by keys that are not owners, is refused with the Safe named.
    function test_SafeArtistProofBelowThresholdOrByStrangersIsRefused() public onFork {
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
        assertEq(artists.artistIdOf(address(artistSafe)), 0, "no account was created");
    }

    /// @dev DSP-9: an artist statement signed by the Safe (ERC-1271) and relayed by anyone; its
    ///      nonce is spent, so the same authorization cannot be relayed again.
    function test_SafeArtistRelaysASignedStatement() public onFork {
        uint256 tokenId = _soldSafeWork();
        Statement memory s = Statement(
            address(stream),
            tokenId,
            StatementKinds.ARTIST_STATEMENT,
            keccak256("6529-works/artist-statement/1"),
            HashRef(HASH_SHA256, keccak256("a statement signed by a Safe")),
            "ar://safe-artist-statement",
            bytes32(0),
            bytes32(0)
        );
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            statements.authorizationDigest(Role.ARTIST, s, address(artistSafe), 7, deadline);
        bytes memory signature = _safeSignature(artistSafe, digest);

        vm.prank(makeAddr("relayer"));
        statements.appendSigned(Role.ARTIST, s, address(artistSafe), 7, deadline, signature);
        (uint64 count,) = statements.chainOf(address(stream), tokenId);
        assertEq(count, 1);
        assertTrue(statements.nonceUsed(address(artistSafe), 7));
        vm.expectRevert();
        statements.appendSigned(Role.ARTIST, s, address(artistSafe), 7, deadline, signature);
    }

    /// @dev WS-14, GV-2: a royalty-rate change consented by the artist Safe (a wallet-prefixed
    ///      ERC-1271 proof) and executed by the network Safe through the manager after 3 days.
    function test_SafeArtistConsentsAndNetworkSafeChangesTheRoyaltyRate() public onFork {
        (bytes32 root, Work[] memory works) = _safePackage();
        uint256 tokenId = _startBySafe(root, works);
        _ethBid(auction.saleIdOf(address(stream), tokenId), collector, 1 ether);
        _settleAtEnd(auction.saleIdOf(address(stream), tokenId));
        records.openRecord(tokenId, works[0].item, works[0].media);

        uint32 rate = 10_000;
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline))
        );
        bytes[] memory consents = new bytes[](1);
        consents[0] = _safeProof(artistSafe, digest);
        _safeGovern(
            networkSafe,
            address(records),
            abi.encodeCall(
                records.setRoyaltyRate, (tokenId, rate, works[0].item, state, deadline, consents)
            )
        );
        (,,,,, uint32 stored) = IStream(address(stream)).coreOf(tokenId);
        assertEq(stored, rate);
    }

    /// @dev ECO-20, ECO-42: a release signed by the artist Safe (ERC-1271, no prefix: the
    ///      ledger checks the payout address itself), relayed by anyone, pays the Safe; the
    ///      nonce is spent.
    function test_SafeArtistSignedReleasePaysTheSafe() public onFork {
        _soldSafeWork();
        (address wallet, ISplitWallet.Payee[] memory payees) = _sellerWallet();
        uint256 due = wallet.balance;
        assertGt(due, 0);
        IReleaseVerifier.Authorization memory a = _authorization(wallet, 1);
        bytes memory signature = _safeSignature(artistSafe, releaseVerifier.releaseDigest(a));

        uint256 before = address(artistSafe).balance;
        vm.prank(makeAddr("relayer"));
        splitFactory.releaseWithAuthorization(payees, bytes32(0), a, signature);
        assertEq(address(artistSafe).balance - before, due);
        assertTrue(releaseVerifier.nonceUsed(address(artistSafe), 1));
    }

    /// @dev ECO-20: a signature by the Safe stops verifying once an owner that signed it is
    ///      swapped out (the Safe's ERC-1271 answer changed); the new owner set signs again.
    function test_SafeSignatureFailsAfterAnOwnerSwap() public onFork {
        _soldSafeWork();
        (address wallet, ISplitWallet.Payee[] memory payees) = _sellerWallet();
        IReleaseVerifier.Authorization memory a = _authorization(wallet, 2);
        bytes32 digest = releaseVerifier.releaseDigest(a);
        bytes memory signedBefore = _safeSignature(artistSafe, digest);

        _swapOwner(artistSafe, 1, "artist replacement owner");
        vm.expectRevert(
            abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, address(artistSafe))
        );
        splitFactory.releaseWithAuthorization(payees, bytes32(0), a, signedBefore);

        uint256 before = address(artistSafe).balance;
        splitFactory.releaseWithAuthorization(
            payees, bytes32(0), a, _safeSignature(artistSafe, digest)
        );
        assertGt(address(artistSafe).balance, before);
    }

    /// @dev ECO-15, ECO-42: the artist Safe releases its own share by a Safe transaction (an
    ///      artist payee must call from its payout address); the ETH reaches the Safe through
    ///      the split vault with all gas forwarded, and nobody else can release it.
    function test_SafeArtistReleasesItsShareByATransaction() public onFork {
        _soldSafeWork();
        (address wallet, ISplitWallet.Payee[] memory payees) = _sellerWallet();
        uint256 due = wallet.balance;
        bytes memory call =
            abi.encodeCall(ISplitWallet.release, (payees, bytes32(0), CURRENCY_ETH, 0));
        vm.prank(collector);
        (bool ok,) = address(splitFactory).call(call);
        assertFalse(ok, "only the payout address releases an artist payee");

        uint256 before = address(artistSafe).balance;
        assertTrue(_safeCall(artistSafe, address(splitFactory), call));
        assertEq(address(artistSafe).balance - before, due);
        assertEq(wallet.balance, 0);
    }

    // ------------------------------------------------------------------ the Safe as a holder

    /// @dev A Safe bids with its own ETH, is outbid and claims its credit back to itself, bids
    ///      again, wins, and receives the 721 at settlement (the fallback handler answers
    ///      `onERC721Received`).
    function test_SafeBidsWinsAndReceivesThe721() public onFork {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);

        uint256 start = address(collectorSafe).balance;
        assertTrue(_safeBid(saleId, 1 ether), "first bid");
        _ethBid(saleId, collector, auction.minimumBid(saleId));
        assertEq(auction.claimable(address(collectorSafe), CURRENCY_ETH), 1 ether, "credited");
        assertTrue(
            _safeCall(
                collectorSafe,
                address(auction),
                abi.encodeCall(auction.claim, (CURRENCY_ETH, address(collectorSafe)))
            ),
            "claim the credit"
        );
        assertEq(address(collectorSafe).balance, start, "the credit came back to the Safe");

        uint256 top = auction.minimumBid(saleId);
        assertTrue(_safeBid(saleId, top), "winning bid");
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), address(collectorSafe));
        assertEq(address(collectorSafe).balance, start - top);
    }

    /// @dev A Safe bids in the uniform edition auction with its own ETH and receives its 1155
    ///      copies at the claim (the fallback handler answers `onERC1155Received`).
    function test_SafeReceivesAnEdition() public onFork {
        Work memory w = _work(artist, collectionId);
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.edition = EditionTerms(0, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (uint256 oneSaleId, uint256 tokenId) = _start(root, works, 0);
        uint256 saleId = editionAuction.open(
            address(editions), tokenId, abi.encode(w.item, root, _proofOf(works, 0))
        );
        IUniformEditionAuction ea = IUniformEditionAuction(address(editionAuction));
        uint256 amount = 3 * ea.stepPrice(saleId, 20);
        assertTrue(
            _safeCallValue(
                collectorSafe,
                address(editionAuction),
                amount,
                abi.encodeCall(editionAuction.bid, (saleId, 20, 3))
            ),
            "edition bid"
        );
        _settleAtEnd(oneSaleId);
        editions.createEdition(tokenId, w.item);
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
        for (uint256 i;; ++i) {
            uint256[] memory order = IUniformEditionAuctionLens(address(editionAuction))
                .settlementOrderFor(saleId, address(this));
            if (editionAuction.settle(saleId, order)) break;
            require(i < 64, "settlement does not advance");
        }
        (uint256 won,) = editionAuction.claimBidFor(saleId, 1);
        assertEq(won, 3);
        assertEq(editions.balanceOf(address(collectorSafe), tokenId), 3);
    }

    /// @dev ECO-41: an unbid work goes to the museum's vault; the vault forwards it to the
    ///      museum Safe the network set (7 days), which receives it as an ERC-721 receiver.
    function test_MuseumVaultForwardsAnUnbidWorkToAMuseumSafe() public onFork {
        GovernedVault museumVault = GovernedVault(payable(museum));
        ISafe museumSafeWallet = _newSafe("museum");
        _safeGovern(
            networkSafe,
            address(museumVault),
            abi.encodeCall(
                museumVault.setDestination,
                (museumVault.destinationRevision(), address(museumSafeWallet))
            )
        );
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), museum);
        museumVault.forwardERC721(address(stream), tokenId);
        assertEq(stream.ownerOf(tokenId), address(museumSafeWallet));
    }

    /// @dev ECO-41, ECO-42: the network fee of a sale lands in the fee vault, which forwards it
    ///      to the fee Safe with all gas (the Safe's `receive` emits an event).
    function test_FeeVaultForwardsToTheFeeSafe() public onFork {
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        _sell(root, works, 0, collector, 1 ether);
        uint256 fee = networkFee.balance;
        assertGt(fee, 0, "the sale paid the network fee");
        uint256 before = address(feeSafe).balance;
        GovernedVault(payable(networkFee)).forward(CURRENCY_ETH, type(uint256).max);
        assertEq(address(feeSafe).balance - before, fee);
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
        _keep(root, works);
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
        tokenId = IStream(address(stream)).totalMinted();
    }

    /// @dev The artist Safe's work, sold to the EOA collector for 1 ETH.
    function _soldSafeWork() internal returns (uint256 tokenId) {
        (bytes32 root, Work[] memory works) = _safePackage();
        tokenId = _startBySafe(root, works);
        uint256 saleId = auction.saleIdOf(address(stream), tokenId);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
    }

    /// @dev The artist Safe's seller wallet (sole payee, artist-resolved), deployed.
    function _sellerWallet() internal returns (address wallet, ISplitWallet.Payee[] memory payees) {
        payees = new ISplitWallet.Payee[](1);
        payees[0] = ISplitWallet.Payee(uint256(uint160(address(artistSafe))), address(0), 100_000);
        wallet = splitFactory.createWallet(payees, bytes32(0));
        assertEq(wallet, economics.newWorkTerms(PRODUCT_STREAM, payees).seller);
    }

    function _authorization(address wallet, uint256 nonce)
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
            type(uint256).max,
            nonce,
            block.timestamp + 1 days
        );
    }

    /// @dev Replaces owner `index` of `safe` by a new key, by a Safe transaction to itself
    ///      signed by the current threshold.
    function _swapOwner(ISafe safe, uint256 index, string memory label) internal {
        address[] memory owners = safe.getOwners();
        uint256 oldKey = safeKeys[address(safe)][index];
        address oldOwner = vm.addr(oldKey);
        address prev = address(1); // the Safe owner list's sentinel
        for (uint256 i; i < owners.length && owners[i] != oldOwner; ++i) {
            prev = owners[i];
        }
        (address newOwner, uint256 newKey) = makeAddrAndKey(label);
        assertTrue(
            _safeCall(
                safe, address(safe), abi.encodeCall(ISafe.swapOwner, (prev, oldOwner, newOwner))
            ),
            "swapOwner"
        );
        safeKeys[address(safe)][index] = newKey;
    }

    function _safeBid(uint256 saleId, uint256 amount) internal returns (bool) {
        return _safeCallValue(
            collectorSafe,
            address(auction),
            amount,
            abi.encodeCall(
                auction.bid,
                (
                    saleId,
                    address(0),
                    Payment(PaymentMethod.DIRECT, address(collectorSafe), amount, 0, 0, "")
                )
            )
        );
    }
}
