// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
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
import { FixedAuthority, Mock1271Account } from "../mocks/economics/EconomicsMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @dev A multi-signature wallet reduced to what the payout check can see of one: it declares
///      ERC-165 and the token-receiver interfaces, answers ERC-1271, returns nothing for a
///      function it does not have (a Safe with no fallback handler), and calls out for its
///      owners. It declares no network interface and is governed by no AccessManager.
contract MultisigWalletMock {
    address[] public owners;
    uint256 public immutable threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        owners = owners_;
        threshold = threshold_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x150b7a02 || id == 0x4e2312e0;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function execute(address to, bytes calldata payload) external returns (bytes memory) {
        (bool ok, bytes memory result) = to.call(payload);
        require(ok, "call failed");
        return result;
    }

    fallback() external payable { }

    receive() external payable { }
}

/// @dev An artist's own revenue split outside the network: it holds what it is paid, pulls
///      from the ledger when asked and pays its two members half each.
contract OwnSplitMock {
    address payable public immutable first;
    address payable public immutable second;

    constructor(address payable first_, address payable second_) {
        (first, second) = (first_, second_);
    }

    function pull(address ledger, bytes calldata releaseCall) external {
        (bool ok,) = ledger.call(releaseCall);
        require(ok, "release failed");
        uint256 half = address(this).balance / 2;
        first.transfer(half);
        second.transfer(address(this).balance);
    }

    receive() external payable { }
}

