// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { PrimaryOutcome, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Stream } from "src/stream/Stream.sol";
import { MockPackageRegistry, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @dev `coreOf`'s six words, hashed.
function _coreHash(Stream stream, uint256 id) view returns (bytes32) {
    (bytes32 itemHash, uint256 artistId, uint256 cid, uint8 kind, uint8 seed, uint32 rate) =
        stream.coreOf(id);
    return keccak256(abi.encode(itemHash, artistId, cid, kind, seed, rate));
}

/// @notice A mint policy that answers whatever the test sets, reverts, burns all its gas, or
///         first tries every write it could attempt on Stream and on the minting adapter, so the
///         tests can show that no policy reaches an existing token.
contract HostilePolicy is IMintPolicy {
    enum Mode {
        ANSWER,
        REVERT,
        BURN,
        REENTER,
        MALFORMED
    }

    Mode public mode;
    address public immutable artistRegistry;
    MintRecord internal _record;
    /// @dev The existing token the re-entry attempts target, and how many attempts succeeded.
    uint256 public target;
    uint256 public reentrySuccesses;

    constructor(address artists) {
        artistRegistry = artists;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setTarget(uint256 tokenId) external {
        target = tokenId;
    }

    function setRecord(MintRecord calldata r) external {
        _record = r;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IMintPolicy).interfaceId || id == type(IERC165).interfaceId;
    }

    function authorize(MintContext calldata context, bytes calldata)
        external
        returns (MintRecord memory)
    {
        Mode m = mode;
        if (m == Mode.REVERT) revert("policy refuses");
        if (m == Mode.BURN) {
            while (true) { }
        }
        if (m == Mode.MALFORMED) {
            assembly ("memory-safe") {
                mstore(0, 0x20)
                return(0, 0x40)
            }
        }
        if (m == Mode.REENTER) _reenter(msg.sender, context.adapter);
        return _record;
    }

    /// @dev Each write the policy could try with the call it holds: none may succeed.
    function _reenter(address stream, address adapter) internal {
        uint256 id = target;
        bytes[9] memory calls = [
            abi.encodeCall(IStream.burn, (id, 1)),
            abi.encodeCall(
                IStream.settlePrimary, (id, PrimaryOutcome.SOLD, address(this), address(0), 1)
            ),
            abi.encodeCall(IStream.setRoyaltyRate, (id, 0)),
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", adapter, address(this), id
            ),
            abi.encodeCall(IStream.setDependency, ("ENTROPY_MODULE", address(0), address(this))),
            abi.encodeCall(IStream.rescueToMuseum, (id)),
            abi.encodeCall(IStream.linkEdition, (id, id)),
            abi.encodeCall(IStream.mint, (address(this), 0, 1, "")),
            abi.encodeCall(IStream.setAdmittedMinter, (address(this), true))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = stream.call(calls[i]);
            if (ok) ++reentrySuccesses;
        }
    }

    function preview(MintContext calldata, bytes calldata)
        external
        pure
        returns (PrimaryTerms memory terms)
    {
        return terms;
    }
}

