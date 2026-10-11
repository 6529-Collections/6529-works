// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";

/// @notice Auction-lane mocks: a configurable 6529 Stream stand-in, a federation registry, a
///         faithful Permit2 signature-transfer, an EIP-2612 token and a hostile actor.

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
    mapping(uint256 => bool) public primarySettled;
    uint256 public nextId;
    uint256 public burned;
    Mode public mode;
    bool public safeMint = true;
    bool public checkKind = true;

    constructor() ERC721("Mock Stream", "MSTR") { }

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

    /// @dev E11: only the adapter that minted the token, while the token is still in its
    ///      custody, may mark its primary sale settled. Enforcing custody here pins the
    ///      adapter's settle order (mark before delivery) in every settlement test.
    function markPrimarySettled(uint256 tokenId) external {
        require(mintedBy[tokenId] == msg.sender, "not the minting adapter");
        require(_ownerOf(tokenId) == msg.sender, "not in custody");
        require(!primarySettled[tokenId], "already settled");
        primarySettled[tokenId] = true;
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

    function burn(uint256 id, uint256 amount) external {
        if (!isAdmittedMinter[msg.sender]) revert NotAdmittedMinter(msg.sender);
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

/// @dev A federation registry whose entries the test writes directly.
contract MockFederationRegistry is IFederationRegistry {
    mapping(address => Entry) internal _entries;

    function register(address token, Entry calldata entry_) external {
        _entries[token] = entry_;
        emit Registered(token, entry_.artistId, entry_);
    }

    function setStatus(address token, Status status, bytes32 voteRef) external {
        _entries[token].status = status;
        emit StatusSet(token, status, voteRef);
    }

    function setArtistDelisted(uint256, bool, bytes32) external pure {
        revert("unused");
    }

    function entry(address token) external view returns (Entry memory) {
        return _entries[token];
    }

    function isActive(address token) external view returns (bool) {
        return _entries[token].status == Status.ACTIVE;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IFederationRegistry).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Permit2's `permitWitnessTransferFrom`, with the same EIP-712 domain, type strings,
///      unordered nonces and spender binding as the canonical deployment.
contract MockPermit2 is ISignatureTransfer {
    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string public constant STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                block.chainid,
                address(this)
            )
        );
    }

    function digest(
        PermitTransferFrom memory permit,
        address spender,
        bytes32 witness,
        string memory witnessTypeString
    ) public view returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(STUB, witnessTypeString));
        bytes32 permissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 data = keccak256(
            abi.encode(typeHash, permissions, spender, permit.nonce, permit.deadline, witness)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, data));
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        require(block.timestamp <= permit.deadline, "SignatureExpired");
        require(details.requestedAmount <= permit.permitted.amount, "InvalidAmount");
        uint256 bit = 1 << (permit.nonce & 0xff);
        uint256 flipped = nonceBitmap[owner][permit.nonce >> 8] ^= bit;
        require(flipped & bit != 0, "InvalidNonce");
        require(
            SignatureVerifier.isValid(
                owner, digest(permit, msg.sender, witness, witnessTypeString), signature
            ),
            "InvalidSigner"
        );
        (bool ok, bytes memory data) = permit.permitted.token
            .call(abi.encodeCall(IERC20.transferFrom, (owner, details.to, details.requestedAmount)));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}

/// @dev A standard ERC-20 with EIP-2612 permits.
contract PermitToken is ERC20Permit {
    constructor() ERC20("Permit USD", "PUSD") ERC20Permit("Permit USD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
