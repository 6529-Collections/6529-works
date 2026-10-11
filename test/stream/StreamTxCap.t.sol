// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { console2 } from "forge-std/Test.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";

import { License, PackageItem, Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice Worst-case transactions against the EIP-7825 (Fusaka) cap of 16,777,216 gas. Foundry
///         pins Prague, which does not enforce the cap, so each test adds the intrinsic cost
///         (21,000 plus calldata under EIP-7623's floor pricing) to the measured execution and
///         asserts the total fits with at least 25% to spare.
contract StreamTxCapTest is RecordsFixture {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    uint256 internal constant MARGIN_CAP = (TX_GAS_CAP * 3) / 4;

    uint256[] internal partyKeys;

    /// @dev EIP-7623: `21000 + max(4 * tokens + execution, 10 * tokens)`, tokens = zero bytes
    ///      plus four per nonzero byte.
    function _txGas(bytes memory callData, uint256 execution) internal pure returns (uint256) {
        uint256 tokens;
        for (uint256 i; i < callData.length; ++i) {
            tokens += callData[i] == 0 ? 1 : 4;
        }
        uint256 standard = 4 * tokens + execution;
        uint256 floor = 10 * tokens;
        return 21_000 + (standard > floor ? standard : floor);
    }

    function _call(address target, address from, bytes memory callData, string memory label)
        internal
        returns (uint256 total)
    {
        vm.prank(from);
        uint256 before = gasleft();
        (bool ok, bytes memory reason) = target.call(callData);
        uint256 execution = before - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        total = _txGas(callData, execution);
        console2.log(label, total);
        assertLt(total, MARGIN_CAP);
    }

    /// @dev An item with 16 parties (the artist first) and 16 payees, committing to `media`.
    function _wideItem(uint256 salt, MediaFile[] memory media)
        internal
        returns (PackageItem memory item)
    {
        item = _recordsItem(salt, media);
        item.parties = new Party[](16);
        item.payees = new ISplitWallet.Payee[](16);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 6_250);
        delete partyKeys;
        partyKeys.push(artistKey);
        for (uint256 i = 1; i < 16; ++i) {
            uint256 key = 0x1000 + i;
            address account = vm.addr(key);
            artists.register(account);
            partyKeys.push(key);
            item.parties[i] = Party(account, PartyRole.COLLABORATOR);
            item.payees[i] = ISplitWallet.Payee(uint256(uint160(account)), address(0), 6_250);
        }
        item.license = License(string(_repeat("l", 64)), _registerText("long license"));
    }

    function _maxMedia(uint256 salt) internal returns (MediaFile[] memory media) {
        media = new MediaFile[](32);
        media[0] = _mediaFile(salt * 100, FileRole.PRIMARY, false);
        for (uint256 i = 1; i < 32; ++i) {
            media[i] = _mediaFile(salt * 100 + i, FileRole.AUXILIARY, false);
        }
    }

    function _repeat(bytes1 c, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = c;
        }
    }

    function test_txCap_mintWidestItem() public {
        PackageItem memory item = _wideItem(1, _single(1, false));
        bytes memory callData = abi.encodeCall(auction.start, (stream, _request(item)));
        _call(address(auction), address(this), callData, "mint, 16 parties and payees:");
    }

    function test_txCap_openRecordWorstCase() public {
        MediaFile[] memory media = _maxMedia(1);
        PackageItem memory item = _wideItem(1, media);
        uint256 tokenId = _mint(item);
        bytes memory callData = abi.encodeCall(records.openRecord, (tokenId, item, media));
        _call(address(records), outsider, callData, "openRecord, 32 files, 16 parties:");
    }

    function test_txCap_relicenseWithSixteenConsents() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _wideItem(1, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        License memory next = License(string(_repeat("m", 64)), _registerText("next text"));
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.RELICENSE,
                tokenId,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
        bytes[] memory sigs = new bytes[](16);
        for (uint256 i; i < 16; ++i) {
            sigs[i] = _sign(partyKeys[i], structHash);
        }
        bytes memory callData =
            abi.encodeCall(records.relicense, (tokenId, next, item, state, deadline, sigs));
        _call(address(records), governor, callData, "relicense, 16 consents:");
    }

    function test_txCap_addLocatorLongestUri() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = records.mediaOf(tokenId)[0].fileId;
        Locator memory locator =
            Locator(LocatorKind.IPFS, string.concat("ipfs://", string(_repeat("b", 2041))));
        bytes memory callData = abi.encodeCall(records.addLocator, (tokenId, file, locator));
        _call(address(records), platform, callData, "addLocator, 2,048-byte URI:");
    }

    function test_txCap_preferredLocatorScansSixteen() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = records.mediaOf(tokenId)[0].fileId;
        // The platform's 8 and the artist's 8: the most a file can hold.
        for (uint256 i; i < 16; ++i) {
            vm.prank(i < 8 ? platform : artist);
            records.addLocator(
                tokenId, file, Locator(LocatorKind.ARWEAVE, string.concat("ar://", vm.toString(i)))
            );
        }
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        bytes memory callData = abi.encodeCall(records.preferredLocator, (tokenId, file));
        _call(address(records), outsider, callData, "preferredLocator, 16 scanned:");
    }

    function test_txCap_syncOnChainThirtyTwoFiles() public {
        MediaFile[] memory media = _maxMedia(2);
        PackageItem memory item = _wideItem(2, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        for (uint256 i; i < 32; ++i) {
            _upload(200 + i);
        }
        bytes memory callData = abi.encodeCall(records.syncOnChain, (tokenId));
        _call(address(records), outsider, callData, "syncOnChain, 32 files:");
    }
}
