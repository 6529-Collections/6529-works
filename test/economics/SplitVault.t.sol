// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {
    IERC721Errors,
    IERC1155Errors
} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { SplitVault } from "src/economics/SplitVault.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev Deploys `SplitVault.INIT_CODE` itself (so it is the vault's commander, not the ledger)
///      and measures the bare CREATE2.
contract VaultDeployer {
    function deploy(bytes32 salt) external returns (address vault, uint256 gasUsed) {
        bytes memory code = SplitVault.INIT_CODE;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            vault := create2(0, add(code, 0x20), mload(code), salt)
        }
        gasUsed = before - gasleft();
    }

    /// @dev Sends a vault instruction: `target`, `value`, `data`.
    function instruct(address vault, address target, uint256 value, bytes calldata data)
        external
        returns (bool ok, bytes memory result)
    {
        (ok, result) = vault.call(abi.encodePacked(uint256(uint160(target)), value, data));
    }
}

/// @dev Pays with Solidity's `transfer`: a 2,300-gas stipend.
contract StipendSender {
    function send(address payable to) external payable {
        to.transfer(msg.value);
    }
}

contract Mock721 is ERC721("Mock", "M") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract Mock1155 is ERC1155("") {
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev Answers a plain ETH payment with a megabyte of return data.
contract MegabyteReturner {
    fallback() external payable {
        assembly ("memory-safe") {
            return(0, 0x100000)
        }
    }
}

/// @notice The split wallet's code, `SplitVault`: its exact bytes, what it accepts, what it
///         refuses, and who can move its funds.
contract SplitVaultTest is EconomicsBase {
    address internal wallet;

    function setUp() public override {
        super.setUp();
        wallet = _wallet(_list(_fixed(alice, 60_000), _fixed(bob, 40_000)));
    }

    function test_RuntimeIsTheDocumentedSixtySixBytes() public view {
        bytes memory expected = abi.encodePacked(hex"73", address(ledger), SplitVault.RUNTIME_TAIL);
        assertEq(expected.length, 66);
        assertEq(wallet.code, expected);
        assertEq(SplitVault.INIT_CODE.length, 68);
        assertEq(ledger.walletInitCodeHash(), keccak256(SplitVault.INIT_CODE));
    }

    /// @dev Golden values: every split wallet's address depends on these bytes, so a change to
    ///      `SplitVault` must change this test, the ledger's `walletInitCodeHash` and every
    ///      document that pins them (economics spec, ABIs and interface IDs).
    function test_Golden_InitCodeHashAndRuntime() public {
        assertEq(
            keccak256(SplitVault.INIT_CODE),
            0xb9eef1357f6b37574caf5dac663c3a2daa34e486366257eacc5c9cdba5eb5518
        );
        assertEq(
            SplitVault.RUNTIME_TAIL,
            hex"3314601f5736603657005b5f5f604036038060405f375f6020355f355af1603a575b5f5ffd5b3d5f5f3e3d5ff3"
        );
        assertEq(
            keccak256(wallet.code),
            keccak256(abi.encodePacked(hex"73", address(ledger), SplitVault.RUNTIME_TAIL))
        );
        VaultDeployer deployer = new VaultDeployer();
        (address other,) = deployer.deploy(bytes32(uint256(7)));
        assertEq(other.code, abi.encodePacked(hex"73", address(deployer), SplitVault.RUNTIME_TAIL));
    }

    /// @dev The vault copies a callee's whole return data: a recipient that answers a payment
    ///      with a megabyte fails only its own payee's release (`ETHTransferFailed`), records
    ///      nothing, and leaves every other payee's release as it was.
    function test_AnOversizedReturnFailsOnlyItsOwnRelease() public {
        address big = address(new MegabyteReturner());
        address w = _wallet(_list(_fixed(big, 60_000), _fixed(bob, 40_000)));
        vm.deal(w, 1 ether);
        uint256 iBig = _indexOf(w, big);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.ETHTransferFailed.selector, big, 0.6 ether)
        );
        _release(w, ETH, iBig);
        assertEq(w.balance, 1 ether);
        assertEq(ledger.released(w, ETH, iBig), 0);
        assertEq(_release(w, ETH, _indexOf(w, bob)), 0.4 ether);
        assertEq(bob.balance, 0.4 ether);
    }

    function test_AcceptsPlainETHFromAnyoneWithinTheStipend() public {
        vm.deal(bob, 3 ether);
        vm.prank(bob);
        (bool ok,) = wallet.call{ value: 1 ether }("");
        assertTrue(ok);
        StipendSender sender = new StipendSender();
        vm.prank(bob);
        sender.send{ value: 1 ether }(payable(wallet));
        assertEq(wallet.balance, 2 ether);
    }

    function test_AcceptsETHFromAnotherVault() public {
        VaultDeployer deployer = new VaultDeployer();
        (address other,) = deployer.deploy(bytes32(0));
        vm.deal(other, 1 ether);
        (bool ok,) = deployer.instruct(other, wallet, 1 ether, "");
        assertTrue(ok);
        assertEq(wallet.balance, 1 ether);
        assertEq(other.balance, 0);
    }

    function test_CallsWithCalldataFromAnyoneButTheLedgerRevert() public {
        vm.deal(wallet, 1 ether);
        bytes memory instruction = abi.encodePacked(uint256(uint160(bob)), uint256(1 ether));
        vm.prank(bob);
        (bool ok, bytes memory ret) = wallet.call(instruction);
        assertFalse(ok);
        assertEq(ret.length, 0);
        (ok,) = wallet.call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1));
        assertFalse(ok);
        assertEq(wallet.balance, 1 ether);
        assertEq(bob.balance, 0);
    }

    /// @dev The vault obeys its deployer only: the same instruction moves funds when it comes
    ///      from the ledger. Every rule about when the ledger sends one lives in the ledger.
    function test_OnlyTheLedgersInstructionMovesFunds() public {
        vm.deal(wallet, 1 ether);
        token.mint(wallet, 100);
        vm.startPrank(address(ledger));
        (bool ok,) = wallet.call(abi.encodePacked(uint256(uint160(bob)), uint256(0.25 ether)));
        assertTrue(ok);
        (bool tok, bytes memory ret) = wallet.call(
            abi.encodePacked(
                uint256(uint160(address(token))),
                uint256(0),
                abi.encodeWithSignature("transfer(address,uint256)", bob, 30)
            )
        );
        vm.stopPrank();
        assertTrue(tok);
        assertEq(abi.decode(ret, (bool)), true, "the token's return data comes back");
        assertEq(bob.balance, 0.25 ether);
        assertEq(token.balanceOf(bob), 30);
        // A failed instruction reverts with no data.
        vm.prank(address(ledger));
        (ok, ret) = wallet.call(abi.encodePacked(uint256(uint160(bob)), uint256(5 ether)));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_SafeNftTransfersToAVaultFail() public {
        Mock721 nft = new Mock721();
        nft.mint(address(this), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, wallet)
        );
        nft.safeTransferFrom(address(this), wallet, 1);
        Mock1155 multi = new Mock1155();
        multi.mint(alice, 1, 5);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, wallet)
        );
        multi.safeTransferFrom(alice, wallet, 1, 5, "");
    }

    /// @dev Vault code deployed by anyone else obeys that deployer, and the ledger never counts
    ///      it as a wallet: only the ledger's own CREATE2 creates wallets.
    function test_VaultCodeDeployedElsewhereIsNeverAWallet() public {
        VaultDeployer deployer = new VaultDeployer();
        (address other,) = deployer.deploy(bytes32(0));
        assertEq(other.code, abi.encodePacked(hex"73", address(deployer), SplitVault.RUNTIME_TAIL));
        assertFalse(ledger.isWallet(other));
        assertEq(ledger.configOf(other), bytes32(0));
        vm.deal(other, 1 ether);
        vm.prank(address(ledger));
        (bool ok,) = other.call(abi.encodePacked(uint256(uint160(bob)), uint256(1 ether)));
        assertFalse(ok, "the ledger cannot command another deployer's vault");
    }

    /// @dev Funds at a predicted address stay put until its vault exists; a release reverts with
    ///      `WalletNotDeployed` and moves nothing. The old wallets had their own code, so this
    ///      path did not exist; without the ledger's balance check the call to an empty address
    ///      would "succeed" and the release would be counted without moving anything.
    function test_ReleaseFromAnUndeployedWalletRevertsAndMovesNothing() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 50_000), _fixed(bob, 50_000));
        address predicted = _remember(payees, bytes32(uint256(9)));
        vm.deal(predicted, 1 ether);
        token.mint(predicted, 100);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, predicted));
        _release(predicted, ETH, 0);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, predicted));
        _release(predicted, address(token), _indexOf(predicted, bob));
        assertEq(predicted.balance, 1 ether);
        assertEq(token.balanceOf(predicted), 100);
        assertEq(ledger.totalReleased(predicted, ETH), 0);
        // Deploying it, permissionlessly, releases everything held there.
        vm.prank(makeAddr("anyone"));
        ledger.createWallet(payees, bytes32(uint256(9)));
        _release(predicted, ETH, 0);
        _release(predicted, address(token), _indexOf(predicted, bob));
        assertEq(token.balanceOf(bob), 50);
    }

    /// @dev A wallet is named by its payee list and salt: any other list or salt names another
    ///      address, so it can never reach this wallet's funds.
    function test_AWrongPayeeListOrSaltNamesAnotherAddress() public {
        vm.deal(wallet, 1 ether);
        ISplitWallet.Payee[] memory real = _payeesOf(wallet);
        ISplitWallet.Payee[] memory shifted = _list(_fixed(alice, 90_000), _fixed(bob, 10_000));
        uint256 iAlice = _indexOf(wallet, alice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, iAlice));
        ledger.release(shifted, bytes32(0), ETH, iAlice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, iAlice));
        ledger.release(real, bytes32(uint256(1)), ETH, iAlice);
        // Funds sent to the other address stay there until its own vault exists.
        address other = ledger.walletFor(real, bytes32(uint256(1)));
        vm.deal(other, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, other));
        ledger.release(real, bytes32(uint256(1)), ETH, iAlice);
        assertEq(wallet.balance, 1 ether);
        assertEq(ledger.release(real, bytes32(0), ETH, iAlice), 0.6 ether);
    }

    /// @dev Deployment writes one slot (`configOf`) and creates one account, whatever the payee
    ///      count: the list lives only in calldata and the `WalletCreated` event.
    function test_CreateWalletWritesOneSlotAndOneAccount() public {
        ISplitWallet.Payee[] memory many = new ISplitWallet.Payee[](16);
        for (uint256 i; i < 16; ++i) {
            many[i] = _fixed(address(uint160(i + 1)), i == 0 ? D - 15 : 1);
        }
        address predicted = ledger.walletFor(many, bytes32(0));
        assertEq(predicted.code.length, 0);
        vm.record();
        ledger.createWallet(many, bytes32(0));
        (, bytes32[] memory writes) = vm.accesses(address(ledger));
        assertEq(writes.length, 1, "one slot: configOf");
        (, bytes32[] memory vaultWrites) = vm.accesses(predicted);
        assertEq(vaultWrites.length, 0, "the vault has no storage");
        assertEq(predicted.code.length, 66);
        assertEq(ledger.configOf(predicted), keccak256(abi.encode(many)));
    }

    /// @dev Prague gas of a deployment: the bare vault CREATE2 and `createWallet` by payee count.
    ///      (Glamsterdam estimates are in docs/spec/economics-and-payouts.md.)
    function test_DeploymentGas() public {
        VaultDeployer deployer = new VaultDeployer();
        (, uint256 bare) = deployer.deploy(bytes32(uint256(1)));
        emit log_named_uint("bare vault CREATE2", bare);
        assertLt(bare, 50_000);
        uint256[4] memory counts = [uint256(1), 2, 16, 64];
        uint256[4] memory ceilings = [uint256(90_000), 95_000, 180_000, 450_000];
        for (uint256 k; k < 4; ++k) {
            uint256 n = counts[k];
            ISplitWallet.Payee[] memory list = new ISplitWallet.Payee[](n);
            for (uint256 i; i < n; ++i) {
                list[i] = _artist(1_000 + i, i == 0 ? uint32(D - (n - 1)) : 1);
            }
            uint256 before = gasleft();
            ledger.createWallet(list, bytes32(0));
            uint256 used = before - gasleft();
            emit log_named_uint(string.concat("createWallet, payees: ", vm.toString(n)), used);
            assertLt(used, ceilings[k]);
        }
    }

    /// @dev Logs-only reconstruction: the `WalletCreated` event alone gives the wallet, its
    ///      payee hash, the salt and every payee (kind, ID or account, share).
    function test_WalletCreatedLogsTheWholeConfiguration() public {
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(alice, 50_000), _fixed(bob, 30_000), _artist(ARTIST, 20_000));
        bytes32 salt = bytes32(uint256(77));
        vm.recordLogs();
        address w = ledger.createWallet(payees, salt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(ledger));
        assertEq(logs[0].topics[0], ISplitFactory.WalletCreated.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(w))));
        assertEq(logs[0].topics[2], keccak256(abi.encode(payees)));
        (bytes32 loggedSalt, ISplitWallet.Payee[] memory logged) =
            abi.decode(logs[0].data, (bytes32, ISplitWallet.Payee[]));
        assertEq(loggedSalt, salt);
        assertEq(keccak256(abi.encode(logged)), keccak256(abi.encode(payees)));
        assertEq(ledger.walletFor(logged, loggedSalt), w);
    }
}
