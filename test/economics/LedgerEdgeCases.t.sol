// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { MockERC20 } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev A token whose `transfer` moves the amount and then returns two words.
contract LongReturnToken is MockERC20("Long", "LNG") {
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        assembly ("memory-safe") {
            mstore(0, 1)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

/// @dev An account whose plain-ETH fallback accepts the value and returns two words.
contract LongReturnRecipient {
    fallback() external payable {
        assembly ("memory-safe") {
            mstore(0, 1)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

/// @notice Review C, missing test 7: the split ledger's edges (LIM-ECO-9) fail closed with no
///         movement. A vault or the ledger named as the asset, a vault as the signer of a release
///         authorization, an ETH recipient or a token returning more than one word. Each test pins
///         the documented behaviour; the payee-list cases (an artist ID of 2^160 or more, the
///         ledger as fixed payee) are in `SplitFactory.t.sol`
///         (`test_RejectsPayeesThatCanNeverBePaid`).
contract LedgerEdgeCasesTest is EconomicsBase {
    address internal wallet;

    function setUp() public override {
        super.setUp();
        wallet = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        vm.deal(wallet, 2 ether);
    }

    /// @dev The wallet itself, another vault and the ledger as `asset`: the balance read fails
    ///      (the vault refuses a static call from the ledger; the ledger has no `balanceOf`), the
    ///      release reverts, nothing moves.
    function test_AVaultOrTheLedgerAsTheAssetReverts() public {
        address other = _wallet(_list(_fixed(alice, D)));
        address[3] memory assets = [wallet, other, address(ledger)];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert();
            vm.prank(alice);
            ledger.release(_payeesOf(wallet), bytes32(0), assets[i], _indexOf(wallet, alice));
        }
        assertEq(wallet.balance, 2 ether);
        assertEq(alice.balance, 0);
    }

    /// @dev A vault as the fixed payee whose authorization is checked: its ERC-1271 answer is a
    ///      static call into the vault's instruction path, which halts, so the check reports a
    ///      shortfall (`BoundedCallShortfall`), not `InvalidSignature`. Nothing moves, no nonce is
    ///      used. Nested vaults are push-only.
    function test_AVaultAsASignerRevertsWithAShortfall() public {
        address child = _wallet(_list(_fixed(alice, D)));
        ISplitWallet.Payee[] memory parentPayees = _list(_fixed(child, 50_000), _fixed(bob, 50_000));
        address parent = _wallet(parentPayees);
        vm.deal(parent, 1 ether);
        uint256 index = _indexOf(parent, child);
        IReleaseVerifier.Authorization memory a =
            _auth(parent, ETH, index, child, alice, 0.5 ether, 1);
        vm.expectPartialRevert(BoundedCall.BoundedCallShortfall.selector);
        ledger.releaseWithAuthorization(parentPayees, bytes32(0), a, new bytes(65));
        assertEq(parent.balance, 1 ether);
        assertFalse(ledger.nonceUsed(child, 1));
        // The push path pays the nested vault.
        ledger.release(parentPayees, bytes32(0), ETH, index);
        assertEq(child.balance, 0.5 ether);
    }

    /// @dev An ETH recipient whose fallback returns more than one word is refused
    ///      (`ETHTransferFailed`; the ledger copies at most one word); the payee releases to
    ///      another recipient instead.
    function test_AnEthRecipientReturningMoreThanOneWordIsRefused() public {
        address recipient = address(new LongReturnRecipient());
        uint256 index = _indexOf(wallet, alice);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.ETHTransferFailed.selector, recipient, 1 ether)
        );
        vm.prank(alice);
        ledger.releaseTo(_payeesOf(wallet), bytes32(0), ETH, index, recipient);
        vm.prank(alice);
        ledger.releaseTo(_payeesOf(wallet), bytes32(0), ETH, index, alice);
        assertEq(alice.balance, 1 ether);
    }

    /// @dev A token whose `transfer` returns more than one word cannot be released from any
    ///      vault (`TokenCallFailed`): fail closed, the tokens stay in the wallet.
    function test_ATokenReturningMoreThanOneWordIsRefused() public {
        LongReturnToken t = new LongReturnToken();
        t.mint(wallet, 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(t), IERC20.transfer.selector
            )
        );
        ledger.release(_payeesOf(wallet), bytes32(0), address(t), _indexOf(wallet, bob));
        assertEq(t.balanceOf(wallet), 100);
    }
}
