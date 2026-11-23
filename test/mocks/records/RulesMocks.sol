// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";

/// @notice An accounts module whose wallets the test sets and whose `requireSigned` checks a
///         real ECDSA signature: a proof is `abi.encodePacked(wallet, r, s, v)`.
contract SigningAccounts {
    error NotAWallet(uint256 accountId, address wallet);
    error BadSignature(address wallet);

    mapping(uint256 => mapping(address => bool)) public isWallet;
    mapping(uint256 => address) public payoutAddress;

    function setWallet(uint256 accountId, address wallet, bool ok) external {
        isWallet[accountId][wallet] = ok;
    }

    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        external
        view
        returns (address wallet)
    {
        wallet = address(bytes20(proof[:20]));
        if (!isWallet[accountId][wallet]) revert NotAWallet(accountId, wallet);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, proof[20:]);
        if (err != ECDSA.RecoverError.NoError || recovered != wallet) revert BadSignature(wallet);
    }
}

/// @notice A chunk store serving whatever bytes the test gives it, by chunk hash.
contract RulesChunkStore {
    mapping(bytes32 => bytes) internal _data;

    function put(bytes calldata data) external {
        _data[keccak256(data)] = data;
    }

    function chunkData(bytes32 chunkHash) external view returns (bytes memory) {
        bytes memory d = _data[chunkHash];
        require(d.length != 0, "missing");
        return d;
    }
}

/// @notice A token contract that answers `StreamWorkFacts6529` what the test sets, and calls back
///         into `StreamWorkFacts6529` from its metadata hook (the one call `StreamWorkFacts6529`
///         makes that is not static) to try to open twice or change what was just written.
contract ReenteringToken {
    IWorkFacts public facts;
    bytes32 public itemHash;
    address public records;
    address public renderer;
    bool public armed;
    bytes internal _reentry;
    uint256 public reentered;

    constructor(IWorkFacts facts_) {
        facts = facts_;
    }

    function set(bytes32 itemHash_, address records_, address renderer_) external {
        (itemHash, records, renderer) = (itemHash_, records_, renderer_);
    }

    function arm(bytes calldata reentry) external {
        (armed, _reentry) = (true, reentry);
    }

    function itemHashOf(uint256) external view returns (bytes32) {
        return itemHash;
    }

    function moduleOf(bytes32 slot) external view returns (address) {
        return slot == "RECORDS" ? records : renderer;
    }

    function emitMetadataUpdate(uint256, uint256) external {
        _reenter();
    }

    /// @notice Drives a RECORDS-module call as this token's records module would.
    function call(bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = address(facts).call(data);
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        (bool ok,) = address(facts).call(_reentry);
        if (ok) ++reentered;
    }
}

/// @notice A renderer with code whose answer the test reads.
contract CodeRenderer {
    uint256 public immutable tag;

    constructor(uint256 tag_) {
        tag = tag_;
    }

    function tokenURI(address, uint256) external view returns (string memory) {
        return tag == 0 ? "data:,a" : "data:,b";
    }
}

/// @notice An Independent Stream module whose fee share per token the test sets.
contract FeeGate {
    mapping(address => uint32) public feeShareOf;

    function setFeeShare(address token, uint32 share) external {
        feeShareOf[token] = share;
    }

    function canMint(address, address) external pure returns (bool) {
        return false;
    }

    /// @dev No Independent Stream listing (StreamTerms reads an Independent Stream pair from it).
    function entry(address) external pure returns (IIndependentStreamRegistry.Entry memory e) { }

    function wasMinter(address) external pure returns (bool) {
        return false;
    }

    function minterRemovedAt(address) external pure returns (uint256) {
        return 0;
    }
}
