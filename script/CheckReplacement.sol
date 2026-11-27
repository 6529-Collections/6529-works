// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";

/// @title CheckReplacement
/// @notice What the network checks before it announces a replacement accounts module or mint
///         policy ([Replacing a module](../docs/operations/replacing-modules.md)): the candidate
///         answers, for every account and every package root on a list, what the module in
///         force answers now. Read-only. It compares answers and assumes nothing about how the
///         candidate produces them, so it also fits a candidate that imports state instead of
///         reading the module it replaces.
/// @dev The lists are the operator's: every artist ID of the module in force (its
///      `ArtistRegistered` events) with every address that was ever a root (`ChangeExecuted`),
///      and every root of `PackageRevoked` and of the `PackageRegistered` events of a signer
///      named in `SignerApprovalsKilled`. A check passes only for the block it is run at: run
///      it again right before the announcement and before the activation.
library CheckReplacement {
    /// @notice The candidate's answer about an account differs from the module in force.
    error AccountDiffers(string what, uint256 artistId);
    /// @notice The candidate's answer about a wallet of an account differs.
    error WalletDiffers(uint256 artistId, address wallet);
    /// @notice The candidate's answer about an address differs.
    error AddressDiffers(string what, address account);
    /// @notice A root the policy in force reports as revoked is not revoked in the candidate.
    error RootNotRevoked(bytes32 packageRoot);

    /// @notice Reverts unless `candidate` answers as `live` for every account in `artistIds`
    ///         (root, acting root, payout address, freeze, identity, pending change, and who
    ///         acts: the root, the address the ID is made from, each of `wallets`) and for
    ///         every address in `wallets` (the account it names and the account it is
    ///         reserved for).
    /// @param live The accounts module in force.
    /// @param candidate The module that would replace it.
    /// @param artistIds The accounts to compare.
    /// @param wallets Addresses to compare for every account: former roots, consolidated
    ///        wallets, and addresses that must have no power.
    function accounts(
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