/// @notice Who may receive money, on the deployed stack (re-ported from the retired
///         `RecipientValidation` suite). An artist's payout address must be able to pull
///         (artist-resolved payees are pull-only), so the accounts module refuses every
///         contract of the deployment and of the network, none of which can; the network fee
///         recipient must accept payments, so the
///         economics resolver refuses the system contracts that cannot.
contract RecipientValidationPortedTest is IntegrationBase {
    /// @dev A payout the accounts module should have refused was staged.
    error PayoutAccepted(address payout);

    /// @dev The suite deploys the entropy module too, so every contract a deployment can have
    ///      is checked as a payout.
    function _withVrf() internal pure override returns (bool) {
        return true;
    }

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

    /// @dev Stages `payout` and requires the accounts module to refuse it with
    ///      `InvalidIdentity`; `isPayoutAllowed` must say the same. One contract, one assertion.
    function assertRefusedAsPayout(address payout, string calldata name) external {
        assertGt(payout.code.length, 0, string.concat(name, " is not deployed"));
        assertFalse(accounts.isPayoutAllowed(payout), string.concat(name, " reads as allowed"));
        try this.stagePayout(payout) {
            revert PayoutAccepted(payout);
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector),
                string.concat(name, " was not refused as an invalid identity")
            );
        }
    }

    /// @dev No contract of the deployment can call `release` for an artist or sign a release,
    ///      so none can become a payout. Every contract the deployment names
    ///      (`VerifyCore.codeNames`: the factory, the manager and each contract the deploy
    ///      creates, the entropy module included) is tried on its own; a refusal of one says
    ///      nothing about the next, and the failure message lists every contract accepted.
    function test_Payout_RefusesEveryContractOfTheDeployment() public {
        string[] memory names = VerifyCore.codeNames(params);
        assertEq(names.length, DeployCore.order(params).length + 2);
        assertGe(names.length, 35, "the whole deployment, the entropy module included");
        string memory accepted;
        uint256 checked;
        for (uint256 i; i < names.length; ++i) {
            address a = DeployCore.addressOf(deployment, names[i]);
            try this.assertRefusedAsPayout(a, names[i]) {
                ++checked;
            } catch {
                accepted = string.concat(accepted, names[i], " ");
            }
        }
        assertEq(accepted, "", "accepted as an artist payout");
        assertEq(checked, names.length, "every contract was tried");
        assertEq(accounts.payoutAddress(artistId), artist);
    }

    /// @dev Contracts created after genesis are refused by the same rules: a deployed vault of
    ///      someone else and a contract governed by the same AccessManager.
    function test_Payout_RefusesLaterContractsOfTheNetwork() public {
        address governed = address(new FixedAuthority(address(manager)));
        address[2] memory refused = [_otherWallet(true), governed];
        for (uint256 i; i < refused.length; ++i) {
            assertFalse(accounts.isPayoutAllowed(refused[i]));
            vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
            this.stagePayout(refused[i]);
        }
        // A contract governed by another manager is not the network's.
        address foreign = address(new FixedAuthority(makeAddr("anotherManager")));
        assertTrue(accounts.isPayoutAllowed(foreign));
        assertEq(accounts.payoutAddress(artistId), artist);
    }

    /// @dev An account cannot be created for a contract of the deployment either: `register`
    ///      makes the root the payout and applies the same check.
    function test_Payout_RegisterRefusesAContractOfTheDeployment() public {
        address[4] memory refused =
            [address(claimRouter), address(feeVault), address(auction), address(facts)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(address(registry));
            vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
            accounts.register(refused[i], bytes32(0), bytes32(0));
        }
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

    /// @dev Accounts that can pull stay allowed: an EOA, a smart account (an ERC-1271 wallet),
    ///      a multi-signature wallet and an artist's own split contract outside the network.
    ///      None declares a network interface or is governed by the network's manager. Each
    ///      is staged, announced, applied after the own-change delay, and then paid.
    function test_Payout_AcceptsAccountsThatCanPull() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (makeAddr("ownerOne"), makeAddr("ownerTwo"));
        address[4] memory allowed = [
            makeAddr("artistVault"),
            address(new Mock1271Account()),
            address(new MultisigWalletMock(two, 2)),
            address(new OwnSplitMock(payable(two[0]), payable(two[1])))
        ];
        for (uint256 i; i < allowed.length; ++i) {
            assertTrue(accounts.isPayoutAllowed(allowed[i]));
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

        // The split contract, now the payout, pulls the artist's share and pays its members.
        uint256 owed = ledger.releasable(sellerPayees, bytes32(0), address(0), 0);
        assertGt(owed, 0);
        OwnSplitMock(payable(allowed[3]))
            .pull(
                address(ledger),
                abi.encodeCall(ledger.release, (sellerPayees, bytes32(0), address(0), 0))
            );
        assertEq(two[0].balance + two[1].balance, owed);
    }

    /// @dev A multi-signature wallet as the payout pulls the artist's share itself.
    function test_Payout_AMultisigWalletPullsItsShare() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (makeAddr("ownerOne"), makeAddr("ownerTwo"));
        MultisigWalletMock safe = new MultisigWalletMock(two, 2);
        stagePayout(address(safe));
        vm.warp(block.timestamp + accounts.OWN_CHANGE_DELAY());
        accounts.executeChange(artistId);
        uint256 owed = ledger.releasable(sellerPayees, bytes32(0), address(0), 0);
        assertGt(owed, 0);
        safe.execute(
            address(ledger),
            abi.encodeCall(ledger.release, (sellerPayees, bytes32(0), address(0), 0))
        );
        assertEq(address(safe).balance, owed);
    }

    /// @dev The check runs again when a change is executed. An address with no code when the
    ///      change was staged, at which a contract governed by the network's manager is then
    ///      deployed, is caught at execution and the change is cleared.
    function test_Payout_AGovernedContractDeployedWhileTheChangeWaitsIsCaughtAtExecution() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(accounts.isPayoutAllowed(predicted), "no code yet");
        stagePayout(predicted);
        assertEq(address(new FixedAuthority(address(manager))), predicted);
        assertFalse(accounts.isPayoutAllowed(predicted));
        vm.warp(block.timestamp + accounts.OWN_CHANGE_DELAY());
        vm.expectEmit(address(accounts));
        emit IArtistRegistry.ChangeCancelled(artistId, address(accounts), false);
        accounts.executeChange(artistId);
        assertEq(accounts.payoutAddress(artistId), artist);
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
