// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IAccounts } from "src/interfaces/core/IAccounts.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @notice A test-only successor accounts module that reads through the module it replaces:
///         every account it has not changed itself is answered by `previous`, as that module
///         answers it now (identity, wallets, payout address, pending changes and freezes), so
///         every existing account keeps its ID, including one that moved to another address.
///         An account this module has changed, or created, is answered from its own records.
/// @dev It shows that the accounts interface the permanent contracts use is enough for a
///      successor to carry every account over. It is not a design for a real successor: it has
///      no events, no waiting periods, no contest, and it trusts `previous` for consolidation.
///      Consent digests keep the domain of `previous`, so signatures made before the
///      replacement stay valid. `registerIndependent` is not implemented.
contract ReadThroughAccounts is IAccounts {
    error NotNetwork(address caller);
    error NotPackageRegistry(address caller);
    error AccountTaken(address root);

    /// @dev An account as this module records it; `root` is zero for an account it has not
    ///      changed (read through).
    struct Own {
        address root;
        address payout;
        uint48 frozenUntil;
        bytes32 profileId;
        bytes32 profileDocHash;
    }

    /// @notice The accounts module this one replaces.
    IArtistRegistry public immutable previous;
    /// @notice The only caller of the network's functions.
    address public immutable network;
    /// @notice The only caller of `register`.
    address public immutable packageRegistry;

    mapping(uint256 artistId => Own) private _own;
    mapping(address root => uint256 artistId) private _idOfRoot;

    constructor(IArtistRegistry previous_, address network_, address packageRegistry_) {
        (previous, network, packageRegistry) = (previous_, network_, packageRegistry_);
    }

    // ----- writes -----

    /// @notice The network sets an existing account's root, payout address and freeze here.
    ///         From then on this module answers for the account and `previous` is not read.
    function setAccount(uint256 artistId, address root, address payout, uint48 frozenUntil_)
        external
    {
        if (msg.sender != network) revert NotNetwork(msg.sender);
        (ArtistIdentity memory identity,) = artist(artistId);
        _own[artistId] =
            Own(root, payout, frozenUntil_, identity.profileId, identity.profileDocHash);
        _idOfRoot[root] = artistId;
    }

    /// @notice Creates an account for `root`, as `Accounts.register` does: the package registry
    ///         calls it after it has verified the account's own acceptance.
    function register(address root, bytes32 profileId, bytes32 profileDocHash)
        external
        returns (uint256 artistId)
    {
        if (msg.sender != packageRegistry) revert NotPackageRegistry(msg.sender);
        if (root == address(0) || artistIdOf(root) != 0 || previous.reservedFor(root) != 0) {
            revert AccountTaken(root);
        }
        artistId = uint256(uint160(root));
        _own[artistId] = Own(root, root, 0, profileId, profileDocHash);
        _idOfRoot[root] = artistId;
    }

    // ----- IAccounts -----

    /// @inheritdoc IAccounts
    function isWallet(uint256 accountId, address wallet) public view returns (bool) {
        uint256 id = _resolve(accountId);
        Own storage o = _own[id];
        if (o.root == address(0)) return previous.isWallet(accountId, wallet);
        // forge-lint: disable-next-line(block-timestamp)
        if (wallet == address(0) || o.frozenUntil > block.timestamp) return false;
        return wallet == o.root || previous.consolidationSource().isConsolidated(o.root, wallet);
    }

    /// @inheritdoc IAccounts
    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        public
        view
        returns (address wallet)
    {
        if (proof.length < 20) revert SignatureVerifier.InvalidSignature(address(0));
        wallet = address(bytes20(proof[:20]));
        if (!isWallet(accountId, wallet)) revert SignatureVerifier.InvalidSignature(wallet);
        SignatureVerifier.check(wallet, digest, proof[20:]);
    }

    /// @inheritdoc IAccounts
    function requireConsent(uint256 accountId, bytes32 what, bytes calldata proof)
        external
        view
        returns (address wallet)
    {
        return requireSigned(accountId, consentDigest(msg.sender, what), proof);
    }

    /// @inheritdoc IAccounts
    function consentDigest(address subject, bytes32 what) public view returns (bytes32) {
        return previous.consentDigest(subject, what);
    }

    /// @inheritdoc IAccounts
    function frozenUntil(uint256 accountId) external view returns (uint48) {
        Own storage o = _own[_resolve(accountId)];
        return o.root == address(0) ? previous.frozenUntil(accountId) : o.frozenUntil;
    }

    /// @inheritdoc IAccounts
    function payoutAddress(uint256 artistId) external view returns (address) {
        Own storage o = _own[artistId];
        if (o.root == address(0)) return previous.payoutAddress(artistId);
        // forge-lint: disable-next-line(block-timestamp)
        return o.frozenUntil > block.timestamp ? address(0) : o.payout;
    }

    // ----- the reads the mint policy and the Independent Stream module use -----

    /// @notice The account `account` is or was a root of, here or in `previous`; zero for none.
    function artistIdOf(address account) public view returns (uint256) {
        uint256 id = _idOfRoot[account];
        return id != 0 ? id : previous.artistIdOf(account);
    }

    /// @notice The account's identity and the end of its freeze; reverts for an unknown account
    ///         (as `previous` does).
    function artist(uint256 artistId)
        public
        view
        returns (ArtistIdentity memory identity, uint48 frozenUntil_)
    {
        Own storage o = _own[artistId];
        if (o.root == address(0)) return previous.artist(artistId);
        identity = ArtistIdentity(o.root, o.payout, o.profileId, o.profileDocHash);
        frozenUntil_ = o.frozenUntil;
    }

    /// @notice The account's root; reverts for an unknown account (as `previous` does).
    function authorityOf(uint256 artistId) external view returns (address) {
        address root = _own[artistId].root;
        return root == address(0) ? previous.authorityOf(artistId) : root;
    }

    /// @notice The account's root, or zero while nobody may act for it.
    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        Own storage o = _own[artistId];
        if (o.root == address(0)) return previous.activeAuthorityOf(artistId);
        // forge-lint: disable-next-line(block-timestamp)
        return o.frozenUntil > block.timestamp ? address(0) : o.root;
    }

    /// @notice Whether this module, and not `previous`, answers for the account.
    function answersItself(uint256 artistId) external view returns (bool) {
        return _own[artistId].root != address(0);
    }

    /// @dev The account `accountId` names: an artist ID, or an address that is or was a root.
    function _resolve(uint256 accountId) private view returns (uint256 id) {
        id = accountId;
        if (_own[id].root == address(0) && accountId >> 160 == 0) {
            uint256 mapped = artistIdOf(address(uint160(accountId)));
            if (mapped != 0) id = mapped;
        }
    }
}
