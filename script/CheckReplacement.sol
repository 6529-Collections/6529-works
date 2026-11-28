// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";

/// @notice What the check reads from a candidate accounts module beyond `IArtistRegistry`.
interface INamesPrevious {
    /// @notice The module this one replaces and reads accounts from.
    function previous() external view returns (address);
}

/// @title CheckReplacement
/// @notice What the network checks before it announces a replacement accounts module or mint
///         policy ([Replacing a module](../docs/operations/replacing-modules.md)): the candidate
///         answers, for every account and every package root on a list, what the module in
///         force answers now, and a candidate accounts module is wired to take over: it reads
///         the directory, it names the module in force as the one it replaces, and its
///         restricted functions belong to the same roles. Read-only.
/// @dev The lists are the operator's, built from the events of the module in force and of
///      every module before it (follow `previous()` to the first): a module emits nothing for
///      an account it only reads from the one it replaced. Every artist ID
///      (`ArtistRegistered`, `AccountInherited`) with every address that was ever a root
///      (`ChangeExecuted`, `AccountInherited`), and every root of `PackageRevoked` and of the
///      `PackageRegistered` events of a signer named in `SignerApprovalsKilled`, in every
///      policy of the chain. The check says nothing about an account, an address
///      or a root that is not on its lists, so an incomplete list can pass where the full one
///      would not. A check passes only for the block it is run at: run it again right before
///      the announcement and before the activation.
library CheckReplacement {
    /// @notice The candidate's answer about an account differs from the module in force.
    error AccountDiffers(string what, uint256 artistId);
    /// @notice The candidate's answer about a wallet of an account differs.
    error WalletDiffers(uint256 artistId, address wallet);
    /// @notice The candidate's answer about an address differs.
    error AddressDiffers(string what, address account);
    /// @notice A root the policy in force reports as revoked is not revoked in the candidate.
    error RootNotRevoked(bytes32 packageRoot);
    /// @notice `live` is not the accounts module the directory names (`inForce`).
    error NotInForce(address live, address inForce);
    /// @notice The candidate reads another directory: once activated it would refuse every
    ///         write, and the module it replaces writes no more either.
    error WrongDirectory(address candidateDirectory);
    /// @notice The candidate does not name the module in force as the one it replaces.
    error WrongPrevious(address candidatePrevious);
    /// @notice A restricted function of the candidate does not belong to the role that holds
    ///         it on the module in force (`expected`). A function nobody mapped belongs to the
    ///         manager's administrator.
    error RoleDiffers(bytes4 selector, uint64 role, uint64 expected);

    /// @notice Reverts unless `candidate` answers as `live` for every account in `artistIds`
    ///         (root, acting root, payout address, freeze, identity, pending change, and who
    ///         acts: the root, the address the ID is made from, each of `wallets`) and for
    ///         every address in `wallets` (the account it names and the account it is
    ///         reserved for), and unless it is wired to take over (`wiring`).
    /// @param directory The directory whose ACCOUNTS slot the candidate would take.
    /// @param live The accounts module in force.
    /// @param candidate The module that would replace it.
    /// @param artistIds The accounts to compare.
    /// @param wallets Addresses to compare for every account: former roots, consolidated
    ///        wallets, and addresses that must have no power.
    function accounts(
        IModuleSlots directory,
        IArtistRegistry live,
        IArtistRegistry candidate,
        uint256[] memory artistIds,
        address[] memory wallets
    ) internal view {
        for (uint256 i; i < artistIds.length; ++i) {
            uint256 id = artistIds[i];
            address root = live.authorityOf(id);
            if (_authorityOf(candidate, id) != root) revert AccountDiffers("authorityOf", id);
            if (candidate.activeAuthorityOf(id) != live.activeAuthorityOf(id)) {
                revert AccountDiffers("activeAuthorityOf", id);
            }
            if (candidate.payoutAddress(id) != live.payoutAddress(id)) {
                revert AccountDiffers("payoutAddress", id);
            }
            if (candidate.frozenUntil(id) != live.frozenUntil(id)) {
                revert AccountDiffers("frozenUntil", id);
            }
            (ArtistIdentity memory mine,) = candidate.artist(id);
            (ArtistIdentity memory theirs,) = live.artist(id);
            if (keccak256(abi.encode(mine)) != keccak256(abi.encode(theirs))) {
                revert AccountDiffers("artist", id);
            }
            if (
                keccak256(abi.encode(candidate.pendingChange(id)))
                    != keccak256(abi.encode(live.pendingChange(id)))
            ) revert AccountDiffers("pendingChange", id);
            _sameWallet(live, candidate, id, root);
            _sameWallet(live, candidate, id, address(uint160(id)));
            _sameWallet(live, candidate, uint256(uint160(root)), root);
            for (uint256 j; j < wallets.length; ++j) {
                _sameWallet(live, candidate, id, wallets[j]);
            }
        }
        for (uint256 j; j < wallets.length; ++j) {
            address w = wallets[j];
            if (candidate.artistIdOf(w) != live.artistIdOf(w)) {
                revert AddressDiffers("artistIdOf", w);
            }
            if (candidate.reservedFor(w) != live.reservedFor(w)) {
                revert AddressDiffers("reservedFor", w);
            }
            _sameWallet(live, candidate, uint256(uint160(w)), w);
        }
        wiring(directory, live, candidate);
    }

    /// @notice Reverts unless `candidate` can take over from `live`: `live` is the accounts
    ///         module the directory names, the candidate reads that directory (only the module
    ///         its directory names writes), it names `live` as the module it replaces, and
    ///         each function only a role may call (`freeze`, `unfreeze`, `stageReplacement`,
    ///         `cancelReplacement`, `cancelOwnChange`, `resolveContested`,
    ///         `setConsolidationSource`, `setPackageRegistry`) belongs to the same role on the
    ///         candidate as on `live`, in the directory's access manager.
    /// @dev Run before the activation: afterwards the candidate is the module in force and
    ///      `live` is not.
    /// @param directory The directory whose ACCOUNTS slot the candidate would take.
    /// @param live The accounts module in force.
    /// @param candidate The module that would replace it.
    function wiring(IModuleSlots directory, IArtistRegistry live, IArtistRegistry candidate)
        internal
        view
    {
        address inForce = directory.moduleOf(Slots.ACCOUNTS);
        if (address(live) != inForce) revert NotInForce(address(live), inForce);
        address named = candidate.directory();
        if (named != address(directory)) revert WrongDirectory(named);
        address replaced = INamesPrevious(address(candidate)).previous();
        if (replaced != address(live)) revert WrongPrevious(replaced);

        IAccessManager manager = IAccessManager(IAccessManaged(address(directory)).authority());
        bytes4[8] memory restricted = [
            IArtistRegistry.freeze.selector,
            IArtistRegistry.unfreeze.selector,
            IArtistRegistry.stageReplacement.selector,
            IArtistRegistry.cancelReplacement.selector,
            IArtistRegistry.cancelOwnChange.selector,
            IArtistRegistry.resolveContested.selector,
            IArtistRegistry.setConsolidationSource.selector,
            IArtistRegistry.setPackageRegistry.selector
        ];
        for (uint256 i; i < restricted.length; ++i) {
            uint64 expected = manager.getTargetFunctionRole(address(live), restricted[i]);
            uint64 role = manager.getTargetFunctionRole(address(candidate), restricted[i]);
            if (role != expected) revert RoleDiffers(restricted[i], role, expected);
        }
    }

    /// @notice Reverts unless every root of `roots` that `live` reports as revoked
    ///         (`packageOf`: revoked, revoked in advance, or its signer's approvals killed) is
    ///         reported as revoked by `candidate` too.
    /// @param live The mint policy in force.
    /// @param candidate The policy that would replace it.
    /// @param roots The package roots to compare.
    /// @return revoked How many of `roots` the policy in force reports as revoked.
    function mintPolicy(IPackageRegistry live, IPackageRegistry candidate, bytes32[] memory roots)
        internal
        view
        returns (uint256 revoked)
    {
        for (uint256 i; i < roots.length; ++i) {
            (IPackageRegistry.PackageStatus status,,) = live.packageOf(roots[i]);
            if (status != IPackageRegistry.PackageStatus.REVOKED) continue;
            ++revoked;
            (status,,) = candidate.packageOf(roots[i]);
            if (status != IPackageRegistry.PackageStatus.REVOKED) revert RootNotRevoked(roots[i]);
        }
    }

    function _sameWallet(
        IArtistRegistry live,
        IArtistRegistry candidate,
        uint256 accountId,
        address wallet
    ) private view {
        if (candidate.isWallet(accountId, wallet) != live.isWallet(accountId, wallet)) {
            revert WalletDiffers(accountId, wallet);
        }
    }

    /// @dev The candidate's root of `id`, or zero when it does not know the account.
    function _authorityOf(IArtistRegistry candidate, uint256 id) private view returns (address) {
        try candidate.authorityOf(id) returns (address root) {
            return root;
        } catch {
            return address(0);
        }
    }
}
