// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { FixedAuthority } from "../mocks/economics/EconomicsMocks.sol";
import { InterfaceStub } from "../mocks/identity/IdentityWorksMocks.sol";
import { AccountsFixture } from "./AccountsFixture.sol";

/// @dev Answers `authority()` with whatever bytes the test sets, or reverts.
contract RawAuthorityAnswer {
    bytes internal _answer;
    bool internal _reverts;

    function setAnswer(bytes calldata answer, bool reverts) external {
        (_answer, _reverts) = (answer, reverts);
    }

    function authority() external view returns (bytes memory) {
        bytes memory a = _answer;
        bool reverts = _reverts;
        assembly ("memory-safe") {
            if reverts { revert(add(a, 0x20), mload(a)) }
            return(add(a, 0x20), mload(a))
        }
    }
}

/// @notice Which addresses the accounts module refuses as an artist's payout, beyond its
///         wiring and the split factory's vaults (`AccountsWiring.t.sol`): its AccessManager,
///         its consolidation source, the list fixed at deployment, every contract that
///         declares a protocol contract's interface, and every contract governed by its
///         AccessManager. The same answer at staging, at execution, at registration and from
///         `isPayoutAllowed`.
contract AccountsPayoutCheckTest is AccountsFixture, GasRuleAssertions {
    function _refused(address account) internal {
        assertFalse(registry.isPayoutAllowed(account), "isPayoutAllowed");
        (bool ok, bytes memory data) = _relay(_changeCall(artistKey, _identity(artist, account)));
        assertFalse(ok, "staged");
        assertEq(data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
    }

    function _allowed(address account) internal {
        assertTrue(registry.isPayoutAllowed(account), "isPayoutAllowed");
        uint256 snapshot = vm.snapshotState();
        _stage(artistKey, _identity(artist, account));
        assertEq(registry.pendingChange(artistId).next.payout, account);
        vm.revertToState(snapshot);
    }

    function test_PayoutValidation_RejectsTheManagerAndTheConsolidationSource() public {
        _refused(address(manager));
        _refused(address(adapter));
        // The source in force is the one refused.
        Burner other = new Burner(address(adapter), 0);
        _allowed(address(other));
        vm.prank(network);
        registry.setConsolidationSource(
            adapter, IConsolidationSource(address(other)), address(other).codehash
        );
        _refused(address(other));
        _allowed(address(adapter));
    }

    function test_PayoutValidation_RejectsTheContractsListedAtDeployment() public {
        address listed = makeAddr("listed helper");
        address alsoListed = address(new InterfaceStub(0x12345678));
        address unlisted = address(new InterfaceStub(0x12345678));
        _allowed(listed);
        _allowed(alsoListed);
        address[] memory list = new address[](2);
        (list[0], list[1]) = (listed, alsoListed);
        registry = new Accounts(
            address(manager),
            adapter,
            address(adapter).codehash,
            Accounts.Wiring(
                address(directory),
                streamAddr,
                editionsAddr,
                address(factory),
                address(outcomes),
                packageRegistry,
                address(0)
            ),
            list
        );
        artistId = _register(artist);
        _refused(listed);
        _refused(alsoListed);
        _allowed(unlisted);
        _allowed(makeAddr("anyone else"));
        vm.prank(packageRegistry);
        vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
        registry.register(listed, PROFILE, PROFILE_DOC);
    }

    /// @dev The four interfaces `ProtocolContracts` names beyond the module's own list: the
    ///      claim router, a sale adapter, the English auction and a package registry.
    function test_PayoutValidation_RejectsContractsDeclaringAProtocolInterface() public {
        bytes4[4] memory ids = [
            type(IClaimRouter).interfaceId,
            type(ISaleAdapter).interfaceId,
            type(IEnglishAuction).interfaceId,
            type(IPackageRegistry).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            _refused(address(new InterfaceStub(ids[i])));
        }
        _allowed(address(new InterfaceStub(0x12345678)));
    }

    /// @dev A contract that answers this module's AccessManager as its `authority()` is the
    ///      network's. One governed by another manager, or whose answer is not one clean word,
    ///      is not.
    function test_PayoutValidation_RejectsContractsGovernedByTheSameManager() public {
        _refused(address(new FixedAuthority(address(manager))));
        _allowed(address(new FixedAuthority(makeAddr("another manager"))));
        _allowed(address(new FixedAuthority(address(0))));

        RawAuthorityAnswer raw = new RawAuthorityAnswer();
        bytes memory word = abi.encode(address(manager));
        raw.setAnswer(word, false);
        _refused(address(raw));
        raw.setAnswer(bytes.concat(word, bytes32(0)), false);
        _allowed(address(raw));
        raw.setAnswer(abi.encodePacked(address(manager)), false);
        _allowed(address(raw));
        raw.setAnswer("", false);
        _allowed(address(raw));
        raw.setAnswer(word, true);
        _allowed(address(raw));
        // Dirty upper bits are not the manager's address.
        raw.setAnswer(abi.encode(uint256(uint160(address(manager))) | (1 << 160)), false);
        _allowed(address(raw));
    }

    /// @dev The check runs again at execution: a governed contract deployed at the staged
    ///      address while the change waits clears the change.
    function test_PayoutValidation_RecheckedForAGovernedContractDeployedLater() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        _stage(artistKey, _identity(artist, predicted));
        assertEq(address(new FixedAuthority(address(manager))), predicted);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(registry));
        emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        registry.executeChange(artistId);
        assertEq(registry.payoutAddress(artistId), artist);
    }

    /// @dev `register` makes the root the payout, so a governed contract or one declaring a
    ///      protocol interface gets no account.
    function test_PayoutValidation_RegisterAppliesTheSameCheck() public {
        address[3] memory refused = [
            address(new FixedAuthority(address(manager))),
            address(new InterfaceStub(type(IClaimRouter).interfaceId)),
            address(manager)
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(packageRegistry);
            vm.expectRevert(IArtistRegistry.InvalidIdentity.selector);
            registry.register(refused[i], PROFILE, PROFILE_DOC);
        }
    }

    /// @dev The probe of `authority()` forwards all gas: with the contract costing 1x to 100x
    ///      its base the payout is refused all the same, and a probe that runs short reverts
    ///      with `BoundedCallShortfall`, never "allowed".
    function test_GasRule_TheGovernedProbeNeverAnswersForGas() public {
        Burner slow = new Burner(address(new FixedAuthority(address(manager))), 20_000);
        bytes memory data = abi.encodeCall(Accounts.isPayoutAllowed, (address(slow)));
        Outcome memory o = _assertSameAtEveryMultiple(slow, stranger, address(registry), data);
        assertFalse(abi.decode(o.data, (bool)));
        slow.burnerSetMultiple(4);
        _assertShortfallNeverAnswers(slow, stranger, address(registry), data);

        ArtistIdentity memory next = _identity(artist, address(slow));
        (o,) = _assertShortfallNeverAnswers(
            slow, stranger, address(registry), _changeCall(artistKey, next)
        );
        assertFalse(o.ok);
        assertEq(o.data, abi.encodeWithSelector(IArtistRegistry.InvalidIdentity.selector));
    }
}
