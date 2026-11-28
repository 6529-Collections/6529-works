// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { CheckReplacement } from "script/CheckReplacement.sol";
import { DeployCore } from "script/DeployCore.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { ICurationVerifier } from "src/interfaces/ICurationVerifier.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { AccountsSuccessorBase } from "./AccountsSuccessor.t.sol";

/// @dev Forwards every read to an accounts module, but answers that `wallet` acts for
///      `accountId`: a candidate that would hand an account to an address that lost it.
contract OneWrongWallet {
    address internal immutable inner;
    uint256 internal immutable accountId;
    address internal immutable wallet;

    constructor(address inner_, uint256 accountId_, address wallet_) {
        (inner, accountId, wallet) = (inner_, accountId_, wallet_);
    }

    fallback() external {
        if (bytes4(msg.data) == IAccounts.isWallet.selector) {
            (uint256 id, address w) = abi.decode(msg.data[4:], (uint256, address));
            if (id == accountId && w == wallet) {
                assembly ("memory-safe") {
                    mstore(0, 1)
                    return(0, 0x20)
                }
            }
        }
        (bool ok, bytes memory data) = inner.staticcall(msg.data);
        assembly ("memory-safe") {
            if iszero(ok) { revert(add(data, 0x20), mload(data)) }
            return(add(data, 0x20), mload(data))
        }
    }
}

