// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { Supports165 } from "./StreamMocks.sol";

/// @notice A mint policy that answers `authorize` with the exact bytes the test sets, and keeps
///         the calldata Stream sent it, so a test can check what Stream passed it.
contract RawAnswerPolicy is Supports165 {
    address public immutable artistRegistry;
    bytes internal _answer;
    bytes public lastInput;

    constructor(address artists) {
        artistRegistry = artists;
    }

    function _interface() internal pure override returns (bytes4) {
        return type(IMintPolicy).interfaceId;
    }

    function setAnswer(bytes calldata answer) external {
        _answer = answer;
    }

    function authorize(IMintPolicy.MintContext calldata, bytes calldata) external {
        lastInput = msg.data;
        bytes memory answer = _answer;
        assembly ("memory-safe") {
            return(add(answer, 0x20), mload(answer))
        }
    }

    function preview(IMintPolicy.MintContext calldata, bytes calldata)
        external
        pure
        returns (PrimaryTerms memory terms)
    {
        return terms;
    }
}

/// @notice A sale adapter whose ERC-165 answer the test can withdraw after its admission.
contract SwitchableSaleAdapter is IERC165 {
    bytes32 public immutable saleKind;
    bool public answers = true;

    constructor(bytes32 kind) {
        saleKind = kind;
    }

    function setAnswers(bool answers_) external {
        answers = answers_;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        return answers && (id == type(ISaleAdapter).interfaceId || id == type(IERC165).interfaceId);
    }

    function start(IMintTarget token, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        return token.mint(address(this), 0, 1, data);
    }
}
