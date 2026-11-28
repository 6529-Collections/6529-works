// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { StatementLogFixture } from "./StatementLogFixture.sol";
import { StreamCoreMock } from "./StatementLogPolicy.t.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { OZERC721Mock, OZERC1155Mock } from "../mocks/records/RecordsMocks.sol";
import { ERC1271WalletMock } from "../mocks/libraries/AdversarialTargets.sol";

/// @notice The statement log's gas rule (DSP-26): every call out (the item fallback's ERC-165
///         probe and `itemHashOf`, the dispute subject's ERC-165 probes and `ownerOf`, the OWNER
///         reads and the relayed ERC-1271 check) goes to a dependency wrapped in a `Burner`
///         costing 1x, 2x, 4x, 10x and 100x its base. The answer never changes with the cost,
///         and running short reverts with `BoundedCall.BoundedCallShortfall`: never "no outcome",
///         never an unchecked dispute subject, never "not the owner", never "invalid signature".
///         Uses only the log's external interface, so it also runs against earlier builds.
contract StatementLogGasRuleTest is StatementLogFixture, GasRuleAssertions {
    uint256 internal constant BASE = 10_000;

    function setUp() public override {
        super.setUp();
    }

    function _dispute(address token, uint256 id) internal pure returns (Statement memory s) {
        s = _statement(token, id);
        s.kind = StatementKinds.DISPUTE_OUTCOME;
    }

    /// @dev Records an outcome about `itemHash` and returns a Stream-shaped token minted from it,
    ///      wrapped in a burner.
    function _streamWithItemOutcome() internal returns (Burner token, bytes32 outcome) {
        bytes32 itemHash = keccak256("an item");
        vm.prank(platform);
        outcome = stmtLog.appendPlatform(_dispute(address(0), uint256(itemHash)));
        token = new Burner(address(new StreamCoreMock(itemHash)), BASE);
    }

    // ------------------------------------------------- latestDisputeOutcome, item fallback

    function test_GasRule_LatestDisputeOutcome_ItemOutcomeAtEveryCostNeverZeroWhenShort() public {
        (Burner token, bytes32 outcome) = _streamWithItemOutcome();
        bytes memory call =
            abi.encodeCall(IStatementLog.latestDisputeOutcome, (address(token), uint256(1)));
        Outcome memory o = _assertSameAtEveryMultiple(token, stranger, address(stmtLog), call);
        assertTrue(o.ok);
        assertEq(abi.decode(o.data, (bytes32)), outcome, "the item's outcome");
        token.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(token, stranger, address(stmtLog), call);
    }

    function test_GasRule_LatestDisputeOutcome_UnknownWorkAtEveryCost() public {
        (Burner token,) = _streamWithItemOutcome();
        StreamCoreMock(token.burnerInner()).setMode(StreamCoreMock.Mode.UNKNOWN_WORK);
        bytes memory call =
            abi.encodeCall(IStatementLog.latestDisputeOutcome, (address(token), uint256(1)));
        Outcome memory o = _assertSameAtEveryMultiple(token, stranger, address(stmtLog), call);
        assertEq(abi.decode(o.data, (bytes32)), bytes32(0), "no such work");
        token.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(token, stranger, address(stmtLog), call);
    }

    // ------------------------------------------------------------ the dispute subject

    function test_GasRule_DisputeSubject_NonexistentTokenRefusedAtEveryCostNeverAccepted() public {
        OZERC721Mock nft721 = new OZERC721Mock();
        nft721.mint(tokenOwner, 1);
        Burner token = new Burner(address(nft721), BASE);

        bytes memory missing =
            abi.encodeCall(IStatementLog.appendPlatform, (_dispute(address(token), 5)));
        Outcome memory o = _assertSameAtEveryMultiple(token, platform, address(stmtLog), missing);
        assertFalse(o.ok);
        assertEq(
            o.data,
            abi.encodeWithSelector(
                IStatementLog.UnknownDisputeSubject.selector, address(token), uint256(5)
            )
        );
        token.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(token, platform, address(stmtLog), missing);

        token.burnerSetMultiple(1);
        bytes memory present =
            abi.encodeCall(IStatementLog.appendPlatform, (_dispute(address(token), 1)));
        o = _assertSameAtEveryMultiple(token, platform, address(stmtLog), present);
        assertTrue(o.ok, "an existing token is accepted");
        token.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(token, platform, address(stmtLog), present);
    }

    // ------------------------------------------------------------------- OWNER reads

    function test_GasRule_Owner_Erc721OwnerAuthorisedAtEveryCostNeverRefusedWhenShort() public {
        OZERC721Mock nft721 = new OZERC721Mock();
        nft721.mint(tokenOwner, 5);
        Burner token = new Burner(address(nft721), BASE);
        bytes memory call =
            abi.encodeCall(IStatementLog.append, (Role.OWNER, _statement(address(token), 5)));
        Outcome memory o = _assertSameAtEveryMultiple(token, tokenOwner, address(stmtLog), call);
        assertTrue(o.ok);
        token.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(token, tokenOwner, address(stmtLog), call);
    }

    /// @dev `ownerOf` is refused cheaply, then `balanceOf` answers: the fall-through holds at
    ///      every cost, and running short in either read is a shortfall.
    function test_GasRule_Owner_Erc1155HolderAuthorisedAtEveryCostNeverRefusedWhenShort() public {
        OZERC1155Mock nft1155 = new OZERC1155Mock();
        nft1155.mint(tokenOwner, 9, 3);
        Burner token = new Burner(address(nft1155), BASE);
        bytes memory call =
            abi.encodeCall(IStatementLog.append, (Role.OWNER, _statement(address(token), 9)));
        Outcome memory o = _assertSameAtEveryMultiple(token, tokenOwner, address(stmtLog), call);
        assertTrue(o.ok);
        token.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(token, tokenOwner, address(stmtLog), call);
    }

    // ------------------------------------------------------------ relayed ERC-1271

    function test_GasRule_Relay_Erc1271SignerAcceptedAtEveryCostNeverInvalidWhenShort() public {
        uint256 walletKey = 0xB0B;
        Burner wallet = new Burner(address(new ERC1271WalletMock(vm.addr(walletKey))), BASE);
        resolver.grant(address(nft), 1, address(wallet));
        Statement memory s = _statement();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = stmtLog.authorizationDigest(Role.ARTIST, s, address(wallet), 1, deadline);
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(walletKey, digest);
        bytes memory call = abi.encodeCall(
            IStatementLog.appendSigned,
            (Role.ARTIST, s, address(wallet), 1, deadline, abi.encodePacked(r, sv, v))
        );
        Outcome memory o = _assertSameAtEveryMultiple(wallet, stranger, address(stmtLog), call);
        assertTrue(o.ok);
        wallet.burnerSetMultiple(10);
        _assertShortfallNeverAnswers(wallet, stranger, address(stmtLog), call);
    }
}
