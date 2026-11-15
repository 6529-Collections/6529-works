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
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Roles } from "src/governance/Roles.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { ProtocolContracts } from "src/libraries/ProtocolContracts.sol";
import {
    BlocklistToken,
    NoReturnToken,
    RejectingRecipient
} from "../mocks/economics/EconomicsMocks.sol";
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
}

/// @dev Exposes the protocol-contract check the economics resolver applies to fee recipients.
contract ProtocolProbe {
    function isProtocolContract(address account) external view returns (bool) {
        return ProtocolContracts.isProtocolContract(account);
    }
}

/// @notice The governed vault the network fee recipient and the museum become: it receives ETH,
///         ERC-20s, ERC-721s and ERC-1155s, moves them only to a destination governance sets on
///         the funds path (FUNDS_SETTER, 14 days), and can be a split-wallet payee that releases
///         or consents to escrow recovery toward that destination.
/// @dev New contract: every test fails without it (the file does not compile on main).
contract GovernedVaultTest is EconomicsBase {
    GovernedVault internal vault;
    address internal safe = makeAddr("networkSafe");
    address internal stranger = makeAddr("vaultStranger");

    function setUp() public override {
        super.setUp();
        vault = new GovernedVault(address(manager), ledger, safe);
    }

    function test_ConstructorSetsTheFirstDestination() public {
        vm.expectEmit(true, true, false, true);
        emit IGovernedVault.DestinationSet(address(0), safe, 1);
        GovernedVault v = new GovernedVault(address(manager), ledger, safe);
        assertEq(v.destination(), safe);
        assertEq(v.destinationRevision(), 1);
        assertEq(address(v.ledger()), address(ledger));
        assertEq(v.authority(), address(manager));
    }

    function test_ConstructorRefusesBadDestinationsAndLedgers() public {
        vm.expectRevert(
            abi.encodeWithSelector(IGovernedVault.InvalidDestination.selector, address(0))
        );
        new GovernedVault(address(manager), ledger, address(0));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        new GovernedVault(address(manager), ISplitLedger(alice), safe);
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
        GovernedVault v =
            new GovernedVault(address(manager), ledger, address(new RejectingRecipient()));
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
        uint32 delay = Roles.FUNDS;
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
        assertEq(vault.releaseToDestination(payees, bytes32(0), address(usdc), index), 100);
        assertEq(usdc.balanceOf(safe), 100);
    }

    /// @dev A credit escrowed under the vault (a token that blocks it) moves to the destination
    ///      with the vault's consent, which anyone may record, and governance's `recover`.
    function test_EscrowCreditMovesToTheDestinationWithTheVaultsConsent() public {
        BlocklistToken usdc = new BlocklistToken();
        usdc.mint(address(this), 50);
        usdc.approve(address(escrow), 50);
        escrow.depositERC20(address(vault), address(usdc), 50);
        usdc.setBlocked(address(vault), true);
        vm.expectRevert();
        escrow.flush(address(vault), address(usdc));

        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.RecoveryNotConsented.selector, address(vault), safe
            )
        );
        escrow.recover(address(vault), safe, address(usdc));
        vm.prank(stranger);
        vault.consentToRecovery(escrow);
        assertEq(escrow.recoveryConsent(address(vault)), safe);
        escrow.recover(address(vault), safe, address(usdc));
        escrow.flush(safe, address(usdc));
        assertEq(usdc.balanceOf(safe), 50);
    }
}
