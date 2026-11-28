// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamRegistry } from "src/independent/IndependentStreamRegistry.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";

/// @dev The directory as an Independent Stream token and the Independent Stream module read it:
///      settable slots and an AccessManager whose only immediate caller is `network`.
contract SymDirectory {
    mapping(bytes32 => address) public moduleOf;
    address public authority;

    constructor(address manager) {
        authority = manager;
    }

    function set(bytes32 slot, address module) external {
        moduleOf[slot] = module;
    }
}

/// @dev An AccessManager (and an `IAuthority`) that lets `network` call anything at once.
contract SymManager {
    address public immutable network;

    constructor(address network_) {
        network = network_;
    }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32) {
        return (caller == network, 0);
    }
}

/// @dev An Independent Stream gate whose answers the proof makes symbolic.
contract SymGate {
    bool public answer = true;
    uint256 public removedAt;

    function set(bool answer_, uint256 removedAt_) external {
        (answer, removedAt) = (answer_, removedAt_);
    }

    function canMint(address, address) external view returns (bool) {
        return answer;
    }

    function minterRemovedAt(address) external view returns (uint256) {
        return removedAt;
    }
}

/// @dev An accounts module that says every caller is a wallet of every account.
contract SymEveryoneIsTheArtist {
    function isWallet(uint256, address) external pure returns (bool) {
        return true;
    }
}

/// @dev A sale contract the proof drives.
contract SymMinter {
    function mintTo(address token, address to, MintFacts calldata f) external returns (uint256) {
        return IStream(token).mint(to, f);
    }

    function record(address token, uint256 id) external {
        IStream(token).recordPrimarySale(id, false, address(0), 0);
    }
}

/// @dev The economics resolver as the Independent Stream module's constructor reads it.
contract SymEconomics {
    function splitFactory() external pure returns (address) {
        return address(0x5917);
    }
}

/// @dev A predecessor Independent Stream module whose answers the proof makes symbolic, so the
///      module under proof inherits one listing, one template, one sale contract and one account
///      flag.
contract SymPrevious {
    IIndependentStreamRegistry.Listing internal _listing;
    IIndependentStreamRegistry.Template internal _template;
    IIndependentStreamRegistry.SaleContract internal _sale;
    bool public delisted;

    function set(
        IIndependentStreamRegistry.Listing memory l,
        IIndependentStreamRegistry.Template memory t,
        IIndependentStreamRegistry.SaleContract memory s,
        bool delisted_
    ) external {
        (_listing, _template, _sale, delisted) = (l, t, s, delisted_);
    }

    function entropyModule() external pure returns (address) {
        return address(0);
    }

    function listingOf(address) external view returns (IIndependentStreamRegistry.Listing memory) {
        return _listing;
    }

    function templateOf(address)
        external
        view
        returns (IIndependentStreamRegistry.Template memory)
    {
        return _template;
    }

    function saleContractOf(address)
        external
        view
        returns (IIndependentStreamRegistry.SaleContract memory)
    {
        return _sale;
    }

    function isAccountDelisted(uint256) external view returns (bool) {
        return delisted;
    }
}

