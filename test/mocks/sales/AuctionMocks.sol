// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import {
    Payment,
    PaymentMethod,
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { MockFederationRegistry, PermitToken } from "./SaleMocks.sol";

/// @notice English-auction mocks: a configurable ERC-721 mint target, a hostile bidder or
///         wallet, and EIP-2612 tokens that burn gas or block recipients. The federation
///         registry, Permit2 and the plain EIP-2612 token are shared with the other sale
///         adapters' tests, in `SaleMocks.sol`.

/// @dev An ERC-721 that mints through `IMintTarget` on terms the test sets. `mode` injects the
///      faults an admitted but broken token could produce.
contract MockMintTarget is ERC721, IMintTarget {
    enum Mode {
        NORMAL,
        ZERO_ID,
        WRONG_CUSTODY,
        REJECT_TRANSFERS,
        HUGE_ID
    }

    PrimaryTerms internal _terms;
    mapping(uint256 => PrimaryTerms) internal _locked;
    address public creatorNow;
    mapping(address => bool) public isAdmittedMinter;
    mapping(uint256 => address) public mintedBy;
    uint256 public nextId;
    uint256 public burned;
    Mode public mode;
    bool public safeMint = true;
    bool public checkKind = true;
    /// @dev Set on the mock that stands in for 6529 Stream: an unsold work then moves to this
    ///      resolver's museum in `settlePrimary`, as Stream moves it (owner decision 17).
    IEconomicsResolver public museumResolver;
    /// @dev The reported settlement, hashed into one word as 6529 Stream writes one: tests
    ///      compare it with `settlementHash`, and gas measured on this mock stays Stream-like.
    mapping(uint256 => bytes32) public settled;

    constructor() ERC721("Mock Stream", "MSTR") { }

    function setMuseumResolver(IEconomicsResolver resolver) external {
        museumResolver = resolver;
    }

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
        emit AdmittedMinterSet(adapter, admitted);
    }

    function setTerms(PrimaryTerms calldata terms) external {
        _terms = terms;
    }

    /// @dev Simulates a recovery: the artist's current authority, resolved when terms are read.
    function setCreatorNow(address creator) external {
        creatorNow = creator;
    }

    function setLockedCreator(uint256 id, address creator) external {
        _locked[id].creator = creator;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setSafeMint(bool safe) external {
        safeMint = safe;
    }

    function setCheckKind(bool check) external {
        checkKind = check;
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (!isAdmittedMinter[msg.sender]) revert NotAdmittedMinter(msg.sender);
        require(id == 0 && amount == 1, "bad mint");
        terms = _terms;
        if (checkKind) require(ISaleAdapter(msg.sender).saleKind() == terms.saleKind, "kind");
        if (mode == Mode.ZERO_ID) return (0, terms);
        tokenId = mode == Mode.HUGE_ID ? uint256(type(uint32).max) + 1 : ++nextId;
        _locked[tokenId] = terms;
        mintedBy[tokenId] = msg.sender;
        address dest = mode == Mode.WRONG_CUSTODY ? address(0xdead) : to;
        if (safeMint) _safeMint(dest, tokenId);
        else _mint(dest, tokenId);
    }

    /// @dev E11 and owner decision 17: only the adapter that minted the token, while the token
    ///      is still in its custody, settles it, once, with a coherent outcome. Enforcing custody
    ///      here pins the adapter's settle order (settle before delivery) in every settlement
    ///      test. As 6529 Stream's stand-in (`museumResolver` set), it moves an unsold work to
    ///      the museum itself; otherwise it leaves it to the adapter.
    function settlePrimary(
        uint256 tokenId,
        PrimaryOutcome outcome,
        address buyer,
        address currency,
        uint256 price
    ) external returns (PrimarySettlement memory p) {
        require(mintedBy[tokenId] == msg.sender, "not the minting adapter");
        require(_ownerOf(tokenId) == msg.sender, "not in custody");
        require(settled[tokenId] == 0, "already settled");
        require(outcome != PrimaryOutcome.NONE, "outcome");
        require((outcome == PrimaryOutcome.SOLD) == (buyer != address(0)), "buyer");
        require(outcome == PrimaryOutcome.SOLD || price == 0, "price");
        settled[tokenId] = settlementHash(outcome, buyer, currency, price);
        PrimaryTerms storage t = _locked[tokenId];
        (p.seller, p.feeRecipient, p.feeShare) = (t.seller, t.feeRecipient, t.feeShare);
        if (outcome != PrimaryOutcome.SOLD && address(museumResolver) != address(0)) {
            p.holder = museumResolver.museum();
            _transfer(msg.sender, p.holder, tokenId);
        }
    }

    function primarySettled(uint256 tokenId) external view returns (bool) {
        return settled[tokenId] != 0;
    }

    function settlementHash(PrimaryOutcome outcome, address buyer, address currency, uint256 price)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(outcome, buyer, currency, price));
    }

    function exists(uint256 id) external view returns (bool) {
        return _ownerOf(id) != address(0);
    }

    function primaryTerms(uint256 id, bytes calldata)
        external
        view
        returns (PrimaryTerms memory t)
    {
        if (id == 0) return _terms;
        t = _locked[id];
        require(t.saleKind != bytes32(0), "unknown");
        // E8: a minted token's terms carry no currency; the adapter owns it.
        t.currency = address(0);
        if (creatorNow != address(0)) t.creator = creatorNow;
    }

    /// @dev L-3: admitted minters, and the adapter that minted the token even after removal.
    function burn(uint256 id, uint256 amount) external {
        if (!isAdmittedMinter[msg.sender] && mintedBy[id] != msg.sender) {
            revert NotAdmittedMinter(msg.sender);
        }
        require(amount == 1 && ownerOf(id) == msg.sender, "burn");
        _burn(id);
        ++burned;
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        if (mode == Mode.REJECT_TRANSFERS && _ownerOf(tokenId) != address(0) && to != address(0)) {
            revert("transfers paused");
        }
        return super._update(to, tokenId, auth);
    }
}

