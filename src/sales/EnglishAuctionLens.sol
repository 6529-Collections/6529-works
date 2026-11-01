// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { Splits } from "../economics/Splits.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { PRODUCT_FEDERATED } from "../interfaces/types/EconomicsTypes.sol";
import { LockedTerms, PrimaryTerms } from "../interfaces/types/SaleTypes.sol";

/// @title IEnglishAuctionStorage
/// @notice The raw storage reader `EnglishAuction` exposes for its lens.
interface IEnglishAuctionStorage {
    /// @notice The words at `slots`, in order.
    /// @param slots The storage slots to read.
    /// @return words The words.
    function storageWords(bytes32[] calldata slots) external view returns (bytes32[] memory words);
}

/// @title EnglishAuctionLens
/// @notice The read side of `EnglishAuction`: every view of `IEnglishAuction` and `ISaleAdapter`
///         the auction does not declare itself, and its constants and dependencies. It is
///         deployed in its own transaction before the auction, whose constructor pins its
///         address, code hash and dependencies (the rc.2 review's GAS M-2: creating it inside
///         the auction's deployment put both contracts' code in one transaction). The auction
///         forwards those calls to it unchanged (`EnglishAuction.fallback`), so callers use the
///         auction's address and `IEnglishAuction`; every answer, revert data included, is
///         byte for byte what the auction answered when the views lived in it (the
///         differential test, `EnglishAuctionLensDifferential.t.sol`, compares the two builds).
/// @dev Stateless: no storage, and no record of any auction. It reads its CALLER's storage
///      words through `IEnglishAuctionStorage.storageWords` and decodes them with the auction's
///      layout (slot numbers below, struct packing in `EnglishAuction`), and it repeats the
///      auction's derived-state rules (`_state`, `_resumedEnd`, the minimum bid). Called
///      through the auction's fallback, the caller is the auction. A call made directly to the
///      lens reads the direct caller instead: an account with no `storageWords` gets a revert,
///      and a contract that answers it gets its own words decoded. Either way nothing changes:
///      every function is a view, the lens has no state to change, and the auction's state is
///      only ever written by the auction. The views call out to the token (`primaryTerms`), the
///      economics resolver and the federation registry from this address instead of the
///      auction's; those are views that do not read their caller.
contract EnglishAuctionLens {
    /// @notice The longest a dispute pause lasts; one pause per auction (ADR 0001 section 12).
    uint64 public constant MAX_PAUSE = 7 days;
    /// @notice An opening bid is at most this many increment floors of its currency (1 ETH for
    ///         the 0.001 ETH floor), and at most `type(uint96).max`, the largest bid: the
    ///         absolute ceiling of the governed opening bid.
    uint256 public constant OPENING_BID_FLOORS = 1_000;
    /// @notice Gas forwarded to a seller or fee wallet on an ETH payout; a refusal is escrowed.
    ///         Under the EIP-8037 draft it caps regular gas only: a wallet that writes new state
    ///         draws state gas from the settler's EIP-8037 reservoir, so whether it is paid or
    ///         escrowed can depend on the settler's gas limit (CALLS-3, LIM-GAS-2). Settlers should
    ///         send at most 2^24 gas.
    uint256 public constant PAYOUT_GAS = 100_000;

    /// @dev The auction's storage slots (`forge inspect EnglishAuction storageLayout`).
    uint256 private constant _FEDERATION_REGISTRY_SLOT = 1;
    uint256 private constant _FEDERATION_CODE_HASH_SLOT = 2;
    uint256 private constant _SETTINGS_SLOT = 3;
    uint256 private constant _LISTED_SLOT = 5;
    uint256 private constant _TERMS_SLOT = 7;
    uint256 private constant _SALES_SLOT = 8;
    uint256 private constant _OPENING_BIDS_SLOT = 9;
    uint256 private constant _CREDITS_SLOT = 10;

    /// @dev The auction's sale flags.
    uint8 private constant _PAUSE_USED = 1;
    uint8 private constant _DELIVERY_PENDING = 2;
    uint8 private constant _RECIPIENT_SET = 4;

    /// @notice The revenue escrow for refused payouts (`IEnglishAuction.escrow`).
    address public immutable escrow;
    /// @notice The statement log `cancel` reads (`IEnglishAuction.statementLog`).
    address public immutable statementLog;
    /// @notice The asset allowlist: currencies, defaults and increment floors.
    IAssetAllowlist public immutable allowlist;
    /// @notice The economics resolver: the network fee recipient of federated sales (MARKET-3).
    IEconomicsResolver public immutable economicsResolver;
    /// @notice The canonical Permit2, or zero when PERMIT2 payments are disabled.
    address public immutable permit2;

    /// @dev `EnglishAuction.Sale`, decoded from its three words.
    struct Sale {
        address token;
        uint32 tokenId;
        uint32 endTime;
        uint16 termsId;
        IEnglishAuction.AuctionState status;
        uint8 flags;
        address bidder;
        uint96 bid;
        address recipient;
        uint32 pausedAt;
        uint24 pausedTotal;
    }

    /// @dev `EnglishAuction.Terms`, decoded from its two words.
    struct Terms {
        address currency;
        uint96 incrementFloor;
        uint96 openingBid;
        uint24 incrementShare;
        uint24 extensionWindow;
        uint32 registryFee;
        bool federated;
    }

    /// @param escrow_ The auction's revenue escrow.
    /// @param statementLog_ The auction's statement log.
    /// @param allowlist_ The auction's asset allowlist.
    /// @param economicsResolver_ The auction's economics resolver.
    /// @param permit2_ The auction's Permit2, or zero.
    constructor(
        address escrow_,
        address statementLog_,
        IAssetAllowlist allowlist_,
        IEconomicsResolver economicsResolver_,
        address permit2_
    ) {
        (escrow, statementLog, allowlist, economicsResolver, permit2) =
        (escrow_, statementLog_, allowlist_, economicsResolver_, permit2_);
    }

    // ------------------------------------------------------------------------------- views

    /// @notice One auction (`IEnglishAuction.auction`): its stored fields, with a pause that
    ///         has run its course reported as resumed.
    /// @param saleId The sale ID.
    /// @return a The auction; reverts with `UnknownSale` for a sale ID with no sale.
    function auction(uint256 saleId) external view returns (IEnglishAuction.Auction memory a) {
        uint256 base = _saleBase(saleId);
        bytes32[] memory w = _read3(bytes32(base), bytes32(base + 1), bytes32(base + 2));
        Sale memory s = _decodeSale(uint256(w[0]), uint256(w[1]), uint256(w[2]));
        // The terms' second word and the settings only matter for a pause that has run its
        // course; the auction reads them only then, and so does the lens.
        // forge-lint: disable-next-line(block-timestamp)
        bool lapsed = s.pausedAt != 0 && block.timestamp > s.pausedAt + MAX_PAUSE;
        uint256 tb = _termsBase(s.termsId);
        Terms memory t;
        // Zero unless a lapsed pause needs it (`_state` and `_resumedEnd` read it only then).
        uint256 settings = 0;
        if (lapsed) {
            w = _read3(bytes32(tb), bytes32(tb + 1), bytes32(_SETTINGS_SLOT));
            t = _decodeTerms(uint256(w[0]), uint256(w[1]));
            settings = uint256(w[2]);
        } else {
            t = _decodeTerms(uint256(_read1(bytes32(tb))), 0);
        }
        a.state = _state(s, t, settings);
        if (a.state == IEnglishAuction.AuctionState.NONE) {
            revert ISaleAdapter.UnknownSale(saleId);
        }
        a.token = s.token;
        a.tokenId = s.tokenId;
        a.currency = t.currency;
        a.incrementFloor = t.incrementFloor;
        a.bidder = s.bidder;
        a.recipient = _recipientOf(s);
        a.bid = s.bid;
        a.endTime = s.endTime;
        a.pausedAt = s.pausedAt;
        a.pausedTotal = s.pausedTotal;
        // The pause clock is in seconds; a validator moves it by seconds, not days.
        // forge-lint: disable-next-line(block-timestamp)
        if (a.pausedAt != 0 && block.timestamp > a.pausedAt + MAX_PAUSE) {
            // Truncating as the auction does: the end fits 32 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            a.endTime = uint64(_resumedEnd(s, t, settings, MAX_PAUSE));
            a.pausedAt = 0;
            a.pausedTotal = MAX_PAUSE;
        }
    }

    /// @notice The terms a sale settles on (`IEnglishAuction.lockedTerms`): the locked currency,
    ///         the token's seller and fee terms, and for a federated token the registry fee share
    ///         locked at start, paid to the resolver's federated network fee recipient.
    /// @param saleId The sale ID.
    /// @return lt The terms; reverts with `UnknownSale` for a sale ID with no sale, and with
    ///         `InvalidSaleTerms` for a fee share above 100,000.
    function lockedTerms(uint256 saleId) external view returns (LockedTerms memory lt) {
        (, uint256 w0) = _existing(saleId);
        Sale memory s = _decodeSale(w0, 0, 0);
        uint256 tb = _termsBase(s.termsId);
        bytes32[] memory w = _read2(bytes32(tb), bytes32(tb + 1));
        Terms memory t = _decodeTerms(uint256(w[0]), uint256(w[1]));
        bool federated = t.federated;
        PrimaryTerms memory p = IMintTarget(s.token).primaryTerms(s.tokenId, "");
        lt = LockedTerms(
            s.token,
            s.tokenId,
            t.currency,
            0,
            p.seller,
            federated ? economicsResolver.networkFeeRecipient(PRODUCT_FEDERATED) : p.feeRecipient,
            federated ? t.registryFee : p.feeShare
        );
        if (lt.feeShare > Splits.DENOMINATOR) {
            revert ISaleAdapter.InvalidSaleTerms(s.token, s.tokenId);
        }
    }

    /// @notice The smallest bid the sale accepts now (`IEnglishAuction.minimumBid`, D12).
    /// @param saleId The sale ID.
    /// @return The minimum bid; reverts with `UnknownSale` for a sale ID with no sale.
    function minimumBid(uint256 saleId) external view returns (uint256) {
        uint256 base = _saleBase(saleId);
        bytes32[] memory words = _read2(bytes32(base), bytes32(base + 1));
        Sale memory s = _decodeSale(uint256(words[0]), uint256(words[1]), 0);
        if (s.status == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
        uint256 tb = _termsBase(s.termsId);
        Terms memory t;
        if (s.bidder == address(0)) {
            t = _decodeTerms(0, uint256(_read1(bytes32(tb + 1))));
            return Math.max(Math.max(t.openingBid, s.bid), 1);
        }
        bytes32[] memory w = _read2(bytes32(tb), bytes32(tb + 1));
        t = _decodeTerms(uint256(w[0]), uint256(w[1]));
        uint256 high = s.bid;
        // Rounded up, exactly: the high bid fits 96 bits and the share 17.
        uint256 step = (high * t.incrementShare + Splits.DENOMINATOR - 1) / Splits.DENOMINATOR;
        return high + Math.max(step, t.incrementFloor);
    }

    /// @notice Who may claim the sale's pending delivery (`IEnglishAuction.pendingDelivery`).
    /// @param saleId The sale ID.
    /// @return The pending recipient, or zero when no delivery is pending.
    function pendingDelivery(uint256 saleId) external view returns (address) {
        uint256 base = _saleBase(saleId);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 flags = uint8(uint256(_read1(bytes32(base))) >> 248);
        if (flags & _DELIVERY_PENDING == 0) return address(0);
        // The recipient when one is stored, else the bidder: one more word, as in the auction.
        bytes32 slot = bytes32(flags & _RECIPIENT_SET != 0 ? base + 2 : base + 1);
        return address(uint160(uint256(_read1(slot))));
    }

    /// @notice The governed auction parameters (`IEnglishAuction.config`).
    /// @return The duration, anti-snipe window and increment share new sales lock.
    function config() external view returns (IEnglishAuction.AuctionConfig memory) {
        uint256 c = uint256(_read1(bytes32(_SETTINGS_SLOT)));
        // The settings word packs three 32-bit fields from the low end.
        // forge-lint: disable-next-line(unsafe-typecast)
        return IEnglishAuction.AuctionConfig(uint32(c), uint32(c >> 32), uint32(c >> 64));
    }

    /// @notice The opening bid a sale in `currency` locks at start (`IEnglishAuction.openingBid`).
    /// @param currency The currency.
    /// @return The opening bid, in the currency's base units.
    function openingBid(address currency) external view returns (uint256) {
        return uint256(_read1(_mapSlot(bytes32(uint256(uint160(currency))), _OPENING_BIDS_SLOT)));
    }

    /// @notice An account's claimable credit in a currency (`ISaleAdapter.claimable`).
    /// @param account The credited account.
    /// @param currency The currency.
    /// @return The credit, in the currency's base units.
    function claimable(address account, address currency) external view returns (uint256) {
        bytes32 inner = _mapSlot(bytes32(uint256(uint160(account))), _CREDITS_SLOT);
        return uint256(_read1(_mapSlot(bytes32(uint256(uint160(currency))), uint256(inner))));
    }

    /// @notice Whether the emergency start pause is on (`ISaleAdapter.paused`).
    /// @return True while starts are paused.
    function paused() external view returns (bool) {
        return uint40(uint256(_read1(bytes32(_SETTINGS_SLOT))) >> 96) != 0;
    }

    /// @notice Whether `token` may sell through the auction (`ISaleAdapter.isTarget`): listed,
    ///         or active in the installed federation registry whose code hash still matches.
    /// @param token The token contract.
    /// @return True if it may sell.
    function isTarget(address token) external view returns (bool) {
        // The auction reads the listing first, and the registry words only for an unlisted token.
        bytes32 listed = _read1(_mapSlot(bytes32(uint256(uint160(token))), _LISTED_SLOT));
        if (uint8(uint256(listed)) != 0) return true;
        bytes32[] memory w =
            _read2(bytes32(_FEDERATION_REGISTRY_SLOT), bytes32(_FEDERATION_CODE_HASH_SLOT));
        address registry = address(uint160(uint256(w[0])));
        return registry != address(0) && registry.codehash == w[1]
            && IFederationRegistry(registry).isActive(token);
    }

    /// @notice The installed federation registry (`ISaleAdapter.federationRegistry`).
    /// @return The registry, or zero for none.
    function federationRegistry() external view returns (address) {
        return address(uint160(uint256(_read1(bytes32(_FEDERATION_REGISTRY_SLOT)))));
    }

    /// @notice The code hash pinned when the federation registry was installed; a registry whose
    ///         code no longer matches serves no token.
    /// @return The pinned code hash, or zero with no registry.
    function federationRegistryCodeHash() external view returns (bytes32) {
        return _read1(bytes32(_FEDERATION_CODE_HASH_SLOT));
    }

    /// @notice The derived sale ID (`IEnglishAuction.saleIdOf`).
    /// @param token The token contract.
    /// @param tokenId The token ID.
    /// @return `uint256(keccak256(abi.encode(token, tokenId)))`.
    function saleIdOf(address token, uint256 tokenId) external pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, tokenId)));
    }

    /// @notice The interfaces the auction answers (ERC-165): `IEnglishAuction`, `ISaleAdapter`,
    ///         `IERC721Receiver` and `IERC165`.
    /// @param interfaceId The interface ID.
    /// @return True for those four.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEnglishAuction).interfaceId
            || interfaceId == type(ISaleAdapter).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------------------- internal

    /// @dev The slot of `key` in the mapping at slot `base`.
    function _mapSlot(bytes32 key, uint256 base) private pure returns (bytes32) {
        return keccak256(abi.encode(key, base));
    }

    /// @dev The caller's words at `slots` (the auction's, through its fallback), in one
    ///      `storageWords` call, written over `slots`. The call is encoded and its answer decoded
    ///      by hand (it is always `0x20`, the length, then one word per slot), which keeps a
    ///      view's overhead small.
    function _read(bytes32[] memory slots) private view returns (bytes32[] memory) {
        address target = msg.sender;
        bytes4 selector = IEnglishAuctionStorage.storageWords.selector;
        assembly ("memory-safe") {
            let n := mload(slots)
            let size := shl(5, n)
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), 0x20)
            mstore(add(ptr, 0x24), n)
            mcopy(add(ptr, 0x44), add(slots, 0x20), size)
            if iszero(staticcall(gas(), target, ptr, add(0x44, size), 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if iszero(eq(returndatasize(), add(0x40, size))) { revert(0, 0) }
            returndatacopy(add(slots, 0x20), 0x40, size)
        }
        return slots;
    }

    function _read1(bytes32 a) private view returns (bytes32) {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = a;
        return _read(slots)[0];
    }

    function _read2(bytes32 a, bytes32 b) private view returns (bytes32[] memory) {
        bytes32[] memory slots = new bytes32[](2);
        (slots[0], slots[1]) = (a, b);
        return _read(slots);
    }

    function _read3(bytes32 a, bytes32 b, bytes32 c) private view returns (bytes32[] memory) {
        bytes32[] memory slots = new bytes32[](3);
        (slots[0], slots[1], slots[2]) = (a, b, c);
        return _read(slots);
    }

    /// @dev The first slot of a sale in `EnglishAuction._sales`.
    function _saleBase(uint256 saleId) private pure returns (uint256) {
        return uint256(_mapSlot(bytes32(saleId), _SALES_SLOT));
    }

    /// @dev The first slot of a terms record in `EnglishAuction._terms`.
    function _termsBase(uint16 termsId) private pure returns (uint256) {
        return uint256(_mapSlot(bytes32(uint256(termsId)), _TERMS_SLOT));
    }

    /// @dev A sale that exists, as the auction's `_existing` requires before anything else: its
    ///      first slot and first word, whose stored status is not NONE.
    function _existing(uint256 saleId) private view returns (uint256 base, uint256 w0) {
        base = _saleBase(saleId);
        w0 = uint256(_read1(bytes32(base)));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint8(w0 >> 240) == 0) revert ISaleAdapter.UnknownSale(saleId);
    }

    // Decoding packed words: each cast takes exactly the field's width at its offset.
    // forge-lint: disable-start(unsafe-typecast)
    function _decodeSale(uint256 w0, uint256 w1, uint256 w2) private pure returns (Sale memory s) {
        s.token = address(uint160(w0));
        s.tokenId = uint32(w0 >> 160);
        s.endTime = uint32(w0 >> 192);
        s.termsId = uint16(w0 >> 224);
        s.status = IEnglishAuction.AuctionState(uint8(w0 >> 240));
        s.flags = uint8(w0 >> 248);
        s.bidder = address(uint160(w1));
        s.bid = uint96(w1 >> 160);
        s.recipient = address(uint160(w2));
        s.pausedAt = uint32(w2 >> 160);
        s.pausedTotal = uint24(w2 >> 192);
    }

    function _decodeTerms(uint256 w0, uint256 w1) private pure returns (Terms memory t) {
        t.currency = address(uint160(w0));
        t.incrementFloor = uint96(w0 >> 160);
        t.openingBid = uint96(w1);
        t.incrementShare = uint24(w1 >> 96);
        t.extensionWindow = uint24(w1 >> 120);
        t.registryFee = uint32(w1 >> 144);
        t.federated = uint8(w1 >> 176) != 0;
    }

    // forge-lint: disable-end(unsafe-typecast)

    /// @dev `EnglishAuction._state`: PAUSED while a pause is live (through `pausedAt +
    ///      MAX_PAUSE` inclusive), ENDED once the end has passed.
    function _state(Sale memory s, Terms memory t, uint256 settings)
        private
        view
        returns (IEnglishAuction.AuctionState)
    {
        IEnglishAuction.AuctionState status = s.status;
        if (status != IEnglishAuction.AuctionState.ACTIVE) return status;
        uint256 end = s.endTime;
        uint256 pausedAt = s.flags & _PAUSE_USED == 0 ? 0 : s.pausedAt;
        if (pausedAt != 0) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp <= pausedAt + MAX_PAUSE) {
                return IEnglishAuction.AuctionState.PAUSED;
            }
            end = _resumedEnd(s, t, settings, MAX_PAUSE);
        }
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < end
            ? IEnglishAuction.AuctionState.ACTIVE
            : IEnglishAuction.AuctionState.ENDED;
    }

    /// @dev `EnglishAuction._resumedEnd`: the remaining time at the pause, but at least the
    ///      longer of the governed duration and the locked window from the resumption.
    function _resumedEnd(Sale memory s, Terms memory t, uint256 settings, uint256 length)
        private
        pure
        returns (uint256)
    {
        uint256 pausedAt = s.pausedAt;
        // The governed duration is the settings word's low 32 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 duration = uint32(settings);
        return
            pausedAt + length
                + Math.max(s.endTime - pausedAt, Math.max(duration, t.extensionWindow));
    }

    /// @dev The token's recipient: the stored one, or the bidder when none is stored.
    function _recipientOf(Sale memory s) private pure returns (address) {
        return s.flags & _RECIPIENT_SET != 0 ? s.recipient : s.bidder;
    }
}