/// @notice The check the network runs before it announces a replacement accounts module or
///         mint policy (`script/CheckReplacement.sol`), on the real deployed stack: it passes
///         for a module deployed naming the one it replaces, and fails for one that starts
///         empty, for one that would let a former root act, for one that is not wired to take
///         over (another directory, another module named as replaced, a restricted function
///         nobody mapped), and for a mint policy that would take a revoked root again.
contract ReplacementCheckTest is AccountsSuccessorBase {
    address internal frozenArtist;
    address internal pendingArtist;

    function setUp() public override {
        super.setUp();
        frozenArtist = _actor("checkFrozenArtist");
        pendingArtist = _actor("checkPendingArtist");
        _publish(_one(_work(frozenArtist, collectionId)));
        _publish(_one(_work(pendingArtist, collectionId)));
    }

    function checkAccounts(address candidate, uint256[] memory ids, address[] memory wallets)
        external
        view
    {
        CheckReplacement.accounts(
            IModuleSlots(address(directory)),
            IArtistRegistry(address(accounts)),
            IArtistRegistry(candidate),
            ids,
            wallets
        );
    }

    function checkWiring(address live, address candidate) external view {
        CheckReplacement.wiring(
            IModuleSlots(address(directory)), IArtistRegistry(live), IArtistRegistry(candidate)
        );
    }

    /// @dev An `Accounts` with the genesis arguments that reads `directory_` and names
    ///      `replaced`, with no function mapped to a role.
    function _unmapped(address directory_, address replaced) internal returns (Accounts) {
        return new Accounts(
            address(manager),
            IConsolidationSource(address(consolidation)),
            address(consolidation).codehash,
            Accounts.Wiring(
                directory_,
                address(stream),
                address(editions),
                address(ledger),
                address(statements),
                address(registry),
                replaced
            ),
            DeployCore.notPayouts(deployment)
        );
    }

    function checkPolicy(address candidate, bytes32[] memory roots)
        external
        view
        returns (uint256)
    {
        return CheckReplacement.mintPolicy(
            IPackageRegistry(address(registry)), IPackageRegistry(candidate), roots
        );
    }

    /// @dev A moved account, a frozen one, one with a change pending and one untouched.
    function _accountsInEveryState()
        internal
        returns (uint256[] memory ids, address[] memory wallets)
    {
        _moveAccount();
        uint256 frozenId = uint256(uint160(frozenArtist));
        uint256 pendingId = uint256(uint160(pendingArtist));
        _asNetwork(address(accounts), abi.encodeCall(accounts.freeze, (frozenId)));
        address second = _actor("checkSecondWallet");
        _consolidate(pendingArtist, second);
        uint256 moved = artistId;
        artistId = pendingId;
        (address keepLead, address keepNew) = (lead, newRoot);
        (lead, newRoot) = (pendingArtist, second);
        _govern(network, address(accounts), _replacement());
        (lead, newRoot, artistId) = (keepLead, keepNew, moved);

        ids = new uint256[](4);
        (ids[0], ids[1], ids[2]) = (artistId, frozenId, pendingId);
        ids[3] = uint256(uint160(_actor("checkNobody")));
        _publish(_one(_work(address(uint160(ids[3])), collectionId)));
        wallets = new address[](5);
        (wallets[0], wallets[1], wallets[2]) = (lead, newRoot, second);
        (wallets[3], wallets[4]) = (collector, makeAddr("checkNeverSeen"));
    }

    function test_ReplacementCheck_PassesForAModuleNamingTheOneItReplaces() public {
        (uint256[] memory ids, address[] memory wallets) = _accountsInEveryState();
        Accounts candidate = _newSuccessor(accounts);
        this.checkAccounts(address(candidate), ids, wallets);
        this.checkWiring(address(accounts), address(candidate));
    }

    /// @dev A candidate that answers every read as the module in force, but reads another
    ///      directory: activated, it would refuse every write.
    function test_ReplacementCheck_FailsForAModuleThatReadsAnotherDirectory() public {
        (uint256[] memory ids, address[] memory wallets) = _accountsInEveryState();
        address other = makeAddr("anotherDirectory");
        address candidate = address(_unmapped(other, address(accounts)));
        bytes memory refusal =
            abi.encodeWithSelector(CheckReplacement.WrongDirectory.selector, other);
        vm.expectRevert(refusal);
        this.checkAccounts(candidate, ids, wallets);
        vm.expectRevert(refusal);
        this.checkWiring(address(accounts), candidate);
    }

    /// @dev A candidate that names a module other than the one in force: here the module in
    ///      force was itself a replacement, and the candidate names the first module.
    function test_ReplacementCheck_FailsForAModuleThatNamesAnotherModuleAsReplaced() public {
        Accounts second = _installSuccessor();
        Accounts stale = _newSuccessor(accounts);
        vm.expectRevert(
            abi.encodeWithSelector(CheckReplacement.WrongPrevious.selector, address(accounts))
        );
        this.checkWiring(address(second), address(stale));
        // The module given as in force must be the one the directory names.
        vm.expectRevert(
            abi.encodeWithSelector(
                CheckReplacement.NotInForce.selector, address(accounts), address(second)
            )
        );
        this.checkWiring(address(accounts), address(stale));
        // A candidate naming the module in force passes.
        this.checkWiring(address(second), address(_newSuccessor(second)));
    }

    /// @dev A candidate whose restricted functions nobody mapped: each belongs to the
    ///      manager's administrator, so the network could not freeze an account. Mapping
    ///      `freeze` alone moves the refusal to `unfreeze`.
    function test_ReplacementCheck_FailsForAModuleWhoseRestrictedFunctionsAreNotMapped() public {
        (uint256[] memory ids, address[] memory wallets) = _accountsInEveryState();
        address candidate = address(_unmapped(address(directory), address(accounts)));
        uint64 expected = manager.getTargetFunctionRole(address(accounts), Accounts.freeze.selector);
        assertNotEq(expected, manager.ADMIN_ROLE(), "the network's role, not the administrator");
        bytes memory refusal = abi.encodeWithSelector(
            CheckReplacement.RoleDiffers.selector,
            Accounts.freeze.selector,
            manager.ADMIN_ROLE(),
            expected
        );
        vm.expectRevert(refusal);
        this.checkAccounts(candidate, ids, wallets);

        bytes4[] memory one = new bytes4[](1);
        one[0] = Accounts.freeze.selector;
        _asNetwork(
            address(manager),
            abi.encodeCall(manager.setTargetFunctionRole, (candidate, one, expected))
        );
        refusal = abi.encodeWithSelector(
            CheckReplacement.RoleDiffers.selector,
            Accounts.unfreeze.selector,
            manager.ADMIN_ROLE(),
            manager.getTargetFunctionRole(address(accounts), Accounts.unfreeze.selector)
        );
        vm.expectRevert(refusal);
        this.checkWiring(address(accounts), candidate);
    }

    function test_ReplacementCheck_FailsForAModuleThatStartsEmpty() public {
        (uint256[] memory ids, address[] memory wallets) = _accountsInEveryState();
        Accounts empty = new Accounts(
            address(manager),
            IConsolidationSource(address(consolidation)),
            address(consolidation).codehash,
            Accounts.Wiring(
                address(directory),
                address(stream),
                address(editions),
                address(ledger),
                address(statements),
                address(registry),
                address(0)
            ),
            DeployCore.notPayouts(deployment)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CheckReplacement.AccountDiffers.selector, "authorityOf", artistId
            )
        );
        this.checkAccounts(address(empty), ids, wallets);
        // With no account to compare, the addresses alone show it: the first address of the
        // moved account would be its own account again.
        vm.expectRevert(
            abi.encodeWithSelector(CheckReplacement.AddressDiffers.selector, "artistIdOf", lead)
        );
        this.checkAccounts(address(empty), new uint256[](0), wallets);
    }

    function test_ReplacementCheck_FailsForAModuleThatLetsAFormerRootAct() public {
        (uint256[] memory ids, address[] memory wallets) = _accountsInEveryState();
        address wrong = address(new OneWrongWallet(address(accounts), artistId, lead));
        vm.expectRevert(
            abi.encodeWithSelector(CheckReplacement.WalletDiffers.selector, artistId, lead)
        );
        this.checkAccounts(wrong, ids, wallets);
    }

    function test_ReplacementCheck_AMintPolicyMustRefuseEveryRevokedRoot() public {
        bytes32[] memory roots = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            roots[i] = _rootOf(_one(_work(lead, collectionId)));
        }
        // Revoked after registration, revoked in advance, registered and never revoked, and
        // never seen.
        _approve(roots[0]);
        _approve(roots[2]);
        for (uint256 i; i < 2; ++i) {
            _asNetwork(
                address(registry),
                abi.encodeCall(PackageRegistry.revokePackage, (roots[i], keccak256("revoked")))
            );
        }
        assertEq(this.checkPolicy(address(_policy(address(registry))), roots), 2);
        assertEq(this.checkPolicy(address(registry), roots), 2);

        address fresh = address(_policy(address(0)));
        vm.expectRevert(abi.encodeWithSelector(CheckReplacement.RootNotRevoked.selector, roots[0]));
        this.checkPolicy(fresh, roots);
    }

    function _policy(address replaced) internal returns (PackageRegistry) {
        return new PackageRegistry(
            address(manager),
            ICurationVerifier(address(verifier)),
            address(verifier).codehash,
            address(directory),
            IEconomicsResolver(address(economics)),
            address(0),
            cc0TextFileId,
            replaced
        );
    }
}
