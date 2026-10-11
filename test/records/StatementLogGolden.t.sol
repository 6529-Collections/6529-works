// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/records/StatementKinds.sol";
import { HashRef, HASH_SHA256 } from "src/records/HashRef.sol";
import { Role, Statement } from "src/records/IStatementLog.sol";
import { ArtistResolverMock } from "../mocks/RecordsMocks.sol";

/// @notice Golden vectors with fixed hex values for every wire format a verifier depends on: the
///         EIP-712 type hashes and digest, the entry-hash preimage and the head fold. The hex
///         values were produced by a third implementation (pure-Python Keccak with hand-written
///         encodings), and the digest is also checked against forge's own typed-data encoder, so
///         neither the contract nor `StatementModel` vouches for itself. Any change to a type
///         string, a domain tag or a preimage field breaks these tests.
contract StatementLogGoldenTest is Test {
    address internal constant LOG = 0x6529000000000000000000000000000000000001;
    address internal constant RESOLVER = 0x6529000000000000000000000000000000000002;
    address internal constant SIGNER = 0x6529000000000000000000000000000000000003;
    address internal constant TOKEN = 0x5555555555555555555555555555555555555555;
    uint256 internal constant NONCE = 7;
    uint64 internal constant DEADLINE = 2_000_000_000;
    uint64 internal constant RECORDED_AT = 1_700_000_000;

    StatementLog internal statementLog;

    function setUp() public {
        vm.chainId(1);
        vm.warp(RECORDED_AT);
        deployCodeTo("RecordsMocks.sol:ArtistResolverMock", RESOLVER);
        ArtistResolverMock(RESOLVER).grantEverywhere(SIGNER);
        deployCodeTo(
            "StatementLog.sol:StatementLog",
            abi.encode(address(0xA07), RESOLVER, RESOLVER.codehash),
            LOG
        );
        statementLog = StatementLog(LOG);
    }

    function _statement() internal pure returns (Statement memory) {
        return Statement({
            token: TOKEN,
            id: 42,
            kind: StatementKinds.ARTIST_STATEMENT,
            schema: keccak256("schema/artist-statement/v1"),
            content: HashRef(HASH_SHA256, keccak256("the document")),
            uri: "ar://document",
            fileId: bytes32(0),
            supersedes: bytes32(uint256(0xdecade))
        });
    }

    function test_Golden_TypeHashesAndDomainTags() public pure {
        assertEq(
            keccak256("HashRef(uint16 algorithm,bytes32 digest)"),
            0x121a61476ab0828add4a5b9b9f2bb805adcfa15d81ff19494f98b0fd3e0bd6ed
        );
        assertEq(
            keccak256(
                "Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)"
            ),
            0xc5917de59a1e9cd194c71a1bfa5d2b7a821403b15a6c26ba9ed4aaa207f324f6
        );
        assertEq(
            keccak256(
                "Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)HashRef(uint16 algorithm,bytes32 digest)Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)"
            ),
            0x31b41af4c88eb6a6042a07475f214b72f1819151382b4f7c6600f092bf061f89
        );
        assertEq(
            keccak256(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            ),
            0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
        );
        assertEq(
            keccak256("6529.works.StatementLog.entry.v1"),
            0x0f3311395c5212a871acb58afd86802fdee2d0bd441c4d282deb4870d87e1f11
        );
        assertEq(
            keccak256("6529.works.StatementLog.head.v1"),
            0x20025e2db27e195c57e0612653067df58c83f14892beca1016dfd5dfa49b15e0
        );
    }

    function test_Golden_DomainSeparatorMatchesEip5267Fields() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            statementLog.eip712Domain();
        assertEq(name, "6529 Works Statement Log");
        assertEq(version, "1");
        assertEq(chainId, 1);
        assertEq(verifying, LOG);
        assertEq(
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    chainId,
                    verifying
                )
            ),
            0x75b051dca6358727d5fe93cdc29be21582295eafa128e8efbef7e6530f223320
        );
    }

    function test_Golden_AuthorizationDigest() public view {
        bytes32 digest =
            statementLog.authorizationDigest(Role.ARTIST, _statement(), SIGNER, NONCE, DEADLINE);
        assertEq(digest, 0x72db11a97266f8af68809f0c675beae7e586328e006995f45f0bcaa6101341d5);
    }

    /// @dev Forge's own EIP-712 encoder (not hand-written type strings) agrees with the contract.
    function test_Golden_DigestMatchesForgeTypedDataEncoder() public view {
        string memory types = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"Authorization":[{"name":"role","type":"uint8"},{"name":"signer","type":"address"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint64"},{"name":"statement","type":"Statement"}],',
            '"Statement":[{"name":"token","type":"address"},{"name":"id","type":"uint256"},{"name":"kind","type":"bytes32"},{"name":"schema","type":"bytes32"},{"name":"content","type":"HashRef"},{"name":"uri","type":"string"},{"name":"fileId","type":"bytes32"},{"name":"supersedes","type":"bytes32"}],',
            '"HashRef":[{"name":"algorithm","type":"uint16"},{"name":"digest","type":"bytes32"}]},'
        );
        string memory domain = string.concat(
            '"primaryType":"Authorization","domain":{"name":"6529 Works Statement Log","version":"1","chainId":1,"verifyingContract":"',
            vm.toString(LOG),
            '"},'
        );
        string memory message = string.concat(
            '"message":{"role":1,"signer":"',
            vm.toString(SIGNER),
            '","nonce":"7","deadline":"2000000000","statement":',
            _statementJson(_statement()),
            "}}"
        );
        bytes32 expected = vm.eip712HashTypedData(string.concat(types, domain, message));
        assertEq(expected, 0x72db11a97266f8af68809f0c675beae7e586328e006995f45f0bcaa6101341d5);
        assertEq(
            statementLog.authorizationDigest(Role.ARTIST, _statement(), SIGNER, NONCE, DEADLINE),
            expected
        );
    }

    function _statementJson(Statement memory s) internal pure returns (string memory) {
        string memory head = string.concat(
            '{"token":"',
            vm.toString(s.token),
            '","id":"',
            vm.toString(s.id),
            '","kind":"',
            vm.toString(s.kind),
            '","schema":"',
            vm.toString(s.schema)
        );
        return string.concat(
            head,
            '","content":{"algorithm":2,"digest":"',
            vm.toString(s.content.digest),
            '"},"uri":"',
            s.uri,
            '","fileId":"',
            vm.toString(s.fileId),
            '","supersedes":"',
            vm.toString(s.supersedes),
            '"}'
        );
    }

    /// @dev The entry hash (resolver included) and the first head of a chain, for a fixed log,
    ///      chain, resolver, signer, time and statement.
    function test_Golden_EntryHashAndHead() public {
        vm.prank(SIGNER);
        bytes32 entry = statementLog.append(Role.ARTIST, _statement());
        assertEq(entry, 0x9d2023b48135217ae6890865f741d06709812534fac2f23ba3d1b7f0664267cb);

        (uint64 count, bytes32 head) = statementLog.chainOf(TOKEN, 42);
        assertEq(count, 1);
        assertEq(head, 0x77858d3d57071dd53c884e76681314dda773c76dec240bf8d840c217c683d1e5);
        assertEq(
            statementLog.subjectKey(TOKEN, 42),
            0x7cc63a2d4ee562fdcae382d38b9451623779eabc5f107b97ac03f0070fa56823
        );
    }
}
