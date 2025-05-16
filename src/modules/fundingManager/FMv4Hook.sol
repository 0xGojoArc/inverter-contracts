// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

interface IStepLadderBondingCurveManager {
    function beforeSwapHook(address sender, uint256 amountIn) external;
    function beforeAddLiquidityHook(address sender, uint256 amountIn) external;
}

contract FundingManagerHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    IStepLadderBondingCurveManager public immutable bondingCurveManager;

    mapping(PoolId => uint256) public beforeSwapCount;

    mapping(PoolId => uint256) public beforeAddLiquidityCount;

    constructor(
        IPoolManager _poolManager,
        IStepLadderBondingCurveManager _bondingCurveManager
    ) BaseHook(_poolManager) {
        bondingCurveManager = _bondingCurveManager;
    }

    /// @notice Returns the hook permission bitmap this contract uses.
    /// @dev This is not part of IHooks, so do NOT tag with `override`.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountIn = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : 0;
        bondingCurveManager.beforeSwapHook(sender, amountIn);
        beforeSwapCount[key.toId()]++;
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata /*params*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4) {
        bondingCurveManager.beforeAddLiquidityHook(sender, 0); //replace with params
        beforeAddLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    function getHookData(address user) public pure returns (bytes memory) {
        return abi.encode(user);
    }
}
