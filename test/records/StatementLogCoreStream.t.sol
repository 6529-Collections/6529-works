// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { StatementLog } from "src/records/StatementLog.sol";
import { Statement } from "src/interfaces/IStatementLog.sol";
import { HashRef } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";

/// @notice `latestDisputeOutcome` against the real permanent `Stream6529` (`CoreFixture`): the item
///         fallback reads `itemHashOf` on a token that declares the core `IStream`, a burned or
///         unminted token reads zero, and a token's own outcome comes first.
contract StatementLogCoreStreamTest is CoreFixture {
    StatementLog internal stmtLog;

    function setUp() public override {
        super.setUp();
        // The test contract is the AccessManager's admin, so it may call `appendPlatform`.
        stmtLog = new StatementLog(address(manager), address(0), bytes32(0));
    }

    function _dispute(address token, uint256 id) internal pure returns (Statement memory s) {
        s.token = token;
        s.id = id;
        s.kind = StatementKinds.DISPUTE_OUTCOME;
        s.schema = keccak256("schema");
        s.content = HashRef(1, keccak256("outcome"));
        s.fileId = bytes32(uint256(1));
    }

    function test_TheItemsOutcomeIsFoundThroughItemHashOf() public {
        uint256 id = _sell(1, collector);
        assertEq(stmtLog.latestDisputeOutcome(address(stream), id), bytes32(0), "no outcome yet");
        bytes32 itemOutcome =
            stmtLog.appendPlatform(_dispute(address(0), uint256(stream.itemHashOf(id))));
        assertEq(stmtLog.latestDisputeOutcome(address(stream), id), itemOutcome, "the item's");
        bytes32 own = stmtLog.appendPlatform(_dispute(address(stream), id));
        assertEq(stmtLog.latestDisputeOutcome(address(stream), id), own, "the token's own first");
    }

    function test_ABurnedOrUnmintedTokenReadsZero() public {
        uint256 id = _mint(1);
        stmtLog.appendPlatform(_dispute(address(0), uint256(stream.itemHashOf(id))));
        sale.burn(address(stream), id);
        assertEq(stmtLog.latestDisputeOutcome(address(stream), id), bytes32(0), "burned");
        assertEq(stmtLog.latestDisputeOutcome(address(stream), 99), bytes32(0), "never minted");
    }
}
