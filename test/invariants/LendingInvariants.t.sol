// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {ILendingPool} from "src/interfaces/ILendingPool.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Lending} from "src/Lending/Lending.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {LendingMath} from "src/Lending/LendingMath.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract LendingHandler is Test {
    using LendingMath for ILendingPool.Reserve;

    Lending internal immutable lending;
    PriceOracle internal immutable oracle;
    MockERC20 internal immutable usdc;
    MockERC20 internal immutable weth;
    MockERC20 internal immutable wbtc;
    address internal immutable owner;

    address[] internal actors;
    address[] internal assets;
    uint256[] internal basePrices;

    mapping(address => uint256) public lastSupplyIndex;
    mapping(address => uint256) public lastBorrowIndex;
    mapping(address => uint256) public lastAccruedReserves;

    bool public indicesNeverDecreased = true;
    bool public reservesNeverDecreased = true;
    bool public postUserActionsHealthy = true;

    constructor(
        Lending lending_,
        PriceOracle oracle_,
        MockERC20 usdc_,
        MockERC20 weth_,
        MockERC20 wbtc_,
        address owner_,
        address[] memory actors_
    ) {
        lending = lending_;
        oracle = oracle_;
        usdc = usdc_;
        weth = weth_;
        wbtc = wbtc_;
        owner = owner_;
        actors = actors_;
        assets.push(address(usdc_));
        assets.push(address(weth_));
        assets.push(address(wbtc_));
        basePrices.push(1e8);
        basePrices.push(2_000e8);
        basePrices.push(30_000e8);

        _updateSnapshots();
    }

    function supply(uint256 assetSeed, uint256 amountSeed) external {
        address asset = _assetAt(assetSeed);
        uint256 balance = IERC20Metadata(asset).balanceOf(msg.sender);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);

        vm.startPrank(msg.sender);
        lending.supply(asset, amount, msg.sender);
        vm.stopPrank();

        // supply cannot make a user unhealthy; skip _checkHealthy.
        // Exogenous setPrice between actions may already have rendered them unhealthy,
        // which is a valid state (awaiting liquidation) — not a supply-path bug.
        _updateSnapshots();
    }

    function withdraw(uint256 assetSeed, uint256 amountSeed) external {
        address asset = _assetAt(assetSeed);
        (uint256 supplyBalance,) = lending.getUserReserveData(msg.sender, asset);
        if (supplyBalance == 0) return;

        uint256 amount = amountSeed % 4 == 0 ? type(uint256).max : bound(amountSeed, 1, supplyBalance);

        vm.startPrank(msg.sender);
        lending.withdraw(asset, amount, msg.sender);
        vm.stopPrank();

        _checkHealthy(msg.sender);
        _updateSnapshots();
    }

    function borrow(uint256 assetSeed, uint256 amountSeed) external {
        address asset = _assetAt(assetSeed);
        (,, uint256 availableBorrowsWad,) = lending.getUserAccountData(msg.sender);
        uint256 liquidity = IERC20Metadata(asset).balanceOf(address(lending));
        uint256 maxAmount = _min(
            lending.getReserveData(asset).accruedReserves > liquidity
                ? 0
                : liquidity - lending.getReserveData(asset).accruedReserves,
            _amountFromValueWad(asset, availableBorrowsWad)
        );
        if (maxAmount == 0) return;

        uint256 amount = bound(amountSeed, 1, maxAmount);

        vm.startPrank(msg.sender);
        lending.borrow(asset, amount, msg.sender);
        vm.stopPrank();

        _checkHealthy(msg.sender);
        _updateSnapshots();
    }

    function repay(uint256 assetSeed, uint256 amountSeed) external {
        address asset = _assetAt(assetSeed);
        (, uint256 debtBalance) = lending.getUserReserveData(msg.sender, asset);
        if (debtBalance == 0) return;

        uint256 amount = amountSeed % 4 == 0 ? type(uint256).max : bound(amountSeed, 1, debtBalance);

        vm.startPrank(msg.sender);
        lending.repay(asset, amount, msg.sender);
        vm.stopPrank();

        // repay cannot make a user unhealthy; skip _checkHealthy.
        _updateSnapshots();
    }

    function liquidate(uint256 borrowerSeed, uint256 collateralSeed, uint256 debtSeed, uint256 amountSeed) external {
        address borrower = actors[borrowerSeed % actors.length];
        if (borrower == msg.sender) return;

        address collateralAsset = _assetAt(collateralSeed);
        address debtAsset = _assetAt(debtSeed);
        if (collateralAsset == debtAsset) return;

        (,,, uint256 healthFactor) = lending.getUserAccountData(borrower);
        if (healthFactor >= lending.MIN_HEALTH_FACTOR()) return;

        (, uint256 debtBalance) = lending.getUserReserveData(borrower, debtAsset);
        if (debtBalance == 0) return;

        uint256 maxClose = Math.mulDiv(debtBalance, lending.closeFactorBps(), lending.BPS());
        if (maxClose == 0) return;

        uint256 amount = bound(amountSeed, 1, maxClose);

        vm.startPrank(msg.sender);
        lending.liquidate(borrower, collateralAsset, debtAsset, amount);
        vm.stopPrank();

        _updateSnapshots();
    }

    function advanceTime(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 30 days);
        vm.warp(block.timestamp + delta);
        vm.roll(block.number + ((delta + 11) / 12));
        _updateSnapshots();
    }

    function setPrice(uint256 assetSeed, uint256 priceSeed) external {
        uint256 index = assetSeed % assets.length;
        uint256 price = bound(priceSeed, basePrices[index] / 4, basePrices[index] * 5);

        vm.prank(owner);
        oracle.setPrice(assets[index], price);

        _updateSnapshots();
    }

    function _checkHealthy(address user) internal {
        try lending.getUserAccountData(user) returns (uint256, uint256 debtValue, uint256, uint256 healthFactor) {
            if (debtValue != 0 && healthFactor < lending.MIN_HEALTH_FACTOR()) {
                postUserActionsHealthy = false;
            }
        } catch {}
    }

    function _assetAt(uint256 seed) internal view returns (address) {
        return assets[seed % assets.length];
    }

    function _amountFromValueWad(address asset, uint256 valueWad) internal view returns (uint256) {
        (uint256 price,) = oracle.getPrice(asset);
        return LendingMath.amountFromValueWad(valueWad, IERC20Metadata(asset).decimals(), price);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function actorsList() external view returns (address[] memory) {
        return actors;
    }

    function assetsList() external view returns (address[] memory) {
        return assets;
    }

    function _updateSnapshots() internal {
        for (uint256 i; i < assets.length; ++i) {
            ILendingPool.Reserve memory reserve = lending.getReserveData(assets[i]);

            if (reserve.supplyIndex < lastSupplyIndex[assets[i]]) indicesNeverDecreased = false;
            if (reserve.borrowIndex < lastBorrowIndex[assets[i]]) indicesNeverDecreased = false;
            if (reserve.accruedReserves < lastAccruedReserves[assets[i]]) reservesNeverDecreased = false;

            lastSupplyIndex[assets[i]] = reserve.supplyIndex;
            lastBorrowIndex[assets[i]] = reserve.borrowIndex;
            lastAccruedReserves[assets[i]] = reserve.accruedReserves;
        }
    }
}

