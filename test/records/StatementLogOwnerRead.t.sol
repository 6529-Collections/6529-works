// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { StatementLogFixture } from "./StatementLogFixture.sol";
import {
    FallbackERC1155Mock,
    MeteredOwnerMock,
    OZERC721Mock,
    OZERC1155Mock
} from "../mocks/records/RecordsMocks.sol";
import { ReturnBombMock } from "../mocks/libraries/AdversarialTargets.sol";

/// @notice The OWNER read: unmodified OpenZeppelin tokens with cold storage, reads that forward
///         all gas (no cap), return-data bombs that reach the size cap, and the ERC-1155 fall
///         through. Shortfalls are stressed in `StatementLogGasRule.t.sol`.
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
        assertGt(needed, 2_000, "the measurement is a genuine cold read");

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

        vm.cool(address(token));
        _expectAppend(Role.OWNER, tokenOwner, _statement(address(token), 9));
        _append(Role.OWNER, tokenOwner, _statement(address(token), 9));

        _notAuthorized(stranger);
        _append(Role.OWNER, stranger, _statement(address(token), 9));
    }

    // ------------------------------------------------------------- no gas cap

    /// @dev The read forwards all gas: a token whose `ownerOf` needs 60k (above the former 50k
    ///      cap) or 2M is read and its owner authorised, as one that needs 30k is.
    function test_Owner_ReadHasNoGasCap() public {
        uint256[3] memory costs = [uint256(30_000), 60_000, 2_000_000];
        for (uint256 i; i < costs.length; ++i) {
            MeteredOwnerMock token = new MeteredOwnerMock(tokenOwner, costs[i]);
            _expectAppend(Role.OWNER, tokenOwner, _statement(address(token), 1));
            _append(Role.OWNER, tokenOwner, _statement(address(token), 1));
        }
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
