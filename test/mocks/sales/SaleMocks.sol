// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    ProductEconomics,
    WorkTerms
} from "src/interfaces/types/EconomicsTypes.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import {
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms
} from "src/interfaces/types/SaleTypes.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";

/// @notice Sales-lane mocks: an edition-like mint target, the escrow and allowlist stand-ins, a
///         Permit2 that reproduces the canonical hashing, nonces and checks, an EIP-2612 token,
///         and hostile wallets and receivers.

/// @dev An `IMintTarget` shaped like 6529 Stream Editions: per-ID terms and size, a minter
///      allowlist, the adapter's `saleKind()` check, and real ERC-1155 receiver checks on mint.
contract MockEditionTarget is ERC1155, IMintTarget {
    error KindMismatch(bytes32 adapterKind, bytes32 termsKind);
    error EditionUnavailable(uint256 id);
    error UnknownEdition(uint256 id);

    mapping(uint256 id => PrimaryTerms) internal _terms;
    mapping(uint256 id => uint256) public size;
    mapping(uint256 id => uint256) public minted;
    mapping(address adapter => bool) public isAdmittedMinter;
    /// @dev Added to the returned token ID, wrapping, to simulate a token that mints something
    ///      else (`type(uint256).max` returns the ID below).
    uint256 public idOffset;

    constructor() ERC1155("") { }

    function setTerms(uint256 id, PrimaryTerms memory t, uint256 size_) external {
        _terms[id] = t;
        size[id] = size_;
    }

    function setCreator(uint256 id, address creator) external {
        _terms[id].creator = creator;
    }

    function setCurrency(uint256 id, address currency) external {
        _terms[id].currency = currency;
    }

    function setAdmittedMinter(address adapter, bool admitted) external {
        isAdmittedMinter[adapter] = admitted;
        emit AdmittedMinterSet(adapter, admitted);
    }

    function setIdOffset(uint256 offset) external {
        idOffset = offset;
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata)
        external
        returns (uint256, PrimaryTerms memory t)
    {
        if (!isAdmittedMinter[msg.sender]) revert NotAdmittedMinter(msg.sender);
        t = _terms[id];
        if (t.saleKind == 0) revert UnknownEdition(id);
        bytes32 kind = ISaleAdapter(msg.sender).saleKind();
        if (kind != t.saleKind) revert KindMismatch(kind, t.saleKind);
        if (minted[id] + amount > size[id]) revert EditionUnavailable(id);
        minted[id] += amount;
        _mint(to, id, amount, "");
        unchecked {
            return (id + idOffset, t);
        }
    }

    function primaryTerms(uint256 id, bytes calldata)
        external
        view
        returns (PrimaryTerms memory t)
    {
        t = _terms[id];
        if (t.saleKind == 0) revert UnknownEdition(id);
    }

    function burn(uint256, uint256) external pure {
        revert("no burn");
    }

    /// @dev Editions record nothing at settlement: a no-op, as `IMintTarget` allows.
    function settlePrimary(uint256, PrimaryOutcome, address, address, uint256)
        external
        pure
        returns (PrimarySettlement memory nothing)
    {
        return nothing;
    }

    /// @dev Reports `IMintTarget`, as the adapters require of a listed token.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IMintTarget).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @dev The revenue escrow's crediting surface: pulls exactly and credits per wallet and asset.
contract MockRevenueEscrow {
    mapping(address wallet => mapping(address asset => uint256)) public owed;
    mapping(address asset => uint256) public totalOwed;

    function depositETH(address wallet) external payable {
        owed[wallet][address(0)] += msg.value;
        totalOwed[address(0)] += msg.value;
    }

    function depositERC20(address wallet, address asset, uint256 amount) external {
        TokenTransfer.pullExact(asset, msg.sender, amount);
        owed[wallet][asset] += amount;
        totalOwed[asset] += amount;
    }
}

/// @dev The allowlist's `isActive` and `defaultCurrency` reads, set by the test.
contract MockAssetAllowlist {
    error CurrencyNotConfigured(bytes32 product);
    error AssetNotActive(address asset);

    mapping(address asset => bool) public isActive;
    mapping(bytes32 product => address) internal _defaults;
    mapping(bytes32 product => bool) internal _configured;

    /// @dev `statusClock`: when the status last changed and the seconds deprecated before.
    mapping(address asset => uint256) internal _since;
    mapping(address asset => uint256) internal _inactiveTotal;

    function set(address asset, bool active) external {
        if (isActive[asset] != active) {
            if (active && _since[asset] != 0) {
                _inactiveTotal[asset] += block.timestamp - _since[asset];
            }
            _since[asset] = block.timestamp;
        }
        isActive[asset] = active;
    }

    function statusClock(address asset) external view returns (uint8, uint256, uint256) {
        return (isActive[asset] ? 1 : 2, _since[asset], _inactiveTotal[asset]);
    }

    function setDefault(bytes32 product, address asset) external {
        _defaults[product] = asset;
        _configured[product] = true;
    }

    function defaultCurrency(bytes32 product) external view returns (address asset) {
        if (!_configured[product]) revert CurrencyNotConfigured(product);
        asset = _defaults[product];
        if (!isActive[asset]) revert AssetNotActive(asset);
    }
}

/// @dev The economics resolver's reads the adapters use: `resolveCurrency` over the mock
///      allowlist, `networkFeeRecipient`, `economics`, `assetAllowlist` and `museum`; the rest is
///      unused.
contract MockEconomicsResolver is IEconomicsResolver {
    MockAssetAllowlist public immutable allowlist;
    /// @dev When set, `assetAllowlist()` reports this address instead (install-check tests).
    address public allowlistOverride;
    /// @dev What `museum()` reports (D140): set directly, without the real setter's checks, so a
    ///      test can make it zero.
    address internal _museum;
    mapping(bytes32 product => ProductEconomics) internal _economics;
    mapping(bytes32 product => bool) internal _known;

    constructor(MockAssetAllowlist allowlist_) {
        allowlist = allowlist_;
    }

    function set(bytes32 product, address feeRecipient, uint32 feeShare) external {
        _economics[product] = ProductEconomics(feeRecipient, feeShare, 6529);
        _known[product] = true;
    }

    function unset(bytes32 product) external {
        delete _economics[product];
        delete _known[product];
    }

    function resolveCurrency(bytes32 product, address requested)
        external
        view
        returns (address currency)
    {
        currency = requested == CURRENCY_DEFAULT ? allowlist.defaultCurrency(product) : requested;
        if (!allowlist.isActive(currency)) revert CurrencyNotAllowed(currency);
    }

    function economics(bytes32 product) public view returns (ProductEconomics memory e) {
        if (!_known[product]) revert UnknownProduct(product);
        e = _economics[product];
    }

    function networkFeeRecipient(bytes32 product) external view returns (address) {
        return economics(product).feeRecipient;
    }

    function setMuseumAccount(address museum_) external {
        _museum = museum_;
    }

    function museum() external view returns (address) {
        return _museum;
    }

    function museumRevision() external pure returns (uint64) {
        return 1;
    }

    function setMuseum(uint64, address) external pure {
        revert("unused");
    }

    function setAllowlistOverride(address allowlist_) external {
        allowlistOverride = allowlist_;
    }

    function assetAllowlist() external view returns (address) {
        return allowlistOverride == address(0) ? address(allowlist) : allowlistOverride;
    }

    function revisions(bytes32) external pure returns (uint64, uint64, uint64) {
        return (0, 0, 0);
    }

    function newWorkTerms(bytes32, ISplitWallet.Payee[] calldata)
        external
        pure
        returns (WorkTerms memory)
    {
        revert("unused");
    }

    function defaultLicense(bytes32) external pure returns (License memory) {
        revert("unused");
    }

    function splitFactory() external pure returns (address) {
        return address(0);
    }

    function setFeeTerms(bytes32, uint64, address, uint32) external pure {
        revert("unused");
    }

    function setRoyaltyRate(bytes32, uint64, uint32) external pure {
        revert("unused");
    }

    function setDefaultLicense(bytes32, uint64, License calldata) external pure {
        revert("unused");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEconomicsResolver).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

/// @dev A federation registry whose entries the test writes directly (`IFederationRegistry`):
///      `register` and `setStatus` as the real registry's governed writes, with their events,
///      and `setEntry` and `setCodeHash` as shortcuts.
contract MockFederationRegistry is IFederationRegistry {
    mapping(address token => Entry) internal _entries;

    function setEntry(address token, uint32 feeShare, bool active) external {
        _entries[token].codeHash = token.codehash;
        _entries[token].feeShare = feeShare;
        _entries[token].status = active ? Status.ACTIVE : Status.DELISTED;
    }

    function setCodeHash(address token, bytes32 codeHash) external {
        _entries[token].codeHash = codeHash;
    }

    function register(address token, Entry calldata e) external {
        _entries[token] = e;
        emit Registered(token, e.artistId, e);
    }

    function setStatus(address token, Status status, bytes32 voteRef) external {
        _entries[token].status = status;
        emit StatusSet(token, status, voteRef);
    }

    function setArtistDelisted(uint256, bool, bytes32) external { }

    function entry(address token) external view returns (Entry memory) {
        return _entries[token];
    }

    function isActive(address token) external view returns (bool) {
        return _entries[token].status == Status.ACTIVE;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IFederationRegistry).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

/// @dev Permit2's `permitWitnessTransferFrom`, reproducing the canonical contract: the
///      "Permit2" EIP-712 domain (name, chain ID, verifying contract), the witness type-hash
///      stub, the spender (`msg.sender`) in the signed hash, the deadline and amount checks,
///      the unordered nonce bitmap, ECDSA or ERC-1271 signers, and a solmate-style transfer.
contract MockPermit2 is ISignatureTransfer {
    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string public constant WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address owner => mapping(uint256 word => uint256)) public nonceBitmap;

    error SignatureExpired(uint256 deadline);
    error InvalidAmount(uint256 maxAmount);
    error InvalidNonce();
    error InvalidSignature();
    error InvalidSigner();
    error InvalidContractSignature();
    error TransferFromFailed();

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

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) {
            revert SignatureExpired(permit.deadline);
        }
        if (details.requestedAmount > permit.permitted.amount) {
            revert InvalidAmount(permit.permitted.amount);
        }
        uint256 bit = 1 << uint8(permit.nonce);
        uint256 flipped = nonceBitmap[owner][permit.nonce >> 8] ^= bit;
        if (flipped & bit == 0) revert InvalidNonce();
        bytes32 digest = witnessDigest(msg.sender, permit, witness, witnessTypeString);
        if (owner.code.length == 0) {
            if (signature.length != 65) revert InvalidSignature();
            address signer = ecrecover(
                digest, uint8(signature[64]), bytes32(signature[0:32]), bytes32(signature[32:64])
            );
            if (signer == address(0)) revert InvalidSignature();
            if (signer != owner) revert InvalidSigner();
        } else if (IERC1271(owner).isValidSignature(digest, signature) != 0x1626ba7e) {
            revert InvalidContractSignature();
        }
        (bool ok, bytes memory ret) = permit.permitted.token
            .call(abi.encodeWithSelector(0x23b872dd, owner, details.to, details.requestedAmount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFromFailed();
    }

    function witnessDigest(
        address spender,
        PermitTransferFrom memory permit,
        bytes32 witness,
        string memory witnessTypeString
    ) public view returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(WITNESS_STUB, witnessTypeString));
        bytes32 permissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 dataHash = keccak256(
            abi.encode(typeHash, permissions, spender, permit.nonce, permit.deadline, witness)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, dataHash));
    }
}

/// @dev A standard ERC-20 with EIP-2612 permits (OpenZeppelin).
contract PermitToken is ERC20, ERC20Permit {
    constructor() ERC20("Permit USD", "PUSD") ERC20Permit("Permit USD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A payout wallet that burns every unit of gas it is given.
contract GasBurnerWallet {
    receive() external payable {
        while (true) { }
    }
}

/// @dev An ERC-1155 recipient that accepts, rejects, or calls back into `target` on receipt.
///      `bubble` re-raises a failed callback; otherwise its outcome is recorded.
contract HostileReceiver is IERC1155Receiver {
    enum Mode {
        Accept,
        Reject,
        Reenter
    }

    Mode public mode;
    bool public bubble;
    address public target;
    bytes public data;
    bool public lastOk;
    bytes public lastResult;

    function configure(Mode mode_, bool bubble_, address target_, bytes calldata data_) external {
        mode = mode_;
        bubble = bubble_;
        target = target_;
        data = data_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (mode == Mode.Reject) revert("rejected");
        if (mode == Mode.Reenter) {
            (lastOk, lastResult) = target.call(data);
            if (!lastOk && bubble) {
                bytes memory result = lastResult;
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }

    receive() external payable { }
}
