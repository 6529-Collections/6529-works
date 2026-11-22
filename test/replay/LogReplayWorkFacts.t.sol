// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Stream } from "src/core/Stream.sol";
import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { CodeRenderer } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "../records/RulesFixture.sol";
import { WorkFactsIndexer } from "./WorkFactsIndexer.sol";

/// @notice Every `WorkFacts` record, rebuilt from the contract's logs alone, equals what the
///         contract answers: opens, record and license changes, finalize, repins, locks and
///         on-chain completion, across two token contracts.
contract LogReplayWorkFactsTest is RulesFixture {
    WorkFactsIndexer internal indexer;
    address[] internal tokens;
    uint256[] internal ids;

    function setUp() public override {
        super.setUp();
        indexer = new WorkFactsIndexer(address(facts));
        vm.recordLogs();
    }

    function _track(Stream token, uint256 id) internal {
        tokens.push(address(token));
        ids.push(id);
    }

    function _replayAndCompare() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        indexer.apply_(logs);
        for (uint256 i; i < ids.length; ++i) {
            Facts memory chain = facts.factsOf(tokens[i], ids[i]);
            Facts memory rebuilt = indexer.factsOf(tokens[i], ids[i]);
            assertEq(keccak256(abi.encode(rebuilt)), keccak256(abi.encode(chain)), "replay");
        }
    }

    function test_Replay_EveryFactFromLogsAlone() public {
        // Two works on the pass-through token, one finalized, repinned and locked.
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, true);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", mitText);
        uint256 a = _mintItem(bare, item);
        facts.open(address(bare), a, item, media);
        _track(bare, a);
        records.setRecord(address(bare), a, _record(10));
        records.setLicense(address(bare), a, License("CC-BY-4.0", mitText));
        facts.markOnChainComplete(address(bare), a);
        records.lock(address(bare), a, true, false);
        records.finalize(address(bare), a);
        records.repin(address(bare), a, address(new CodeRenderer(1)));
        records.lock(address(bare), a, false, true);

        (uint256 b,,) = _work(bare, 3);
        _track(bare, b);
        records.setLicense(address(bare), b, License("cc0-1.0", cc0Text));

        // A work on the stream with the real modules, and an unopened one.
        (uint256 c,,) = _work(stream, 4);
        _track(stream, c);
        bytes32 state = _state(c);
        vm.prank(artist);
        rules.finalize(address(stream), c, state);
        uint256 d = _mintItem(stream, _item(5, _single(5)));
        _track(stream, d);

        _replayAndCompare();
    }

    /// @dev Any sequence of the module's calls replays exactly.
    function testFuzz_Replay_AnySequence(uint256 seed) public {
        (uint256 id,,) = _work(bare, 1);
        _track(bare, id);
        address[2] memory pins = [address(new CodeRenderer(1)), address(renderer)];
        License[3] memory licenses =
            [_cc0(), License("cc0-1.0", cc0Text), License("CC0-1.0", mitText)];
        for (uint256 i; i < 12; ++i) {
            uint256 op = uint256(keccak256(abi.encode(seed, i))) % 6;
            if (op == 0) try records.setRecord(address(bare), id, bytes32(i)) { } catch { }
            if (op == 1) try records.setLicense(address(bare), id, licenses[i % 3]) { } catch { }
            if (op == 2) try records.finalize(address(bare), id) { } catch { }
            if (op == 3) try records.repin(address(bare), id, pins[i % 2]) { } catch { }
            if (op == 4) try records.lock(address(bare), id, i % 2 == 0, i % 3 == 0) { } catch { }
            if (op == 5) try facts.markOnChainComplete(address(bare), id) { } catch { }
        }
        _replayAndCompare();
    }
}
