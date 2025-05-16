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

// contract FundingManagerHookTest is Test {
//     using CurrencyLibrary for address;

//     PoolManager public poolManager;
//     FundingManagerHook public hook;
//     StepLadderBondingCurveManager public bondingCurveManager;

//     ERC20Mock public tokenA;
//     MockMemeToken public memeToken;

//     address public user = address(0x1);

//     function setUp() public {
//         // Deploying tokens
//         tokenA = new ERC20Mock("TokenA", "LEE");
//         memeToken = new MockMemeToken("MEME", "MEME");

//         // Deploying PoolManager
//         poolManager = new PoolManager(address(this));

//         // Deploying bonding curve manager
//         bondingCurveManager = new StepLadderBondingCurveManager();

//         // init data for bonding manager
//         bytes memory initData = abi.encode(address(tokenA), address(memeToken), 1_000_000 * 1e18);
//         bondingCurveManager.init(
//             IOrchestrator_v1(address(1)),
//             IModule_v1.Metadata(1, 0, 0, "", "StepLadder"),
//             initData
//         );

//         // Deploying hook
//         hook = new FundingManagerHook(poolManager, IStepLadderBondingCurveManager(address(bondingCurveManager)));

//         vm.label(address(tokenA), "TokenA");
//         vm.label(address(memeToken), "MEME");
//         vm.label(address(poolManager), "PoolManager");
//         vm.label(address(bondingCurveManager), "BondingCurveManager");
//         vm.label(address(hook), "FundingManagerHook");

//         // Mint tokens to user
//         tokenA.mint(user, 1000 ether);
//     }

//     function testAddLiquidity() public {
//         vm.startPrank(user);
//         tokenA.approve(address(poolManager), type(uint256).max);

//         // the pool key
//         PoolKey memory key = PoolKey({
//             currency0: Currency.wrap(address(tokenA)),
//             currency1: Currency.wrap(address(memeToken)),
//             fee: 3000,
//             tickSpacing: 60,
//             hooks: IHooks(address(hook))
//         });

//         poolManager.lock(
//             abi.encodeCall(
//                 IPoolManager.modifyLiquidity,
//                 (
//                     key,
//                     ModifyLiquidityParams({
//                         tickLower: -60,
//                         tickUpper: 60,
//                         liquidityDelta: 1 ether,
//                         salt: bytes32(0)
//                     }),
//                     ""
//                 )
//             )
//         );

//         assertEq(hook.beforeAddLiquidityCount(key.toId()), 1);
//         vm.stopPrank();
//     }
// }


contract FundingManagerHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

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

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^
                (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("FMv4Hook.sol:FMv4Hook", constructorArgs, flags);
        hook = FundingManagerHook(flags);
        // pointsToken = hook.pointsToken();

        // Create the pool
        key = PoolKey(
            Currency.wrap(address(0)),
            currency1,
            3000,
            60,
            IHooks(address(0))
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
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
}