/// @notice Halmos proofs of the Independent Stream token's gate rules on the real
///         `IndependentStream6529`, and of two rules of the real `IndependentStreamRegistry`
///         (docs/testing/README.md, "Symbolic"). Each `check_` is also a Forge fuzz test through
///         its `testFuzz_` twin.
contract IndependentSymbolicTest is Test {
    address internal constant NETWORK = address(0x6529);
    address internal constant COLLECTOR = address(0xC011);
    address internal constant TOKEN = address(0x70CE);
    uint256 internal constant D = 100_000;

    SymDirectory internal directory;
    SymGate internal gate;
    SymMinter internal minter;
    IndependentStream6529 internal ind;
    IndependentStreamRegistry internal registry;
    SymPrevious internal previous;

    function setUp() public {
        SymManager manager = new SymManager(NETWORK);
        directory = new SymDirectory(address(manager));
        gate = new SymGate();
        minter = new SymMinter();
        directory.set(Slots.INDEPENDENT_STREAM, address(gate));
        directory.set(Slots.ACCOUNTS, address(new SymEveryoneIsTheArtist()));
        directory.set(Slots.INDEPENDENT_TERMS, address(this));
        ind = new IndependentStream6529(
            "Artist", "ART", address(0xFAC7), address(directory), 0xA471, address(1), address(0)
        );
        previous = new SymPrevious();
        registry = new IndependentStreamRegistry(
            address(manager),
            address(directory),
            address(0xFAC7),
            address(new SymEconomics()),
            address(0xC0DE),
            address(previous)
        );
    }

    function _facts(uint256 n, uint24 rate) internal pure returns (MintFacts memory f) {
        f.itemHash = keccak256(abi.encode("item", n));
        f.contentHash = keccak256(abi.encode("content", n));
        f.artistId = 0xA471;
        f.collectionId = 1;
        f.royaltyReceiver = address(0xFEE);
        f.royaltyRate = rate;
    }

    /// @notice Only an account that minted here records or burns, whatever the gate answers: a
    ///         caller that never minted reaches neither the minter's token nor one it holds.
    function check_recordOrBurn_onlyAnAccountThatMinted(
        address caller,
        bool answer,
        uint256 removedAt,
        bool burn
    ) public {
        vm.assume(caller != address(minter) && caller != address(0));
        uint256 held = minter.mintTo(address(ind), address(minter), _facts(1, 0));
        uint256 own = minter.mintTo(address(ind), caller, _facts(2, 0));
        gate.set(answer, removedAt);
        assert(!ind.hasMinted(caller));
        bytes memory a = burn
            ? abi.encodeCall(IStream.burn, (held))
            : abi.encodeCall(IStream.recordPrimarySale, (held, true, caller, 1));
        bytes memory b = burn
            ? abi.encodeCall(IStream.burn, (own))
            : abi.encodeCall(IStream.recordPrimarySale, (own, true, caller, 1));
        vm.prank(caller);
        (bool okA,) = address(ind).call(a);
        vm.prank(caller);
        (bool okB,) = address(ind).call(b);
        assert(!okA && !okB);
        // The minter still finishes its own sale.
        minter.record(address(ind), held);
    }

    /// @notice The rescue predicate: a token an account that never minted holds is never
    ///         rescuable, whatever removal time the gate reports; a token the minter holds is
    ///         rescuable exactly when the gate reports a removal at least `rescueDelay` ago.
    function check_rescue_onlyFromAnAccountThatMinted(
        uint48 removedAt,
        uint48 delay,
        uint32 elapsed
    ) public {
        uint256 held = minter.mintTo(address(ind), address(minter), _facts(1, 0));
        uint256 collectors = minter.mintTo(address(ind), COLLECTOR, _facts(2, 0));
        gate.set(false, removedAt);
        vm.prank(NETWORK);
        ind.setRescueDelay(delay);
        vm.warp(block.timestamp + elapsed);
        vm.prank(NETWORK);
        (bool okCollector,) =
            address(ind).call(abi.encodeCall(IStream.rescue, (collectors, NETWORK)));
        assert(!okCollector);
        vm.prank(NETWORK);
        (bool okHeld,) = address(ind).call(abi.encodeCall(IStream.rescue, (held, NETWORK)));
        bool due = removedAt != 0 && block.timestamp >= uint256(removedAt) + delay;
        assert(okHeld == due);
    }

    /// @notice Only the shared TERMS module (the directory's `INDEPENDENT_TERMS`, here this
    ///         contract) sets a royalty, never above 100,000, and a locked rate never changes. The
    ///         amount `royaltyInfo` answers is proved by fuzzing (`testFuzz_royaltyInfo`): the
    ///         solver times out on the 512-bit product.
    function check_royalty_onlyTermsAndALockedRateHolds(
        address caller,
        uint24 first,
        uint24 second,
        bool lock
    ) public {
        uint256 id = minter.mintTo(address(ind), COLLECTOR, _facts(1, 0));
        vm.assume(caller != address(this));
        vm.prank(caller);
        (bool byOther,) = address(ind).call(abi.encodeCall(IStream.setRoyalty, (id, caller, first)));
        assert(!byOther);
        (bool ok1,) =
            address(ind).call(abi.encodeCall(IStream.setRoyalty, (id, address(0xA), first)));
        assert(ok1 == (first <= D));
        uint24 rate = ok1 ? first : 0;
        if (lock) ind.lockRoyaltyRate(id);
        (bool ok2,) =
            address(ind).call(abi.encodeCall(IStream.setRoyalty, (id, address(0xB), second)));
        assert(ok2 == (second <= D && (!lock || second == rate)));
        assert(ind.workOf(id).royaltyRate == (ok2 ? second : rate));
    }

    /// @notice An Independent Stream token has one collection: `createCollection` reverts for every
    ///         caller, the artist (here: everyone) and the network included.
    function check_createCollection_alwaysReverts(address caller, bytes32 metadataHash) public {
        vm.prank(caller);
        (bool ok,) =
            address(ind).call(abi.encodeCall(IStream.createCollection, ("second", metadataHash)));
        assert(!ok);
        assert(ind.collectionCount() == 1);
    }

    /// @notice The network's share of a listed contract never rises: a lowering succeeds exactly
    ///         when the new share is below the current one, and the share after is never above.
    function check_lowerFeeShare_neverRaises(uint32 first, uint32 second) public {
        previous.set(
            IIndependentStreamRegistry.Listing(
                1,
                IIndependentStreamRegistry.Status.ACTIVE,
                IIndependentStreamRegistry.Form.ERC721,
                first,
                address(0xDE),
                address(0)
            ),
            IIndependentStreamRegistry.Template(
                1,
                IIndependentStreamRegistry.Form.ERC721,
                IIndependentStreamRegistry.TemplateStatus.APPROVED
            ),
            IIndependentStreamRegistry.SaleContract(1, 0, IIndependentStreamRegistry.Form.ERC721),
            false
        );
        vm.prank(NETWORK);
        (bool ok,) = address(registry).call(abi.encodeCall(registry.lowerFeeShare, (TOKEN, second)));
        assert(ok == (second < first));
        uint32 now_ = registry.feeShareOf(TOKEN);
        assert(now_ == (ok ? second : first));
        assert(now_ <= first);
    }

    /// @notice `canMint` is false unless the sale contract is added and not removed for the
    ///         listing's form, the listing is ACTIVE, its account is not delisted and its
    ///         template version is APPROVED.
    function check_canMint_onlyAnActiveListingAndAnAddedSaleContract(
        uint48 addedAt,
        uint48 removedAt,
        uint8 status,
        uint8 templateStatus,
        bool delisted,
        uint8 form
    ) public {
        vm.assume(status < 3 && templateStatus < 4 && form < 3);
        previous.set(
            IIndependentStreamRegistry.Listing(
                1,
                IIndependentStreamRegistry.Status(status),
                IIndependentStreamRegistry.Form.ERC721,
                0,
                address(0xDE),
                address(0)
            ),
            IIndependentStreamRegistry.Template(
                1,
                IIndependentStreamRegistry.Form.ERC721,
                IIndependentStreamRegistry.TemplateStatus(templateStatus)
            ),
            IIndependentStreamRegistry.SaleContract(
                addedAt, removedAt, IIndependentStreamRegistry.Form(form)
            ),
            delisted
        );
        bool can = registry.canMint(TOKEN, address(minter));
        bool expected = addedAt != 0 && removedAt == 0
            && form == uint8(IIndependentStreamRegistry.Form.ERC721)
            && status == uint8(IIndependentStreamRegistry.Status.ACTIVE) && !delisted
            && templateStatus == uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED);
        assert(can == expected);
    }

    // ------------------------------------------------------------- the same, under Forge

    function testFuzz_recordOrBurn(address caller, bool answer, uint256 removedAt, bool burn)
        public
    {
        check_recordOrBurn_onlyAnAccountThatMinted(caller, answer, removedAt, burn);
    }

    function testFuzz_rescue(uint48 removedAt, uint48 delay, uint32 elapsed) public {
        check_rescue_onlyFromAnAccountThatMinted(removedAt, delay, elapsed);
    }

    function testFuzz_royalty(address caller, uint24 first, uint24 second, bool lock) public {
        check_royalty_onlyTermsAndALockedRateHolds(caller, first, second, lock);
    }

    /// @notice `royaltyInfo` is exactly floor(price * rate / 100,000) for any price and rate.
    function testFuzz_royaltyInfo(uint256 price, uint24 rate) public {
        rate = uint24(bound(rate, 0, D));
        uint256 id = minter.mintTo(address(ind), COLLECTOR, _facts(1, rate));
        (, uint256 amount) = ind.royaltyInfo(id, price);
        assertEq(amount, (price / D) * rate + (price % D) * rate / D);
    }

    function testFuzz_createCollection(address caller, bytes32 metadataHash) public {
        check_createCollection_alwaysReverts(caller, metadataHash);
    }

    function testFuzz_lowerFeeShare(uint32 first, uint32 second) public {
        check_lowerFeeShare_neverRaises(first, second);
    }

    function testFuzz_canMint(
        uint48 addedAt,
        uint48 removedAt,
        uint8 status,
        uint8 templateStatus,
        bool delisted,
        uint8 form
    ) public {
        check_canMint_onlyAnActiveListingAndAnAddedSaleContract(
            addedAt, removedAt, status % 3, templateStatus % 4, delisted, form % 3
        );
    }
}
