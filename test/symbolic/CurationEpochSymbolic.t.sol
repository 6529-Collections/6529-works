// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Eip712CurationVerifier } from "src/curation/Eip712CurationVerifier.sol";

/// @dev The few AccessManager reads the verifier makes: every caller may call, and every
///      account holds the signer role with no delay, granted at `since`.
contract EpochAuthority {
    uint48 public since;

    function setSince(uint48 since_) external {
        since = since_;
    }

    function canCall(address, address, bytes4) external pure returns (bool, uint32) {
        return (true, 0);
    }

    function hasRole(uint64, address) external pure returns (bool, uint32) {
        return (true, 0);
    }

    function getAccess(uint64, address) external view returns (uint48, uint32, uint32, uint48) {
        return (since, 0, 0, 0);
    }
}

/// @notice Halmos proofs for the curation signer epoch (docs/testing/README.md, "Symbolic").
/// @dev `signerEpoch` packs `since << 128 | salt << 64 | changes`. The proofs start from every
///      stored signer state (written with `vm.store` into the `_signers` mapping at slot 3, as
///      `forge inspect` reports it) and every grant time, so they are unbounded in the state.
contract CurationEpochSymbolicTest is Test {
    uint256 internal constant SIGNERS_SLOT = 3;

    EpochAuthority internal authority;
    Eip712CurationVerifier internal verifier;

    function setUp() public {
        authority = new EpochAuthority();
        verifier = new Eip712CurationVerifier(address(authority));
    }

    /// @dev Writes `SignerState { bool disabled; uint64 changes; uint64 salt; }` for `signer`.
    function _store(address signer, bool disabled, uint64 changes, uint64 salt) internal {
        uint256 packed = (disabled ? 1 : 0) | uint256(changes) << 8 | uint256(salt) << 72;
        vm.store(address(verifier), keccak256(abi.encode(signer, SIGNERS_SLOT)), bytes32(packed));
    }

    /// @notice The epoch holds each of its three fields in its own bits: the grant time, the
    ///         salt and the change count are each recovered exactly, and nothing else is set.
    ///         So two signer states with any differing field never share an epoch.
    function check_signerEpoch_packsItsFieldsInjectively(
        address signer,
        uint48 since,
        uint64 changes,
        uint64 salt,
        bool disabled
    ) public {
        authority.setSince(since);
        _store(signer, disabled, changes, salt);
        assert(verifier.isDisabled(signer) == disabled);
        uint256 epoch = verifier.signerEpoch(signer);
        assert(epoch >> 176 == 0);
        assert(uint48(epoch >> 128) == since);
        assert(uint64(epoch >> 64) == salt);
        assert(uint64(epoch) == changes);
    }

    /// @notice Every disable and every enable ends the epoch: no two of the epochs before, after
    ///         the disable and after the re-enable are equal, and an approval digest over the
    ///         old epoch never equals one over the new.
    function check_disableAndEnable_alwaysEndTheEpoch(
        address signer,
        uint48 since,
        uint64 changes,
        uint64 salt,
        bytes32 packageRoot,
        bytes32 evidenceHash
    ) public {
        vm.assume(changes < type(uint64).max - 1);
        authority.setSince(since);
        _store(signer, false, changes, salt);

        uint256 e0 = verifier.signerEpoch(signer);
        verifier.disableSigner(signer);
        uint256 e1 = verifier.signerEpoch(signer);
        verifier.enableSigner(signer);
        uint256 e2 = verifier.signerEpoch(signer);

        assert(e0 != e1 && e1 != e2 && e0 != e2);
        assert(uint64(e1) == changes + 1 && uint64(e2) == changes + 2);
        assert(
            verifier.approvalDigest(packageRoot, evidenceHash, e2)
                != verifier.approvalDigest(packageRoot, evidenceHash, e0)
        );
    }
}
