// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice The revenue escrow behind refused payouts, on the real stack: a settlement whose
///         seller wallet refuses ETH still settles and credits the escrow for that wallet; anyone
///         flushes it once the wallet accepts again; the network's recovery paths that remain
///         (a split wallet's credit to a wallet with the same payees, its own vaults' credits
///         without consent, anyone else's only with that account's single-use consent).
/// @dev The seller is the work's split vault, which always accepts ETH. `vm.etch` of a reverting
///      runtime at its address stands for any wallet that refuses a payment; the vault's code is
///      put back to show the money then reaches it.
contract EscrowRecoveryTest is RecordFlowsBase {
    address internal lead;
    address internal collector = makeAddr("escrowCollector");
    address internal stranger = makeAddr("escrowStranger");
    address internal newSafe = makeAddr("escrowNewSafe");

    function setUp() public override {
        super.setUp();
        lead = _actor("escrowLead");
    }

    /// @dev A work sold for 1 ether while its seller vault refuses ETH. Returns the work, the
    ///      seller, the seller's part and the vault's own code.
    function _soldWhileRefusing()
        internal
        returns (Work memory w, address seller, uint256 part, bytes memory code)
    {
        w = _work(lead, collectionId);
        Work[] memory works = _one(w);
        (uint256 saleId,) = _startAndOpen(_publish(works), works, 0);
        seller = auction.auction(saleId).seller;
        code = seller.code;
        assertGt(code.length, 0, "the vault is deployed");
        _ethBid(saleId, collector, 1 ether);
        uint256 fee = 1 ether - 1 ether * (100_000 - auction.auction(saleId).feeShare) / 100_000;
        part = 1 ether - fee;
        vm.etch(seller, hex"5f5ffd");
        uint256 vault = networkFee.balance;
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Credited(seller, address(0), address(auction), part, part);
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - vault, fee, "the network's share paid directly");
        assertEq(escrow.owed(seller, address(0)), part, "the seller's part escrowed");
        assertEq(escrow.totalOwed(address(0)), part);
    }

    function test_Escrow_ARefusedSellerPayoutIsEscrowedThenFlushedAndReleased() public {
        (Work memory w, address seller, uint256 part, bytes memory code) = _soldWhileRefusing();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.ETHTransferFailed.selector, seller, part)
        );
        escrow.flush(seller, address(0));

        vm.etch(seller, code);
        vm.prank(stranger);
        assertEq(escrow.flush(seller, address(0)), part);
        assertEq(seller.balance, part);
        assertEq(escrow.owed(seller, address(0)), 0);
        // The artist pulls its share from the vault.
        uint256 before = lead.balance;
        vm.prank(lead);
        assertEq(ledger.release(w.item.payees, bytes32(0), address(0), 0), part);
        assertEq(lead.balance - before, part);
    }

    /// @dev The network moves a split wallet's credit only to a wallet with the same payees (a
    ///      new salt), where the artist releases it; any other replacement is refused. The
    ///      recovery counts as a new credit to the replacement.
    function test_Escrow_TheNetworkRecoversASplitWalletsCreditToAnEquivalentWallet() public {
        (Work memory w, address seller, uint256 part,) = _soldWhileRefusing();
        _governExpectRevert(
            network,
            address(escrow),
            abi.encodeCall(escrow.recover, (seller, newSafe, address(0))),
            abi.encodeWithSelector(IRevenueEscrow.NotEquivalentWallet.selector, seller, newSafe)
        );
        address replacement = ledger.createWallet(w.item.payees, bytes32(uint256(1)));
        assertEq(ledger.configOf(replacement), ledger.configOf(seller));
        vm.prank(stranger);
        (bool ok,) =
            address(escrow).call(abi.encodeCall(escrow.recover, (seller, replacement, address(0))));
        assertFalse(ok, "the network only");
        _govern(
            network,
            address(escrow),
            abi.encodeCall(escrow.recover, (seller, replacement, address(0)))
        );
        assertEq(escrow.owed(seller, address(0)), 0);
        assertEq(escrow.owed(replacement, address(0)), part);
        (,,,, uint48 openedAt,) = escrow.credits(replacement, address(0));
        assertEq(openedAt, block.timestamp, "a new credit to the replacement");

        escrow.flush(replacement, address(0));
        vm.prank(lead);
        assertEq(ledger.release(w.item.payees, bytes32(uint256(1)), address(0), 0), part);
    }

    /// @dev Anyone else's credit moves only where that account named, once.
    function test_Escrow_AnotherAccountsCreditMovesOnlyWithItsConsent() public {
        address other = makeAddr("escrowOther");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        escrow.depositETH{ value: 0.4 ether }(other);
        bytes memory call = abi.encodeCall(escrow.recover, (other, newSafe, address(0)));
        _governExpectRevert(
            network,
            address(escrow),
            call,
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, other, newSafe)
        );
        vm.prank(other);
        escrow.consentToRecovery(makeAddr("elsewhere"));
        _governExpectRevert(
            network,
            address(escrow),
            call,
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, other, newSafe)
        );
        vm.prank(other);
        escrow.consentToRecovery(newSafe);
        _govern(network, address(escrow), call);
        assertEq(escrow.owed(newSafe, address(0)), 0.4 ether);
        assertEq(escrow.recoveryConsent(other), address(0), "one consent, one recovery");

        vm.prank(stranger);
        escrow.depositETH{ value: 0.1 ether }(other);
        _governExpectRevert(
            network,
            address(escrow),
            call,
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, other, newSafe)
        );
    }

    /// @dev The network's own vaults (whose authority is the escrow's) move without consent.
    function test_Escrow_TheNetworkMovesItsOwnVaultsCreditWithoutConsent() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        escrow.depositETH{ value: 0.3 ether }(museum);
        assertEq(escrow.recoveryConsent(museum), address(0));
        _govern(
            network, address(escrow), abi.encodeCall(escrow.recover, (museum, newSafe, address(0)))
        );
        assertEq(escrow.owed(museum, address(0)), 0);
        assertEq(escrow.owed(newSafe, address(0)), 0.3 ether);
        escrow.flush(newSafe, address(0));
        assertEq(newSafe.balance, 0.3 ether);
    }
}