/// @dev A bidder, winner or wallet that misbehaves on demand when it receives ETH or an NFT, and
///      can call anything as itself.
contract HostileActor is IERC721Receiver {
    enum Behaviour {
        ACCEPT,
        REVERT,
        BURN_GAS,
        WRONG_MAGIC,
        HAND_BACK,
        REENTER
    }

    Behaviour public onEth;
    Behaviour public onNft;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentered;
    bool public reentryOk;
    bytes public reentryResult;

    function configure(Behaviour eth, Behaviour nft) external {
        onEth = eth;
        onNft = nft;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function execute(address to, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        bool ok;
        (ok, result) = to.call{ value: value }(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    receive() external payable {
        _act(onEth);
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        Behaviour b = onNft;
        if (b == Behaviour.HAND_BACK) {
            IERC721(msg.sender).transferFrom(address(this), from, tokenId);
        } else {
            _act(b);
        }
        return b == Behaviour.WRONG_MAGIC ? bytes4(0xdeadbeef) : this.onERC721Received.selector;
    }

    function _act(Behaviour b) internal {
        if (b == Behaviour.REVERT) revert("hostile");
        if (b == Behaviour.BURN_GAS) {
            while (true) { }
        }
        if (b == Behaviour.REENTER && !reentered) {
            reentered = true;
            (reentryOk, reentryResult) = reentryTarget.call(reentryData);
        }
    }
}

/// @dev An ERC-20 whose `transfer` burns all the gas it is given (its `transferFrom` is normal),
///      so every direct payout costs the payer the full transfer allowance before the escrow
///      fallback: the most expensive settlement route.
contract GasBurnerToken is PermitToken {
    function transfer(address, uint256) public pure override returns (bool) {
        while (true) { }
        return false;
    }
}

/// @dev An EIP-2612 token that refuses transfers to blocked addresses (USDC-style), so payouts to
///      a blocked wallet take the escrow route.
contract BlockablePermitToken is PermitToken {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @dev A minimal federated template: every `IMintTarget` function, with a settlement hook that
///      records nothing and returns the terms.
contract PlainMintTarget is ERC721, IMintTarget {
    PrimaryTerms internal _terms;
    mapping(address => bool) public isAdmittedMinter;
    uint256 public nextId;

    constructor() ERC721("Federated", "FED") { }

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
        emit AdmittedMinterSet(adapter, admitted);
    }

    function setTerms(PrimaryTerms calldata terms) external {
        _terms = terms;
    }

    function mint(address to, uint256, uint256, bytes calldata)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        require(isAdmittedMinter[msg.sender], "minter");
        tokenId = ++nextId;
        terms = _terms;
        _mint(to, tokenId);
    }

    function primaryTerms(uint256, bytes calldata) external view returns (PrimaryTerms memory t) {
        t = _terms;
        t.currency = address(0);
    }

    function burn(uint256 id, uint256) external {
        require(isAdmittedMinter[msg.sender], "minter");
        _burn(id);
    }

    /// @dev Records nothing; returns the terms, and leaves an unsold work to the adapter.
    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        view
        virtual
        returns (PrimarySettlement memory p)
    {
        (p.seller, p.feeRecipient, p.feeShare) =
        (_terms.seller, _terms.feeRecipient, _terms.feeShare);
    }
}

/// @dev CALLS I-2 (rc.2 review): a listed token whose settlement hook REPORTS an unsold work as
///      taken by `reportedHolder` without moving it. The adapter must not trust the report.
contract HolderReportingTarget is PlainMintTarget {
    address public reportedHolder;

    function setReportedHolder(address holder) external {
        reportedHolder = holder;
    }

    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        view
        override
        returns (PrimarySettlement memory p)
    {
        (p.seller, p.feeRecipient, p.feeShare) =
        (_terms.seller, _terms.feeRecipient, _terms.feeShare);
        p.holder = reportedHolder;
    }
}

/// @dev A listed token that answers 6529 Stream's `primarySale(tokenId)` as the test sets it, to
///      drive the English auction's rescue check (owner decision 20): an outcome per token,
///      or a short answer, or a revert.
contract OutcomeReportingTarget is PlainMintTarget {
    enum Answer {
        FULL,
        SHORT,
        REVERT
    }

    mapping(uint256 id => PrimaryOutcome) public outcomeOf;
    Answer public answer;

    function setOutcome(uint256 id, PrimaryOutcome outcome) external {
        outcomeOf[id] = outcome;
    }

    function setAnswer(Answer answer_) external {
        answer = answer_;
    }

    function primarySale(uint256 id) external view returns (PrimaryOutcome, address, uint256) {
        if (answer == Answer.REVERT) revert("no outcome");
        if (answer == Answer.SHORT) {
            // Sixteen nonzero bytes: less than the word an outcome is.
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 16)
            }
        }
        return (outcomeOf[id], address(0), 0);
    }
}

