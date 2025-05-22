// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";


import {EasyPosm} from "../../../test/utils/easyPosm/EasyPosm.sol";
import {Fixtures} from "../../../test/utils/easyPosm/Fixtures.sol";

// Contracts
import {FundingManagerHook} from "src/modules/fundingManager/FMv4Hook.sol";
import {StepLadderBondingCurveManager} from "src/modules/fundingManager/StepLadderBondingCurveManager.sol";

// Interfaces
import {Currency} from "v4-core/types/Currency.sol";
import {IModule_v1} from "src/modules/base/IModule_v1.sol";
import {IOrchestrator_v1} from "src/orchestrator/interfaces/IOrchestrator_v1.sol";
import {IMemeToken} from "src/modules/fundingManager/StepLadderBondingCurveManager.sol";
import {IStepLadderBondingCurveManager} from "src/modules/fundingManager/FMv4Hook.sol";

// Mocks
import {ERC20Mock} from "test/utils/mocks/ERC20Mock.sol";
import {MockMemeToken} from "test/utils/mocks/MockMemeToken.sol";

// Interfaces
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract FundingManagerHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FundingManagerHook hook;
    // PointsToken pointsToken;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^
                (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        
        // deploy the bonding curve manager first
        StepLadderBondingCurveManager bondingCurveManager = new StepLadderBondingCurveManager();
        
        // deploy the hook with the bonding curve manager
        bytes memory constructorArgs = abi.encode(manager, bondingCurveManager);
        deployCodeTo("src/modules/fundingManager/FMv4Hook.sol:FundingManagerHook", constructorArgs, flags);
        hook = FundingManagerHook(flags);
        // pointsToken = hook.pointsToken();

        // create the pool with the hook
        key = PoolKey(
            Currency.wrap(address(0)),
            currency1,
            3000,
            60,
            IHooks(address(hook))  
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        deal(address(this), 200 ether);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint128(100e18)
            );

        (tokenId, ) = posm.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp,
            hook.getHookData(address(this))
        );
    }

    function test_poolSetup() public {
        // verify pool is initialized
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId); // gets current state of the pool
        assertGt(sqrtPriceX96, 0, "Pool not initialized - sqrtPriceX96 is zero");
        assertEq(tick, 0, "Initial tick should be 0");

        // verify pool parameters
        assertEq(uint24(key.fee), 3000, "Fee should be 3000");
        assertEq(key.tickSpacing, 60, "Tick spacing should be 60");
        
        // verify hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap, "Hook should have beforeSwap permission");
        assertTrue(permissions.beforeAddLiquidity, "Hook should have beforeAddLiquidity permission");
        assertFalse(permissions.afterInitialize, "Hook should not have afterInitialize permission");
        
        // verify bonding curve manager is set
        address bondingCurveManager = address(hook.bondingCurveManager());
        assertTrue(bondingCurveManager != address(0), "Bonding curve manager should be set");
        
        // verify hook data encoding
        address testUser = address(0x123); // create test address
        bytes memory hookData = hook.getHookData(testUser);
        (address decodedUser) = abi.decode(hookData, (address)); //get user address from hook data
        assertEq(decodedUser, testUser, "Hook data should correctly encode user address");
    }

    function test_addLiquidity() public {
        // initial hook call count
        uint256 initialAddLiquidityCount = hook.beforeAddLiquidityCount(poolId);
        
        // liquidity parameters
        int24 newTickLower = tickLower;
        int24 newTickUpper = tickUpper;
        uint128 liquidityAmount = 1e18; // 1 
        
        // required amounts for the liquidity position
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(newTickLower),
            TickMath.getSqrtPriceAtTick(newTickUpper),
            liquidityAmount
        );
        
        // approve tokens to position manager
        IERC20(Currency.unwrap(currency0)).approve(address(posm), amount0 + 1);
        IERC20(Currency.unwrap(currency1)).approve(address(posm), amount1 + 1);
        
        // add liquidity
        (uint256 newTokenId, ) = posm.mint(
            key,
            newTickLower,
            newTickUpper,
            liquidityAmount,
            amount0 + 1, // some buffer for price impact
            amount1 + 1, 
            address(this),
            block.timestamp,
            hook.getHookData(address(this))
        );
        
        // verify the position was created
        assertGt(newTokenId, 0, "New position should have a valid token ID");
        
        // verify hook was called
        uint256 newAddLiquidityCount = hook.beforeAddLiquidityCount(poolId);
        assertEq(
            newAddLiquidityCount,
            initialAddLiquidityCount + 1,
            "Hook's beforeAddLiquidity should be called once"
        );
        
        // verify position data
        uint128 actualLiquidity = posm.getPositionLiquidity(newTokenId);
        assertGt(actualLiquidity, 0, "Position should have liquidity");
    }
}