/// @notice Rule MP-1: the mint policy decides new mints only. Whatever it answers (any record,
///         a revert, a gas burn, a malformed answer, re-entry into Stream or the adapter), no
///         existing token's owner, terms, renderer, record pointers, entropy answer, sale
///         outcome or royalty changes, and nothing is minted outside an admitted adapter's
///         custody.
contract StreamPolicySafetyTest is StreamFixture {
    HostilePolicy internal hostile;
    uint256[] internal existing;

    function setUp() public override {
        super.setUp();
        _bindMocks();
        for (uint256 i = 1; i <= 3; ++i) {
            existing.push(_mint(i));
        }
        auction.settle(stream, existing[0]); // one sold work, delivered later by the adapter
        hostile = new HostilePolicy(address(artists));
        vm.prank(governor);
        stream.setDependency("PACKAGE_REGISTRY", address(registry), address(hostile));
    }

    /// @dev Everything an existing token shows other contracts and the world.
    function _snapshot() internal view returns (bytes32 h) {
        h = keccak256(
            abi.encode(
                stream.workRecords(),
                stream.editions(),
                stream.artistRegistry(),
                stream.splitFactory(),
                stream.defaultRenderer()
            )
        );
        for (uint256 i; i < existing.length; ++i) {
            h = keccak256(abi.encode(h, _tokenView(existing[i])));
        }
    }

    function _tokenView(uint256 id) internal view returns (bytes32) {
        (address receiver, uint256 amount) = stream.royaltyInfo(id, 1 ether);
        bytes32 sale;
        {
            (PrimaryOutcome outcome, address currency, uint256 price) = stream.primarySale(id);
            sale = keccak256(abi.encode(outcome, currency, price));
        }
        return keccak256(
            abi.encode(
                stream.ownerOf(id),
                _coreHash(stream, id),
                receiver,
                amount,
                stream.rendererOf(id),
                stream.entropyModuleOf(id),
                sale,
                keccak256(abi.encode(stream.primaryTerms(id, "")))
            )
        );
    }

    /// @dev A record that passes every core check, built from `seed`.
    function _record(uint256 seed) internal view returns (IMintPolicy.MintRecord memory r) {
        r.itemHash = keccak256(abi.encode("item", seed));
        r.contentHash = keccak256(abi.encode("policy content", seed));
        r.artistId = uint160(artist);
        r.collectionId = collectionId;
        r.royaltyRate = uint32(seed % 100_001);
        r.saleKind = SaleKind.ENGLISH_AUCTION;
        r.seller = seller;
        r.feeRecipient = feeRecipient;
        r.feeShare = 25_000;
        r.creator = artist;
    }

    function test_MP1_AnyAnswerLeavesExistingTokensUnchanged() public {
        bytes32 before = _snapshot();
        hostile.setRecord(_record(1));
        (uint256 id,) = auction.start(stream, _request(_item(99)));
        assertEq(stream.ownerOf(id), address(auction), "minted into the adapter's custody");
        assertEq(_snapshot(), before);
    }

    function test_MP1_ReentryReachesNothing() public {
        bytes32 before = _snapshot();
        hostile.setRecord(_record(2));
        hostile.setTarget(existing[1]);
        hostile.setMode(HostilePolicy.Mode.REENTER);
        auction.start(stream, _request(_item(98)));
        assertEq(hostile.reentrySuccesses(), 0, "no write succeeded from inside the policy");
        assertEq(_snapshot(), before);
    }

    function test_MP1_RevertBurnAndMalformedAnswersMintNothing() public {
        bytes32 before = _snapshot();
        uint256 minted = stream.totalMinted();
        hostile.setMode(HostilePolicy.Mode.REVERT);
        vm.expectRevert(bytes("policy refuses"));
        auction.start(stream, _request(_item(97)));
        hostile.setMode(HostilePolicy.Mode.MALFORMED);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        auction.start(stream, _request(_item(97)));
        hostile.setMode(HostilePolicy.Mode.BURN);
        vm.expectRevert();
        auction.start{ gas: 2_000_000 }(stream, _request(_item(97)));
        assertEq(stream.totalMinted(), minted);
        assertEq(_snapshot(), before);
    }

    /// @dev The core's invariants on a record, each refused with its own error.
    function test_MP1_CoreChecksEveryRecord() public {
        IMintPolicy.MintRecord memory r = _record(3);
        bytes memory data = _request(_item(96));
        r.itemHash = 0;
        _expectRefused(r, data, abi.encodeWithSelector(IMintTarget.InvalidMintRequest.selector));
        r = _record(3);
        r.contentHash = 0;
        _expectRefused(r, data, abi.encodeWithSelector(IMintTarget.InvalidMintRequest.selector));
        r = _record(3);
        r.artistId = 0;
        _expectRefused(r, data, abi.encodeWithSelector(IMintTarget.InvalidMintRequest.selector));
        r.artistId = uint256(type(uint160).max) + 1;
        _expectRefused(r, data, abi.encodeWithSelector(IMintTarget.InvalidMintRequest.selector));
        r = _record(3);
        r.kind = 4;
        _expectRefused(r, data, abi.encodeWithSelector(IMintTarget.InvalidMintRequest.selector));
        r = _record(3);
        r.seedPolicy = 4;
        _expectRefused(r, data, abi.encodeWithSelector(IMintTarget.InvalidMintRequest.selector));
        r = _record(3);
        r.seller = address(0);
        _expectRefused(r, data, abi.encodeWithSelector(IStream.InvalidWorkTerms.selector));
        r = _record(3);
        r.royaltyRate = 100_001;
        _expectRefused(r, data, abi.encodeWithSelector(IStream.InvalidWorkTerms.selector));
        r = _record(3);
        r.feeShare = 100_000;
        _expectRefused(r, data, abi.encodeWithSelector(IStream.InvalidWorkTerms.selector));
        r = _record(3);
        r.feeRecipient = seller;
        _expectRefused(r, data, abi.encodeWithSelector(IStream.InvalidWorkTerms.selector));
        r = _record(3);
        r.collectionId = 999;
        _expectRefused(r, data, abi.encodeWithSelector(IStream.UnknownCollection.selector, 999));
        r = _record(3);
        r.saleKind = SaleKind.FIXED_PRICE;
        _expectRefused(
            r,
            data,
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector,
                SaleKind.FIXED_PRICE,
                SaleKind.ENGLISH_AUCTION
            )
        );
        // Kind and seed policy values a later policy may define (up to 3) are stored as given.
        r = _record(3);
        r.kind = 3;
        r.seedPolicy = 3;
        hostile.setRecord(r);
        (uint256 id,) = auction.start(stream, data);
        (,,, uint8 kind, uint8 seed,) = stream.coreOf(id);
        assertEq(kind, 3);
        assertEq(seed, 3);
    }

    function _expectRefused(IMintPolicy.MintRecord memory r, bytes memory data, bytes memory why)
        internal
    {
        hostile.setRecord(r);
        vm.expectRevert(why);
        auction.start(stream, data);
    }

    /// @dev AUC-44: a policy answering a content hash already minted is refused by Stream.
    function test_MP1_AnAlreadyMintedContentIsRefused() public {
        IMintPolicy.MintRecord memory r = _record(5);
        r.contentHash = keccak256(abi.encode("content", 1)); // existing[0]'s content
        (bytes32 heldItem,,,,,) = stream.coreOf(existing[0]);
        hostile.setRecord(r);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStream.ContentUsed.selector, PRODUCT_STREAM, r.contentHash, heldItem
            )
        );
        auction.start(stream, _request(_item(93)));
    }

    /// @dev AUC-44: replacing the policy with a blank one (no record of any earlier mint)
    ///      cannot mint existing content again: the record is Stream's.
    function test_MP1_ABlankPolicyCannotReMintExistingContent() public {
        MockPackageRegistry blank = new MockPackageRegistry();
        blank.setArtistRegistry(address(artists));
        blank.bindStream(address(stream));
        vm.prank(governor);
        stream.setDependency("PACKAGE_REGISTRY", address(hostile), address(blank));
        PackageItem memory again = _item(2); // existing[1]'s item, the very same
        bytes memory data = _request(again);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStream.ContentUsed.selector,
                PRODUCT_STREAM,
                again.contentHash,
                WorksHashing.itemHash(again)
            )
        );
        auction.start(stream, data);
    }

    /// @dev Only an admitted adapter mints, into its own custody, whatever the policy says.
    function test_MP1_NoMintOutsideAnAdmittedAdaptersCustody() public {
        hostile.setRecord(_record(4));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, outsider));
        stream.mint(outsider, 0, 1, _request(_item(95)));
        vm.prank(address(auction));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        stream.mint(outsider, 0, 1, _request(_item(95)));
    }

    /// @dev Terms the policy reports that hash to an existing terms word's position never
    ///      overwrite it: they go to the overflow range (QUALITY-6), so existing works keep theirs.
    function testFuzz_MP1_RecordsNeverRewriteExistingTerms(uint256 seed, uint160 artistId) public {
        vm.assume(artistId != 0);
        bytes32 before = _snapshot();
        IMintPolicy.MintRecord memory r = _record(seed);
        r.artistId = artistId;
        hostile.setRecord(r);
        auction.start(stream, _request(_item(94)));
        assertEq(_snapshot(), before);
    }
}