/// @dev Mints a chosen token ID. An ID that already exists is reported again without a mint, as
///      a template that re-issues a token ID would.
contract HugeIdTarget is ERC721, IMintTarget {
    mapping(address => bool) public isAdmittedMinter;
    uint256 public id;

    constructor() ERC721("Huge", "HUGE") { }

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
    }

    function setId(uint256 id_) external {
        id = id_;
    }

    function mint(address to, uint256, uint256, bytes calldata)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        tokenId = id;
        terms = PrimaryTerms(
            SaleKind.ENGLISH_AUCTION,
            address(0),
            0,
            "",
            address(0xB),
            address(0xC),
            25_000,
            address(0xA)
        );
        if (_ownerOf(tokenId) == address(0)) _mint(to, tokenId);
    }

    function primaryTerms(uint256, bytes calldata) external pure returns (PrimaryTerms memory t) {
        t.saleKind = SaleKind.ENGLISH_AUCTION;
    }

    function burn(uint256, uint256) external { }

    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        pure
        returns (PrimarySettlement memory p)
    { }
}

/// @dev A registry with different code, for the code-hash pin.
contract MockFederationRegistryV2 is MockFederationRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev A bidding contract that forwards its refunds with `claim(currency, to)` and accepts ETH
///      for other reasons, but has no way to move ETH out.
contract ForwardingBidder {
    function bid(IEnglishAuction auction, uint256 saleId) external payable {
        auction.bid{ value: msg.value }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, address(this), msg.value, 0, 0, "")
        );
    }

    function claimTo(IEnglishAuction auction, address treasury) external {
        auction.claim(address(0), treasury);
    }

    receive() external payable { }
}
