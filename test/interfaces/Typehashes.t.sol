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
        assertEq(Typehashes.FIXED_PRICE_SALE_NAME, "6529 Works Fixed Price Sale");
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
            0x042a3f421b5117b21363cb14bb213061c468e91b1af5d8d925a04a5d0a6648c9
        );
        assertEq(
            Typehashes.RELICENSE, 0x8e6e8db23b02e7536fe205ab2dd4340fc5f4b94ad3878dece0549cff5101996f
        );
        assertEq(
            Typehashes.ROYALTY_RATE_CHANGE,
            0x4f00b7a5a626b7fd46a6eb233ba5926281727b94836ffa9091fa1cc73d7fa038
        );
        assertEq(
            Typehashes.RENDERER_REPIN,
            0xe02c73b10a1645fcc06fd6d114765861f5bcd1cd03d788c53c6bdf196c748bd4
        );
        assertEq(
            Typehashes.IDENTITY_CHANGE,
            0xa474bd174aa5ecb19efe75995251c1fb8289b62bca04bc6c19e869f254e190f0
        );
        assertEq(
            Typehashes.OVERRIDE_ACCEPTANCE,
            0xcccdd16a86d667337789cb112f688c2a3aabcf081e5b281efc5ea2c4ed5e26f0
        );
        assertEq(
            Typehashes.PHASE_CONFIGURATION,
            0x478fdca2250bff3308ee2e9f645397cb387134f7829888377d7a6262516cb071
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
        assertEq(
            Typehashes.PURCHASE_WITNESS,
            0x119cc3e88e6f6279440597a9aeb3fe920bc464408b6f4e8f14fb0ff4e04a4a55
        );
        assertEq(
            Typehashes.DUTCH_PURCHASE_WITNESS,
            0x6369ab0c00b76d262a77c0c13be372b9131ef0eb9a2d5d8409618957095ceddb
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
        assertEq(
            keccak256(bytes.concat(bytes(PERMIT2_STUB), bytes(Typehashes.PURCHASE_WITNESS_TYPE))),
            0xe6059a1eb191e9e77fa847628aa401e15410cf3c4c2a3529af56e79cabe9a592
        );
        assertEq(
            keccak256(
                bytes.concat(bytes(PERMIT2_STUB), bytes(Typehashes.DUTCH_PURCHASE_WITNESS_TYPE))
            ),
            0x8abb1791eb031c454185432a3a1d72b3752bc997984d707a53b5c57ec6da58d3
        );
    }
}
