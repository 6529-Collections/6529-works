// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Typehashes } from "../../src/interfaces/types/Typehashes.sol";

/// @dev Golden typehashes, computed independently with `cast keccak` over the type strings. A
///      failure means a signed payload changed shape: every signer, verifier and tool must change
///      with it.
contract TypehashesTest is Test {
    function test_domainConstants() public pure {
        assertEq(Typehashes.DOMAIN_VERSION, "1");
        assertEq(Typehashes.PACKAGE_REGISTRY_NAME, "6529 Stream Package Registry");
        assertEq(Typehashes.CURATION_VERIFIER_NAME, "6529 Stream Curation Verifier");
        assertEq(Typehashes.ARTIST_REGISTRY_NAME, "6529 Stream Artist Registry");
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
    }
}
