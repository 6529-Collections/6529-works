// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { EditionAuctionStack } from "test/integration/EditionAuctionStack.sol";

/// @notice Builds the keeper tests' chain: the whole system deployed and configured by the
///         deploy library with the committed genesis (the integration fixture), one curated
///         package of two works by one artist (an edition master and an original, accepted
///         and approved), and the artist's signed start requests. Nothing is started: the
///         keeper starts both. keeper/test_keeper.py runs it with a directory to write to; in
///         a plain `forge test` run, with no directory set, it skips:
///
///             KEEPER_FIXTURE_DIR=<dir> forge test --match-path keeper/test/KeeperFixture.t.sol
///
///         It writes the chain state to `<dir>/state.json` (`vm.dumpState`, which the test loads
///         into anvil) and logs, one `KEEPER_FIXTURE <name> <json>` line each, the contract
///         addresses (`deployment`, in the deployment record's shape) and one start request
///         per work (`start0`, `start1`); the test writes those to files itself, so the fixture
///         needs no `fs_permissions`.
/// @dev Nothing is broadcast. The keys are the integration fixture's deterministic test keys;
///      none is logged.
contract KeeperFixture is EditionAuctionStack {
    /// @dev The deployment runs in the test itself, not in `setUp`: `vm.dumpState` writes the
    ///      accounts the running test touched.
    function setUp() public override { }

    function test_WriteKeeperFixture() external {
        string memory dir = vm.envOr("KEEPER_FIXTURE_DIR", string(""));
        if (bytes(dir).length == 0) vm.skip(true);
        // Real time, so the signed deadlines are valid on the anvil node that loads the state.
        vm.warp(vm.unixTime() / 1000);
        vm.roll(100);
        super.setUp();

        address artist = _actor("keeperArtist");
        Work[] memory works = new Work[](2);
        works[0] = _masterWork(artist, 0);
        works[1] = _work(artist, collectionId);
        bytes32 root = _publish(works);
        for (uint256 i; i < works.length; ++i) {
            string memory json = string.concat(
                '{"mintData":"',
                vm.toString(_mintData(root, works, i)),
                '","media":"',
                vm.toString(abi.encode(works[i].media)),
                '","proof":"',
                vm.toString(abi.encode(_proofOf(works, i))),
                '"}\n'
            );
            console2.log(string.concat("KEEPER_FIXTURE start", vm.toString(i), " ", json));
        }
        console2.log(string.concat("KEEPER_FIXTURE deployment ", _record()));
        vm.dumpState(string.concat(dir, "/state.json"));
    }

    function _record() internal view returns (string memory) {
        string[13] memory names = [
            "Stream",
            "Editions",
            "WorkRecords",
            "EnglishAuction",
            "UniformEditionAuction",
            "SaleStarter",
            "SplitFactory",
            "ClaimRouter",
            "RevenueEscrow",
            "FeeRecipientVault",
            "MuseumVault",
            "EconomicsResolver",
            "ArtistRegistry"
        ];
        address[13] memory addrs = [
            address(stream),
            address(editions),
            address(records),
            address(auction),
            address(editionAuction),
            address(deployment.saleStarter),
            address(splitFactory),
            address(claimRouter),
            address(escrow),
            networkFee,
            museum,
            address(economics),
            address(artists)
        ];
        string memory out = '{"chainId":31337,"startBlock":0,"timestamp":';
        out = string.concat(out, vm.toString(block.timestamp), ',"contracts":{');
        for (uint256 i; i < names.length; ++i) {
            out = string.concat(
                out, i == 0 ? "" : ",", '"', names[i], '":{"address":"', vm.toString(addrs[i]), '"}'
            );
        }
        return string.concat(out, "}}\n");
    }
}
