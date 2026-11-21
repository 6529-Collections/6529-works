// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Roles } from "src/governance/Roles.sol";
import { ProtocolContracts } from "src/libraries/ProtocolContracts.sol";
import {
    BlocklistToken,
    NoReturnToken,
    RejectingRecipient
} from "../mocks/economics/EconomicsMocks.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { ReturnDataMock } from "test/mocks/libraries/AdversarialTargets.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract VaultTest721 is ERC721("Work", "WRK") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function safeMint(address to, uint256 id) external {
        _safeMint(to, id);
    }
}

contract VaultTest1155 is ERC1155("") {
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts) external {
        _mintBatch(to, ids, amounts, "");
    }
}

/// @dev Exposes the protocol-contract check the economics resolver applies to fee recipients.
contract ProtocolProbe {
    function isProtocolContract(address account) external view returns (bool) {
        return ProtocolContracts.isProtocolContract(account);
    }
}

/// @notice The governed vault the network fee recipient and the museum become: it receives ETH,
///         ERC-20s, ERC-721s and ERC-1155s, moves them only to a destination the network sets
///         with a delay, and can be a split-wallet payee that releases toward that destination.
///         The network moves its escrow credits itself (C19).
/// @dev New contract: every test fails without it (the file does not compile on main).
contract GovernedVaultTest is EconomicsBase {
    GovernedVault internal vault;
    address internal safe = makeAddr("networkSafe");
    address internal stranger = makeAddr("vaultStranger");

    function setUp() public override {
        super.setUp();
        vault = new GovernedVault(address(manager), safe);
    }

    function test_ConstructorSetsTheFirstDestination() public {
        vm.expectEmit(true, true, false, true);
        emit IGovernedVault.DestinationSet(address(0), safe, 1);
        GovernedVault v = new GovernedVault(address(manager), safe);
        assertEq(v.destination(), safe);
        assertEq(v.destinationRevision(), 1);
        assertEq(v.authority(), address(manager));
    }

    function test_ConstructorRefusesBadDestinations() public {
        vm.expectRevert(
            abi.encodeWithSelector(IGovernedVault.InvalidDestination.selector, address(0))
        );
        new GovernedVault(address(manager), address(0));
    }

    // ------------------------------------------------------------------ receiving

    function test_AcceptsETHWithinAStipendAndAPayoutAllowance() public {
        vm.deal(address(this), 2 ether);
        payable(address(vault)).transfer(1 ether); // 2,300-gas stipend
        vm.deal(address(payer), 1 ether);
        assertFalse(payer.payETH(address(vault), 1 ether, 100_000), "paid directly, not escrowed");
        assertEq(address(vault).balance, 2 ether);
        assertEq(escrow.owed(address(vault), ETH), 0);
    }

    function test_ReceivesWorksThroughSafeTransfers() public {
        VaultTest721 works = new VaultTest721();
        works.safeMint(address(vault), 1);
        assertEq(works.ownerOf(1), address(vault));
        VaultTest1155 editions = new VaultTest1155();
        editions.mint(address(vault), 7, 3);
        assertEq(editions.balanceOf(address(vault), 7), 3);
        assertTrue(vault.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(vault.supportsInterface(type(IGovernedVault).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
    }

    /// @dev The resolver refuses recognised protocol contracts as fee recipient or museum; the
    ///      vault declares none of their interfaces, so it can be named.
    function test_IsNotAProtocolContract() public {
        assertFalse(new ProtocolProbe().isProtocolContract(address(vault)));
    }

    // ------------------------------------------------------------------ forwarding

    function test_AnyoneForwardsETHToTheDestinationOnly() public {
        vm.deal(address(vault), 3 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IGovernedVault.Forwarded(ETH, safe, 1 ether);
        vm.prank(stranger);
        assertEq(vault.forward(ETH, 1 ether), 1 ether);
        vm.prank(stranger);
        assertEq(vault.forward(ETH, type(uint256).max), 2 ether);
        assertEq(safe.balance, 3 ether);
        assertEq(stranger.balance, 0);
        vm.expectRevert(abi.encodeWithSelector(IGovernedVault.NothingToForward.selector, ETH));
        vault.forward(ETH, type(uint256).max);
    }

    function test_ForwardsERC20sIncludingTokensThatReturnNothing() public {
        token.mint(address(vault), 500);
        assertEq(vault.forward(address(token), 200), 200);
        assertEq(vault.forward(address(token), type(uint256).max), 300);
        assertEq(token.balanceOf(safe), 500);
        NoReturnToken quiet = new NoReturnToken();
        quiet.mint(address(vault), 9);
        assertEq(vault.forward(address(quiet), type(uint256).max), 9);
        assertEq(quiet.balanceOf(safe), 9);
    }

    function test_ARefusingDestinationKeepsTheFunds() public {
        GovernedVault v = new GovernedVault(address(manager), address(new RejectingRecipient()));
        vm.deal(address(v), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernedVault.ETHTransferFailed.selector, v.destination(), 1 ether
            )
        );
        v.forward(ETH, 1 ether);
        assertEq(address(v).balance, 1 ether);
    }

    function test_ForwardsWorksAndEditionsToTheDestination() public {
        VaultTest721 works = new VaultTest721();
        works.mint(address(vault), 5);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IGovernedVault.TokenForwarded(address(works), 5, safe, 1);
        vm.prank(stranger);
        vault.forwardERC721(address(works), 5);
        assertEq(works.ownerOf(5), safe);

        VaultTest1155 editions = new VaultTest1155();
        editions.mint(address(vault), 7, 4);
        vm.prank(stranger);
        vault.forwardERC1155(address(editions), 7, 3);
        assertEq(editions.balanceOf(safe, 7), 3);
        assertEq(editions.balanceOf(address(vault), 7), 1);
    }

    /// @dev The vault accepts a batch of editions (the batch receiver hook) and forwards each.
    function test_AcceptsABatchOfEditionsAndForwardsEach() public {
        VaultTest1155 editions = new VaultTest1155();
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (1, 2, 3, 4);
        editions.mintBatch(address(vault), ids, amounts);
        assertEq(editions.balanceOf(address(vault), 1), 3);
        assertEq(editions.balanceOf(address(vault), 2), 4);
        assertEq(
            vault.onERC1155BatchReceived(address(0), address(0), ids, amounts, ""),
            IERC1155Receiver.onERC1155BatchReceived.selector
        );
        vm.prank(stranger);
        vault.forwardERC1155(address(editions), 2, 4);
        assertEq(editions.balanceOf(safe, 2), 4);
    }

    // ------------------------------------------------------------------ the destination

    function test_SetDestinationIsCompareAndSet() public {
        address next = makeAddr("nextSafe");
        vm.expectRevert(abi.encodeWithSelector(IGovernedVault.RevisionMismatch.selector, 2, 1));
        vault.setDestination(2, next);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IGovernedVault.DestinationSet(safe, next, 2);
        vault.setDestination(1, next);
        assertEq(vault.destination(), next);
        assertEq(vault.destinationRevision(), 2);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernedVault.InvalidDestination.selector, address(vault))
        );
        vault.setDestination(2, address(vault));
        vm.deal(address(vault), 1 ether);
        vault.forward(ETH, 1 ether);
        assertEq(next.balance, 1 ether);
    }

    /// @dev FUNDS_SETTER with the 14-day funds delay: a stranger is refused, and a scheduled
    ///      change runs only after the delay (a guardian may cancel it meanwhile).
    function test_SetDestinationIsGovernedInTheFundsClass() public {
        address next = makeAddr("nextSafe");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        vault.setDestination(1, next);

        uint64 funds = Roles.FUNDS_SETTER;
        uint32 delay = Roles.DELAY_3D;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IGovernedVault.setDestination.selector;
        manager.setTargetFunctionRole(address(vault), selectors, funds);
        manager.grantRole(funds, stranger, delay);
        bytes memory call = abi.encodeCall(IGovernedVault.setDestination, (1, next));
        vm.startPrank(stranger);
        manager.schedule(address(vault), call, 0);
        vm.warp(block.timestamp + delay - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotReady.selector,
                manager.hashOperation(stranger, address(vault), call)
            )
        );
        manager.execute(address(vault), call);
        vm.warp(block.timestamp + 1);
        manager.execute(address(vault), call);
        vm.stopPrank();
        assertEq(vault.destination(), next);
    }

    // ------------------------------------------------------------------ as a payee

    /// @dev The vault as the fee payee of a royalty wallet: anyone pushes its share to it; when a
    ///      token blocks the vault, anyone releases its share straight to the destination.
    function test_PayeeShareIsPushedOrReleasedToTheDestination() public {
        address seller = makeAddr("sellerWallet");
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(seller, 75_000), _fixed(address(vault), 25_000));
        address royalty = _wallet(payees);
        uint256 index = _indexOf(royalty, address(vault));
        vm.deal(royalty, 4 ether);
        vm.prank(stranger);
        _release(royalty, ETH, index);
        assertEq(address(vault).balance, 1 ether);

        BlocklistToken usdc = new BlocklistToken();
        usdc.mint(royalty, 400);
        usdc.setBlocked(address(vault), true);
        vm.expectRevert();
        _release(royalty, address(usdc), index);
        vm.prank(stranger);
        assertEq(vault.releaseToDestination(ledger, payees, bytes32(0), address(usdc), index), 100);
        assertEq(usdc.balanceOf(safe), 100);
    }

    /// @dev C19: a credit escrowed under the vault (a token that blocks it) is the network's own,
    ///      so the network moves it with `recover` and no consent, to wherever it names. Fails
    ///      without the change: `recover` requires the vault's recorded consent.
    function test_TheNetworkMovesTheVaultsEscrowCreditWithoutConsent() public {
        BlocklistToken usdc = new BlocklistToken();
        usdc.mint(address(this), 50);
        usdc.approve(address(escrow), 50);
        escrow.depositERC20(address(vault), address(usdc), 50);
        usdc.setBlocked(address(vault), true);
        vm.expectRevert();
        escrow.flush(address(vault), address(usdc));

        address elsewhere = makeAddr("elsewhere");
        assertEq(escrow.recoveryConsent(address(vault)), address(0), "no consent recorded");
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Recovered(address(vault), elsewhere, address(usdc), 50, 50, false);
        escrow.recover(address(vault), elsewhere, address(usdc));
        escrow.flush(elsewhere, address(usdc));
        assertEq(usdc.balanceOf(elsewhere), 50);
    }

    /// @dev Review C F4: a work moves only to a destination that accepts ERC-721s. A split vault
    ///      or a plain contract refuses it and the work stays in the vault; an account works.
    ///      Fails without the change: `transferFrom` strands the work in the contract.
    function test_ForwardERC721RefusesADestinationThatCannotHoldWorks() public {
        VaultTest721 works = new VaultTest721();
        works.mint(address(vault), 9);
        address splitVault = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        address[2] memory refusing = [splitVault, address(new ProtocolProbe())];
        for (uint256 i; i < 2; ++i) {
            GovernedVault v = new GovernedVault(address(manager), refusing[i]);
            works.mint(address(v), 10 + i);
            vm.expectRevert();
            vm.prank(stranger);
            v.forwardERC721(address(works), 10 + i);
            assertEq(works.ownerOf(10 + i), address(v), "the work stays in the vault");
        }
        VaultTest1155 editions = new VaultTest1155();
        GovernedVault toSplit = new GovernedVault(address(manager), splitVault);
        editions.mint(address(toSplit), 1, 2);
        vm.expectRevert();
        toSplit.forwardERC1155(address(editions), 1, 2);
        assertEq(editions.balanceOf(address(toSplit), 1), 2);
        // A destination that accepts works (another governed vault) receives it.
        GovernedVault successor = new GovernedVault(address(manager), safe);
        vault.setDestination(1, address(successor));
        vault.forwardERC721(address(works), 9);
        assertEq(works.ownerOf(9), address(successor));
    }

    /// @dev The caller picks the ledger, so its answer is copied only up to 1,024 bytes: a
    ///      longer refusal reverts with `BoundedCallFailed(ledger)`, a short one keeps its
    ///      reason, and an answer that is not one word is malformed. Fails without the change:
    ///      the typed call re-raises the whole 4,096-byte payload.
    function test_ReleaseToDestinationBoundsTheLedgersAnswer() public {
        ReturnDataMock fake = new ReturnDataMock();
        ISplitWallet.Payee[] memory payees = _list(_fixed(address(vault), 100_000));
        ISplitLedger ledger_ = ISplitLedger(address(fake));

        fake.configure(new bytes(4096), true);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, address(fake))
        );
        vault.releaseToDestination(ledger_, payees, bytes32(0), ETH, 0);

        bytes memory reason = abi.encodeWithSignature("Refused(uint256)", 7);
        fake.configure(reason, true);
        vm.expectRevert(reason);
        vault.releaseToDestination(ledger_, payees, bytes32(0), ETH, 0);

        fake.configure(abi.encode(uint256(1), uint256(2)), false);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallMalformedReturn.selector, address(fake))
        );
        vault.releaseToDestination(ledger_, payees, bytes32(0), ETH, 0);

        fake.configure(abi.encode(uint256(5)), false);
        assertEq(vault.releaseToDestination(ledger_, payees, bytes32(0), ETH, 0), 5);

        address codeless = makeAddr("codelessLedger");
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallMalformedReturn.selector, codeless)
        );
        vault.releaseToDestination(ISplitLedger(codeless), payees, bytes32(0), ETH, 0);
    }
}
