// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";

/// @dev The English auction surface the edition auction reads: `auction(saleId)`, with each
///      1/1's state and end set by the test. Unknown sales revert as the real one does.
contract MockOneOfOneAuction {
    mapping(uint256 saleId => IEnglishAuction.Auction) internal _auctions;

    function saleIdOf(address token, uint256 id) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }

    function set(address token, uint256 id, IEnglishAuction.AuctionState state, uint64 endTime)
        external
    {
        IEnglishAuction.Auction storage a = _auctions[saleIdOf(token, id)];
        (a.token, a.tokenId, a.state, a.endTime) = (token, id, state, endTime);
    }

    function auction(uint256 saleId) external view returns (IEnglishAuction.Auction memory a) {
        a = _auctions[saleId];
        if (a.state == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEnglishAuction).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev 6529 Stream's reads: `coreOf` (the stored item hash and kind) and `economics`.
contract MockMasterStream {
    address public economics;
    mapping(uint256 id => bytes32) internal _itemHashes;
    mapping(uint256 id => ItemKind) internal _kinds;

    constructor(address economics_) {
        economics = economics_;
    }

    function setWork(uint256 id, bytes32 itemHash, ItemKind kind) external {
        (_itemHashes[id], _kinds[id]) = (itemHash, kind);
    }

    function coreOf(uint256 id)
        external
        view
        returns (bytes32, uint256, uint256, ItemKind, SeedPolicy, uint32)
    {
        bytes32 itemHash = _itemHashes[id];
        if (itemHash == 0) revert IStream.UnknownWork(id);
        return (itemHash, 1, 1, _kinds[id], SeedPolicy.NONE, 6529);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IStream).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev 6529 Stream Editions' surface for the auction: `stream`, `exists` (set by the test) and
///      `mint` for admitted adapters, a real ERC-1155 mint (so receivers' hooks run), counting
///      copies per edition.
contract MockEditionToken is ERC1155 {
    address public stream;
    mapping(uint256 id => bool) public exists;
    mapping(address adapter => bool) public admitted;
    mapping(uint256 id => uint256) public minted;
    /// @dev Added to the ID `mint` returns, to model a broken token.
    uint256 public returnOffset;

    constructor(address stream_) ERC1155("") {
        stream = stream_;
    }

    function setStream(address stream_) external {
        stream = stream_;
    }

    function setReturnOffset(uint256 offset) external {
        returnOffset = offset;
    }

    function setExists(uint256 id, bool value) external {
        exists[id] = value;
    }

    function admit(address adapter, bool value) external {
        admitted[adapter] = value;
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256, PrimaryTerms memory terms)
    {
        if (!admitted[msg.sender]) revert IMintTarget.NotAdmittedMinter(msg.sender);
        if (amount == 0 || data.length != 0 || !exists[id]) {
            revert IMintTarget.InvalidMintRequest();
        }
        minted[id] += amount;
        terms.saleKind = ISaleAdapter(msg.sender).saleKind();
        _mint(to, id, amount, "");
        return (id + returnOffset, terms);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IEditions).interfaceId
            || interfaceId == type(IMintTarget).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @dev The economics resolver's `newWorkTerms`, returning the payout terms the test sets.
contract MockWorkTermsResolver {
    WorkTerms internal _terms;
    bool public refuse;

    function set(address seller, address feeRecipient, uint32 feeShare) external {
        _terms = WorkTerms(seller, feeRecipient, feeShare, seller, 6529);
    }

    function setRefuse(bool value) external {
        refuse = value;
    }

    function newWorkTerms(bytes32, ISplitWallet.Payee[] calldata)
        external
        view
        returns (WorkTerms memory)
    {
        require(!refuse, "payees");
        return _terms;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEconomicsResolver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev A wallet that refuses ETH (no receive), and accepts ERC-1155 copies.
contract EthRefusingHolder is IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

/// @dev A bidder contract that refuses ERC-1155 copies but takes ETH, and can place, raise,
///      withdraw and claim its own bids.
contract CopyRefusingBidder {
    receive() external payable { }

    function bid(IUniformEditionAuction a, uint256 saleId, uint256 step, uint256 quantity)
        external
        payable
        returns (uint256)
    {
        return a.bid{ value: msg.value }(saleId, step, quantity);
    }

    function claimBid(IUniformEditionAuction a, uint256 saleId, uint256 bidId, address to)
        external
        returns (uint256, uint256)
    {
        return a.claimBid(saleId, bidId, to);
    }
}

/// @dev A bidder whose ERC-1155 hook and ETH receive re-enter the auction: claiming, bidding and
///      settling again. Every re-entry must fail with the reentrancy guard; `reverted` records it.
contract ReentrantBidder is IERC1155Receiver {
    IUniformEditionAuction public immutable auction;
    uint256 public saleId;
    uint256 public bidId;
    uint8 public mode;
    bool public attempted;
    bytes public lastRevert;

    constructor(IUniformEditionAuction auction_) {
        auction = auction_;
    }

    function setTarget(uint256 saleId_, uint256 bidId_, uint8 mode_) external {
        (saleId, bidId, mode) = (saleId_, bidId_, mode_);
    }

    function bid(uint256 step, uint256 quantity) external payable returns (uint256) {
        return auction.bid{ value: msg.value }(saleId, step, quantity);
    }

    function claimBid(uint256 id, address to) external returns (uint256, uint256) {
        return auction.claimBid(saleId, id, to);
    }

    function _reenter() internal {
        attempted = true;
        bool ok;
        bytes memory ret;
        if (mode == 0) {
            (ok, ret) = address(auction)
                .call(
                    abi.encodeCall(IUniformEditionAuction.claimBid, (saleId, bidId, address(this)))
                );
        } else if (mode == 1) {
            (ok, ret) = address(auction)
                .call(abi.encodeCall(IUniformEditionAuction.settle, (saleId, new uint256[](0))));
        } else {
            (ok, ret) = address(auction)
                .call(abi.encodeCall(IUniformEditionAuction.claimBidFor, (saleId, bidId)));
        }
        require(!ok, "re-entry succeeded");
        lastRevert = ret;
    }

    receive() external payable {
        _reenter();
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        _reenter();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

/// @dev A seller wallet that tries to re-enter `settle` when paid; the re-entry reverts, so its
///      receive fails and the payout goes to the escrow.
contract ReentrantSeller {
    IUniformEditionAuction public auction;
    uint256 public saleId;

    function setTarget(IUniformEditionAuction auction_, uint256 saleId_) external {
        (auction, saleId) = (auction_, saleId_);
    }

    receive() external payable {
        auction.settle(saleId, new uint256[](0));
    }
}

/// @dev A payout wallet (seller or fee recipient) that, while being paid, tries to re-enter the
///      auction's `settle` and `claimBid`, records each attempt's revert data, and then accepts
///      the payment, so the payout lands directly and the re-entries' outcome is observable.
contract ReenteringPayee {
    IUniformEditionAuction public auction;
    uint256 public saleId;
    uint256 public bidId;
    uint256 public calls;
    bytes public settleRevert;
    bytes public claimRevert;
    bool public settleSucceeded;
    bool public claimSucceeded;

    function setTarget(IUniformEditionAuction auction_, uint256 saleId_, uint256 bidId_) external {
        (auction, saleId, bidId) = (auction_, saleId_, bidId_);
    }

    receive() external payable {
        ++calls;
        if (address(auction) == address(0)) return;
        (bool ok, bytes memory ret) = address(auction)
            .call(abi.encodeCall(IUniformEditionAuction.settle, (saleId, new uint256[](0))));
        (settleSucceeded, settleRevert) = (ok, ret);
        (ok, ret) = address(auction)
            .call(abi.encodeCall(IUniformEditionAuction.claimBid, (saleId, bidId, address(this))));
        (claimSucceeded, claimRevert) = (ok, ret);
    }
}
