// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { HashRef, HASH_SHA256 } from "src/interfaces/types/HashRef.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { StatementModel } from "./StatementModel.sol";
import { ArtistResolverMock, ERC721OwnerMock, ERC1155BalanceMock } from "../mocks/RecordsMocks.sol";

/// @notice Shared setup for the statement log tests: an AccessManager with the curator and
///         platform selectors mapped to roles, an artist resolver, and token ownership sources.
abstract contract StatementLogFixture is Test {
    uint64 internal constant CURATOR_ROLE = 1;
    uint64 internal constant PLATFORM_ROLE = 2;
    uint64 internal constant GOVERNANCE_ROLE = 3;
    uint32 internal constant GOVERNANCE_DELAY = 30 days;

    AccessManager internal manager;
    StatementLog internal stmtLog;
    ArtistResolverMock internal resolver;
    ERC721OwnerMock internal nft;
    ERC1155BalanceMock internal editions;

    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal platform = makeAddr("platform");
    address internal governor = makeAddr("governor");
    address internal stranger = makeAddr("stranger");
    uint256 internal artistKey = 0xA471;
    uint256 internal ownerKey = 0x0412;
    uint256 internal curatorKey = 0xC0C0;
    address internal artist;
    address internal tokenOwner;
    address internal curatorSigner;

    function setUp() public virtual {
        artist = vm.addr(artistKey);
        tokenOwner = vm.addr(ownerKey);
        curatorSigner = vm.addr(curatorKey);
        manager = new AccessManager(admin);
        resolver = new ArtistResolverMock();
        stmtLog = new StatementLog(address(manager), address(resolver), address(resolver).codehash);
        nft = new ERC721OwnerMock();
        editions = new ERC1155BalanceMock();

        bytes4[] memory curatorSelectors = new bytes4[](1);
        curatorSelectors[0] = stmtLog.appendCurator.selector;
        bytes4[] memory platformSelectors = new bytes4[](1);
        platformSelectors[0] = stmtLog.appendPlatform.selector;
        bytes4[] memory governanceSelectors = new bytes4[](1);
        governanceSelectors[0] = stmtLog.appendGovernanceManifest.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(address(stmtLog), curatorSelectors, CURATOR_ROLE);
        manager.setTargetFunctionRole(address(stmtLog), platformSelectors, PLATFORM_ROLE);
        // The integrator maps the governance manifest to the 30-day class; the log cannot.
        manager.setTargetFunctionRole(address(stmtLog), governanceSelectors, GOVERNANCE_ROLE);
        manager.grantRole(GOVERNANCE_ROLE, governor, GOVERNANCE_DELAY);
        manager.grantRole(CURATOR_ROLE, curator, 0);
        manager.grantRole(CURATOR_ROLE, curatorSigner, 0);
        manager.grantRole(PLATFORM_ROLE, platform, 0);
        vm.stopPrank();

        nft.setOwner(1, tokenOwner);
        resolver.grant(address(nft), 1, artist);
    }

    /// @dev A valid statement about token 1 of the test ERC-721.
    function _statement() internal view returns (Statement memory) {
        return _statement(address(nft), 1);
    }

    /// @dev A valid governance manifest: subject `(authority, 0)`, kind GOVERNANCE_MANIFEST.
    function _governanceStatement() internal view returns (Statement memory s) {
        s = _statement(address(manager), 0);
        s.kind = StatementKinds.GOVERNANCE_MANIFEST;
        s.schema = keccak256("schema/governance-manifest/v1");
        s.uri = "ar://manifest";
    }

    /// @dev Schedules a governance manifest as the governor, waits out the 30-day delay and executes
    ///      it through the AccessManager.
    function _scheduleAndExecuteManifest(Statement memory s) internal {
        bytes memory data = abi.encodeCall(StatementLog.appendGovernanceManifest, (s));
        vm.prank(governor);
        manager.schedule(address(stmtLog), data, 0);
        vm.warp(block.timestamp + GOVERNANCE_DELAY);
        vm.prank(governor);
        manager.execute(address(stmtLog), data);
    }

    function _statement(address token, uint256 id) internal pure returns (Statement memory) {
        return Statement({
            token: token,
            id: id,
            kind: StatementKinds.ARTIST_STATEMENT,
            schema: keccak256("schema/artist-statement/v1"),
            content: HashRef(HASH_SHA256, keccak256("the document")),
            uri: "ar://document",
            fileId: bytes32(0),
            supersedes: bytes32(0)
        });
    }

    /// @dev Sets `expectEmit` for the next append to `s`'s subject and returns the entry hash and
    ///      head the model predicts. Call it immediately before the append (and any `prank`).
    function _expectAppend(Role role, address signer, Statement memory s)
        internal
        returns (bytes32, bytes32)
    {
        StatementModel.Appended memory e;
        e.subjectKey = StatementModel.subjectKey(s.token, s.id);
        e.kind = s.kind;
        e.signer = signer;
        e.role = role;
        e.resolver = role == Role.ARTIST ? stmtLog.artistResolver() : address(0);
        bytes32 previous;
        (e.index, previous) = stmtLog.chainOf(s.token, s.id);
        e.recordedAt = uint64(block.timestamp);
        e.entryHash = StatementModel.entryHash(
            address(stmtLog), block.chainid, e.index, role, signer, e.resolver, e.recordedAt, s
        );
        e.head = StatementModel.fold(previous, e.entryHash);
        vm.expectEmit(true, true, true, true, address(stmtLog));
        emit IStatementLog.StatementAppended(
            e.subjectKey,
            e.kind,
            e.signer,
            e.role,
            e.resolver,
            e.index,
            e.recordedAt,
            e.entryHash,
            e.head,
            s
        );
        return (e.entryHash, e.head);
    }

    function _append(Role role, address from, Statement memory s) internal returns (bytes32) {
        vm.prank(from);
        return stmtLog.append(role, s);
    }

    /// @dev An EIP-712 signature (r, s, v) over the independently computed digest.
    function _signAs(
        uint256 key,
        uint256 chainId,
        address verifying,
        Role role,
        Statement memory s,
        uint256 nonce,
        uint64 deadline
    ) internal pure returns (bytes memory) {
        bytes32 digest = StatementModel.digest(
            chainId, verifying, role, s, vm.addr(key), nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(key, digest);
        return abi.encodePacked(r, sv, v);
    }

    function _sign(uint256 key, Role role, Statement memory s, uint256 nonce, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signAs(key, block.chainid, address(stmtLog), role, s, nonce, deadline);
    }

    /// @dev Submits a relayed statement from an unrelated relayer.
    function _relay(
        Role role,
        Statement memory s,
        address signer,
        uint256 nonce,
        uint64 deadline,
        bytes memory signature
    ) internal returns (bytes32) {
        vm.prank(stranger);
        return stmtLog.appendSigned(role, s, signer, nonce, deadline, signature);
    }

    function _ascii(uint256 length) internal pure returns (string memory) {
        bytes memory b = new bytes(length);
        for (uint256 i; i < length; ++i) {
            b[i] = "a";
        }
        return string(b);
    }
}
