// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IArtistRoleResolver } from "src/interfaces/IArtistRoleResolver.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @dev The slice of `IArtistRegistry` the package registry calls, with the identity lane's
///      rules that matter to it: artist ID `uint256(uint160(first root))`, every past root keeps
///      mapping to its ID, `register` only from the bound package registry, `authorityOf` and
///      `artist` revert for unknown IDs, and `requireSigned` accepts the root or any wallet added
///      with `addWallet`, nobody while frozen, and an unregistered address as its own wallet.
///      `recover` stands in for an executed root change.
contract CurationArtistRegistryMock is IERC165 {
    error UnknownArtist(uint256 artistId);
    error AccountTaken(address account);
    error UnboundCaller(address caller);

    address public packageRegistry;
    mapping(address account => uint256) public artistIdOf;
    mapping(uint256 artistId => ArtistIdentity) internal _identity;
    mapping(uint256 artistId => mapping(address wallet => bool)) internal _wallets;
    mapping(uint256 artistId => bool) public frozen;
    uint256 public registrations;

    function bindPackageRegistry(address target) external {
        packageRegistry = target;
    }

    function register(address root, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId)
    {
        if (msg.sender != packageRegistry) revert UnboundCaller(msg.sender);
        if (artistIdOf[root] != 0) revert AccountTaken(root);
        artistId = uint256(uint160(root));
        artistIdOf[root] = artistId;
        _identity[artistId] = ArtistIdentity(root, root, profileId, profileDocHash);
        ++registrations;
    }

    /// @dev Test hook: an executed root change.
    function recover(uint256 artistId, address next) external {
        _known(artistId);
        artistIdOf[next] = artistId;
        _identity[artistId].root = next;
    }

    /// @dev Test hook: a wallet consolidated with the account's root.
    function addWallet(uint256 artistId, address wallet, bool isIt) external {
        _wallets[artistId][wallet] = isIt;
    }

    /// @dev Test hook: freezes or unfreezes the account.
    function setFrozen(uint256 artistId, bool isFrozen) external {
        frozen[artistId] = isFrozen;
    }

    /// @dev Test hook: an executed profile change.
    function setProfile(uint256 artistId, bytes32 profileId, bytes32 profileDocHash) external {
        _known(artistId);
        _identity[artistId].profileId = profileId;
        _identity[artistId].profileDocHash = profileDocHash;
    }

    function authorityOf(uint256 artistId) external view returns (address) {
        _known(artistId);
        return _identity[artistId].root;
    }

    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        _known(artistId);
        return frozen[artistId] ? address(0) : _identity[artistId].root;
    }

    function artist(uint256 artistId)
        external
        view
        returns (ArtistIdentity memory identity, uint48 frozenUntil)
    {
        _known(artistId);
        return (_identity[artistId], 0);
    }

    function isWallet(uint256 accountId, address wallet) public view returns (bool) {
        if (wallet == address(0)) return false;
        uint256 id = accountId;
        if (_identity[id].root == address(0) && accountId >> 160 == 0) {
            uint256 mapped = artistIdOf[address(uint160(accountId))];
            if (mapped != 0) id = mapped;
        }
        address root = _identity[id].root;
        if (root == address(0)) return id >> 160 == 0 && wallet == address(uint160(id));
        if (frozen[id]) return false;
        return wallet == root || _wallets[id][wallet];
    }

    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        external
        view
        returns (address wallet)
    {
        if (proof.length < 20) revert SignatureVerifier.InvalidSignature(address(0));
        wallet = address(bytes20(proof[:20]));
        if (!isWallet(accountId, wallet)) revert SignatureVerifier.InvalidSignature(wallet);
        SignatureVerifier.check(wallet, digest, proof[20:]);
    }

    function isArtist(address, uint256, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRoleResolver).interfaceId
            || interfaceId == type(IAccounts).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }

    function _known(uint256 artistId) internal view {
        if (_identity[artistId].root == address(0)) revert UnknownArtist(artistId);
    }
}

/// @dev An artist registry that answers `register` with another artist ID than the
///      `uint160(account)` the package registry assigns: the code a pinned registry could never
///      run, kept to show `acceptPackage` refuses it instead of recording a mismatched account.
contract MisnumberingArtistRegistry is IERC165 {
    function artistIdOf(address) external pure returns (uint256) {
        return 0;
    }

    function requireSigned(uint256, bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function register(address root, bytes32, bytes32) external pure returns (uint256) {
        return uint256(uint160(root)) + 1;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }
}

/// @dev An artist registry that registers every account under an ID one below its address.
contract UndernumberingArtistRegistry is IERC165 {
    function artistIdOf(address) external pure returns (uint256) {
        return 0;
    }

    function requireSigned(uint256, bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function register(address root, bytes32, bytes32) external pure returns (uint256) {
        return uint256(uint160(root)) - 1;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtistRegistry).interfaceId;
    }
}