/// @notice Drives Stream with a hostile policy: random records, honest re-entry attempts and
///         policy swaps, recording each existing token's view once it is minted.
contract PolicyHandler {
    Stream internal immutable stream;
    MockSaleAdapter internal immutable adapter;
    HostilePolicy internal immutable hostile;
    StreamPolicyInvariantTest internal immutable owner;
    uint256[] public tokens;
    mapping(uint256 tokenId => bytes32) public viewOf;
    uint256 public salt = 1000;

    constructor(Stream s, MockSaleAdapter a, HostilePolicy h, StreamPolicyInvariantTest o) {
        (stream, adapter, hostile, owner) = (s, a, h, o);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function mintRandom(uint256 seed, uint8 mode) external {
        // No gas burn here: the run's gas would be spent in one call.
        uint8 m = mode % 4;
        hostile.setMode(HostilePolicy.Mode(m == 2 ? 4 : m));
        hostile.setRecord(owner.recordFrom(seed));
        if (tokens.length != 0) hostile.setTarget(tokens[seed % tokens.length]);
        try adapter.start(stream, owner.requestFor(++salt)) returns (
            uint256 tokenId, PrimaryTerms memory
        ) {
            bytes32 content = owner.recordFrom(seed).contentHash;
            if (tokenOfContent[content] != 0) duplicateMinted = true;
            tokenOfContent[content] = tokenId;
            contents.push(content);
            tokens.push(tokenId);
            viewOf[tokenId] = owner.viewOf(tokenId);
        } catch { }
    }

    /// @dev Content hashes minted so far, by the token that minted each.
    mapping(bytes32 contentHash => uint256 tokenId) public tokenOfContent;
    bytes32[] public contents;
    bool public duplicateMinted;
}

/// @notice MP-1 as a stateful invariant: after any sequence of hostile-policy mints, every
///         token minted earlier reads exactly as it did when it was minted, and is held by the
///         adapter that minted it.
contract StreamPolicyInvariantTest is StreamFixture {
    PolicyHandler internal handler;
    HostilePolicy internal hostile;

    function setUp() public override {
        super.setUp();
        _bindMocks();
        hostile = new HostilePolicy(address(artists));
        vm.prank(governor);
        stream.setDependency("PACKAGE_REGISTRY", address(registry), address(hostile));
        handler = new PolicyHandler(stream, auction, hostile, this);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PolicyHandler.mintRandom.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function recordFrom(uint256 seed) external view returns (IMintPolicy.MintRecord memory r) {
        r.itemHash = keccak256(abi.encode("item", seed));
        r.contentHash = keccak256(abi.encode("policy content", seed % 64));
        r.artistId = seed % 7 == 0 ? 0 : uint160(artist);
        r.collectionId = seed % 11 == 0 ? 2 : collectionId;
        r.kind = uint8(seed % 5);
        r.seedPolicy = uint8((seed >> 8) % 5);
        r.royaltyRate = uint32(seed % 100_002);
        r.saleKind = seed % 13 == 0 ? SaleKind.FIXED_PRICE : SaleKind.ENGLISH_AUCTION;
        r.seller = seed % 17 == 0 ? address(0) : seller;
        r.feeRecipient = feeRecipient;
        r.feeShare = uint32((seed >> 16) % 100_001);
        r.creator = artist;
    }

    function requestFor(uint256 s) external view returns (bytes memory) {
        return _request(_item(s));
    }

    function viewOf(uint256 id) public view returns (bytes32) {
        (address receiver, uint256 amount) = stream.royaltyInfo(id, 1 ether);
        return keccak256(
            abi.encode(
                stream.ownerOf(id),
                _coreHash(stream, id),
                receiver,
                amount,
                stream.rendererOf(id),
                stream.entropyModuleOf(id),
                abi.encode(stream.primaryTerms(id, ""))
            )
        );
    }

    function invariant_MP1_ExistingTokensNeverChange() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.tokens(i);
            assertEq(viewOf(id), handler.viewOf(id), "an existing token changed");
            assertEq(stream.ownerOf(id), address(auction), "held by the adapter that minted it");
            // AUC-44: each minted content is Stream's record of the one token that minted it.
            bytes32 content = handler.contents(i);
            (bytes32 itemHash,,,,,) = stream.coreOf(handler.tokenOfContent(content));
            assertEq(stream.consumedItemOf(content), itemHash, "Stream's content record");
        }
        assertFalse(handler.duplicateMinted(), "a content minted twice");
    }
}
