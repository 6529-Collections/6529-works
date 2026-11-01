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
import { ItemKind, PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";

/// @dev The English auction surface the edition auction reads: `auctionClock(saleId)` on its
///      hot paths and `auction(saleId)` in the lens's `endTimes`, with each 1/1's state and end
///      set by the test. Unknown sales revert as the real one does.
contract MockOneOfOneAuction {
    mapping(uint256 saleId => IEnglishAuction.Auction) internal _auctions;

    function saleIdOf(address token, uint256 id) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }

    function set(address token, uint256 id, IEnglishAuction.AuctionState state, uint64 endTime)
        external
    {
        IEnglishAuction.Auction storage a = _auctions[saleIdOf(token, id)];
        // A pause records when it began, as the real auction does; anything else clears it.
        if (state != IEnglishAuction.AuctionState.PAUSED) {
            a.pausedAt = 0;
        } else if (a.state != IEnglishAuction.AuctionState.PAUSED) {
            a.pausedAt = uint64(block.timestamp);
        }
        (a.token, a.tokenId, a.state, a.endTime) = (token, id, state, endTime);
    }

    /// @dev Sets when a 1/1's dispute pause began.
    function setPausedAt(address token, uint256 id, uint64 pausedAt) external {
        _auctions[saleIdOf(token, id)].pausedAt = pausedAt;
    }

    /// @dev Whether `auction` and `auctionClock` answer short: `auction` its first ten words,
    ///      without `state`; `auctionClock` its first two, without `pausedAt`.
    bool public shortAnswer;

    function setShortAnswer(bool value) external {
        shortAnswer = value;
    }

    function auction(uint256 saleId) external view returns (IEnglishAuction.Auction memory a) {
        a = _auctions[saleId];
        if (a.state == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
        if (shortAnswer) {
            bytes memory full = abi.encode(a);
            assembly ("memory-safe") {
                return(add(full, 0x20), 0x140)
            }
        }
    }

    function auctionClock(uint256 saleId)
        external
        view
        returns (IEnglishAuction.AuctionState state, uint64 endTime, uint64 pausedAt)
    {
        IEnglishAuction.Auction storage a = _auctions[saleId];
        (state, endTime, pausedAt) = (a.state, a.endTime, a.pausedAt);
        if (state == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
        if (shortAnswer) {
            bytes memory two = abi.encode(state, endTime);
            assembly ("memory-safe") {
                return(add(two, 0x20), 0x40)
            }
        }
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
    /// @dev The binding Editions keeps: the adapter, the hash of the item it passed, and the
    ///      economics locked from `resolver` at the binding (when set).
    mapping(uint256 id => address) public minterOf;
    mapping(uint256 id => bytes32) public boundItemHash;
    mapping(uint256 id => WorkTerms) internal _locked;
    address public resolver;
    /// @dev Counts the `bindMinter` calls.
    uint256 public binds;

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

    function setResolver(address resolver_) external {
        resolver = resolver_;
    }

    /// @dev Editions' rule: admitted callers only; binds an unbound edition (locking the
    ///      resolver's economics if it does not exist yet), a no-op for the bound adapter, and
    ///      `MinterMismatch` for another. The item is only hashed and recorded.
    function bindMinter(uint256 id, PackageItem calldata item) external returns (WorkTerms memory) {
        if (!admitted[msg.sender]) revert IMintTarget.NotAdmittedMinter(msg.sender);
        ++binds;
        address bound = minterOf[id];
        if (bound == address(0)) {
            minterOf[id] = msg.sender;
            boundItemHash[id] = WorksHashing.itemHashCalldata(item);
            if (!exists[id] && resolver != address(0)) {
                _locked[id] = MockWorkTermsResolver(resolver).newWorkTerms(bytes32(0), item.payees);
            }
            emit IEditions.EditionMinterBound(id, msg.sender);
        } else if (bound != msg.sender) {
            revert IEditions.MinterMismatch(id, bound);
        }
        return _locked[id];
    }

    /// @dev The economics an edition recorded (as `createEdition` or a binding locked them).
    function setLocked(uint256 id, address seller, address feeRecipient, uint32 feeShare) external {
        _locked[id] = WorkTerms(seller, feeRecipient, feeShare, seller, 0);
    }

    /// @dev The fields the lens reads: the economics locked at the binding.
    function edition(uint256 id) external view returns (IEditions.Edition memory e) {
        WorkTerms memory w = _locked[id];
        (e.seller, e.feeRecipient, e.feeShare, e.minter) =
        (w.seller, w.feeRecipient, w.feeShare, minterOf[id]);
        e.minted = uint64(minted[id]);
    }

    /// @dev Editions' rule: the bound adapter mints even after its removal; an unbound edition
    ///      needs an admitted caller.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256, PrimaryTerms memory terms)
    {
        address bound = minterOf[id];
        if (bound != msg.sender) {
            if (!admitted[msg.sender]) revert IMintTarget.NotAdmittedMinter(msg.sender);
            if (bound != address(0)) revert IEditions.MinterMismatch(id, bound);
        }
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
