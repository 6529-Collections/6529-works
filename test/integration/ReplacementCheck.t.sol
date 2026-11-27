// SPDX-License-Identifier: MIT
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
///         empty, for one that would let a former root act, and for a mint policy that would
///         take a revoked root again.
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
            IArtistRegistry(address(accounts)), IArtistRegistry(candidate), ids, wallets
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
        // And for the module in force against itself.
        this.checkAccounts(address(accounts), ids, wallets);
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
