// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract InternalSwapPool is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant DONATE_THRESHOLD_MIN = 0.0001 ether;

    address public immutable nativeToken;

    struct ClaimableFees {
        uint256 amount0;
        uint256 amount1;
    }

    mapping(PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    constructor(address _poolManager, address _nativeToken) BaseHook(IPoolManager(_poolManager)) {
        nativeToken = _nativeToken;
    }

    function poolFees(PoolKey calldata _poolkey) public view returns (ClaimableFees memory) {
        return _poolFees[_poolkey.toId()];
    }

    function depositFees(PoolKey calldata _poolkey, uint256 _amount0, uint256 _amount1) public {
        _poolFees[_poolkey.toId()].amount0 += _amount0;
        _poolFees[_poolkey.toId()].amount1 += _amount1;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4 _selector, BeforeSwapDelta _beforeSwapDelta, uint24 _fee)
    {
        _selector = IHooks.beforeSwap.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4 _selector, int128 _hookDeltaUnspecified)
    {
        // Determine which currency is being swapped into the pool for fee distribution
        Currency swapFeeCurrency = params.amountSpecified < 0 == params.zeroForOne ? key.currency1 : key.currency0;

        // Calculate the swap amount for fee distribution
        int128 swapAmount = params.amountSpecified < 0 == params.zeroForOne ? delta.amount1() : delta.amount0();

        uint256 swapFee = uint256(uint128(swapAmount < 0 ? -swapAmount : swapAmount)) * 99 / 100; // 1% fee

        depositFees(key, params.zeroForOne ? swapFee : 0, !params.zeroForOne ? 0 : swapFee);

        swapFeeCurrency.take(poolManager, address(this), swapFee, false);

        // Set the hook delta to negative swap fee to indicate fees have been taken
        _hookDeltaUnspecified = -int128(int256(swapFee));

        _distributeFees(key);
        _selector = IHooks.afterSwap.selector;
    }

    function _distributeFees(PoolKey calldata _poolKey) internal {
        PoolId _poolId = _poolKey.toId();
        uint256 donateAmount = _poolFees[_poolId].amount0;

        if (donateAmount < DONATE_THRESHOLD_MIN) {
            return;
        }

        BalanceDelta delta = poolManager.donate(_poolKey, donateAmount, 0, "");

        // Wee need to ensure the delta is settled
        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }

        _poolFees[_poolId].amount0 -= donateAmount;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
