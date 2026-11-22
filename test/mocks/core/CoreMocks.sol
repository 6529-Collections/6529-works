// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";

/// @notice A renderer module that answers a fixed string.
contract MockRenderer {
    string public answer = "data:,mock";

    function tokenURI(address, uint256) external view returns (string memory) {
        return answer;
    }
}

/// @notice A TERMS module that passes calls straight through (no rules).
contract MockTerms {
    function setRoyalty(address token, uint256 id, address receiver, uint24 rate) external {
        IStream(token).setRoyalty(id, receiver, rate);
    }

    function lockRoyaltyRate(address token, uint256 id) external {
        IStream(token).lockRoyaltyRate(id);
    }

    function setEditionRoyalty(address editions, uint256 id, address receiver, uint24 rate)
        external
    {
        IEditions(editions).setRoyalty(id, receiver, rate);
    }

    function refresh(address token, uint256 from, uint256 to) external {
        IStream(token).emitMetadataUpdate(from, to);
    }
}

/// @notice A RECORDS module that passes calls straight through to `IWorkFacts` (no rules).
contract MockRecords {
    IWorkFacts public immutable facts;

    constructor(IWorkFacts facts_) {
        facts = facts_;
    }

    function setRecord(address token, uint256 id, bytes32 recordFileId) external {
        facts.setRecord(token, id, recordFileId);
    }

    function setLicense(address token, uint256 id, License calldata next) external {
        facts.setLicense(token, id, next);
    }

    function finalize(address token, uint256 id) external {
        facts.finalize(token, id);
    }

    function repin(address token, uint256 id, address renderer) external {
        facts.repin(token, id, renderer);
    }

    function lock(address token, uint256 id, bool license, bool repin_) external {
        facts.lock(token, id, license, repin_);
    }
}

/// @notice A sale contract (minter) that does what the test tells it, holding tokens in custody.
contract MockSale {
    function mint(address token, MintFacts calldata f) external returns (uint256) {
        return IStream(token).mint(address(this), f);
    }

    function mintTo(address token, address to, MintFacts calldata f) external returns (uint256) {
        return IStream(token).mint(to, f);
    }

    function record(address token, uint256 id, bool sold, address buyer, uint256 price) external {
        IStream(token).recordPrimarySale(id, sold, buyer, price);
    }

    function burn(address token, uint256 id) external {
        IStream(token).burn(id);
    }

    function send(address token, uint256 id, address to) external {
        IERC721(token).transferFrom(address(this), to, id);
    }

    function createEdition(address editions, uint256 id, uint40 max, address receiver, uint24 rate)
        external
    {
        IEditions(editions).create(id, max, receiver, rate);
    }

    function mintEdition(address editions, address to, uint256 id, uint256 amount, uint256 price)
        external
    {
        IEditions(editions).mint(to, id, amount, price);
    }

    function seal(address editions, uint256 id, uint40 supply) external {
        IEditions(editions).seal(id, supply);
    }
}

/// @notice An accounts module with one settable payout per artist and open `isWallet` answers.
contract MockAccounts {
    mapping(uint256 => address) public payoutAddress;
    mapping(uint256 => mapping(address => bool)) public isWallet;

    function setPayout(uint256 artistId, address payout) external {
        payoutAddress[artistId] = payout;
    }

    function setWallet(uint256 accountId, address wallet, bool ok) external {
        isWallet[accountId][wallet] = ok;
    }
}

/// @notice An Independent Stream gate whose answers the test sets.
contract MockIndependentStreamGate {
    mapping(address => mapping(address => bool)) public canMint;
    mapping(address => bool) public wasMinter;
    mapping(address => uint256) public minterRemovedAt;
    mapping(address => uint32) public feeShareOf;

    function setMinter(address token, address minter, bool ok) external {
        canMint[token][minter] = ok;
        if (ok) wasMinter[minter] = true;
    }

    function remove(address minter, uint256 when) external {
        minterRemovedAt[minter] = when;
    }

    /// @dev No Independent Stream listing (StreamTerms reads an Independent Stream pair from it).
    function entry(address) external pure returns (IIndependentStreamRegistry.Entry memory e) { }
}

/// @notice A module that misbehaves in any seam position: as a renderer it reverts, burns all
///         its gas or lies; as TERMS, RECORDS or a minter it tries everything it must not be
///         able to do, and re-enters from the ERC-721 receiver hook.
contract HostileModule {
    enum Mode {
        LIE,
        REVERT,
        BURN_GAS
    }

    Mode public mode;
    address public target;
    uint256 public targetId;
    uint256 public reentered;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function tokenURI(address, uint256) external view returns (string memory) {
        if (mode == Mode.REVERT) revert("hostile");
        if (mode == Mode.BURN_GAS) {
            uint256 x;
            while (true) {
                ++x;
            }
        }
        return "data:,a lie";
    }

    /// @notice Tries every call a module must not succeed at against a token `victim` holds.
    /// @return succeeded A bit per attempt that did NOT revert (0 means the core held).
    function attack(address token, uint256 id, address victim)
        external
        returns (uint256 succeeded)
    {
        bytes[6] memory calls = [
            abi.encodeCall(IERC721.transferFrom, (victim, address(this), id)),
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)", victim, address(this), id
            ),
            abi.encodeCall(IStream.burn, (id)),
            abi.encodeCall(IStream.recordPrimarySale, (id, true, address(this), 1)),
            abi.encodeCall(IStream.rescue, (id, address(this))),
            abi.encodeCall(IERC721.approve, (address(this), id))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = token.call(calls[i]);
            if (ok) succeeded |= 1 << i;
        }
    }

    /// @notice Passes any call through, so a test can drive it as TERMS, RECORDS or a minter.
    function exec(address to, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = to.call(data);
    }

    /// @notice Arms a re-entrant burn and sale record from the receiver hook.
    function arm(address token, uint256 id) external {
        (target, targetId) = (token, id);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata)
        external
        returns (bytes4)
    {
        if (target != address(0)) {
            (bool a,) = target.call(abi.encodeCall(IStream.burn, (id)));
            (bool b,) =
                target.call(abi.encodeCall(IStream.recordPrimarySale, (id, false, address(0), 0)));
            if (a || b) ++reentered;
        }
        return this.onERC721Received.selector;
    }
}
