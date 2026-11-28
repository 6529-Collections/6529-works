// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { ScriptIO } from "script/ScriptIO.sol";

/// @notice A stand-in for a Safe singleton: the answers the deploy guards ask a Safe for, kept
///         in the storage of whoever runs this code (a proxy that delegates to it). Slot 0 is
///         left to the proxy, which keeps its singleton there, as in a Safe.
contract SafeLikeSingleton {
    address internal _singleton;
    address[] internal _owners;
    uint256 internal _threshold;
    address[] internal _modules;

    function setup(address[] calldata owners, uint256 threshold) external {
        _owners = owners;
        _threshold = threshold;
    }

    function enableModule(address module) external {
        _modules.push(module);
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function getModulesPaginated(address, uint256)
        external
        view
        returns (address[] memory array, address next)
    {
        return (_modules, address(1));
    }
}

/// @notice A wallet that is not a Safe proxy and answers like one: its storage slot 0 names a
///         canonical singleton, and its owners, threshold and modules read as a bare 2-of-3
///         Safe's. Its own code decides who can act for it, here whoever deployed it.
contract LookAlikeWallet is SafeLikeSingleton {
    address public immutable hiddenOwner = msg.sender;

    constructor(address singleton, address[] memory owners, uint256 threshold) {
        _singleton = singleton;
        _owners = owners;
        _threshold = threshold;
    }

    function act(address to, bytes calldata data) external returns (bytes memory answer) {
        require(msg.sender == hiddenOwner, "not the hidden owner");
        bool ok;
        (ok, answer) = to.call(data);
        require(ok, "call failed");
    }
}

/// @notice The deploy guards accept as the network only a wallet whose own runtime code is a
///         supported Safe proxy (Safe 1.3.0 or 1.4.1), and check that before they use any of
///         the wallet's answers. The two proxies are etched here from their runtime code, so
///         the suite runs without a fork; `test/fork/SafeNetwork.t.sol` checks the same hashes
///         against proxies the canonical factories create.
contract DeployGuardsSafeTest is Test {
    /// @dev The runtime code of the proxy Safe 1.3.0's canonical factories create (171 bytes).
    bytes internal constant SAFE_130_PROXY =
        hex"608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea2646970667358221220d1429297349653a4918076d650332de1a1068c5f3e07c5c82360c277770b955264736f6c63430007060033";
    /// @dev The runtime code of the proxy Safe 1.4.1's canonical factory creates (171 bytes).
    bytes internal constant SAFE_141_PROXY =
        hex"608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033";
    string internal constant EXAMPLE = "config/genesis.core.example.json";

    /// @dev Two canonical singleton addresses, holding the stand-in singleton's code.
    address internal singleton130 = DeployGuards.SAFE_130_L1;
    address internal singleton141 = DeployGuards.SAFE_141_L1;
    address[] internal singletons;
    bytes32[] internal codehashes;
    address[] internal owners;

    function setUp() public {
        bytes memory code = address(new SafeLikeSingleton()).code;
        vm.etch(singleton130, code);
        vm.etch(singleton141, code);
        singletons.push(singleton130);
        singletons.push(singleton141);
        codehashes.push(singleton130.codehash);
        codehashes.push(singleton141.codehash);
        for (uint256 i; i < 3; ++i) {
            owners.push(makeAddr(string.concat("owner ", vm.toString(i))));
        }
    }

    // ------------------------------------------------------------------ the pinned hashes

    function test_ThePinnedHashesAreTheTwoSafeProxies() public pure {
        assertEq(SAFE_130_PROXY.length, 171);
        assertEq(SAFE_141_PROXY.length, 171);
        assertEq(keccak256(SAFE_130_PROXY), DeployGuards.SAFE_130_PROXY_CODEHASH);
        assertEq(keccak256(SAFE_141_PROXY), DeployGuards.SAFE_141_PROXY_CODEHASH);
        bytes32[] memory proxies = DeployGuards.canonicalSafeProxies();
        assertEq(proxies.length, 2);
        assertEq(proxies[0], DeployGuards.SAFE_130_PROXY_CODEHASH);
        assertEq(proxies[1], DeployGuards.SAFE_141_PROXY_CODEHASH);
    }

    /// @dev The scripts read the list through `ScriptIO.safeProxies`.
    function test_TheScriptsUseThePinnedProxies() public {
        bytes32[] memory proxies = new ProxyListHarness().safeProxies();
        assertEq(proxies.length, 2);
        assertEq(proxies[0], DeployGuards.SAFE_130_PROXY_CODEHASH);
        assertEq(proxies[1], DeployGuards.SAFE_141_PROXY_CODEHASH);
    }

    // ------------------------------------------------------------------ real proxies pass

    function test_ASafe130ProxyPassesTheHolderGuards() public {
        address safe = _proxy("safe 1.3.0", SAFE_130_PROXY, singleton130, 2);
        assertEq(safe.codehash, DeployGuards.SAFE_130_PROXY_CODEHASH);
        this.checkHoldersExternal(_genesis(safe));
    }

    function test_ASafe141ProxyPassesTheHolderGuards() public {
        address safe = _proxy("safe 1.4.1", SAFE_141_PROXY, singleton141, 2);
        assertEq(safe.codehash, DeployGuards.SAFE_141_PROXY_CODEHASH);
        this.checkHoldersExternal(_genesis(safe));
    }

    // ------------------------------------------------------------------ anything else is refused

    /// @dev A look-alike with a canonical singleton in slot 0 and a bare Safe's answers passes
    ///      every check that reads the wallet's storage or asks the wallet; its own code, which
    ///      lets a hidden owner act, is what the guard refuses.
    function test_ALookAlikeWalletIsRefusedWhateverItAnswers() public {
        address hiddenOwner = makeAddr("hidden owner");
        vm.prank(hiddenOwner);
        address wallet = address(new LookAlikeWallet(singleton141, owners, 2));
        assertEq(address(uint160(uint256(vm.load(wallet, bytes32(0))))), singleton141);
        this.requireSafeExternal(wallet);
        this.requireBareSafeExternal(wallet);
        assertEq(this.ownersOfExternal(wallet).length, 3);
        vm.prank(hiddenOwner);
        LookAlikeWallet(wallet).act(address(this), abi.encodeCall(this.ping, ()));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.NotASafeProxy.selector, "NETWORK", wallet, wallet.codehash
            )
        );
        this.checkHoldersExternal(_genesis(wallet));
    }

    /// @dev Another build of the same proxy source (one byte of its metadata differs) is not a
    ///      supported proxy.
    function test_AnotherProxyBuildIsRefused() public {
        bytes memory other = SAFE_141_PROXY;
        other[other.length - 20] = bytes1(uint8(other[other.length - 20]) ^ 0x01);
        address safe = _proxy("another build", other, singleton141, 2);
        this.requireSafeExternal(safe);
        this.requireBareSafeExternal(safe);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.NotASafeProxy.selector, "NETWORK", safe, keccak256(other)
            )
        );
        this.checkHoldersExternal(_genesis(safe));
    }

    /// @dev An address with no code (a key, or a Safe that is not deployed yet) and an EIP-7702
    ///      delegated account are refused as before, whatever the delegate is.
    function test_AnAddressWithoutCodeAndADelegatedAccountAreNotASafe() public {
        address undeployed = makeAddr("undeployed safe");
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "NETWORK", undeployed)
        );
        this.checkHoldersExternal(_genesis(undeployed));

        address safe = _proxy("delegate", SAFE_141_PROXY, singleton141, 2);
        address delegated = makeAddr("delegated account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", safe));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "NETWORK", delegated)
        );
        this.checkHoldersExternal(_genesis(delegated));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.HolderNotASafe.selector, "NETWORK", delegated)
        );
        this.requireSafeProxyExternal(delegated);
    }

    /// @dev A supported proxy is still held to the other checks: its singleton must be a
    ///      canonical one, its threshold at least two, with no module and no guard.
    function test_ASupportedProxyIsStillHeldToTheOtherChecks() public {
        address elsewhere = address(new SafeLikeSingleton());
        address safe = _proxy("other singleton", SAFE_141_PROXY, elsewhere, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGuards.NotACanonicalSafe.selector, "NETWORK", safe, elsewhere
            )
        );
        this.checkHoldersExternal(_genesis(safe));

        safe = _proxy("one of three", SAFE_141_PROXY, singleton141, 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.ThresholdTooLow.selector, "NETWORK", safe, 1)
        );
        this.checkHoldersExternal(_genesis(safe));

        safe = _proxy("with a module", SAFE_130_PROXY, singleton130, 2);
        address module = makeAddr("module");
        SafeLikeSingleton(safe).enableModule(module);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.SafeHasModules.selector, "NETWORK", safe, module)
        );
        this.checkHoldersExternal(_genesis(safe));

        safe = _proxy("with a guard", SAFE_130_PROXY, singleton130, 2);
        address guard = makeAddr("guard");
        vm.store(safe, DeployGuards.SAFE_GUARD_SLOT, bytes32(uint256(uint160(guard))));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGuards.SafeHasGuard.selector, "NETWORK", safe, guard)
        );
        this.checkHoldersExternal(_genesis(safe));
    }

    // ------------------------------------------------------------------ external wrappers

    function ping() external pure returns (bool) {
        return true;
    }

    function checkHoldersExternal(string memory json) external view {
        DeployGuards.checkHolders(
            json, vm.readFile(EXAMPLE), singletons, codehashes, DeployGuards.canonicalSafeProxies()
        );
    }

    function requireSafeProxyExternal(address account) external view {
        DeployGuards.requireSafeProxy("NETWORK", account, DeployGuards.canonicalSafeProxies());
    }

    function requireSafeExternal(address account) external view {
        DeployGuards.requireSafe("NETWORK", account);
    }

    function requireBareSafeExternal(address account) external view {
        DeployGuards.requireBareSafe("NETWORK", account, singletons, codehashes);
    }

    function ownersOfExternal(address account) external view returns (address[] memory) {
        return DeployGuards.ownersOf("NETWORK", account);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A wallet with runtime code `code` (a Safe proxy) whose slot 0 names `singleton`, set
    ///      up through its own fallback with the three owners and `threshold`.
    function _proxy(string memory label, bytes memory code, address singleton, uint256 threshold)
        internal
        returns (address safe)
    {
        safe = makeAddr(label);
        vm.etch(safe, code);
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(singleton))));
        SafeLikeSingleton(safe).setup(owners, threshold);
        assertEq(SafeLikeSingleton(safe).getThreshold(), threshold, "the proxy delegates");
    }

    /// @dev A genesis file naming `network`, three pausers' worth of holders reduced to what the
    ///      holder guards read: one pauser and two curation signers.
    function _genesis(address network) internal returns (string memory) {
        return string.concat(
            "{\"network\":\"",
            vm.toString(network),
            "\",\"holders\":[{\"role\":\"PAUSER\",\"account\":\"",
            vm.toString(makeAddr("pauser")),
            "\"},{\"role\":\"CURATION_SIGNER\",\"account\":\"",
            vm.toString(makeAddr("signer 1")),
            "\"},{\"role\":\"CURATION_SIGNER\",\"account\":\"",
            vm.toString(makeAddr("signer 2")),
            "\"}]}"
        );
    }
}

/// @notice `ScriptIO` as the scripts use it, to read its list of supported Safe proxies.
contract ProxyListHarness is ScriptIO { }
