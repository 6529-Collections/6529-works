// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISaleAdapter } from "../../src/interfaces/ISaleAdapter.sol";

/// @dev An account the Medusa harnesses act through, so they need no cheatcodes and run unchanged
///      under Medusa, Echidna and Forge. Only the harness that deployed it may make it call. It
///      accepts ETH unless told to refuse, and answers ERC-1271 for the digests it approved.
contract Actor {
    address internal immutable _owner;
    bool public refuseETH;
    mapping(bytes32 digest => bool) public approved;

    constructor() {
        _owner = msg.sender;
    }

    receive() external payable {
        require(!refuseETH, "refused");
    }

    function call(address target, bytes calldata data)
        external
        payable
        returns (bool ok, bytes memory ret)
    {
        require(msg.sender == _owner, "not owner");
        (ok, ret) = target.call{ value: msg.value }(data);
    }

    function setRefuseETH(bool refuse) external {
        require(msg.sender == _owner, "not owner");
        refuseETH = refuse;
    }

    function approve(bytes32 digest) external {
        require(msg.sender == _owner, "not owner");
        approved[digest] = true;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }
}

/// @dev A stub AccessManager: one governor may call every restricted function at once (zero
///      delay), and nobody else may call any. The Medusa harnesses test the contracts' own rules,
///      not the role matrix or the delays, which the Forge suites and `roles.md` cover.
contract Gate {
    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32) {
        return (caller == governor, 0);
    }
}

/// @dev A sale adapter as Stream and Editions see it: the harness makes it call them; it holds
///      the works and copies it mints to itself.
contract SaleAdapter {
    address internal immutable _keeper;
    bytes32 public saleKind;

    constructor(bytes32 kind) {
        _keeper = msg.sender;
        saleKind = kind;
    }

    function act(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        require(msg.sender == _keeper, "not keeper");
        (ok, ret) = target.call(data);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(ISaleAdapter).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev A plain ERC-20 written for the harnesses: exact transfers, returns `true`, no hooks.
contract PlainToken {
    address internal immutable _minter;
    mapping(address account => uint256) public balanceOf;
    mapping(address account => mapping(address spender => uint256)) public allowance;
    uint256 public totalSupply;

    constructor() {
        _minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == _minter, "not minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev What every harness shares: the outcome bookkeeping. A harness predicts whether each call
///      succeeds before making it; a prediction that fails is recorded with its name.
abstract contract MedusaBase {
    /// Marks the harnesses as test contracts, as forge-std's `Test` does, so `forge build --sizes`
    /// (and so `tools/check_budgets.py`) leaves them out: a harness carries the creation code of
    /// every contract it deploys, is never deployed on a chain, and Medusa runs with its code
    /// size check off. Forge finds no test function in them and runs nothing.
    function IS_TEST() external pure returns (bool) {
        return true;
    }

    bool public outcomeMismatch;
    string public lastMismatch;

    /// Makes the call and records a mismatch when its success differs from the model's
    /// prediction. Returns whether the call succeeded and its return data.
    function _expect(
        Actor who,
        address target,
        bytes memory data,
        bool expected,
        string memory what
    ) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = who.call(target, data);
        _record(ok, expected, what);
    }

    function _record(bool ok, bool expected, string memory what) internal {
        if (ok != expected && !outcomeMismatch) {
            outcomeMismatch = true;
            lastMismatch = string(abi.encodePacked(what, ok ? " succeeded" : " reverted"));
        }
    }

    function _must(Actor who, address target, bytes memory data)
        internal
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = who.call(target, data);
        require(ok, "setup call failed");
    }
}
