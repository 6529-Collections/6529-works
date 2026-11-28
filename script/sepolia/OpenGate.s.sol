// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Roles } from "src/governance/Roles.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { SepoliaOpenGate } from "./SepoliaOpenGate.sol";

interface IOpenGateConfigurator {
    function streamManager() external view returns (address);
}

interface IOpenGateManager {
    function network() external view returns (address);
}

/// @title OpenGate
/// @notice Plans the deployment of `SepoliaOpenGate` (a Sepolia test convenience, never for
///         mainnet) for the test instance the deployment record `FLOWS_RECORD` names, the
///         network's two role grants that open it, their revocation, and the two calls anyone
///         makes through it. It refuses every chain except Sepolia and a local development
///         chain.
/// @dev It holds no key and broadcasts nothing. Like `script/sepolia/Flows.s.sol`, every entry
///      point reads the live chain (run it with `--rpc-url`) and prints lines for the driver
///      `script/sepolia/flows.ps1` to act on: `TX <label> <from> <to> <value> <calldata>` (where
///      `<from>` is `any`, a role name, an address, or `safe:<address>` for a call a Safe makes)
///      and `INFO <key> <value>`.
///
///      The gate's address is fixed before it exists: it is created through the canonical
///      CREATE2 factory with a constant salt, so it depends only on the gate's code and on the
///      instance's curation verifier and Stream. Anyone may send the creation; the gate has no
///      owner.
contract OpenGate is Script {
    using Strings for uint256;
    using Strings for address;

    /// @notice The chain is neither Sepolia nor a local development chain.
    error NotATestChain(uint256 chainId);
    /// @notice The gate is not deployed yet (run the `gateDeploy` step first).
    error GateNotDeployed(address gate);

    /// @dev The salt of the gate's creation through the canonical CREATE2 factory (forge-std's
    ///      `CREATE2_FACTORY`, the same address as `DeployGuards.CREATE2_FACTORY`), which creates
    ///      `initCode` at `keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))` when sent
    ///      `salt ++ initCode`.
    bytes32 internal constant SALT = keccak256("6529-stream/sepolia/open-gate/1");

    struct Addrs {
        address verifier;
        address stream;
        address registry;
        address manager;
        address gate;
    }

    // ------------------------------------------------------------------ inputs

    function _addrs() internal view returns (Addrs memory a) {
        if (block.chainid != 11_155_111 && block.chainid != 31_337) {
            revert NotATestChain(block.chainid);
        }
        string memory json = vm.readFile(vm.envString("FLOWS_RECORD"));
        a.verifier = vm.parseJsonAddress(json, ".CurationVerifier");
        a.stream = vm.parseJsonAddress(json, ".Stream6529");
        a.registry = vm.parseJsonAddress(json, ".PackageRegistry");
        a.manager = IOpenGateConfigurator(vm.parseJsonAddress(json, ".GovernanceConfigurator"))
            .streamManager();
        a.gate = vm.computeCreate2Address(SALT, keccak256(_initCode(a)), CREATE2_FACTORY);
    }

    function _initCode(Addrs memory a) internal pure returns (bytes memory) {
        return
            abi.encodePacked(type(SepoliaOpenGate).creationCode, abi.encode(a.verifier, a.stream));
    }

    function _deployed(Addrs memory a) internal view returns (Addrs memory) {
        if (a.gate.code.length == 0) revert GateNotDeployed(a.gate);
        return a;
    }

    function _has(Addrs memory a, uint64 role) internal view returns (bool member) {
        (member,) = IAccessManager(a.manager).hasRole(role, a.gate);
    }

    // ------------------------------------------------------------------ output

    function _tx(string memory label, string memory from, address to, bytes memory data)
        internal
        pure
    {
        console2.log(
            string.concat("TX ", label, " ", from, " ", to.toHexString(), " 0 ", vm.toString(data))
        );
    }

    function _info(string memory key, string memory value) internal pure {
        console2.log(string.concat("INFO ", key, " ", value));
    }

    // ------------------------------------------------------------------ plans

    /// @notice The gate's address, whether it has code and which of its two roles it holds.
    function state() external view {
        Addrs memory a = _addrs();
        _info("gate", vm.toString(a.gate));
        _info("deployed", a.gate.code.length != 0 ? "true" : "false");
        _info("curationSigner", _has(a, Roles.CURATION_SIGNER) ? "true" : "false");
        _info("platform", _has(a, Roles.PLATFORM) ? "true" : "false");
        _info("network", vm.toString(IOpenGateManager(a.manager).network()));
    }

    /// @notice The gate's creation through the CREATE2 factory (anyone sends it). Prints only
    ///         the address when the gate exists already.
    function deployTx() external view {
        Addrs memory a = _addrs();
        _info("gate", vm.toString(a.gate));
        if (a.gate.code.length != 0) return;
        _tx("deployOpenGate", "any", CREATE2_FACTORY, abi.encodePacked(SALT, _initCode(a)));
    }

    /// @notice The network's two grants that open the gate: `CURATION_SIGNER` (package
    ///         approvals) and `PLATFORM` (collections), each with no execution delay. The network
    ///         is the admin of both roles with no delay, so each grant is one Safe transaction
    ///         that takes effect at once. A role the gate holds already is left out.
    function grantTx() external view {
        Addrs memory a = _deployed(_addrs());
        string memory from =
            string.concat("safe:", IOpenGateManager(a.manager).network().toHexString());
        if (!_has(a, Roles.CURATION_SIGNER)) {
            _tx(
                "grantOpenGate-curationSigner",
                from,
                a.manager,
                abi.encodeCall(IAccessManager.grantRole, (Roles.CURATION_SIGNER, a.gate, 0))
            );
        }
        if (!_has(a, Roles.PLATFORM)) {
            _tx(
                "grantOpenGate-platform",
                from,
                a.manager,
                abi.encodeCall(IAccessManager.grantRole, (Roles.PLATFORM, a.gate, 0))
            );
        }
    }

    /// @notice The network's revocations that close the gate. Packages registered through it
    ///         before stay approved; `PackageRegistry.killSignerApprovals(gate)` stops them too.
    function revokeTx() external view {
        Addrs memory a = _addrs();
        string memory from =
            string.concat("safe:", IOpenGateManager(a.manager).network().toHexString());
        if (_has(a, Roles.CURATION_SIGNER)) {
            _tx(
                "revokeOpenGate-curationSigner",
                from,
                a.manager,
                abi.encodeCall(IAccessManager.revokeRole, (Roles.CURATION_SIGNER, a.gate))
            );
        }
        if (_has(a, Roles.PLATFORM)) {
            _tx(
                "revokeOpenGate-platform",
                from,
                a.manager,
                abi.encodeCall(IAccessManager.revokeRole, (Roles.PLATFORM, a.gate))
            );
        }
    }

    /// @notice `PackageRegistry.registerPackage` of `root` with the gate's approval (anyone
    ///         sends it).
    function registerTx(bytes32 root) external view {
        Addrs memory a = _deployed(_addrs());
        (bytes32 evidence, bytes memory attestation) = SepoliaOpenGate(a.gate).attestationOf(root);
        _info("evidence", vm.toString(evidence));
        _tx(
            "registerPackage-openGate",
            "any",
            a.registry,
            abi.encodeCall(IPackageRegistry.registerPackage, (root, evidence, attestation))
        );
    }

    /// @notice `SepoliaOpenGate.createCollection` sent by `creator`. Prints the ID the collection
    ///         gets if it is the next one created.
    function collectionTx(address creator, string calldata name) external {
        Addrs memory a = _deployed(_addrs());
        bytes32 metadataHash =
            keccak256(abi.encode("6529-stream/sepolia/open-gate/collection", name));
        vm.prank(creator);
        uint256 id = SepoliaOpenGate(a.gate).createCollection(name, metadataHash);
        _info("collectionId", id.toString());
        _tx(
            "createCollection-openGate",
            creator.toHexString(),
            a.gate,
            abi.encodeCall(SepoliaOpenGate.createCollection, (name, metadataHash))
        );
    }
}
