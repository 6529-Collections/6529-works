// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";

/// @notice Economics-lane mocks: a standard ERC-20 and the hostile-token matrix (fee-on-transfer,
///         no-return, returns-false, rebasing, USDC-style blocklist, callback), an artist payout
///         resolver, and hostile recipients and claim targets.

/// @dev A plain ERC-20 that returns `true`. The base of every hostile token below.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) public virtual {
        _balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _spendAllowance(address from, uint256 amount) internal {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(_balances[from] >= amount, "balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev Burns `feeBps` of every transfer from the amount the recipient receives.
contract FeeOnTransferToken is MockERC20("Fee", "FEE") {
    uint256 public feeBps = 100;

    function setFee(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(_balances[from] >= amount, "balance");
        uint256 fee = amount * feeBps / 10_000;
        _balances[from] -= amount;
        _balances[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @dev Charges the fee to the sender on top of `amount`; the recipient gets exactly `amount`, so
///      only a sender-side delta check catches it.
contract SenderFeeToken is MockERC20("SFee", "SFEE") {
    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        require(_balances[from] >= amount + fee, "balance");
        _balances[from] -= amount + fee;
        _balances[to] += amount;
        totalSupply -= fee;
        emit Transfer(from, to, amount);
    }
}

/// @dev Moves funds and returns the non-canonical word 2 instead of `true`.
contract NonCanonicalTrueToken is MockERC20("Two", "TWO") {
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 32)
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// @dev `transfer` records the gas it was given and reverts unless that is at least `need`, so a
///      test can calibrate `need` to the full allowance and then detect any starvation.
contract GasCheckingToken is MockERC20("Gas", "GAS") {
    uint256 public need;
    uint256 public seen;

    function setNeed(uint256 need_) external {
        need = need_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 g = gasleft();
        seen = g;
        require(g >= need, "starved");
        return super.transfer(to, amount);
    }
}

/// @dev USDT-style: `transfer` and `transferFrom` move funds but return no data while `silent`.
contract NoReturnToken is MockERC20("NoReturn", "NRT") {
    bool public silent = true;

    function setSilent(bool silent_) external {
        silent = silent_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        _maybeReturnNothing();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        _maybeReturnNothing();
        return true;
    }

    function _maybeReturnNothing() private view {
        if (silent) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
    }
}

/// @dev Mode 0: standard. Mode 1: returns `false` and moves nothing. Mode 2: moves the funds but
///      returns `false` (a lying token).
contract ReturnsFalseToken is MockERC20("False", "FLS") {
    uint8 public mode = 1;

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) return false;
        _transfer(msg.sender, to, amount);
        return mode == 0;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == 1) return false;
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        return mode == 0;
    }
}

/// @dev Share-based rebasing token: balance = shares * index / 1e18. Moving an amount moves
///      `amount * 1e18 / index` shares, rounded down, so the recipient may get a little less.
contract RebasingToken is MockERC20("Rebase", "RBT") {
    uint256 public index = 1e18;

    function setIndex(uint256 index_) external {
        index = index_;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account] * index / 1e18;
    }

    function sharesOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) public override {
        _balances[to] += amount * 1e18 / index;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 shares = amount * 1e18 / index;
        require(_balances[from] >= shares, "balance");
        _balances[from] -= shares;
        _balances[to] += shares;
        emit Transfer(from, to, amount);
    }
}

/// @dev USDC-style blocklist logic, shared by the tokens that need it.
abstract contract BlocklistTokenBase is MockERC20("Blocklist", "USDB") {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual override {
        require(!blocked[from] && !blocked[to], "Blacklistable: account is blacklisted");
        super._transfer(from, to, amount);
    }
}

/// @dev USDC-style: transfers from or to a blocked address revert.
contract BlocklistToken is BlocklistTokenBase { }

/// @dev `transferFrom` never spends the allowance, so an approval survives the pull.
contract StickyAllowanceToken is BlocklistTokenBase {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _transfer(from, to, amount);
        return true;
    }
}

/// @dev `transfer` burns more gas than a payer's direct-route allowance; `transferFrom` is cheap.
contract GasHungryToken is MockERC20("Hungry", "HGT") {
    uint256 public constant BURN = 400_000;

    /// @dev Burns `BURN` gas before moving funds. Given less, it runs out of gas (no underflow:
    ///      `start - gasleft()` only grows); given more, it succeeds.
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 start = gasleft();
        while (start - gasleft() < BURN) { }
        return super.transfer(to, amount);
    }
}

/// @dev Calls `hookTarget` with `hookData` after every transfer and records the outcome, like an
///      ERC-777 hook. Used to prove reentry through a token callback is blocked.
contract CallbackToken is MockERC20("Callback", "CBT") {
    address public hookTarget;
    bytes public hookData;
    bool public lastHookOk;
    bytes public lastHookResult;

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (hookTarget != address(0)) {
            (lastHookOk, lastHookResult) = hookTarget.call(hookData);
        }
    }
}

/// @dev Artist payout resolver whose answers the test controls.
contract MockArtistResolver is IArtistPayoutResolver {
    mapping(uint256 => address) public payout;
    bool public down;

    function set(uint256 artistId, address account) external {
        payout[artistId] = account;
    }

    function setDown(bool down_) external {
        down = down_;
    }

    function payoutAddress(uint256 artistId) external view returns (address) {
        require(!down, "resolver down");
        return payout[artistId];
    }
}

/// @dev Accepts ETH only if it was given at least `need` gas, so it detects starvation.
contract GasCheckingWallet {
    uint256 public immutable need;

    constructor(uint256 need_) {
        need = need_;
    }

    receive() external payable {
        require(gasleft() >= need, "starved");
    }
}

