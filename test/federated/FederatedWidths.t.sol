// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { PRODUCT_FEDERATED, ProductEconomics } from "src/interfaces/types/EconomicsTypes.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The stream template's stored widths, at values above 16 bits: a network share above
///         65,535 (governance may set any share below the denominator), and work and token
///         counters past 65,535.
contract FederatedWidthsTest is FederationBase {
    /// @dev The template's packed counters (`forge inspect FederatedStream storageLayout`):
    ///      `_workCount` in the low 4 bytes of slot 16, `_tokenCount` in the next 4.
    uint256 internal constant COUNTS_SLOT = 16;

    /// @dev A copy deployed while the federated share is 70% locks the whole share: the mint
    ///      logs it and deploys the royalty vault at it.
    function test_Mint_AShareAbove16BitsIsKeptWhole() public {
        ProductEconomics memory e = economics.economics(PRODUCT_FEDERATED);
        (uint64 revision,,) = economics.revisions(PRODUCT_FEDERATED);
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(
                economics.setFeeTerms, (PRODUCT_FEDERATED, revision, e.feeRecipient, 70_000)
            )
        );
        FederatedStream s = _deployStream(fedArtist);
        _join(address(s), fedArtist);
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        s.approveItem(_itemHash(w), RATE);
        address seller = splitFactory.walletFor(w.item.payees, 0);
        vm.expectEmit(true, true, false, true, address(s));
        emit IFederatedStream.WorkOpened(1, _itemHash(w), seller, RATE, 70_000, w.item, w.media);
        vm.expectEmit(true, true, true, true, address(s));
        emit IFederatedStream.TokenMinted(1, 1, address(auction), 70_000);
        uint256 saleId = auction.start(address(s), _mintData(w));
        uint256 tokenId = auction.auction(saleId).tokenId;
        (address receiver,) = s.royaltyInfo(tokenId, 1 ether);
        assertGt(receiver.code.length, 0, "the royalty vault at 70% is deployed");
    }

    /// @dev Past 65,535 works and tokens, the IDs are stored whole.
    function test_Mint_IdsAbove16BitsAreStoredWhole() public {
        _joinedFed();
        bytes32 word = vm.load(address(fed), bytes32(COUNTS_SLOT));
        uint256 counts = uint256(word) & ~uint256(type(uint64).max);
        counts |= uint256(0xffff) | uint256(0xffff) << 32;
        vm.store(address(fed), bytes32(COUNTS_SLOT), bytes32(counts));
        (, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        assertEq(tokenId, 65_536);
        assertEq(fed.liveTokenOf(65_536), 65_536);
        (uint256 workId,,) = fed.tokenInfo(65_536);
        assertEq(workId, 65_536);
    }
}
