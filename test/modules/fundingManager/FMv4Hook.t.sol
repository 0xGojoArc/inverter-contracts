// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

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

contract FundingManagerHookTest is Test {
    using CurrencyLibrary for address;

    PoolManager public poolManager;
    FundingManagerHook public hook;
    StepLadderBondingCurveManager public bondingCurveManager;

    ERC20Mock public tokenA;
    MockMemeToken public memeToken;

    address public user = address(0x1);

    function setUp() public {
        // Deploying tokens
        tokenA = new ERC20Mock("TokenA", "LEE");
        memeToken = new MockMemeToken("MEME", "MEME");

        // Deploying PoolManager
        poolManager = new PoolManager(address(this));

        // Deploying bonding curve manager
        bondingCurveManager = new StepLadderBondingCurveManager();

        // init data for bonding manager
        bytes memory initData = abi.encode(address(tokenA), address(memeToken), 1_000_000 * 1e18);
        bondingCurveManager.init(
            IOrchestrator_v1(address(1)),
            IModule_v1.Metadata(1, 0, 0, "", "StepLadder"),
            initData
        );

        // Deploying hook
        hook = new FundingManagerHook(poolManager, IStepLadderBondingCurveManager(address(bondingCurveManager)));

        vm.label(address(tokenA), "TokenA");
        vm.label(address(memeToken), "MEME");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(bondingCurveManager), "BondingCurveManager");
        vm.label(address(hook), "FundingManagerHook");

        // Mint tokens to user
        tokenA.mint(user, 1000 ether);
    }

    function testAddLiquidity() public {
        vm.startPrank(user);
        tokenA.approve(address(poolManager), type(uint256).max);

        // the pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(memeToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.lock(
            abi.encodeCall(
                IPoolManager.modifyLiquidity,
                (
                    key,
                    ModifyLiquidityParams({
                        tickLower: -60,
                        tickUpper: 60,
                        liquidityDelta: 1 ether,
                        salt: bytes32(0)
                    }),
                    ""
                )
            )
        );

        assertEq(hook.beforeAddLiquidityCount(key.toId()), 1);
        vm.stopPrank();
    }
}
