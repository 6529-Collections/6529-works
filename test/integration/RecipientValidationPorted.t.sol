// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import {
    PRODUCT_EDITIONS,
    PRODUCT_INDEPENDENT,
    PRODUCT_STREAM
} from "src/interfaces/types/EconomicsTypes.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { Mock1271Account } from "../mocks/economics/EconomicsMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Who may receive money, on the deployed stack (re-ported from the retired
///         `RecipientValidation` suite). An artist's payout address must be able to pull
///         (artist-resolved payees are pull-only), so the accounts module refuses the network
///         contracts that cannot; the network fee recipient must accept payments, so the
///         economics resolver refuses the system contracts that cannot.
contract RecipientValidationPortedTest is IntegrationBase {
    /// @dev A payout the accounts module should have refused was staged.
    error PayoutAccepted(address payout);

    address internal artist;
    address internal bidder = makeAddr("recipientBidder");
    address internal stranger = makeAddr("recipientStranger");
    uint256 internal artistId;
    address internal seller;
    ISplitWallet.Payee[] internal sellerPayees;

    function setUp() public override {
        super.setUp();
        artist = _actor("recipientArtist");
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        artistId = accounts.artistIdOf(artist);
        _sell(root, works, 0, bidder, 1 ether);
        for (uint256 i; i < works[0].item.payees.length; ++i) {
            sellerPayees.push(works[0].item.payees[i]);
        }
        seller = ledger.createWallet(works[0].item.payees, bytes32(0));
    }

    /// @dev The artist's next identity with `payout`, staged by the artist's own signature.
    function stagePayout(address payout) public {
        (ArtistIdentity memory id,) = accounts.artist(artistId);
        id.payout = payout;
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            accounts.changeDigest(artistId, id, accounts.changeNonce(artistId), deadline);
        accounts.stageChange(
            artistId, id, deadline, abi.encodePacked(artist, _sign(artist, digest))
        );
    }

    /// @dev Someone else's single-payee vault, deployed when `deploy`.
    function _otherWallet(bool deploy) internal returns (address) {
        ISplitWallet.Payee[] memory other = new ISplitWallet.Payee[](1);
        other[0] = ISplitWallet.Payee(0, makeAddr("someoneElse"), Splits.DENOMINATOR);
        return deploy
            ? ledger.createWallet(other, bytes32(uint256(1)))
            : ledger.walletFor(other, bytes32(uint256(1)));
    }

    // ------------------------------------------------------------------ artist payouts

    /// @dev The deployed contracts the accounts module knows or recognises (ERC-165) cannot
    ///      become a payout: the escrow, both tokens, the directory, the split ledger, the
    ///      statement log, the package registry, the accounts module itself and a deployed vault.
    function test_Payout_RefusesNetworkContractsThatCannotPull() public {
        address[9] memory refused = [
            address(escrow),
            address(stream),
            address(editions),
            address(directory),
            address(ledger),
            address(statements),
            address(registry),
            address(accounts),
            _otherWallet(true)
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
            this.stagePayout(refused[i]);
        }
        assertEq(accounts.payoutAddress(artistId), artist);
    }

    /// @dev The claim router, both sale adapters and WorkFacts cannot call `release` either
    ///      (`ProtocolContracts` names the first three as unable to pull a payout), yet the
    ///      accounts module accepts each: `_payoutAllowed` compares only its wired addresses and
    ///      probes a list of interfaces that includes none of the router's or the adapters', and
    ///      WorkFacts declares no ERC-165. With the router as payout, any stranger can strand an
    ///      ERC-20 artist share: `ClaimRouter.claim` releases it to the router (the router is
    ///      then the payout, so the ledger's caller check passes), and the router has no way to
    ///      move tokens on.
    function check_Payout_RefusesTheRouterTheAdaptersAndWorkFacts() external {
        address[4] memory refused =
            [address(claimRouter), address(auction), address(editionAuction), address(facts)];
        for (uint256 i; i < refused.length; ++i) {
            try this.stagePayout(refused[i]) {
                revert PayoutAccepted(refused[i]);
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
            }
        }
    }

    function test_Finding_PayoutAcceptsTheRouterTheAdaptersAndWorkFacts() public {
        _expectFailure(
            abi.encodeCall(this.check_Payout_RefusesTheRouterTheAdaptersAndWorkFacts, ()),
            PayoutAccepted.selector,
            "Accounts accepts the claim router, the sale adapters and WorkFacts as a payout"
        );
    }

    /// @dev With the artist's own wallet as payout, a stranger batching the artist's index
    ///      through the router gets `NotPayoutAddress`; the share stays for the artist alone.
    function test_StrangerCannotMoveTheArtistShareThroughTheRouter() public {
        uint256 owed = ledger.releasable(sellerPayees, bytes32(0), address(0), 0);
        assertGt(owed, 0, "the sale paid the seller vault");
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](1);
        claims[0] = IClaimRouter.Claim(sellerPayees, bytes32(0), address(0), 0);
        bytes memory reason = abi.encodeWithSelector(
            ISplitWallet.NotPayoutAddress.selector, address(claimRouter), artist
        );
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, seller, reason.length, reason
            )
        );
        claimRouter.claim(claims, false);
        assertEq(ledger.releasable(sellerPayees, bytes32(0), address(0), 0), owed);
        uint256 before = artist.balance;
        vm.prank(artist);
        assertEq(ledger.release(sellerPayees, bytes32(0), address(0), 0), owed);
        assertEq(artist.balance - before, owed);
    }

    /// @dev Accounts that can pull stay allowed: an EOA and a smart account (an ERC-1271
    ///      wallet declaring none of the network interfaces). Staged, announced, applied after
    ///      the own-change delay.
    function test_Payout_AcceptsAccountsThatCanPull() public {
        address[2] memory allowed = [makeAddr("artistVault"), address(new Mock1271Account())];
        for (uint256 i; i < allowed.length; ++i) {
            vm.recordLogs();
            stagePayout(allowed[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool staged;
            for (uint256 j; j < logs.length; ++j) {
                if (
                    logs[j].emitter == address(accounts)
                        && logs[j].topics[0] == IArtistRegistry.ChangeStaged.selector
                ) staged = true;
            }
            assertTrue(staged, "ChangeStaged");
            vm.warp(block.timestamp + accounts.OWN_CHANGE_DELAY());
            accounts.executeChange(artistId);
            assertEq(accounts.payoutAddress(artistId), allowed[i]);
        }
    }

    /// @dev A vault's predicted address has no code until someone deploys it, so it cannot be
    ///      told apart from an empty account at staging. Deployed while the change waits, it is
    ///      caught at execution and the change is cleared.
    function test_Payout_APredictedVaultIsCaughtOnceDeployed() public {
        stagePayout(_otherWallet(false));
        _otherWallet(true);
        vm.warp(block.timestamp + accounts.OWN_CHANGE_DELAY());
        vm.expectEmit(address(accounts));
        emit IArtistRegistry.ChangeCancelled(artistId, address(accounts), false);
        accounts.executeChange(artistId);
        assertEq(accounts.payoutAddress(artistId), artist);
    }

    // ------------------------------------------------------------------ the network fee

    /// @dev The network's wait for `setFeeTerms` under the genesis policy.
    function _feeDelay() internal view returns (uint32 delay) {
        bool immediate;
        (immediate, delay) =
            manager.canCall(network, address(economics), economics.setFeeTerms.selector);
        assertFalse(immediate);
        assertGt(delay, 0);
    }

    /// @dev Governance cannot point a product's network fee at a system contract that cannot
    ///      accept a payment: each governed execution reverts after the network's wait, and the
    ///      product keeps its recipient.
    function test_FeeRecipient_RefusesSystemContracts() public {
        address[11] memory refused = [
            address(escrow),
            address(claimRouter),
            address(auction),
            address(editionAuction),
            address(stream),
            address(editions),
            address(economics),
            address(allowlist),
            address(ledger),
            address(accounts),
            address(registry)
        ];
        bytes32[3] memory products = [PRODUCT_STREAM, PRODUCT_EDITIONS, PRODUCT_INDEPENDENT];
        bytes[11] memory calls;
        for (uint256 i; i < refused.length; ++i) {
            bytes32 product = products[i % 3];
            (uint64 revision,,) = economics.revisions(product);
            calls[i] =
                abi.encodeCall(economics.setFeeTerms, (product, revision, refused[i], 25_000));
            vm.prank(network);
            manager.schedule(address(economics), calls[i], 0);
        }
        vm.warp(block.timestamp + _feeDelay());
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(network);
            vm.expectRevert(
                abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, refused[i])
            );
            manager.execute(address(economics), calls[i]);
            assertEq(economics.networkFeeRecipient(products[i % 3]), networkFee);
        }
    }

    /// @dev The refused change leaves the fee recipient valid: a work started afterwards
    ///      settles and pays the network its share directly, nothing escrowed.
    function test_FeeRecipient_WorksStartedAfterARefusedChangeSettle() public {
        (uint64 revision,,) = economics.revisions(PRODUCT_STREAM);
        bytes memory call = abi.encodeCall(
            economics.setFeeTerms, (PRODUCT_STREAM, revision, address(escrow), 25_000)
        );
        vm.prank(network);
        manager.schedule(address(economics), call, 0);
        vm.warp(block.timestamp + _feeDelay());
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.InvalidFeeRecipient.selector, address(escrow))
        );
        manager.execute(address(economics), call);

        uint32 share = economics.economics(PRODUCT_STREAM).feeShare;
        Work[] memory works = _one(_work(artist, collectionId));
        bytes32 root = _publish(works);
        uint256 feeBefore = networkFee.balance;
        uint256 tokenId = _sell(root, works, 0, bidder, 1 ether);
        assertEq(stream.ownerOf(tokenId), bidder);
        assertEq(
            networkFee.balance - feeBefore, 1 ether * uint256(share) / 100_000, "the fee is paid"
        );
        assertEq(escrow.totalOwed(address(0)), 0);
    }
}
