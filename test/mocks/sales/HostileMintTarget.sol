// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import {
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms
} from "src/interfaces/types/SaleTypes.sol";

/// @notice A listed or federated mint target that breaks the settlement promise of
///         `IMintTarget` on demand (LIM-SAL-16, AUC-38 to AUC-41). Each call the English auction
///         makes into a token at settlement can fail on its own: the outcome view `primarySale`
///         (read before settling), `settlePrimary`, `ownerOf`, `primaryTerms` (the artist an
///         unsold work goes to) and the delivery's `safeTransferFrom`. A rule fails its call
///         only inside a time window, inside a band of the gas the call was given, for one buyer
///         (`settlePrimary`), for one transaction origin, and after a number of calls that went
///         through (`settlePrimary` and `safeTransferFrom`, which can count): so a test can fail
///         calls selectively, steer by the gas or the identity of a settler, and change behaviour
///         between calls.
contract HostileMintTarget is ERC721, IMintTarget {
    /// @dev The calls the auction makes into a token at settlement.
    enum Call {
        SALE_VIEW,
        SETTLE,
        OWNER_OF,
        TERMS,
        TRANSFER
    }

    /// @dev REPORT is a well-formed but hostile answer: SALE_VIEW reports an outcome (the sale
    ///      looks rescued); SETTLE returns `reported` (for example a seller the payout refuses);
    ///      OWNER_OF names `liar` as the holder; TERMS names `liar` as the artist.
    enum Fault {
        NONE,
        REVERT,
        BURN_GAS,
        MALFORMED,
        REENTER,
        REPORT
    }

    struct Rule {
        Fault fault;
        uint64 from;
        uint64 until;
        uint64 minGas;
        uint64 maxGas;
        uint32 skip;
        address onlyBuyer;
        address onlyOrigin;
    }

    mapping(Call => Rule) public rules;
    mapping(Call => uint256) public passed;
    mapping(address => bool) public isAdmittedMinter;
    mapping(uint256 => address) public mintedBy;
    mapping(uint256 => bool) public primarySettled;
    PrimaryTerms internal _terms;
    PrimarySettlement public reported;
    address public liar;
    address public reentryTarget;
    bytes public reentryData;
    bool public bubbleReentry;
    bool public reentryOk;
    bytes public reentryResult;
    uint256 public nextId;

    constructor() ERC721("Hostile", "HSTL") { }

    // ------------------------------------------------------------------ configuration

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
        emit AdmittedMinterSet(adapter, 0, admitted);
    }

    function setTerms(PrimaryTerms calldata terms) external {
        _terms = terms;
    }

    /// @dev Fails `call` with `fault` from now on, with no other condition.
    function fail(Call call, Fault fault) external {
        rules[call] = Rule(fault, 0, 0, 0, 0, 0, address(0), address(0));
    }

    function setRule(Call call, Rule calldata rule) external {
        rules[call] = rule;
    }

    function clear(Call call) external {
        delete rules[call];
    }

    function setReported(PrimarySettlement calldata p) external {
        reported = p;
    }

    function setLiar(address liar_) external {
        liar = liar_;
    }

    function setReentry(address target, bytes calldata data, bool bubble) external {
        (reentryTarget, reentryData, bubbleReentry) = (target, data, bubble);
    }

    // ------------------------------------------------------------------ IMintTarget

    function mint(address to, uint256, uint256, bytes calldata)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (!isAdmittedMinter[msg.sender]) revert NotAdmittedMinter(msg.sender);
        tokenId = ++nextId;
        mintedBy[tokenId] = msg.sender;
        _safeMint(to, tokenId);
        terms = _terms;
    }

    function primaryTerms(uint256, bytes calldata) external view returns (PrimaryTerms memory t) {
        Fault f = _active(Call.TERMS, address(0));
        _faultView(f);
        t = _terms;
        if (f == Fault.REPORT) t.creator = liar;
    }

    function burn(uint256 id, uint256) external {
        require(mintedBy[id] == msg.sender, "not the minting adapter");
        _burn(id);
    }

    function settlePrimary(uint256 id, PrimaryOutcome, address buyer, address, uint256)
        external
        returns (PrimarySettlement memory p)
    {
        Fault f = _active(Call.SETTLE, buyer);
        if (f == Fault.REENTER) _reenter();
        else _faultCall(f);
        if (f == Fault.NONE || f == Fault.REENTER) ++passed[Call.SETTLE];
        require(mintedBy[id] == msg.sender && _ownerOf(id) == msg.sender, "custody");
        require(!primarySettled[id], "settled");
        primarySettled[id] = true;
        if (f == Fault.REPORT) return reported;
        (p.seller, p.feeRecipient, p.feeShare) =
        (_terms.seller, _terms.feeRecipient, _terms.feeShare);
    }

    /// @dev `IStream.primarySale`, which the auction reads before settling: NONE unless REPORT.
    function primarySale(uint256) external view returns (PrimaryOutcome, address, uint256) {
        Fault f = _active(Call.SALE_VIEW, address(0));
        if (f == Fault.MALFORMED) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
        _faultView(f);
        return (f == Fault.REPORT ? PrimaryOutcome.SOLD : PrimaryOutcome.NONE, address(0), 0);
    }

    /// @dev The holder the token's own ledger records, whatever `ownerOf` answers.
    function holderOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function ownerOf(uint256 id) public view override returns (address) {
        Fault f = _active(Call.OWNER_OF, address(0));
        _faultView(f);
        return f == Fault.REPORT ? liar : super.ownerOf(id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data)
        public
        override
    {
        Fault f = _active(Call.TRANSFER, address(0));
        if (f == Fault.REENTER) _reenter();
        else _faultCall(f);
        if (f == Fault.NONE || f == Fault.REENTER) ++passed[Call.TRANSFER];
        super.safeTransferFrom(from, to, id, data);
    }

    // ------------------------------------------------------------------ faults

    function _active(Call call, address buyer) internal view returns (Fault) {
        Rule memory r = rules[call];
        if (r.fault == Fault.NONE) return Fault.NONE;
        uint256 g = gasleft();
        if (
            block.timestamp < r.from || (r.until != 0 && block.timestamp >= r.until) || g < r.minGas
                || (r.maxGas != 0 && g > r.maxGas)
                || (r.onlyBuyer != address(0) && buyer != r.onlyBuyer) || passed[call] < r.skip
                || (r.onlyOrigin != address(0) && tx.origin != r.onlyOrigin)
        ) return Fault.NONE;
        return r.fault;
    }

    /// @dev REPORT and REENTER are handled by the caller; MALFORMED returns a dirty word, which
    ///      the auction's ABI decoder refuses for every return type it reads here.
    function _faultView(Fault f) internal pure {
        if (f == Fault.REVERT) revert("hostile");
        if (f == Fault.BURN_GAS) {
            while (true) { }
        }
        if (f == Fault.MALFORMED) {
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 32)
            }
        }
    }

    function _faultCall(Fault f) internal pure {
        _faultView(f);
    }

    function _reenter() internal {
        bytes memory result;
        (reentryOk, result) = reentryTarget.call(reentryData);
        reentryResult = result;
        if (!reentryOk && bubbleReentry) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// @dev An admitted ERC-20 that, once switched on, burns all the gas any transfer is given: both
///      of a settlement's payout frames then spend their whole allowance (the auction's worst
///      case, AUC-40).
contract BurningToken is ERC20 {
    bool public burning;

    constructor() ERC20("Burning USD", "BUSD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurning(bool burning_) external {
        burning = burning_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (burning) {
            while (true) { }
        }
        super._update(from, to, value);
    }
}
