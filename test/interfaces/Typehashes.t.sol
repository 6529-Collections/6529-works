// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Typehashes } from "../../src/interfaces/types/Typehashes.sol";

/// @dev Golden typehashes, computed independently with `cast keccak` over the type strings. A
///      failure means a signed payload changed shape: every signer, verifier and tool must change
///      with it.
contract TypehashesTest is Test {
    /// @dev Permit2's `PermitWitnessTransferFrom` stub that every witness type string completes.
    string internal constant PERMIT2_STUB = "PermitWitnessTransferFrom(TokenPermissions permitted,"
        "address spender,uint256 nonce,uint256 deadline,";

    function test_domainConstants() public pure {
        assertEq(Typehashes.DOMAIN_VERSION, "1");
        assertEq(Typehashes.PACKAGE_REGISTRY_NAME, "6529 Works Package Registry");
        assertEq(Typehashes.CURATION_VERIFIER_NAME, "6529 Works Curation Verifier");
        assertEq(Typehashes.WORK_RECORDS_NAME, "6529 Works Records");
        assertEq(Typehashes.ARTIST_REGISTRY_NAME, "6529 Works Artist Registry");
    }

    function test_signedPayloadTypehashes() public pure {
        assertEq(
            Typehashes.MOVE_TO_STREAM,
            0xe193fedc71b458003faf3a90795989683ea6a572f7cae0f6729d1219894814f8
        );
        assertEq(
            Typehashes.PACKAGE_ACCEPTANCE,
            0x557d83fa1b5c5123a734c14182eab668ea8678f09c42986018a05d2be5aa362f
        );
        assertEq(
            Typehashes.PACKAGE_APPROVAL,
            0xbf131d47e2ddcf4bd120061a8a3c2841ef379caa26b7eec0881120e1d8a43cdd
        );
        assertEq(
            Typehashes.RELICENSE, 0x8e6e8db23b02e7536fe205ab2dd4340fc5f4b94ad3878dece0549cff5101996f
        );
        assertEq(
            Typehashes.ROYALTY_RATE_CHANGE,
            0x4f00b7a5a626b7fd46a6eb233ba5926281727b94836ffa9091fa1cc73d7fa038
        );
        assertEq(
            Typehashes.RENOUNCE_POWERS,
            0xff8cc1b150cf1b390fd870b4a587d3c2632e80f32efbefe166b9f7b0131d3aff
        );
        assertEq(
            Typehashes.IDENTITY_CHANGE,
            0x861dd247b7856a4fbd738106b59a20eabf86c787bcc7c5c77f8bf506b24e4495
        );
        assertEq(
            Typehashes.REPLACEMENT_ACCEPTANCE,
            0xa0e556173f6123b1243ffd400cc5066b72e9f63a185f7c223a7a9761be52aeff
        );
        assertEq(
            Typehashes.ACCOUNT_CONSENT,
            0x698c989ad77f65b3786711063b64ef5589a2f9efc6261c97a73e4eee803af539
        );
        assertEq(
            Typehashes.ARTIST_REGISTRATION,
            0x251edc52a2bb08ba54c8c256d514ddd287d55597cda1692026fb5fcbf0f8a8d9
        );
        assertEq(
            Typehashes.INDEPENDENT_LISTING,
            0xc6c1acdb6e5275d9f6ab97f01f142831a32aa8d4d19a2562f68647103f1436d0
        );
    }

    function test_witnessTypehashes() public pure {
        assertEq(
            Typehashes.BID_WITNESS,
            0x36fe48f963a8333b63c773927bbdc20f266277d65935733a27e6264edda25ea8
        );
        assertEq(
            Typehashes.START_BID_WITNESS,
            0xb8513f1f66acd0543fe8542e5c408fd4a7b59dfcf47fc1e4c2c164c66cd5bd0e
        );
    }

    /// @dev Each witness type string must complete Permit2's stub into the full typehash Permit2
    ///      recomputes on-chain.
    function test_witnessTypeStrings() public pure {
        assertEq(
            keccak256(bytes.concat(bytes(PERMIT2_STUB), bytes(Typehashes.BID_WITNESS_TYPE))),
            0x0bfd3d1d308e98f9f0a38b17a9eaaad1118b7813eead91902f6714537c0eb034
        );
        assertEq(
            keccak256(bytes.concat(bytes(PERMIT2_STUB), bytes(Typehashes.START_BID_WITNESS_TYPE))),
            0xb44f39960bfdaf0c5fedccb2b3159844117a56c2d506bcf2c35776fe2c346acf
        );
    }
}
