// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IVRFV2PlusWrapper } from "src/entropy/IVRFV2PlusWrapper.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { EntropyBase } from "./EntropyBase.sol";
import {
    EntropyAccountsMock,
    EntropyDirectoryMock,
    EntropyIndependentRegistryMock,
    MockVrfCoordinator,
    MockVrfWrapper,
    RedeliveringVrfWrapper
} from "test/mocks/entropy/EntropyMocks.sol";

/// @notice The paid draw of an Independent Stream contract: the request gate (a provider, a VRF
///         item, a served contract, a wallet of its artist, the quote), the wait and its repeats,
///         the provider's bounded answers, delivery by the provider alone, and the governed
///         provider setter. The directory, the Independent Stream registry and the accounts
///         module are stand-ins that answer the three reads the gate makes.
contract VrfEntropyIndependentTest is EntropyBase {
    uint256 internal constant ARTIST_ID = 6529;
    uint256 internal constant ITEM_SALT = 500;
    uint256 internal constant WORD = uint256(keccak256("independent randomness"));

    address internal artist = makeAddr("artist wallet");
    address internal token = makeAddr("independent stream");
    address internal otherToken = makeAddr("another independent stream");

    EntropyDirectoryMock internal directory;
    EntropyIndependentRegistryMock internal listing;
    EntropyAccountsMock internal accounts;
    MockVrfWrapper internal wrapper;

    function setUp() public override {
        super.setUp();
        directory = new EntropyDirectoryMock();
        listing = new EntropyIndependentRegistryMock();
        accounts = new EntropyAccountsMock();
        wrapper = new MockVrfWrapper();
        module = new VrfEntropyModule(
            address(manager),
            address(coordinator),
            address(coordinator).codehash,
            _config(),
            RETRY_DELAY,
            IPackageRegistry(address(registry)),
            address(registry).codehash,
            IModuleSlots(address(directory))
        );
        vm.startPrank(admin);
        manager.setTargetFunctionRole(
            address(module), _selector(module.setCoordinator.selector), Roles.SUCCESSOR_SETTER
        );
        manager.setTargetFunctionRole(
            address(module), _selector(module.setWrapper.selector), Roles.SUCCESSOR_SETTER
        );
        vm.stopPrank();

        directory.setModule(Slots.INDEPENDENT_STREAM, address(listing));
        directory.setModule(Slots.ACCOUNTS, address(accounts));
        listing.list(token, ARTIST_ID, true);
        accounts.setWallet(ARTIST_ID, artist, true);
        vm.deal(artist, 1 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _vrfItem() internal pure returns (PackageItem memory) {
        return _makeItem(ITEM_SALT, SeedPolicy.VRF);
    }

    function _key(address token_, bytes32 contentHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(token_, contentHash));
    }

    /// @dev The successor sets the provider, pinning the new one's code hash.
    function _setWrapper(address next) internal {
        address current = module.wrapper();
        bytes32 codeHash = next.codehash;
        vm.prank(successor);
        module.setWrapper(current, next, codeHash);
    }

    /// @dev The artist requests `item`'s seed for `token`, paying exactly the quote.
    function _paidRequest(PackageItem memory item) internal returns (uint256 requestId) {
        uint256 price = IVRFV2PlusWrapper(module.wrapper()).calculateRequestPriceNative(0, 1);
        vm.prank(artist);
        requestId = module.requestIndependentSeed{ value: price }(token, item);
    }

    /// @dev The artist's request of `item` for `token`, paying exactly the quote, reverts with
    ///      `data`.
    function _expectRefused(PackageItem memory item, bytes memory data) internal {
        uint256 price = wrapper.price();
        vm.prank(artist);
        vm.expectRevert(data);
        module.requestIndependentSeed{ value: price }(token, item);
    }

    function _assertUndelivered(address token_, bytes32 contentHash) internal view {
        (bool delivered, bytes32 seed) = module.independentSeedOf(token_, contentHash);
        assertFalse(delivered, "undelivered");
        assertEq(seed, bytes32(0), "no seed");
    }

    // ------------------------------------------------------------------ requestIndependentSeed

    /// @dev The artist pays the provider's quote, the network's subscription is not used, and
    ///      the provider's delivery fixes the seed for this contract and content only.
    function test_RequestIndependentSeed_AnArtistWalletPaysTheQuoteAndTheWrapperDelivers() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        bytes32 key = _key(token, item.contentHash);
        uint256 price = wrapper.price();
        uint256 subscriptionRequests = coordinator.nextId();
        uint256 balance = artist.balance;
        _assertUndelivered(token, item.contentHash);

        vm.expectEmit(address(module));
        emit IEntropyModule.IndependentSeedRequested(token, item.contentHash, key, 7001);
        uint256 requestId = _paidRequest(item);
        assertEq(requestId, 7001);
        assertEq(wrapper.received(), price, "the requester paid the provider");
        assertEq(artist.balance, balance - price, "the quote, no more");
        assertEq(address(module).balance, 0, "the module keeps nothing");
        assertEq(coordinator.nextId(), subscriptionRequests, "no subscription request");
        _assertUndelivered(token, item.contentHash);

        vm.expectEmit(address(module));
        emit IEntropyModule.SeedDelivered(key, requestId, bytes32(WORD));
        wrapper.fulfill(requestId, WORD);
        (bool delivered, bytes32 seed) = module.independentSeedOf(token, item.contentHash);
        assertTrue(delivered);
        assertEq(seed, bytes32(WORD));
        _assertUndelivered(otherToken, item.contentHash);
        assertFalse(module.isDeliveredContent(key), "not a curated seed");
        assertFalse(module.isDeliveredContent(item.contentHash), "not a curated seed");
    }

    /// @dev With no provider set, a request is refused; so is an item that is not a VRF item or
    ///      has no content hash.
    function test_RequestIndependentSeed_RefusesWithoutAProviderOrAVrfItemWithContent() public {
        PackageItem memory item = _vrfItem();
        _expectRefused(item, _notRequestable(_hash(item)));

        _setWrapper(address(wrapper));
        PackageItem memory plain = _makeItem(ITEM_SALT, SeedPolicy.NONE);
        _expectRefused(plain, _notRequestable(_hash(plain)));
        PackageItem memory artistSeed = _makeItem(ITEM_SALT, SeedPolicy.ARTIST);
        _expectRefused(artistSeed, _notRequestable(_hash(artistSeed)));
        PackageItem memory empty = _vrfItem();
        empty.contentHash = 0;
        _expectRefused(empty, _notRequestable(_hash(empty)));

        assertEq(wrapper.received(), 0, "nothing paid");
        _paidRequest(item);
    }

    /// @dev The gate reads the directory now: an empty INDEPENDENT_STREAM or ACCOUNTS slot, a
    ///      contract the registry does not serve, and a caller who is not a wallet of the
    ///      contract's artist are each refused, and nothing is paid or stamped.
    function test_RequestIndependentSeed_RefusesAnEmptySlotAnUnservedContractAndAStranger()
        public
    {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        bytes memory refused = _notRequestable(_hash(item));
        uint256 price = wrapper.price();

        directory.setModule(Slots.INDEPENDENT_STREAM, address(0));
        _expectRefused(item, refused);
        directory.setModule(Slots.INDEPENDENT_STREAM, address(listing));

        directory.setModule(Slots.ACCOUNTS, address(0));
        _expectRefused(item, refused);
        directory.setModule(Slots.ACCOUNTS, address(accounts));

        listing.list(token, ARTIST_ID, false);
        _expectRefused(item, refused);
        listing.list(token, ARTIST_ID, true);

        // A contract that was never listed, asked for by the artist of another one.
        vm.prank(artist);
        vm.expectRevert(refused);
        module.requestIndependentSeed{ value: price }(otherToken, item);

        // A wallet of another artist, and one removed from this artist's account.
        accounts.setWallet(ARTIST_ID + 1, stranger, true);
        vm.deal(stranger, price);
        vm.prank(stranger);
        vm.expectRevert(refused);
        module.requestIndependentSeed{ value: price }(token, item);
        accounts.setWallet(ARTIST_ID, artist, false);
        _expectRefused(item, refused);
        accounts.setWallet(ARTIST_ID, artist, true);

        assertEq(wrapper.received(), 0, "nothing paid");
        // No refusal started the wait.
        _paidRequest(item);
    }

    function test_RequestIndependentSeed_RefusesLessThanTheQuote() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        uint256 price = wrapper.price();
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InsufficientPayment.selector, price));
        module.requestIndependentSeed{ value: price - 1 }(token, item);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InsufficientPayment.selector, price));
        module.requestIndependentSeed(token, item);

        // The quote is read at the request: a raised price is the one to pay.
        wrapper.setPrice(2 * price);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.InsufficientPayment.selector, 2 * price)
        );
        module.requestIndependentSeed{ value: price }(token, item);
        assertEq(wrapper.received(), 0, "nothing paid");
        _paidRequest(item);
        assertEq(wrapper.received(), 2 * price);
    }

    /// @dev One request at a time: a second is refused until the wait has passed, the wait
    ///      doubles with each repeat as a curated draw's does, and a repeat adds a request
    ///      without invalidating the earlier one.
    function test_RequestIndependentSeed_ARepeatWaitsAndTheWaitDoubles() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        bytes32 itemHash = _hash(item);
        uint256 first = _paidRequest(item);
        uint64 at = uint64(block.timestamp);

        _expectRefused(
            item,
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, itemHash, at + RETRY_DELAY
            )
        );
        vm.warp(at + RETRY_DELAY - 1);
        _expectRefused(
            item,
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, itemHash, at + RETRY_DELAY
            )
        );
        vm.warp(at + RETRY_DELAY);
        uint256 second = _paidRequest(item);
        assertEq(second, first + 1, "a new request");
        uint64 repeatedAt = uint64(block.timestamp);

        // The first repeat waits twice the delay.
        vm.warp(repeatedAt + RETRY_DELAY);
        _expectRefused(
            item,
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, itemHash, repeatedAt + 2 * RETRY_DELAY
            )
        );

        // The earlier request still delivers, and the later delivery changes nothing.
        wrapper.fulfill(first, WORD);
        vm.recordLogs();
        wrapper.fulfill(second, WORD + 1);
        assertEq(_countModuleLogs(IEntropyModule.SeedDelivered.selector), 0, "a silent no-op");
        (bool delivered, bytes32 seed) = module.independentSeedOf(token, item.contentHash);
        assertTrue(delivered);
        assertEq(seed, bytes32(WORD), "the first delivery is final");
    }

    function test_RequestIndependentSeed_RefusesADeliveredDraw() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        wrapper.fulfill(_paidRequest(item), WORD);
        vm.warp(block.timestamp + 365 days);
        uint256 paid = wrapper.received();
        _expectRefused(
            item, abi.encodeWithSelector(IEntropyModule.SeedAlreadyDelivered.selector, _hash(item))
        );
        assertEq(wrapper.received(), paid, "nothing more paid");
        // The same content on another served contract is another draw.
        listing.list(otherToken, ARTIST_ID, true);
        uint256 price = wrapper.price();
        vm.prank(artist);
        module.requestIndependentSeed{ value: price }(otherToken, item);
        _assertUndelivered(otherToken, item.contentHash);
    }

    /// @dev A late delivery of an earlier request that lands inside a repeat fixes the seed: the
    ///      repeat does not overwrite it with its request ID and logs no request, and its ID is
    ///      still known, so its own delivery is a silent no-op.
    function test_RequestIndependentSeed_ADeliveryInsideARepeatKeepsItsSeed() public {
        RedeliveringVrfWrapper late = new RedeliveringVrfWrapper();
        _setWrapper(address(late));
        PackageItem memory item = _vrfItem();
        uint256 first = _paidRequest(item);
        vm.warp(block.timestamp + RETRY_DELAY);

        late.deliverDuringNextRequest(first, WORD);
        vm.recordLogs();
        uint256 second = _paidRequest(item);
        assertEq(second, first + 1);
        assertEq(
            _countModuleLogs(IEntropyModule.IndependentSeedRequested.selector),
            0,
            "no request logged for a delivered draw"
        );
        (bool delivered, bytes32 seed) = module.independentSeedOf(token, item.contentHash);
        assertTrue(delivered);
        assertEq(seed, bytes32(WORD), "the seed, not the request ID");

        vm.prank(address(late));
        module.rawFulfillRandomWords(second, _oneWord(WORD + 1));
        (, seed) = module.independentSeedOf(token, item.contentHash);
        assertEq(seed, bytes32(WORD), "unchanged");
    }

    /// @dev The provider's answers are copied through `BoundedCall` with a 1,024-byte bound: an
    ///      empty or longer refusal reverts with `BoundedCallFailed(wrapper)`, a short one keeps
    ///      its reason, and a quote or request ID that is not one word is malformed.
    function test_RequestIndependentSeed_TheProvidersAnswersAreBounded() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        address wr = address(wrapper);
        bytes memory request =
            abi.encodePacked(IVRFV2PlusWrapper.requestRandomWordsInNative.selector);
        bytes memory quote =
            abi.encodePacked(IVRFV2PlusWrapper.calculateRequestPriceNative.selector);
        bytes memory failed = abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, wr);
        bytes memory malformed =
            abi.encodeWithSelector(BoundedCall.BoundedCallMalformedReturn.selector, wr);

        // The quote: an empty refusal, a refusal with a reason, two words, no words.
        vm.mockCallRevert(wr, quote, "");
        _expectRefused(item, failed);
        vm.clearMockedCalls();
        vm.mockCallRevert(wr, quote, abi.encodeWithSelector(MockVrfWrapper.FeeTooLow.selector));
        _expectRefused(item, abi.encodeWithSelector(MockVrfWrapper.FeeTooLow.selector));
        vm.clearMockedCalls();
        vm.mockCall(wr, quote, abi.encode(wrapper.price(), uint256(1)));
        _expectRefused(item, malformed);
        vm.clearMockedCalls();

        // The request: a refusal longer than the bound, a short one, an empty one, two words.
        vm.mockCallRevert(wr, request, new bytes(4096));
        _expectRefused(item, failed);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            wr, request, abi.encodeWithSelector(MockVrfWrapper.NotNativePayment.selector)
        );
        _expectRefused(item, abi.encodeWithSelector(MockVrfWrapper.NotNativePayment.selector));
        vm.clearMockedCalls();
        vm.mockCallRevert(wr, request, "");
        _expectRefused(item, failed);
        vm.clearMockedCalls();
        vm.mockCall(wr, request, abi.encode(uint256(7001), uint256(1)));
        _expectRefused(item, malformed);
        vm.clearMockedCalls();

        // Every refusal reverted the whole call: no wait started and nothing was paid.
        assertEq(wrapper.received(), 0);
        _paidRequest(item);
    }

    /// @dev A request ID of zero, or one the provider already returned, is refused and records
    ///      nothing.
    function test_RequestIndependentSeed_RefusesAZeroOrRepeatedRequestId() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        bytes memory request =
            abi.encodePacked(IVRFV2PlusWrapper.requestRandomWordsInNative.selector);

        vm.mockCall(address(wrapper), request, abi.encode(uint256(0)));
        _expectRefused(item, abi.encodeWithSelector(IEntropyModule.InvalidRequestId.selector, 0));
        vm.clearMockedCalls();

        uint256 first = _paidRequest(item);
        PackageItem memory second = _makeItem(ITEM_SALT + 1, SeedPolicy.VRF);
        vm.mockCall(address(wrapper), request, abi.encode(first));
        _expectRefused(
            second, abi.encodeWithSelector(IEntropyModule.InvalidRequestId.selector, first)
        );
        vm.clearMockedCalls();
        _assertUndelivered(token, second.contentHash);

        // The first request still belongs to the first work alone.
        wrapper.fulfill(first, WORD);
        (bool delivered,) = module.independentSeedOf(token, item.contentHash);
        assertTrue(delivered);
        _assertUndelivered(token, second.contentHash);
    }

    /// @dev The provider's code is pinned: once the code at its address differs from the hash
    ///      set with it, a request is refused before anything is paid, and so is a delivery.
    function test_RequestIndependentSeed_RefusesAProviderWhoseCodeChanged() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        uint256 requestId = _paidRequest(item);
        vm.warp(block.timestamp + RETRY_DELAY);

        vm.etch(address(wrapper), address(new RedeliveringVrfWrapper()).code);
        bytes memory changed =
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(wrapper));
        uint256 balance = artist.balance;
        _expectRefused(item, changed);
        assertEq(artist.balance, balance, "nothing paid");
        vm.prank(address(wrapper));
        vm.expectRevert(changed);
        module.rawFulfillRandomWords(requestId, _oneWord(WORD));
        _assertUndelivered(token, item.contentHash);
    }

    // ------------------------------------------------------------------ rawFulfillRandomWords

    /// @dev Only the provider delivers a paid request: the coordinator does not know its ID, and
    ///      no one else may call. The provider cannot deliver an ID it did not issue, the
    ///      coordinator's IDs included, and must deliver exactly one word.
    function test_Fulfill_TheProviderAloneDeliversItsRequests() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        uint256 requestId = _paidRequest(item);
        uint256 curatedId = _request(0);

        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, requestId));
        coordinator.deliver(address(module), requestId, _oneWord(WORD));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector, stranger, address(coordinator)
            )
        );
        module.rawFulfillRandomWords(requestId, _oneWord(WORD));

        vm.startPrank(address(wrapper));
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, curatedId));
        module.rawFulfillRandomWords(curatedId, _oneWord(WORD));
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, requestId + 1)
        );
        module.rawFulfillRandomWords(requestId + 1, _oneWord(WORD));
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.InvalidRandomWords.selector, requestId)
        );
        module.rawFulfillRandomWords(requestId, two);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.InvalidRandomWords.selector, requestId)
        );
        module.rawFulfillRandomWords(requestId, new uint256[](0));
        vm.stopPrank();

        _assertUndelivered(token, item.contentHash);
        assertFalse(module.isDelivered(items[0]), "the curated draw is untouched");
        wrapper.fulfill(requestId, WORD);
        (bool delivered,) = module.independentSeedOf(token, item.contentHash);
        assertTrue(delivered);
    }

    /// @dev Curated and paid draws are kept apart: a curated item whose content hash equals a
    ///      paid draw's key is drawn on the subscription, and the paid draw stays undelivered.
    function test_Fulfill_ACuratedDrawNeverFillsAnIndependentSeed() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        bytes32 key = _key(token, item.contentHash);
        PackageItem memory curated = _makeItem(ITEM_SALT + 2, SeedPolicy.VRF);
        curated.contentHash = key;
        bytes32 curatedRoot = WorksHashing.leaf(_hash(curated));
        registry.setStatus(curatedRoot, IPackageRegistry.PackageStatus.APPROVED);

        uint256 id = module.requestSeed(curated, curatedRoot, new bytes32[](0));
        coordinator.fulfill(id, 0xC0FFEE);
        assertTrue(module.isDeliveredContent(key), "the curated draw");
        _assertUndelivered(token, item.contentHash);

        // And the other way: the paid draw's delivery leaves a curated draw of the same
        // content hash undelivered.
        PackageItem memory same = _makeItem(ITEM_SALT + 3, SeedPolicy.VRF);
        same.contentHash = item.contentHash;
        wrapper.fulfill(_paidRequest(item), WORD);
        assertFalse(module.isDeliveredContent(same.contentHash), "not the curated one");
    }

    // ------------------------------------------------------------------ setWrapper

    /// @dev The provider setter is governed and compare-and-set; it refuses the current provider
    ///      and the coordinator as the next one, and code that does not have the given hash.
    function test_SetWrapper_IsGovernedCompareAndSetAndPinned() public {
        address w = address(wrapper);
        bytes32 hash = w.codehash;
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        module.setWrapper(address(0), w, hash);

        vm.startPrank(successor);
        vm.expectRevert(IEntropyModule.ExpectedValueMismatch.selector);
        module.setWrapper(address(1), w, hash);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(0)));
        module.setWrapper(address(0), address(0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, w));
        module.setWrapper(address(0), w, keccak256("another code"));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, stranger));
        module.setWrapper(address(0), stranger, stranger.codehash);
        address coord = address(coordinator);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, coord));
        module.setWrapper(address(0), coord, coord.codehash);
        assertEq(module.wrapper(), address(0), "unchanged");

        vm.expectEmit(address(module));
        emit IEntropyModule.WrapperSet(address(0), w, hash);
        module.setWrapper(address(0), w, hash);
        assertEq(module.wrapper(), w);

        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, w));
        module.setWrapper(w, w, hash);
        // The coordinator setter refuses the provider in turn.
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, w));
        module.setCoordinator(coord, w, hash);
        vm.stopPrank();
        assertEq(module.wrapper(), w, "unchanged");
        assertEq(module.coordinator(), coord, "unchanged");
    }

    /// @dev Setting the provider to zero turns paid draws off: no code is asked of the zero
    ///      address, requests are refused, and the old provider can no longer deliver.
    function test_SetWrapper_ZeroTurnsPaidDrawsOff() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        uint256 requestId = _paidRequest(item);

        vm.expectEmit(address(module));
        emit IEntropyModule.WrapperSet(address(wrapper), address(0), bytes32(0));
        vm.prank(successor);
        module.setWrapper(address(wrapper), address(0), bytes32(0));
        assertEq(module.wrapper(), address(0));

        vm.warp(block.timestamp + RETRY_DELAY);
        _expectRefused(item, _notRequestable(_hash(item)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector,
                address(wrapper),
                address(coordinator)
            )
        );
        wrapper.fulfill(requestId, WORD);
        _assertUndelivered(token, item.contentHash);
    }

    /// @dev A new provider starts a new tenure for paid draws: an undelivered draw may be
    ///      requested from it at once, its wait starts again at the base delay, and the old
    ///      provider's request can no longer deliver.
    function test_SetWrapper_ANewProviderIsAskedAtOnce() public {
        _setWrapper(address(wrapper));
        PackageItem memory item = _vrfItem();
        bytes32 itemHash = _hash(item);
        uint256 oldId = _paidRequest(item);
        vm.warp(block.timestamp + RETRY_DELAY);
        _paidRequest(item); // the first repeat: the next wait is twice the delay

        MockVrfWrapper next = new MockVrfWrapper();
        _setWrapper(address(next));
        uint256 newId = _paidRequest(item);
        assertEq(next.received(), next.price(), "the new provider was paid");
        uint64 at = uint64(block.timestamp);
        _expectRefused(
            item,
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, itemHash, at + RETRY_DELAY
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector,
                address(wrapper),
                address(coordinator)
            )
        );
        wrapper.fulfill(oldId, WORD);
        next.fulfill(newId, WORD + 2);
        (bool delivered, bytes32 seed) = module.independentSeedOf(token, item.contentHash);
        assertTrue(delivered);
        assertEq(seed, bytes32(WORD + 2));
    }

    /// @dev Setting the provider does not restart a curated draw's backoff, and replacing the
    ///      coordinator does not restart a paid draw's.
    function test_SetWrapper_LeavesTheCuratedBackoffAndSetCoordinatorThePaidOne() public {
        _request(0);
        uint64 at = uint64(block.timestamp);
        vm.warp(at + RETRY_DELAY);
        _request(0); // the first repeat
        uint64 repeatedAt = uint64(block.timestamp);
        _setWrapper(address(wrapper));
        vm.warp(repeatedAt + RETRY_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, items[0], repeatedAt + 2 * RETRY_DELAY
            )
        );
        vm.prank(stranger);
        module.requestSeed(_item(0), root, proofs[0]);

        PackageItem memory item = _vrfItem();
        _paidRequest(item);
        uint64 paidAt = uint64(block.timestamp);
        _swap(address(new MockVrfCoordinator()));
        _expectRefused(
            item,
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector, _hash(item), paidAt + RETRY_DELAY
            )
        );
    }
}
