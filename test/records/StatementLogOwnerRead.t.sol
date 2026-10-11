// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IStatementLog, Role, Statement } from "src/records/IStatementLog.sol";
import { StatementLogFixture } from "./StatementLogFixture.sol";
import {
    FallbackERC1155Mock,
    MeteredOwnerMock,
    OZERC721Mock,
    OZERC1155Mock
} from "../mocks/RecordsMocks.sol";
import { ReturnBombMock } from "../mocks/AdversarialTargets.sol";

/// @notice The OWNER read: unmodified OpenZeppelin tokens with cold storage, the gas cap pinned
///         from both sides, return-data bombs that reach the size cap, and the ERC-1155 fall
///         through.
contract StatementLogOwnerReadTest is StatementLogFixture {
    function _notAuthorized(address who) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IStatementLog.NotAuthorized.selector, Role.OWNER, who)
        );
    }

    /// @dev The least gas a cold `staticcall` needs in order to succeed.
    function _minimumReadGas(address token, bytes memory call) internal returns (uint256) {
        uint256 low = 0;
        uint256 high = 200_000;
        while (low + 1 < high) {
            uint256 mid = (low + high) / 2;
            vm.cool(token);
            (bool ok,) = token.staticcall{ gas: mid }(call);
            if (ok) high = mid;
            else low = mid;
        }
        return high;
    }

    // ----------------------------------------------- real tokens, cold storage

    function test_OZ_ERC721_OwnerAuthorisedWithColdStorageAndLargeMargin() public {
        OZERC721Mock token = new OZERC721Mock();
        token.mint(tokenOwner, 5);
        uint256 needed = _minimumReadGas(address(token), abi.encodeCall(IERC721.ownerOf, (5)));
        emit log_named_uint("gas an OpenZeppelin ERC-721 ownerOf needs, cold", needed);
        // A real cold read is a few thousand gas; the cap leaves at least a tenfold margin. (The
        // cap's lower side is pinned by the metered-token test, not by a standard token.)
        assertGt(needed, 2_000, "the measurement is a genuine cold read");
        assertLt(needed * 10, stmtLog.OWNER_READ_GAS(), "standard tokens keep a wide margin");

        vm.cool(address(token));
        _expectAppend(Role.OWNER, tokenOwner, _statement(address(token), 5));
        _append(Role.OWNER, tokenOwner, _statement(address(token), 5));

        _notAuthorized(stranger);
        _append(Role.OWNER, stranger, _statement(address(token), 5));
    }

    function test_OZ_ERC1155_HolderAuthorisedWithColdStorageAndLargeMargin() public {
        OZERC1155Mock token = new OZERC1155Mock();
        token.mint(tokenOwner, 9, 3);
        uint256 needed =
            _minimumReadGas(address(token), abi.encodeCall(IERC1155.balanceOf, (tokenOwner, 9)));
        emit log_named_uint("gas an OpenZeppelin ERC-1155 balanceOf needs, cold", needed);
        assertGt(needed, 2_000, "the measurement is a genuine cold read");
        assertLt(needed * 10, stmtLog.OWNER_READ_GAS(), "standard tokens keep a wide margin");

        vm.cool(address(token));
        _expectAppend(Role.OWNER, tokenOwner, _statement(address(token), 9));
        _append(Role.OWNER, tokenOwner, _statement(address(token), 9));

        _notAuthorized(stranger);
        _append(Role.OWNER, stranger, _statement(address(token), 9));
    }

    // ------------------------------------------------------- the gas cap itself

    /// @dev A token that needs 30k gas is read; one that needs more than the cap is refused, and
    ///      the refusal costs the caller no more than the cap. Pins the cap from below and above.
    function test_Owner_ReadGasCapIsEnforcedFromBothSides() public {
        MeteredOwnerMock cheap = new MeteredOwnerMock(tokenOwner, 30_000);
        _append(Role.OWNER, tokenOwner, _statement(address(cheap), 1));

        MeteredOwnerMock dear = new MeteredOwnerMock(tokenOwner, 60_000);
        uint256 before = gasleft();
        _notAuthorized(tokenOwner);
        _append(Role.OWNER, tokenOwner, _statement(address(dear), 1));
        // Two reads (ownerOf, then the ERC-1155 fall through) of at most 50k gas each.
        assertLt(before - gasleft(), 2 * stmtLog.OWNER_READ_GAS() + 60_000);
    }

    // ------------------------------------------------------------- return bombs

    function test_Owner_OversizedReturnDataIsRefusedAtTheSizeCap() public {
        bytes32 ownerWord = bytes32(uint256(uint160(tokenOwner)));
        // Each size is cheap enough to return inside the read gas cap, so the refusal is the size
        // cap, not an out-of-gas.
        uint256[3] memory sizes = [uint256(64), 1_000, 10_000];
        for (uint256 i; i < sizes.length; ++i) {
            address bomb = address(new ReturnBombMock(sizes[i], ownerWord));
            uint256 before = gasleft();
            _notAuthorized(tokenOwner);
            _append(Role.OWNER, tokenOwner, _statement(bomb, 1));
            assertLt(before - gasleft(), 250_000, "the bomb was not copied or paid for");
        }
        // Control: the same mock returning exactly one word is the owner.
        address exact = address(new ReturnBombMock(32, ownerWord));
        _append(Role.OWNER, tokenOwner, _statement(exact, 1));
    }

    // -------------------------------------------------------- ERC-1155 fall through

    /// @dev A token with a catch-all fallback answers `ownerOf` with empty data; the holder must
    ///      still be recognised through `balanceOf`.
    function test_Owner_ERC1155WithEmptyFallbackStillAuthorisesHolders() public {
        FallbackERC1155Mock token = new FallbackERC1155Mock();
        token.setBalance(7, tokenOwner, 5);
        _expectAppend(Role.OWNER, tokenOwner, _statement(address(token), 7));
        _append(Role.OWNER, tokenOwner, _statement(address(token), 7));

        _notAuthorized(stranger); // no balance
        _append(Role.OWNER, stranger, _statement(address(token), 7));
    }
}
