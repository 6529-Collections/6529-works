// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { DeployCore } from "script/DeployCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    MoveAuthorization,
    Party,
    PartyAcceptance,
    PartyRole,
    PackageItem,
    SaleTerms,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { DelegationManagementMock } from "test/mocks/identity/DelegationManagementMock.sol";

/// @notice Builds the keeper tests' chain: the whole plain-core stack deployed and configured by
///         the deploy library (`script/DeployCore.sol`) with the committed genesis policy, the
///         network accepted, one curation signer granted, collection 1 created, and one curated
///         package of two works by one artist (an edition master and an original), registered
///         and accepted, with the artist's signed start requests. Nothing is started: the keeper
///         starts both. keeper/test_keeper.py runs it with a directory to write to; in a plain
///         `forge test` run, with no directory set, it skips:
///
///             KEEPER_FIXTURE_DIR=<dir> forge test --match-path keeper/test/KeeperFixture.t.sol
///
///         It writes the chain state to `<dir>/state.json` (`vm.dumpState`, which the test loads
///         into anvil) and logs, one `KEEPER_FIXTURE <name> <json>` line each, the contract
///         addresses (`deployment`, in the deployment record's shape), one start request per
///         work (`start0`, `start1`) and the second work's media chunk (`chunk1`), which the
///         fixture leaves unwritten so the test can show the keeper waiting for it. Each work's
///         descriptive record is a stored JSON file, so a finalize can pin it.
/// @dev Nothing is broadcast. The network is anvil's account 8, so a test can act as the network
///      with the node's own key; the artist and the curation signer are deterministic test keys,
///      none logged.
contract KeeperFixture is Test {
    string internal constant GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";
    /// @dev Anvil's default account 8.
    address internal constant NETWORK = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f;
    /// @dev The genesis file's platform key (it may create collections).
    address internal constant PLATFORM = address(0xb051);
    uint256 internal constant SIGNER_KEY = 0x5161;
    uint256 internal constant ARTIST_KEY = 0xA7157;

    DeployCore.Deployment internal d;

    function test_WriteKeeperFixture() external {
        string memory dir = vm.envOr("KEEPER_FIXTURE_DIR", string(""));
        if (bytes(dir).length == 0) vm.skip(true);
        // Real time, so the signed deadlines are valid on the anvil node that loads the state.
        vm.warp(vm.unixTime() / 1000);
        vm.roll(100);
        _deploy();

        address artist = vm.addr(ARTIST_KEY);
        bytes[2] memory data = [bytes("keeper work 0: an edition master"), "keeper work 1"];
        PackageItem[] memory items = new PackageItem[](2);
        MediaFile[][] memory media = new MediaFile[][](2);
        for (uint256 i; i < 2; ++i) {
            media[i] = _media(data[i], i == 0);
            items[i] = _item(artist, media[i], i == 0);
        }
        bytes32[2] memory leaves = [_leaf(items[0]), _leaf(items[1])];
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encode(leaves[0], leaves[1]))
            : keccak256(abi.encode(leaves[1], leaves[0]));
        _register(root, artist);
        for (uint256 i; i < 2; ++i) {
            bytes32[] memory proof = new bytes32[](1);
            proof[0] = leaves[1 - i];
            bytes memory mintData = _mintData(root, items[i], proof, i);
            console2.log(
                string.concat(
                    "KEEPER_FIXTURE start",
                    vm.toString(i),
                    ' {"mintData":"',
                    vm.toString(mintData),
                    '","media":"',
                    vm.toString(abi.encode(media[i])),
                    '","proof":"',
                    vm.toString(abi.encode(proof)),
                    '"}'
                )
            );
        }
        console2.log(string.concat('KEEPER_FIXTURE chunk1 {"data":"', vm.toString(data[1]), '"}'));
        console2.log(string.concat("KEEPER_FIXTURE deployment ", _record()));
        vm.dumpState(string.concat(dir, "/state.json"));
    }

    function _deploy() internal {
        DeployCore.Params memory p;
        p.deployer = makeAddr("deployer");
        p.namespace = keccak256("6529-works/keeper-fixture");
        p.feeRecipient = makeAddr("feeRecipient");
        p.museum = makeAddr("museum");
        p.marketOwner = makeAddr("marketOwner");
        p.delegation = address(new DelegationManagementMock());
        p.cc0Text = vm.readFileBinary(CC0_FIXTURE);
        p.ethIncrementFloor = 0.001 ether;
        p.auctionConfig = DeployCore.auctionConfig();
        p.editionAuctionConfig = DeployCore.editionAuctionConfig();
        d = DeployCore.deploy(p, address(this));
        string memory json = vm.readFile(GENESIS);
        DeployCore.Manifest memory manifest =
            DeployCore.Manifest(keccak256("keeper fixture manifest"), "ar://keeper-fixture");
        GovernanceConfig.Config memory cfg = DeployCore.config(d, json);
        cfg.network = NETWORK;
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(d, json, manifest);
        vm.prank(p.deployer);
        DeployCore.install(d, cfg, manifest, calls);
        vm.startPrank(NETWORK);
        d.manager.acceptNetwork();
        d.manager.grantRole(Roles.CURATION_SIGNER, vm.addr(SIGNER_KEY), 0);
        vm.stopPrank();
        vm.prank(PLATFORM);
        d.stream.createCollection("Keeper fixture", keccak256("keeper fixture collection"));
    }

    /// @dev One media file holding `data`, registered in the content store; its chunk is written
    ///      only when `write` is set.
    function _media(bytes memory data, bool write) internal returns (MediaFile[] memory media) {
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = keccak256(data);
        if (write) d.contentStore.writeChunk(data);
        bytes32 digest = sha256(data);
        bytes32 fileId =
            d.contentStore.registerManifest(chunks, data.length, 0, "text/plain", digest);
        media = new MediaFile[](1);
        media[0] = MediaFile(fileId, digest, 0);
    }

    /// @dev The work's descriptive record: a one-chunk JSON file, written and registered.
    function _recordFile(bytes32 contentHash) internal returns (bytes32) {
        bytes memory data =
            abi.encodePacked('{"name":"keeper work ', vm.toString(contentHash), '"}');
        bytes32[] memory chunks = new bytes32[](1);
        (chunks[0],) = d.contentStore.writeChunk(data);
        return
            d.contentStore
            .registerManifest(chunks, data.length, 0, "application/json", sha256(data));
    }

    function _item(address artist, MediaFile[] memory media, bool master)
        internal
        returns (PackageItem memory i)
    {
        i.kind = uint8(master ? ItemKind.EDITION_MASTER : ItemKind.ORIGINAL);
        i.collectionId = 1;
        i.contentHash = media[0].sha256Hash;
        i.mediaHash = WorksHashing.mediaHash(media);
        i.recordFileId = _recordFile(media[0].sha256Hash);
        i.parties = new Party[](1);
        i.parties[0] = Party(artist, uint8(PartyRole.ARTIST));
        i.payees = new ISplitWallet.Payee[](1);
        i.payees[0] = ISplitWallet.Payee(uint160(artist), address(0), 100_000);
        i.license = License("CC0-1.0", d.workFacts.cc0TextFileId());
        i.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, address(0), "");
        if (master) i.edition = EditionTerms(0, address(0), SaleKind.UNIFORM_AUCTION, "");
    }

    function _leaf(PackageItem memory item) internal pure returns (bytes32) {
        return WorksHashing.leaf(WorksHashing.itemHash(item));
    }

    /// @dev The curation signer approves `root`; the artist accepts it (creating its identity).
    function _register(bytes32 root, address artist) internal {
        ICurationDigests verifier = ICurationDigests(d.curationVerifier);
        address signer = vm.addr(SIGNER_KEY);
        bytes32 evidence = keccak256("keeper fixture evidence");
        bytes32 digest = verifier.approvalDigest(root, evidence, verifier.signerEpoch(signer));
        IRegistry registry = IRegistry(d.packageRegistry);
        registry.registerPackage(root, evidence, abi.encode(signer, _sig(SIGNER_KEY, digest)));
        PartyAcceptance memory a = PartyAcceptance(
            artist, keccak256("keeper artist profile"), 0, uint64(block.timestamp + 1 days)
        );
        bytes memory proof =
            abi.encodePacked(artist, _sig(ARTIST_KEY, registry.acceptanceDigest(root, a)));
        registry.acceptPackage(root, a, proof);
    }

    function _mintData(bytes32 root, PackageItem memory item, bytes32[] memory proof, uint256 n)
        internal
        view
        returns (bytes memory)
    {
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32 digest =
            IRegistry(d.packageRegistry).moveDigest(root, WorksHashing.itemHash(item), n, deadline);
        bytes memory signature = abi.encodePacked(vm.addr(ARTIST_KEY), _sig(ARTIST_KEY, digest));
        return abi.encode(
            StreamMintRequest(root, item, proof, MoveAuthorization(n, deadline, signature))
        );
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The deployment record in the shape `script/DeployCore.s.sol` writes, plus the start
    ///      block and time the test needs.
    function _record() internal view returns (string memory out) {
        DeployCore.Params memory p;
        string[] memory list = DeployCore.order(p);
        out = string.concat(
            '{"chainId":31337,"startBlock":0,"timestamp":', vm.toString(block.timestamp)
        );
        out = string.concat(out, ',"Network":"', vm.toString(NETWORK), '"');
        for (uint256 i; i < list.length; ++i) {
            out = string.concat(
                out, ',"', list[i], '":"', vm.toString(DeployCore.addressOf(d, list[i])), '"'
            );
        }
        out = string.concat(out, "}");
    }
}

interface ICurationDigests {
    function signerEpoch(address signer) external view returns (uint256);
    function approvalDigest(bytes32 packageRoot, bytes32 evidenceHash, uint256 signerEpoch_)
        external
        view
        returns (bytes32);
}

interface IRegistry {
    function registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes calldata attestation)
        external;
    function acceptPackage(
        bytes32 packageRoot,
        PartyAcceptance calldata acceptance,
        bytes calldata proof
    ) external returns (uint256);
    function acceptanceDigest(bytes32 packageRoot, PartyAcceptance calldata acceptance)
        external
        view
        returns (bytes32);
    function moveDigest(bytes32 packageRoot, bytes32 itemHash, uint256 nonce, uint64 deadline)
        external
        view
        returns (bytes32);
}