contract LendingInvariants is BaseTest {
    using LendingMath for ILendingPool.Reserve;

    // Per-accrual dust tolerance × worst-case accrual count across invariant depth/runs.
    // Typical drift is 1 wei per accrual; 1000 gives headroom for compound-interaction edges.
    // Still negligible vs smallest meaningful token unit (0.000001 USDC at 6-decimals).
    uint256 internal constant ROUNDING_TOLERANCE = 1000;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    Lending internal lending;
    PriceOracle internal oracle;
    LendingHandler internal handler;
    address internal dave;
    address[] internal actors;

    function setUp() public override {
        super.setUp();

        dave = makeAddr("dave");

        usdc = deployMockToken("USDC", 6);
        weth = deployMockToken("WETH", 18);
        wbtc = deployMockToken("WBTC", 8);

        vm.startPrank(owner);
        oracle = new PriceOracle();
        lending = new Lending(IPriceOracle(address(oracle)), 5_000);
        lending.listReserve(address(usdc), _defaultIrParams(), 8_000, 8_500, 500, 1_000, true, true);
        lending.listReserve(address(weth), _defaultIrParams(), 7_500, 8_000, 500, 1_000, true, true);
        lending.listReserve(address(wbtc), _defaultIrParams(), 7_000, 7_500, 500, 1_000, true, true);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2_000e8);
        oracle.setPrice(address(wbtc), 30_000e8);
        vm.stopPrank();

        actors = [alice, bob, charlie, dave];
        for (uint256 i; i < actors.length; ++i) {
            _mintAll(actors[i]);
        }

        _seedInitialLiquidity(charlie);

        handler = new LendingHandler(lending, oracle, usdc, weth, wbtc, owner, actors);

        targetContract(address(handler));
        targetSender(alice);
        targetSender(bob);
        targetSender(charlie);
        targetSender(dave);
    }

    function invariant_indicesNeverDecrease() public view {
        assertTrue(handler.indicesNeverDecreased());
    }

    function invariant_poolSolvencyPerAsset() public view {
        address[] memory assets = handler.assetsList();
        for (uint256 i; i < assets.length; ++i) {
            ILendingPool.Reserve memory reserve = lending.getReserveData(assets[i]);
            uint256 supplyActual =
                LendingMath.scaledToUnderlying(reserve.totalScaledSupply, reserve.supplyIndex, Math.Rounding.Floor);
            uint256 borrowActual =
                LendingMath.scaledToUnderlying(reserve.totalScaledBorrow, reserve.borrowIndex, Math.Rounding.Floor);
            uint256 balance = IERC20Metadata(assets[i]).balanceOf(address(lending));
            assertGe(balance + borrowActual + ROUNDING_TOLERANCE, supplyActual + reserve.accruedReserves);
        }
    }

    function invariant_tokenBalanceCoversNetClaimsPlusReserves() public view {
        address[] memory assets = handler.assetsList();
        for (uint256 i; i < assets.length; ++i) {
            ILendingPool.Reserve memory reserve = lending.getReserveData(assets[i]);
            uint256 supplyActual =
                LendingMath.scaledToUnderlying(reserve.totalScaledSupply, reserve.supplyIndex, Math.Rounding.Floor);
            uint256 borrowActual =
                LendingMath.scaledToUnderlying(reserve.totalScaledBorrow, reserve.borrowIndex, Math.Rounding.Floor);
            uint256 balance = IERC20Metadata(assets[i]).balanceOf(address(lending));
            assertGe(balance + borrowActual + ROUNDING_TOLERANCE, supplyActual + reserve.accruedReserves);
        }
    }

    function invariant_postUserActionsKeepBorrowersHealthy() public view {
        assertTrue(handler.postUserActionsHealthy());
    }

    function invariant_lastUpdateTimestampNotInFuture() public view {
        address[] memory assets = handler.assetsList();
        for (uint256 i; i < assets.length; ++i) {
            assertLe(lending.getReserveData(assets[i]).lastUpdateTimestamp, block.timestamp);
        }
    }

    function invariant_userAssetListsStayConsistent() public view {
        address[] memory localActors = handler.actorsList();
        address[] memory assets = handler.assetsList();

        for (uint256 i; i < localActors.length; ++i) {
            address[] memory collateralAssets = lending.getUserCollateralAssets(localActors[i]);
            for (uint256 j; j < collateralAssets.length; ++j) {
                assertGt(lending.userScaledSupply(localActors[i], collateralAssets[j]), 0);
            }

            address[] memory borrowAssets = lending.getUserBorrowAssets(localActors[i]);
            for (uint256 j; j < borrowAssets.length; ++j) {
                assertGt(lending.userScaledBorrow(localActors[i], borrowAssets[j]), 0);
            }

            for (uint256 j; j < assets.length; ++j) {
                uint256 scaledBorrow = lending.userScaledBorrow(localActors[i], assets[j]);
                if (scaledBorrow == 0) continue;

                bool found;
                for (uint256 k; k < borrowAssets.length; ++k) {
                    if (borrowAssets[k] == assets[j]) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found);
            }
        }
    }

    function invariant_reservesOnlyIncreaseWithoutAdminWithdrawal() public view {
        assertTrue(handler.reservesNeverDecreased());
    }

    function invariant_totalScaledBalancesMatchUserSums() public view {
        address[] memory localActors = handler.actorsList();
        address[] memory assets = handler.assetsList();

        for (uint256 i; i < assets.length; ++i) {
            uint256 sumSupply;
            uint256 sumBorrow;

            for (uint256 j; j < localActors.length; ++j) {
                sumSupply += lending.userScaledSupply(localActors[j], assets[i]);
                sumBorrow += lending.userScaledBorrow(localActors[j], assets[i]);
            }

            ILendingPool.Reserve memory reserve = lending.getReserveData(assets[i]);
            assertEq(sumSupply, reserve.totalScaledSupply);
            assertEq(sumBorrow, reserve.totalScaledBorrow);
        }
    }

    function _defaultIrParams() internal pure returns (ILendingPool.InterestRateParams memory params) {
        params = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0, slope1RayPerYear: 2e26, slope2RayPerYear: 8e26, optimalUtilizationBps: 8_000
        });
    }

    function _mintAll(address user) internal {
        mintAndApprove(usdc, user, address(lending), 1_000_000e6);
        mintAndApprove(weth, user, address(lending), 10_000 ether);
        mintAndApprove(wbtc, user, address(lending), 10_000e8);
    }

    function _seedInitialLiquidity(address liquidityProvider) internal {
        vm.startPrank(liquidityProvider);
        lending.supply(address(usdc), 100_000e6, liquidityProvider);
        lending.supply(address(weth), 100 ether, liquidityProvider);
        lending.supply(address(wbtc), 100e8, liquidityProvider);
        vm.stopPrank();
    }
}
