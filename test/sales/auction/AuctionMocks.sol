// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { StreamBase } from "src/core/StreamBase.sol";
import { MintFacts, MintTerms, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IIndependentStreamGate } from "src/interfaces/core/IIndependentStreamGate.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";

/// @notice A mint policy whose answers the test sets. `request` is `abi.encode(uint256 n)`:
///         work `n` gets its own item and content hash. Like the real policies it serves only
///         an active minter of the token. Modes make it misbehave.
contract MockMintPolicy is IERC165 {
    enum Mode {
        OK,
        REVERT,
        BURN_GAS,
        REENTER
    }

    Mode public mode;
    MintTerms internal _terms;
    uint256 public artistId = uint160(0xA11CE);
    address public royaltyReceiver = address(0xFEE);
    uint24 public royaltyRate = 6529;
    bytes public reentry;
    bool public reentered;

    constructor(address seller, address feeRecipient, uint32 feeShare) {
        _terms.saleKind = SaleKind.ENGLISH_AUCTION;
        _terms.seller = seller;
        _terms.feeRecipient = feeRecipient;
        _terms.feeShare = feeShare;
        _terms.creator = address(0xC0FFEE);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReentry(bytes calldata data) external {
        reentry = data;
    }

    function setTerms(bytes32 saleKind, bytes calldata params, address seller, uint32 share)
        external
    {
        (_terms.saleKind, _terms.params, _terms.seller, _terms.feeShare) =
        (saleKind, params, seller, share);
    }

    function authorize(address token, bytes calldata request)
        external
        returns (MintFacts memory f, MintTerms memory t)
    {
        if (!IModules(token).isMinter(msg.sender)) {
            revert IMintPolicy.NotSaleContract(token, msg.sender);
        }
        if (mode == Mode.REVERT) revert("policy says no");
        if (mode == Mode.BURN_GAS) {
            uint256 x;
            while (true) {
                ++x;
            }
        }
        if (mode == Mode.REENTER) {
            (bool ok,) = msg.sender.call(reentry);
            reentered = ok;
        }
        f = factsOf(abi.decode(request, (uint256)));
        t = _terms;
    }

    function factsOf(uint256 n) public view returns (MintFacts memory f) {
        f.itemHash = keccak256(abi.encode("item", n));
        f.contentHash = keccak256(abi.encode("content", n));
        f.artistId = artistId;
        f.collectionId = 1;
        f.royaltyReceiver = royaltyReceiver;
        f.royaltyRate = royaltyRate;
        f.seller = _terms.seller;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId || interfaceId == type(IMintPolicy).interfaceId;
    }
}

/// @notice The Independent Stream module the directory names: a mint policy for Independent Stream
///         tokens and their gate, whose answers the test sets.
contract MockIndependentStreamPolicy is MockMintPolicy, IIndependentStreamGate {
    mapping(address => mapping(address => bool)) public canMint;
    mapping(address => bool) public wasMinter;
    mapping(address => uint256) public minterRemovedAt;
    /// @dev Whether the token is served (`IIndependentStreamRegistry.isActive`), which the English
    ///      auction asks to decide whether an Independent Stream sale goes on.
    mapping(address => bool) public isActive;

    constructor(address seller, address feeRecipient, uint32 feeShare)
        MockMintPolicy(seller, feeRecipient, feeShare)
    { }

    /// @dev Admitting a sale contract for a token also serves the token; refusing it models a
    ///      delisting (the token is no longer served).
    function setMinter(address token, address minter, bool ok) external {
        canMint[token][minter] = ok;
        isActive[token] = ok;
        if (ok) wasMinter[minter] = true;
    }

    /// @dev Stops `minter` minting for `token` while the token stays served (a removed sale
    ///      contract or a suspended version).
    function stopMinting(address token, address minter) external {
        canMint[token][minter] = false;
    }

    /// @dev The share the policy's terms answer.
    function feeShareOf(address) external view returns (uint32) {
        return _terms.feeShare;
    }

    /// @dev Makes the gate deny that `minter` ever was one (a token then refuses its records).
    function forget(address minter) external {
        wasMinter[minter] = false;
    }
}

/// @notice An Independent Stream token: the plain `StreamBase` with its minters answered by the
///         directory's Independent Stream module. One collection; the test is its admin and
///         network.
contract MockIndependentToken is StreamBase {
    IDirectory public immutable directory;
    address public immutable admin;

    constructor(address facts_, IDirectory directory_)
        StreamBase("Independent", "IND", facts_, msg.sender)
    {
        directory = directory_;
        admin = msg.sender;
        _createCollection("Works", bytes32(uint256(1)));
    }

    function isMinter(address account) external view returns (bool) {
        return _isMinter(account);
    }

    function _gate() private view returns (IIndependentStreamGate) {
        return IIndependentStreamGate(directory.moduleOf(Slots.INDEPENDENT_STREAM));
    }

    function _moduleOf(bytes32) internal pure override returns (address) {
        return address(0);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return _gate().canMint(address(this), account);
    }

    function _wasMinter(address account) internal view override returns (bool) {
        return MockIndependentStreamPolicy(address(_gate())).wasMinter(account);
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return _gate().minterRemovedAt(account);
    }

    function _checkAdmin() internal view override {
        require(msg.sender == admin, "admin");
    }

    function _checkNetwork() internal view override {
        require(msg.sender == admin, "network");
    }
}

/// @notice A statement log that answers the dispute outcome the test sets.
contract MockStatementLog {
    mapping(address => mapping(uint256 => bytes32)) public entryOf;
    mapping(address => mapping(uint256 => uint64)) public indexOf;

    function setOutcome(address token, uint256 id, bytes32 entry, uint64 index) external {
        (entryOf[token][id], indexOf[token][id]) = (entry, index);
    }

    function disputeOutcomeOf(address token, uint256 id) external view returns (bytes32, uint64) {
        return (entryOf[token][id], indexOf[token][id]);
    }
}

/// @notice A bidder contract: bids, claims, and can refuse ETH or the token, burn gas on
///         receipt, or re-enter the auction from its receiver hook.
contract BidderContract {
    IEnglishAuction public immutable auction;
    bool public refuseEth;
    bool public refuseToken;
    bool public burnOnToken;
    bytes public reentry;
    bool public reentered;

    constructor(IEnglishAuction auction_) {
        auction = auction_;
    }

    function set(bool refuseEth_, bool refuseToken_, bool burnOnToken_) external {
        (refuseEth, refuseToken, burnOnToken) = (refuseEth_, refuseToken_, burnOnToken_);
    }

    function setReentry(bytes calldata data) external {
        reentry = data;
    }

    function bid(uint256 saleId, address recipient) external payable {
        auction.bid{ value: msg.value }(saleId, recipient);
    }

    function claim(address to) external returns (uint256) {
        return auction.claim(to);
    }

    function claimDelivery(uint256 saleId, address to) external {
        auction.claimDelivery(saleId, to);
    }

    receive() external payable {
        if (refuseEth) revert("no eth");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (reentry.length != 0) {
            (bool ok,) = address(auction).call(reentry);
            reentered = ok;
        }
        if (burnOnToken) {
            uint256 x;
            while (true) {
                ++x;
            }
        }
        if (refuseToken) revert("no token");
        return this.onERC721Received.selector;
    }
}

/// @notice A wallet that refuses ETH (a seller or fee wallet whose payout goes to the escrow).
contract RefusingWallet {
    receive() external payable {
        revert("refused");
    }
}