/// @dev Force-sends ETH with SELFDESTRUCT, so no receive hook runs on the target.
contract ForceSender {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @dev Reverts on any zero-amount transfer or approval (BNB/LEND-style).
contract RevertOnZeroToken is MockERC20("Zero", "ZRO") {
    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount != 0, "zero approve");
        return super.approve(spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(amount != 0, "zero transfer");
        super._transfer(from, to, amount);
    }
}

/// @dev Rejects every ETH transfer.
contract RejectingRecipient {
    receive() external payable {
        revert("no ETH");
    }
}

/// @dev Accepts ETH only while `open`.
contract ToggleRecipient {
    bool public open;

    function setOpen(bool open_) external {
        open = open_;
    }

    receive() external payable {
        require(open, "closed");
    }
}

/// @dev On receiving ETH, calls `target` with `data` once and records the outcome. It can also act
///      as a payee's payout address: `execute` forwards arbitrary calls.
contract ReentrantRecipient {
    address public target;
    bytes public data;
    bool public entered;
    bool public lastOk;
    bytes public lastResult;

    function configure(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function execute(address to, bytes calldata payload) external returns (bytes memory) {
        (bool ok, bytes memory result) = to.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    receive() external payable {
        if (entered || target == address(0)) return;
        entered = true;
        (lastOk, lastResult) = target.call(data);
    }
}

/// @dev An ERC-1271 account that accepts exactly one digest, and can call out as a payout address.
///      With `burn` set, the check first burns up to that much gas (an expensive smart account).
contract Mock1271Account {
    bytes32 public accepted;
    uint256 public burn;

    function accept(bytes32 digest) external {
        accepted = digest;
    }

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        uint256 b = burn;
        if (b != 0) {
            uint256 stop = gasleft() > b ? gasleft() - b : 0;
            while (gasleft() > stop) { }
        }
        return digest == accepted ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function execute(address to, bytes calldata payload) external returns (bytes memory) {
        (bool ok, bytes memory result) = to.call(payload);
        require(ok, "call failed");
        return result;
    }

    receive() external payable { }
}

/// @dev A fake claim target. Mode 0 returns 77; 1 reverts with a custom error; 2 returns nothing;
///      3 returns 31 bytes; 4 returns 64 bytes; 5 returns 64 KiB; 6 reverts with 64 KiB; 7 burns
///      all gas; 8 returns a canonical zero.
contract ClaimWalletAdversary {
    uint8 public mode;
    uint256 public releaseCalls;
    address public lastAsset;
    uint256 public lastPayee;

    error WalletFailure(uint256 marker);

    function configure(uint8 mode_) external {
        mode = mode_;
    }

    fallback() external {
        require(msg.sig == ISplitWallet.release.selector, "unexpected selector");
        (lastAsset, lastPayee) = abi.decode(msg.data[4:], (address, uint256));
        ++releaseCalls;
        uint8 m = mode;
        if (m == 1) revert WalletFailure(123);
        if (m == 7) {
            assembly {
                invalid()
            }
        }
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 77)
            switch m
            case 2 { return(ptr, 0) }
            case 3 { return(ptr, 31) }
            case 4 { return(ptr, 64) }
            case 5 { return(ptr, 65536) }
            case 6 { revert(ptr, 65536) }
            case 8 { mstore(ptr, 0) }
            default { }
            return(ptr, 32)
        }
    }
}

/// @dev A payee whose receipt costs `burn` gas: a stand-in, in Prague gas, for the state gas a
///      first release creates under Glamsterdam (new slots and a new account), which Foundry
///      cannot price. Given less, it runs out of gas.
contract GasHungryPayee {
    uint256 public burn;

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    receive() external payable {
        uint256 start = gasleft();
        while (start - gasleft() < burn) { }
    }
}

/// @dev A claim target whose `release` needs `burn` gas in its own frame before it returns 1, as a
///      split wallet's first release does once its new slots cost Glamsterdam prices. Given less,
///      the wallet frame itself runs out of gas. With `failure` set, it reverts with that data
///      after burning instead of returning.
contract GasHungryWallet {
    uint256 public burn;
    uint256 public releases;
    bytes public failure;

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    function setFailure(bytes calldata failure_) external {
        failure = failure_;
    }

    function release(address, uint256) external returns (uint256) {
        uint256 start = gasleft();
        while (start - gasleft() < burn) { }
        bytes memory f = failure;
        if (f.length != 0) {
            assembly ("memory-safe") {
                revert(add(f, 0x20), mload(f))
            }
        }
        ++releases;
        return 1;
    }
}

/// @dev A fixed payee that burns all the gas it is given while `armed`, and flips cheaply.
contract ArmablePayee {
    bool public armed;

    function arm(bool armed_) external {
        armed = armed_;
    }

    receive() external payable {
        if (armed) {
            assembly {
                invalid()
            }
        }
    }
}

/// @dev On receiving ETH, re-enters the router with a two-item continue-mode batch once.
contract ClaimReentrantRecipient {
    IClaimRouter private immutable router;
    address private first;
    address private second;
    bool private entered;
    uint256 public nestedFirst;
    uint256 public nestedSecond;

    constructor(IClaimRouter router_) {
        router = router_;
    }

    function configure(address first_, address second_) external {
        first = first_;
        second = second_;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](2);
        claims[0] = IClaimRouter.Claim(first, address(0), 0);
        claims[1] = IClaimRouter.Claim(second, address(0), 0);
        uint256[] memory amounts = router.claim(claims, true);
        nestedFirst = amounts[0];
        nestedSecond = amounts[1];
    }
}
