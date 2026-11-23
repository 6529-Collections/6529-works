// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind } from "src/interfaces/types/PackageTypes.sol";

/// @dev The English auction surface the edition auction reads, `auctionClock(saleId)`, with each
///      1/1's state and end set by the test. Unknown sales revert as the real one does.
contract MockOneOfOneAuction {
    struct Clock {
        IEnglishAuction.AuctionState state;
        uint64 endTime;
        uint64 pausedAt;
        uint64 restartedAt;
    }

    mapping(uint256 saleId => Clock) internal _clocks;
    /// @dev Whether `auctionClock` answers short (three words, without `restartedAt`), refuses
    ///      to answer (a broken auction), or burns all its gas.
    bool public shortAnswer;
    /// @dev When nonzero, `auctionClock` answers this as its fourth word, unchecked: a value past
    ///      64 bits makes the answer malformed.
    uint256 public rawRestartedAt;
    bool public refuseClock;
    bool public burnClock;

    function saleIdOf(address token, uint256 id) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }

    function set(address token, uint256 id, IEnglishAuction.AuctionState state, uint64 endTime)
        external
    {
        Clock storage c = _clocks[saleIdOf(token, id)];
        // A pause records when it began, as the real auction does; anything else clears it.
        if (state != IEnglishAuction.AuctionState.PAUSED) {
            c.pausedAt = 0;
        } else if (c.state != IEnglishAuction.AuctionState.PAUSED) {
            c.pausedAt = uint64(block.timestamp);
        }
        (c.state, c.endTime) = (state, endTime);
    }

    function setPausedAt(address token, uint256 id, uint64 pausedAt) external {
        _clocks[saleIdOf(token, id)].pausedAt = pausedAt;
    }

    /// @dev Records that the 1/1 was offered again at `restartedAt`, as the real auction's
    ///      `restart` does.
    function setRestartedAt(address token, uint256 id, uint64 restartedAt) external {
        _clocks[saleIdOf(token, id)].restartedAt = restartedAt;
    }

    function setRawRestartedAt(uint256 value) external {
        rawRestartedAt = value;
    }

    function setShortAnswer(bool value) external {
        shortAnswer = value;
    }

    function setRefuseClock(bool value) external {
        refuseClock = value;
    }

    function setBurnClock(bool value) external {
        burnClock = value;
    }

    /// @dev The clock as a test reads it: state and end.
    function clockOf(address token, uint256 id)
        external
        view
        returns (IEnglishAuction.AuctionState, uint64)
    {
        Clock storage c = _clocks[saleIdOf(token, id)];
        return (c.state, c.endTime);
    }

    function auctionClock(uint256 saleId)
        external
        view
        returns (
            IEnglishAuction.AuctionState state,
            uint64 endTime,
            uint64 pausedAt,
            uint64 restartedAt
        )
    {
        require(!refuseClock, "broken");
        if (burnClock) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        Clock storage c = _clocks[saleId];
        (state, endTime, pausedAt, restartedAt) = (c.state, c.endTime, c.pausedAt, c.restartedAt);
        if (state == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
        if (rawRestartedAt != 0) {
            bytes memory four = abi.encode(state, endTime, pausedAt, rawRestartedAt);
            assembly ("memory-safe") {
                return(add(four, 0x20), 0x80)
            }
        }
        if (shortAnswer) {
            bytes memory three = abi.encode(state, endTime, pausedAt);
            assembly ("memory-safe") {
                return(add(three, 0x20), 0x60)
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEnglishAuction).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev A master token for the edition auction and the real Editions: `ownerOf`, `workOf` and
///      `itemHashOf` from what the test sets, `rendererOf`, `moduleOf` (no RECORDS module), and
///      the package registry's approval check (`IItemApprovals.isApprovedItem`): every root is
///      approved until the test revokes it.
contract MockMasterStream {
    mapping(uint256 id => Work) internal _works;
    mapping(uint256 id => bool) public burned;
    mapping(bytes32 root => bool) public revoked;
    address public renderer;

    function setWork(uint256 id, bytes32 itemHash, ItemKind kind) external {
        Work storage w = _works[id];
        (w.itemHash, w.kind, w.artistId, w.collectionId, w.royaltyRate) =
        (itemHash, uint8(kind), 1, 1, 6529);
    }

    function setOutcome(uint256 id, Outcome outcome) external {
        _works[id].outcome = outcome;
    }

    function setRoyaltyRate(uint256 id, uint24 rate) external {
        _works[id].royaltyRate = rate;
    }

    function burn(uint256 id) external {
        burned[id] = true;
    }

    function setRevoked(bytes32 root, bool value) external {
        revoked[root] = value;
    }

    function setRenderer(address renderer_) external {
        renderer = renderer_;
    }

    function isApprovedItem(bytes32 root, bytes32, bytes32[] calldata)
        external
        view
        returns (bool)
    {
        return !revoked[root];
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (_works[id].itemHash == 0 || burned[id]) {
            revert IERC721Errors.ERC721NonexistentToken(id);
        }
        return address(0xC011EC7);
    }

    function workOf(uint256 id) external view returns (Work memory) {
        return _works[id];
    }

    function itemHashOf(uint256 id) external view returns (bytes32) {
        return _works[id].itemHash;
    }

    function rendererOf(uint256) external view returns (address) {
        return renderer;
    }

    function moduleOf(bytes32) external pure returns (address) {
        return address(0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IStream).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev The economics resolver's `newWorkTerms`, returning the payout terms the test sets, and
///      its split factory (`splitFactory` is this contract): `createWallet` counts its calls and
///      returns the royalty receiver for the royalty payees and the seller for any other list,
///      or `walletOverride` when set; `walletFor` answers the same without counting. It deploys
///      nothing.
contract MockWorkTermsResolver {
    WorkTerms internal _terms;
    bool public refuse;
    uint256 public createWalletCalls;
    address public walletOverride;
    bytes32 public lastPayeesHash;
    /// @dev The network fee recipient settlement reads (R18): the one the test set, else the
    ///      terms' fee recipient.
    address public currentFeeRecipient;
    bool public currentFeeRecipientSet;

    function set(address seller, address feeRecipient, uint32 feeShare) external {
        _terms = WorkTerms(seller, feeRecipient, feeShare, seller, 6529);
    }

    function setRoyaltyReceiver(address receiver) external {
        _terms.royaltyReceiver = receiver;
    }

    function setRefuse(bool value) external {
        refuse = value;
    }

    function setWalletOverride(address wallet) external {
        walletOverride = wallet;
    }

    function newWorkTerms(bytes32, ISplitWallet.Payee[] calldata)
        external
        view
        returns (WorkTerms memory)
    {
        require(!refuse, "payees");
        return _terms;
    }

    function splitFactory() external view returns (address) {
        return address(this);
    }

    function setNetworkFeeRecipient(address recipient) external {
        (currentFeeRecipient, currentFeeRecipientSet) = (recipient, true);
    }

    function networkFeeRecipient(bytes32) external view returns (address) {
        return currentFeeRecipientSet ? currentFeeRecipient : _terms.feeRecipient;
    }

    function walletFor(ISplitWallet.Payee[] calldata payees, bytes32)
        public
        view
        returns (address)
    {
        if (walletOverride != address(0)) return walletOverride;
        bytes32 royalty = keccak256(
            abi.encode(Splits.royaltyPayees(_terms.seller, _terms.feeRecipient, _terms.feeShare))
        );
        return keccak256(abi.encode(payees)) == royalty ? _terms.royaltyReceiver : _terms.seller;
    }

    function createWallet(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        returns (address)
    {
        ++createWalletCalls;
        lastPayeesHash = keccak256(abi.encode(payees));
        return walletFor(payees, salt);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEconomicsResolver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev The revenue escrow's ETH deposit, recording what each wallet is owed.
contract MockRevenueEscrow {
    mapping(address wallet => mapping(address asset => uint256)) public owed;
    mapping(address asset => uint256) public totalOwed;

    function depositETH(address wallet) external payable {
        owed[wallet][address(0)] += msg.value;
        totalOwed[address(0)] += msg.value;
    }
}

/// @dev A renderer answering a fixed string.
contract MockEditionRenderer {
    function tokenURI(address, uint256) external pure returns (string memory) {
        return "data:,edition";
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

/// @dev A bidder contract that refuses ERC-1155 copies but takes ETH, and can place and claim
///      its own bids.
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
///      settling again. Every re-entry must fail with the reentrancy guard; `lastRevert` records
///      it.
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
///      the payment.
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
