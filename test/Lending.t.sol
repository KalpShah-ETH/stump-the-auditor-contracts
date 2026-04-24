// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILendingPool} from "src/interfaces/ILendingPool.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Lending} from "src/Lending/Lending.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract LendingFeeOnTransferERC20 is ERC20, Ownable {
    uint256 internal constant BPS = 10_000;

    uint8 private immutable _DECIMALS;
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _DECIMALS = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);

        uint256 fee = amount * feeBps / BPS;
        uint256 received = amount - fee;
        _transfer(from, to, received);
        if (fee != 0) _transfer(from, address(this), fee);

        return true;
    }
}

contract LendingReentrantERC20 is ERC20, Ownable {
    enum HookType {
        None,
        Transfer,
        TransferFrom
    }

    uint8 private immutable _DECIMALS;
    HookType public hookType;
    address public target;
    bytes public payload;
    bool private entered;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function setHook(HookType hookType_, address target_, bytes calldata payload_) external onlyOwner {
        hookType = hookType_;
        target = target_;
        payload = payload_;
    }

    function clearHook() external onlyOwner {
        hookType = HookType.None;
        target = address(0);
        delete payload;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _maybeReenter(HookType.Transfer);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _maybeReenter(HookType.TransferFrom);
        return success;
    }

    function _maybeReenter(HookType expectedHook) internal {
        if (entered || hookType != expectedHook || target == address(0)) return;

        entered = true;
        (bool success, bytes memory reason) = target.call(payload);
        entered = false;

        if (!success) {
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

contract LendingTest is BaseTest {
    event ReserveListed(
        address indexed asset,
        uint8 decimals,
        uint16 collateralFactorBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 reserveFactorBps
    );
    event ReserveParamsUpdated(
        address indexed asset,
        uint16 collateralFactorBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 reserveFactorBps
    );
    event InterestRateParamsUpdated(
        address indexed asset, uint128 baseRate, uint128 slope1, uint128 slope2, uint64 optimalUtilBps
    );
    event BorrowEnabled(address indexed asset, bool enabled);
    event CollateralEnabled(address indexed asset, bool enabled);
    event Supplied(address indexed user, address indexed asset, uint256 amount, uint256 scaledAmount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount, uint256 scaledAmount);
    event Borrowed(address indexed user, address indexed asset, uint256 amount, uint256 scaledAmount);
    event Repaid(
        address indexed user, address indexed asset, uint256 amount, uint256 scaledAmount, address indexed payer
    );
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        address indexed collateralAsset,
        address debtAsset,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 liquidatorBonus
    );
    event IndexUpdated(address indexed asset, uint256 supplyIndex, uint256 borrowIndex, uint256 reserveAccruedDelta);
    event OracleUpdated(address indexed oracle);
    event CloseFactorUpdated(uint256 bps);
    event ReservesWithdrawn(address indexed asset, uint256 amount, address indexed to);
    event Paused(address account);
    event Unpaused(address account);

    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant WETH_PRICE = 2_000e8;
    uint256 internal constant WBTC_PRICE = 30_000e8;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    Lending internal lending;
    PriceOracle internal oracle;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);
        weth = deployMockToken("WETH", 18);
        wbtc = deployMockToken("WBTC", 8);

        vm.startPrank(owner);
        oracle = new PriceOracle();
        lending = new Lending(IPriceOracle(address(oracle)), 5_000);

        _listReserve(address(usdc), 8_000, 8_500, 500, 1_000, true, true);
        _listReserve(address(weth), 7_500, 8_000, 500, 1_000, true, true);
        _listReserve(address(wbtc), 7_000, 7_500, 500, 1_000, true, true);

        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);
        oracle.setPrice(address(wbtc), WBTC_PRICE);
        vm.stopPrank();

        _mintAll(alice);
        _mintAll(bob);
        _mintAll(charlie);
    }

    function testHappyPathSupplyBorrowAccrueRepay() public {
        _supply(alice, usdc, 1_000e6, alice);

        vm.expectEmit(true, true, false, true);
        emit Supplied(bob, address(weth), 1 ether, 1 ether);
        _supply(bob, weth, 1 ether, bob);

        vm.expectEmit(true, true, false, true);
        emit Borrowed(bob, address(usdc), 500e6, 500e6);
        _borrow(bob, usdc, 500e6, bob);

        (
            uint256 totalCollateralValueWad,
            uint256 totalDebtValueWad,
            uint256 availableBorrowsWad,
            uint256 healthFactor
        ) = lending.getUserAccountData(bob);
        assertEq(totalCollateralValueWad, 2_000e18);
        assertEq(totalDebtValueWad, 500e18);
        assertEq(availableBorrowsWad, 1_000e18);
        assertApproxEqAbs(healthFactor, 3.2e18, 1);

        advanceSeconds(30 days);

        (uint256 aliceSupplyBalance,) = lending.getUserReserveData(alice, address(usdc));
        (, uint256 bobBorrowBalance) = lending.getUserReserveData(bob, address(usdc));
        assertGt(aliceSupplyBalance, 1_000e6);
        assertGt(bobBorrowBalance, 500e6);

        vm.expectEmit(true, true, false, true);
        emit Repaid(bob, address(usdc), bobBorrowBalance, lending.userScaledBorrow(bob, address(usdc)), bob);
        _repay(bob, usdc, type(uint256).max, bob);

        address[] memory borrowAssets = lending.getUserBorrowAssets(bob);
        assertEq(borrowAssets.length, 0);
        (, uint256 remainingDebt) = lending.getUserReserveData(bob, address(usdc));
        assertEq(remainingDebt, 0);
    }

    function testLiquidationTransfersCollateralAsSupplyPosition() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 1_200e8);

        uint256 charlieUsdcBefore = usdc.balanceOf(charlie);
        uint256 charlieScaledBefore = lending.userScaledSupply(charlie, address(weth));

        vm.expectEmit(true, true, true, false);
        emit Liquidated(bob, charlie, address(weth), address(usdc), 500e6, 0, 0);
        vm.prank(charlie);
        (uint256 debtRepaid, uint256 collateralSeized) = lending.liquidate(bob, address(weth), address(usdc), 500e6);

        assertEq(debtRepaid, 500e6);
        assertEq(usdc.balanceOf(charlie), charlieUsdcBefore - debtRepaid);
        assertEq(weth.balanceOf(charlie), 10_000 ether);
        assertGt(collateralSeized, 0);
        assertGt(lending.userScaledSupply(charlie, address(weth)), charlieScaledBefore);

        (, uint256 bobDebtAfter) = lending.getUserReserveData(bob, address(usdc));
        (uint256 bobCollateralAfter,) = lending.getUserReserveData(bob, address(weth));
        assertLt(bobDebtAfter, 1_000e6);
        assertLt(bobCollateralAfter, 1 ether);
    }

    function testOracleFreeWithdrawSucceedsWhenPriceStale() public {
        _supply(alice, usdc, 500e6, alice);

        advanceSeconds(lending.MAX_ORACLE_STALENESS() + 1);

        vm.prank(alice);
        uint256 withdrawn = lending.withdraw(address(usdc), type(uint256).max, alice);

        assertEq(withdrawn, 500e6);
        (uint256 supplyBalance,) = lending.getUserReserveData(alice, address(usdc));
        assertEq(supplyBalance, 0);
    }

    function testWithdrawAllowsHealthyAccountAboveBorrowCapacity() public {
        vm.prank(owner);
        lending.setCollateralEnabled(address(wbtc), false);

        _supply(alice, usdc, 5_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_100e6, bob);
        _supply(bob, wbtc, 1e8, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 1_400e8);

        (,,, uint256 healthFactor) = lending.getUserAccountData(bob);
        assertGt(healthFactor, lending.MIN_HEALTH_FACTOR());

        vm.prank(bob);
        uint256 withdrawn = lending.withdraw(address(wbtc), 1e8, bob);

        assertEq(withdrawn, 1e8);
    }

    function testCollateralDisableDoesNotRemoveExistingCollateralFromHealthFactor() public {
        _supply(bob, usdc, 2_000e6, bob);
        _supply(alice, weth, 1 ether, alice);
        _borrow(alice, usdc, 1_000e6, alice);

        (,,, uint256 healthFactorBefore) = lending.getUserAccountData(alice);
        assertGt(healthFactorBefore, lending.MIN_HEALTH_FACTOR());
        assertTrue(_contains(lending.getUserCollateralAssets(alice), address(weth)));

        vm.prank(owner);
        lending.setCollateralEnabled(address(weth), false);

        (,,, uint256 healthFactorAfter) = lending.getUserAccountData(alice);
        assertEq(healthFactorAfter, healthFactorBefore);
        assertGt(healthFactorAfter, lending.MIN_HEALTH_FACTOR());
        assertTrue(_contains(lending.getUserCollateralAssets(alice), address(weth)));

        vm.expectRevert(abi.encodeWithSelector(ILendingPool.HealthFactorNotBelowThreshold.selector, healthFactorAfter));
        vm.prank(charlie);
        lending.liquidate(alice, address(weth), address(usdc), 500e6);

        _repay(alice, usdc, type(uint256).max, alice);
        _withdraw(alice, weth, type(uint256).max, alice);

        (uint256 supplyBalance,) = lending.getUserReserveData(alice, address(weth));
        (, uint256 borrowBalance) = lending.getUserReserveData(alice, address(usdc));
        assertEq(supplyBalance, 0);
        assertEq(borrowBalance, 0);
    }

    function testSupplyWhileCollateralDisabledDoesNotRegisterCollateralAsset() public {
        vm.prank(owner);
        lending.setCollateralEnabled(address(wbtc), false);

        _supply(alice, wbtc, 1e8, alice);

        address[] memory collateralAssets = lending.getUserCollateralAssets(alice);
        assertEq(collateralAssets.length, 0);
        assertFalse(_contains(collateralAssets, address(wbtc)));
    }

    function testPartialLiquidationAtFullCloseFactorLeavesBorrowerHealthy() public {
        vm.prank(owner);
        lending.setCloseFactor(10_000);

        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 1_125e8);

        (,,, uint256 healthFactorBefore) = lending.getUserAccountData(bob);
        assertApproxEqAbs(healthFactorBefore, 0.9e18, 5);

        vm.prank(charlie);
        lending.liquidate(bob, address(weth), address(usdc), 1_000e6);

        (, uint256 debtAfter,, uint256 healthFactorAfter) = lending.getUserAccountData(bob);
        assertEq(debtAfter, 0);
        assertEq(healthFactorAfter, type(uint256).max);
    }

    function testLiquidationRevertsWhenCollateralIsLessThanSeizeAmount() public {
        vm.prank(owner);
        lending.setCloseFactor(10_000);

        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_400e6, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 1_000e8);

        (uint256 bobCollateralBefore,) = lending.getUserReserveData(bob, address(weth));

        vm.expectRevert(
            abi.encodeWithSelector(ILendingPool.InsufficientSupply.selector, address(weth), 1.47 ether, 1 ether)
        );
        vm.prank(charlie);
        lending.liquidate(bob, address(weth), address(usdc), 1_400e6);

        (uint256 bobCollateralAfter,) = lending.getUserReserveData(bob, address(weth));
        assertEq(bobCollateralAfter, bobCollateralBefore);
    }

    function testFragmentedLiquidationDoesNotCompoundCollateralRounding() public {
        address dave = makeAddr("dave");
        MockERC20 usd6 = deployMockToken("USD6", 6);

        vm.startPrank(owner);
        lending.setCloseFactor(10_000);
        _listReserve(address(usd6), 8_000, 8_500, 1_000, 1_000, true, true);
        oracle.setPrice(address(usd6), 1e8);
        usd6.mint(bob, 3_000);
        usd6.mint(dave, 3_000);
        vm.stopPrank();

        vm.prank(bob);
        usd6.approve(address(lending), type(uint256).max);
        vm.prank(dave);
        usd6.approve(address(lending), type(uint256).max);

        _supply(alice, usdc, 10_000e6, alice);
        vm.prank(bob);
        lending.supply(address(usd6), 3_000, bob);
        _borrow(bob, usdc, 2_000, bob);
        vm.prank(dave);
        lending.supply(address(usd6), 3_000, dave);
        _borrow(dave, usdc, 2_000, dave);

        vm.prank(owner);
        oracle.setPrice(address(usd6), 0.5e8);

        uint256 fragmentedSeized;
        for (uint256 i; i < 1_000; ++i) {
            vm.prank(charlie);
            (, uint256 seized) = lending.liquidate(bob, address(usd6), address(usdc), 1);
            fragmentedSeized += seized;
        }

        vm.prank(charlie);
        (, uint256 singleSeized) = lending.liquidate(dave, address(usd6), address(usdc), 1_000);

        assertLe(fragmentedSeized, singleSeized + 1);
    }

    function testLiquidationDustSeizeClosesTinyCollateralPosition() public {
        vm.prank(owner);
        lending.setCloseFactor(10_000);

        _supply(alice, weth, 1 ether, alice);
        _supply(bob, usdc, 1, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 9_000e8);
        _borrow(bob, weth, 1, bob);

        vm.prank(owner);
        oracle.setPrice(address(usdc), 1);

        vm.prank(charlie);
        (uint256 repaid, uint256 seized) = lending.liquidate(bob, address(usdc), address(weth), 1);

        assertEq(repaid, 1);
        assertEq(seized, 1);
        (uint256 bobCollateralAfter, uint256 bobDebtAfter) = lending.getUserReserveData(bob, address(usdc));
        assertEq(bobCollateralAfter, 0);
        assertEq(bobDebtAfter, 0);
        assertFalse(_contains(lending.getUserCollateralAssets(bob), address(usdc)));
        assertEq(lending.userScaledSupply(charlie, address(usdc)), 1);
    }

    function testDustDebtCanLiquidateWhenCloseFactorWouldRoundToZeroScaledDebt() public {
        _supply(alice, weth, 1, alice);
        _supply(bob, usdc, 1, bob);
        _borrow(bob, weth, 1, bob);

        advanceSeconds(365 days);
        lending.accrueInterest(address(weth));

        vm.prank(owner);
        oracle.setPrice(address(weth), 9_000e8);
        vm.prank(owner);
        oracle.setPrice(address(usdc), 1);

        vm.prank(charlie);
        (uint256 repaid, uint256 seized) = lending.liquidate(bob, address(usdc), address(weth), 2);

        assertEq(repaid, 2);
        assertEq(seized, 1);
        (, uint256 remainingDebt) = lending.getUserReserveData(bob, address(weth));
        assertEq(remainingDebt, 0);
    }

    function testInterestMathOverOneYearAtHalfUtilizationWithinTolerance() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 2 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        uint256 supplyRatePerSecond = lending.currentSupplyRateRay(address(usdc));
        uint256 expectedIndex = lending.RAY() + (supplyRatePerSecond * 365 days);

        advanceSeconds(365 days);

        (uint256 supplyBalance,) = lending.getUserReserveData(alice, address(usdc));
        uint256 expectedBalance = Math.mulDiv(2_000e6, expectedIndex, lending.RAY());
        assertApproxEqRel(supplyBalance, expectedBalance, 1e15);
    }

    function testDecimalsMatrixNoAccountingDrift() public {
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 1e8);
        oracle.setPrice(address(wbtc), 1e8);
        usdc.mint(alice, 1_000_000e6);
        wbtc.mint(alice, 1_000_000e8);
        weth.mint(alice, 1_000_000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(lending), type(uint256).max);
        wbtc.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        _supply(charlie, usdc, 1_000e6, charlie);
        _supply(charlie, wbtc, 1_000e8, charlie);
        _supply(charlie, weth, 1_000e18, charlie);

        MockERC20[3] memory assets = [usdc, wbtc, weth];
        uint256[3] memory supplyAmounts = [uint256(10_000e6), uint256(10_000e8), uint256(10_000e18)];
        uint256[3] memory borrowAmounts = [uint256(100e6), uint256(100e8), uint256(100e18)];

        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j; j < assets.length; ++j) {
                _supply(alice, assets[i], supplyAmounts[i], alice);
                if (i == j) {
                    vm.expectRevert(bytes4(keccak256("SameAssetCollateralDebtNotAllowed()")));
                    vm.prank(alice);
                    lending.borrow(address(assets[j]), borrowAmounts[j], alice);
                } else {
                    _borrow(alice, assets[j], borrowAmounts[j], alice);
                    _repay(alice, assets[j], type(uint256).max, alice);
                }
                _withdraw(alice, assets[i], type(uint256).max, alice);

                (uint256 supplyBalance, uint256 borrowBalance) = lending.getUserReserveData(alice, address(assets[i]));
                assertEq(supplyBalance, 0);
                assertEq(borrowBalance, 0);
            }
        }
    }

    function testSupplySameAssetTwiceKeepsSingleCollateralEntry() public {
        _supply(alice, usdc, 100e6, alice);
        _supply(alice, usdc, 200e6, alice);

        address[] memory collateralAssets = lending.getUserCollateralAssets(alice);
        assertEq(collateralAssets.length, 1);
        assertEq(collateralAssets[0], address(usdc));
    }

    function testBorrowRejectsAssetAlreadySuppliedByBorrower() public {
        bytes4 sameAsset = bytes4(keccak256("SameAssetCollateralDebtNotAllowed()"));

        _supply(alice, usdc, 1_000e6, alice);
        _supply(bob, usdc, 1_000e6, bob);

        vm.expectRevert(sameAsset);
        vm.prank(alice);
        lending.borrow(address(usdc), 100e6, alice);
    }

    function testThirdPartyStaleCollateralDustDoesNotBlockLiquidation() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        advanceSeconds(lending.MAX_ORACLE_STALENESS() + 1);
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), 1_000e8);
        vm.stopPrank();

        _supply(charlie, wbtc, 1, bob);

        address[] memory collateralAssets = lending.getUserCollateralAssets(bob);
        assertFalse(_contains(collateralAssets, address(wbtc)));
        (uint256 wbtcSupply,) = lending.getUserReserveData(bob, address(wbtc));
        assertEq(wbtcSupply, 1);

        vm.prank(charlie);
        (uint256 debtRepaid, uint256 collateralSeized) = lending.liquidate(bob, address(weth), address(usdc), 500e6);

        assertEq(debtRepaid, 500e6);
        assertGt(collateralSeized, 0);
    }

    function testOwnSupplyOfStaleAssetStillEnablesCollateral() public {
        advanceSeconds(lending.MAX_ORACLE_STALENESS() + 1);

        _supply(bob, wbtc, 1, bob);

        address[] memory collateralAssets = lending.getUserCollateralAssets(bob);
        assertTrue(_contains(collateralAssets, address(wbtc)));
        (uint256 wbtcSupply,) = lending.getUserReserveData(bob, address(wbtc));
        assertEq(wbtcSupply, 1);
    }

    function testSupplyOnBehalfCreditsBeneficiaryWhenCollateralAlreadyEnabled() public {
        _supply(alice, usdc, 1_000e6, alice);
        _supply(bob, weth, 1, bob);

        vm.prank(alice);
        lending.supply(address(weth), 1 ether, bob);

        (uint256 collateralValue,, uint256 availableBorrows,) = lending.getUserAccountData(bob);
        assertEq(collateralValue, 2_000e18 + 2_000);
        assertGt(availableBorrows, 0);

        address[] memory collateralAssets = lending.getUserCollateralAssets(bob);
        assertEq(collateralAssets.length, 1);
        assertEq(collateralAssets[0], address(weth));

        vm.prank(bob);
        lending.borrow(address(usdc), 500e6, bob);
    }

    function testFullRepayWithMaxRemovesBorrowAsset() public {
        _supply(alice, usdc, 1_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 400e6, bob);

        _repay(bob, usdc, type(uint256).max, bob);

        address[] memory borrowAssets = lending.getUserBorrowAssets(bob);
        assertEq(borrowAssets.length, 0);
    }

    function testReservesAreUnavailableToWithdrawersUntilAdminWithdrawsThem() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 2 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        advanceSeconds(365 days);
        _repay(bob, usdc, type(uint256).max, bob);

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        (uint256 aliceSupplyBalance,) = lending.getUserReserveData(alice, address(usdc));

        vm.prank(alice);
        uint256 withdrawn = lending.withdraw(address(usdc), type(uint256).max, alice);

        assertEq(withdrawn, aliceSupplyBalance);
        assertApproxEqAbs(usdc.balanceOf(address(lending)), reserve.accruedReserves, 2);
    }

    function testUnrealizedReservesDoNotLockFreshSupplierDeposit() public {
        ILendingPool.InterestRateParams memory aggressiveParams = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0, slope1RayPerYear: 1e27, slope2RayPerYear: 5e27, optimalUtilizationBps: 8_000
        });

        vm.prank(owner);
        lending.setInterestRateParams(address(usdc), aggressiveParams);
        vm.prank(owner);
        lending.setReserveParams(address(usdc), 8_000, 8_500, 500, 5_000);

        _supply(alice, usdc, 1_000e6, alice);
        _supply(bob, weth, 2 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        advanceSeconds(5 * 365 days);
        lending.accrueInterest(address(usdc));

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        assertGt(reserve.accruedReserves, usdc.balanceOf(address(lending)));

        _supply(charlie, usdc, 1e6, charlie);

        (uint256 charlieSupply,) = lending.getUserReserveData(charlie, address(usdc));
        vm.prank(charlie);
        uint256 withdrawn = lending.withdraw(address(usdc), charlieSupply, charlie);

        assertEq(withdrawn, charlieSupply);
    }

    function testSupplyOneUnitProducesNonZeroScaledBalance() public {
        _supply(alice, usdc, 1, alice);
        assertEq(lending.userScaledSupply(alice, address(usdc)), 1);
    }

    function testAccrueInterestHundredYearsTinyBalancesNoOverflow() public {
        _supply(alice, usdc, 1e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1, bob);

        advanceSeconds(100 * 365 days);

        vm.prank(alice);
        lending.accrueInterest(address(usdc));

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        assertGt(reserve.borrowIndex, lending.RAY());
        assertGe(reserve.supplyIndex, lending.RAY());
    }

    function testAccrueInterestTwentyFiveYearsHighUtilizationIndicesRemainMonotonic() public {
        ILendingPool.InterestRateParams memory aggressiveParams = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0, slope1RayPerYear: 1e27, slope2RayPerYear: 5e27, optimalUtilizationBps: 8_000
        });

        vm.prank(owner);
        lending.setInterestRateParams(address(usdc), aggressiveParams);
        vm.prank(owner);
        lending.setReserveParams(address(usdc), 8_000, 8_500, 500, 5_000);

        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 2 ether, bob);
        _borrow(bob, usdc, 2_000e6, bob);

        ILendingPool.Reserve memory reserve = lending.getReserveData(address(usdc));
        uint256 lastSupplyIndex = reserve.supplyIndex;
        uint256 lastBorrowIndex = reserve.borrowIndex;

        for (uint256 year; year < 25; ++year) {
            advanceSeconds(365 days);
            lending.accrueInterest(address(usdc));

            reserve = lending.getReserveData(address(usdc));
            assertGt(reserve.supplyIndex, lastSupplyIndex);
            assertGt(reserve.borrowIndex, lastBorrowIndex);

            lastSupplyIndex = reserve.supplyIndex;
            lastBorrowIndex = reserve.borrowIndex;
        }

        assertEq(lending.utilizationRateRay(address(usdc)), lending.RAY());
        assertLe(lending.currentBorrowRateRay(address(usdc)) * lending.SECONDS_PER_YEAR(), 6e27);
        assertGt(reserve.accruedReserves, 0);
    }

    function testPauseMatrix() public {
        _supply(alice, usdc, 1_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 100e6, bob);

        vm.prank(owner);
        lending.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lending.supply(address(usdc), 1e6, alice);

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lending.borrow(address(usdc), 1e6, bob);

        vm.prank(charlie);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lending.liquidate(bob, address(weth), address(usdc), 1e6);

        vm.prank(bob);
        lending.repay(address(usdc), 10e6, bob);

        vm.prank(alice);
        lending.withdraw(address(usdc), 10e6, alice);

        lending.accrueInterest(address(usdc));
    }

    function testListReserveEmitsEventAndRejectsDuplicate() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);
        ILendingPool.InterestRateParams memory params = _defaultIrParams();

        vm.expectEmit(true, false, false, true);
        emit ReserveListed(address(extra), 18, 7_000, 7_500, 500, 1_000);
        vm.prank(owner);
        lending.listReserve(address(extra), params, 7_000, 7_500, 500, 1_000, true, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.ReserveAlreadyListed.selector, address(extra)));
        lending.listReserve(address(extra), params, 7_000, 7_500, 500, 1_000, true, true);
    }

    function testAdminEvents() public {
        ILendingPool.InterestRateParams memory params = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 1e25, slope1RayPerYear: 3e26, slope2RayPerYear: 9e26, optimalUtilizationBps: 7_500
        });

        vm.expectEmit(true, false, false, true);
        emit ReserveParamsUpdated(address(usdc), 7_000, 8_000, 400, 800);
        vm.prank(owner);
        lending.setReserveParams(address(usdc), 7_000, 8_000, 400, 800);

        vm.expectEmit(true, false, false, true);
        emit InterestRateParamsUpdated(address(usdc), 1e25, 3e26, 9e26, 7_500);
        vm.prank(owner);
        lending.setInterestRateParams(address(usdc), params);

        vm.expectEmit(true, false, false, true);
        emit BorrowEnabled(address(usdc), false);
        vm.prank(owner);
        lending.setBorrowEnabled(address(usdc), false);

        vm.expectEmit(true, false, false, true);
        emit CollateralEnabled(address(usdc), false);
        vm.prank(owner);
        lending.setCollateralEnabled(address(usdc), false);

        PriceOracle newOracle;
        vm.prank(owner);
        newOracle = new PriceOracle();
        vm.expectEmit(true, false, false, false);
        emit OracleUpdated(address(newOracle));
        vm.prank(owner);
        lending.setOracle(IPriceOracle(address(newOracle)));

        vm.expectEmit(false, false, false, true);
        emit CloseFactorUpdated(6_000);
        vm.prank(owner);
        lending.setCloseFactor(6_000);
    }

    function testAccrueInterestEmitsIndexUpdated() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 500e6, bob);

        advanceSeconds(30 days);

        vm.expectEmit(true, false, false, false);
        emit IndexUpdated(address(usdc), 0, 0, 0);
        lending.accrueInterest(address(usdc));
    }

    function testWithdrawReservesEmitsEvent() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 2 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);
        advanceSeconds(365 days);
        _repay(bob, usdc, type(uint256).max, bob);

        uint256 reserveAmount = lending.getReserveData(address(usdc)).accruedReserves;

        vm.expectEmit(true, false, true, true);
        emit ReservesWithdrawn(address(usdc), reserveAmount, feeRecipient);
        vm.prank(owner);
        lending.withdrawReserves(address(usdc), reserveAmount, feeRecipient);
    }

    function testPauseUnpauseEmitEvents() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        vm.prank(owner);
        lending.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        vm.prank(owner);
        lending.unpause();
    }

    function testOnlyOwnerAdminFunctions() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);
        ILendingPool.InterestRateParams memory params = _defaultIrParams();

        _expectUnauthorized(
            alice, abi.encodeCall(lending.listReserve, (address(extra), params, 7_000, 7_500, 500, 1_000, true, true))
        );
        _expectUnauthorized(alice, abi.encodeCall(lending.setReserveParams, (address(usdc), 7_000, 7_500, 500, 1_000)));
        _expectUnauthorized(alice, abi.encodeCall(lending.setInterestRateParams, (address(usdc), params)));
        _expectUnauthorized(alice, abi.encodeCall(lending.setBorrowEnabled, (address(usdc), false)));
        _expectUnauthorized(alice, abi.encodeCall(lending.setCollateralEnabled, (address(usdc), false)));
        _expectUnauthorized(alice, abi.encodeCall(lending.setOracle, (IPriceOracle(address(oracle)))));
        _expectUnauthorized(alice, abi.encodeCall(lending.setCloseFactor, (6_000)));
        _expectUnauthorized(alice, abi.encodeCall(lending.withdrawReserves, (address(usdc), 1, feeRecipient)));
        _expectUnauthorized(alice, abi.encodeCall(lending.pause, ()));
        _expectUnauthorized(alice, abi.encodeCall(lending.unpause, ()));
    }

    function testRevertReserveNotListed() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);

        vm.expectRevert(abi.encodeWithSelector(ILendingPool.ReserveNotListed.selector, address(extra)));
        lending.accrueInterest(address(extra));
    }

    function testRevertBorrowDisabled() public {
        vm.prank(owner);
        lending.setBorrowEnabled(address(usdc), false);

        vm.expectRevert(abi.encodeWithSelector(ILendingPool.BorrowDisabled.selector, address(usdc)));
        _borrow(bob, usdc, 1e6, bob);
    }

    function testLiquidationSucceedsWhenReservesAreDisabledForNewExposure() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        vm.prank(owner);
        lending.setBorrowEnabled(address(usdc), false);
        vm.prank(owner);
        lending.setCollateralEnabled(address(weth), false);
        vm.prank(owner);
        oracle.setPrice(address(weth), 1_000e8);

        uint256 charlieUsdcBefore = usdc.balanceOf(charlie);

        vm.prank(charlie);
        (uint256 debtRepaid, uint256 collateralSeized) = lending.liquidate(bob, address(weth), address(usdc), 500e6);

        assertEq(debtRepaid, 500e6);
        assertGt(collateralSeized, 0);
        assertEq(usdc.balanceOf(charlie), charlieUsdcBefore - debtRepaid);

        (, uint256 bobDebtAfter) = lending.getUserReserveData(bob, address(usdc));
        (uint256 bobCollateralAfter,) = lending.getUserReserveData(bob, address(weth));
        assertLt(bobDebtAfter, 1_000e6);
        assertLt(bobCollateralAfter, 1 ether);
    }

    function testBorrowRequiresCurrentlyEnabledCollateralCapacity() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);

        vm.prank(owner);
        lending.setCollateralEnabled(address(weth), false);

        (uint256 collateralValue,, uint256 availableBorrows,) = lending.getUserAccountData(bob);
        assertEq(collateralValue, 2_000e18);
        assertGt(availableBorrows, 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.HealthFactorBelowThreshold.selector, 0));
        lending.borrow(address(usdc), 1e6, bob);
    }

    function testLiquidationCannotSeizeSupplyNeverEnabledAsCollateral() public {
        vm.prank(owner);
        lending.setCollateralEnabled(address(wbtc), false);

        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _supply(bob, wbtc, 1e8, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 1_000e8);

        vm.expectRevert(abi.encodeWithSelector(ILendingPool.InsufficientSupply.selector, address(wbtc), 500e6, 0));
        vm.prank(charlie);
        lending.liquidate(bob, address(wbtc), address(usdc), 500e6);
    }

    function testRevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ILendingPool.ZeroAmount.selector);
        lending.supply(address(usdc), 0, alice);
    }

    function testRevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ILendingPool.ZeroAddress.selector);
        lending.listReserve(address(0), _defaultIrParams(), 7_000, 7_500, 500, 1_000, true, true);
    }

    function testRevertInsufficientSupply() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.InsufficientSupply.selector, address(usdc), 1e6, 0));
        lending.withdraw(address(usdc), 1e6, alice);
    }

    function testRevertInsufficientLiquidity() public {
        _supply(bob, weth, 1 ether, bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.InsufficientLiquidity.selector, address(usdc), 1e6, 0));
        lending.borrow(address(usdc), 1e6, bob);
    }

    function testRevertHealthFactorBelowThresholdOnBorrow() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);

        uint256 expectedHf = 999_375_390_381_011_867;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.HealthFactorBelowThreshold.selector, expectedHf));
        lending.borrow(address(usdc), 1_601e6, bob);
    }

    function testRevertHealthFactorBelowThresholdOnWithdraw() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);

        uint256 expectedHf = 960_000_000_000_000_000;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.HealthFactorBelowThreshold.selector, expectedHf));
        lending.withdraw(address(weth), 0.4 ether, bob);
    }

    function testRevertHealthFactorNotBelowThreshold() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 400e6, bob);

        (,,, uint256 hf) = lending.getUserAccountData(bob);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.HealthFactorNotBelowThreshold.selector, hf));
        lending.liquidate(bob, address(weth), address(usdc), 100e6);
    }

    function testRevertNoDebt() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.NoDebt.selector, alice, address(usdc)));
        lending.repay(address(usdc), 1e6, alice);
    }

    function testRevertPriceStale() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);

        (, uint256 updatedAt) = oracle.getPrice(address(weth));
        advanceSeconds(lending.MAX_ORACLE_STALENESS() + 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingPool.PriceStale.selector, address(weth), updatedAt, block.timestamp)
        );
        lending.borrow(address(usdc), 100e6, bob);
    }

    function testRevertPriceZero() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);

        vm.prank(owner);
        oracle.setPrice(address(weth), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.PriceZero.selector, address(weth)));
        lending.borrow(address(usdc), 100e6, bob);
    }

    function testRevertCollateralFactorTooHigh() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.CollateralFactorTooHigh.selector, 9_001, 9_000));
        lending.listReserve(address(extra), _defaultIrParams(), 9_001, 9_001, 500, 1_000, true, true);
    }

    function testRevertLiquidationThresholdInvalid() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.LiquidationThresholdInvalid.selector, 7_500, 7_499));
        lending.listReserve(address(extra), _defaultIrParams(), 7_500, 7_499, 500, 1_000, true, true);
    }

    function testRevertLiquidationBonusTooHigh() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.LiquidationBonusTooHigh.selector, 2_001, 2_000));
        lending.listReserve(address(extra), _defaultIrParams(), 7_000, 7_500, 2_001, 1_000, true, true);
    }

    function testRevertReserveFactorTooHigh() public {
        MockERC20 extra = deployMockToken("EXTRA", 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.ReserveFactorTooHigh.selector, 5_001, 5_000));
        lending.listReserve(address(extra), _defaultIrParams(), 7_000, 7_500, 500, 5_001, true, true);
    }

    function testRevertCloseFactorTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.CloseFactorTooHigh.selector, 10_001, 10_000));
        lending.setCloseFactor(10_001);
    }

    function testRevertSelfLiquidation() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);
        vm.prank(owner);
        oracle.setPrice(address(weth), 1_000e8);

        vm.prank(bob);
        vm.expectRevert(ILendingPool.SelfLiquidation.selector);
        lending.liquidate(bob, address(weth), address(usdc), 500e6);
    }

    function testRevertDebtAssetIsCollateralAsset() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);
        vm.prank(owner);
        oracle.setPrice(address(weth), 1_000e8);

        vm.prank(charlie);
        vm.expectRevert(ILendingPool.DebtAssetIsCollateralAsset.selector);
        lending.liquidate(bob, address(usdc), address(usdc), 500e6);
    }

    function testRevertLiquidationAmountExceedsCloseFactor() public {
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 1 ether, bob);
        _borrow(bob, usdc, 1_000e6, bob);
        vm.prank(owner);
        oracle.setPrice(address(weth), 1_000e8);

        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingPool.LiquidationAmountExceedsCloseFactor.selector, 500e6 + 1, 500e6)
        );
        lending.liquidate(bob, address(weth), address(usdc), 500e6 + 1);
    }

    function testRevertUnsupportedTokenOnSupply() public {
        LendingFeeOnTransferERC20 feeToken = _deployFeeToken();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.UnsupportedToken.selector, address(feeToken)));
        lending.supply(address(feeToken), 10 ether, alice);
    }

    function testRevertUnsupportedTokenOnRepay() public {
        LendingFeeOnTransferERC20 feeToken = _deployFeeToken();
        _seedBorrowableFeeToken(feeToken, 1_000 ether);

        _supply(alice, weth, 2 ether, alice);
        vm.prank(alice);
        lending.borrow(address(feeToken), 100 ether, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.UnsupportedToken.selector, address(feeToken)));
        lending.repay(address(feeToken), 10 ether, alice);
    }

    function testRevertUnsupportedTokenOnLiquidation() public {
        LendingFeeOnTransferERC20 feeToken = _deployFeeToken();
        _seedBorrowableFeeToken(feeToken, 1_000 ether);

        _supply(alice, weth, 2 ether, alice);
        vm.prank(alice);
        lending.borrow(address(feeToken), 500 ether, alice);

        vm.prank(owner);
        oracle.setPrice(address(weth), 200e8);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ILendingPool.UnsupportedToken.selector, address(feeToken)));
        lending.liquidate(alice, address(weth), address(feeToken), 100 ether);
    }

    function testReentrantSupplyBlocked() public {
        LendingReentrantERC20 reToken = _setupReentrantReserve();

        vm.prank(owner);
        reToken.setHook(
            LendingReentrantERC20.HookType.TransferFrom,
            address(lending),
            abi.encodeCall(lending.supply, (address(reToken), 1 ether, alice))
        );

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lending.supply(address(reToken), 1 ether, alice);
    }

    function testReentrantWithdrawBlocked() public {
        LendingReentrantERC20 reToken = _setupReentrantReserve();
        vm.prank(alice);
        lending.supply(address(reToken), 10 ether, alice);

        vm.prank(owner);
        reToken.setHook(
            LendingReentrantERC20.HookType.Transfer,
            address(lending),
            abi.encodeCall(lending.withdraw, (address(reToken), 1 ether, alice))
        );

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lending.withdraw(address(reToken), 1 ether, alice);
    }

    function testReentrantBorrowBlocked() public {
        LendingReentrantERC20 reToken = _setupReentrantReserve();
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 2 ether, bob);

        vm.prank(owner);
        reToken.setHook(
            LendingReentrantERC20.HookType.Transfer,
            address(lending),
            abi.encodeCall(lending.borrow, (address(reToken), 1 ether, bob))
        );

        vm.prank(bob);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lending.borrow(address(reToken), 1 ether, bob);
    }

    function testReentrantRepayBlocked() public {
        LendingReentrantERC20 reToken = _setupReentrantReserve();
        _supply(alice, usdc, 2_000e6, alice);
        _supply(bob, weth, 2 ether, bob);
        vm.prank(bob);
        lending.borrow(address(reToken), 1 ether, bob);

        vm.prank(owner);
        reToken.setHook(
            LendingReentrantERC20.HookType.TransferFrom,
            address(lending),
            abi.encodeCall(lending.repay, (address(reToken), 1 ether, bob))
        );

        vm.prank(bob);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lending.repay(address(reToken), 1 ether, bob);
    }

    function testReentrantLiquidateBlocked() public {
        LendingReentrantERC20 reToken = _setupReentrantReserve();
        _supply(alice, weth, 2 ether, alice);
        vm.prank(alice);
        lending.borrow(address(reToken), 100 ether, alice);
        vm.prank(owner);
        oracle.setPrice(address(weth), 50e8);

        vm.prank(owner);
        reToken.setHook(
            LendingReentrantERC20.HookType.TransferFrom,
            address(lending),
            abi.encodeCall(lending.liquidate, (alice, address(weth), address(reToken), 10 ether))
        );

        vm.prank(charlie);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lending.liquidate(alice, address(weth), address(reToken), 10 ether);
    }

    function _defaultIrParams() internal pure returns (ILendingPool.InterestRateParams memory params) {
        params = ILendingPool.InterestRateParams({
            baseRateRayPerYear: 0, slope1RayPerYear: 2e26, slope2RayPerYear: 8e26, optimalUtilizationBps: 8_000
        });
    }

    function _listReserve(
        address asset,
        uint16 collateralFactorBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 reserveFactorBps,
        bool borrowEnabled,
        bool useAsCollateral
    ) internal {
        lending.listReserve(
            asset,
            _defaultIrParams(),
            collateralFactorBps,
            liquidationThresholdBps,
            liquidationBonusBps,
            reserveFactorBps,
            borrowEnabled,
            useAsCollateral
        );
    }

    function _mintAll(address user) internal {
        mintAndApprove(usdc, user, address(lending), 10_000_000e6);
        mintAndApprove(weth, user, address(lending), 10_000 ether);
        mintAndApprove(wbtc, user, address(lending), 1_000e8);
    }

    function _supply(address user, MockERC20 token, uint256 amount, address onBehalfOf) internal {
        vm.prank(user);
        lending.supply(address(token), amount, onBehalfOf);
    }

    function _borrow(address user, MockERC20 token, uint256 amount, address to) internal {
        vm.prank(user);
        lending.borrow(address(token), amount, to);
    }

    function _repay(address user, MockERC20 token, uint256 amount, address onBehalfOf) internal {
        vm.prank(user);
        lending.repay(address(token), amount, onBehalfOf);
    }

    function _withdraw(address user, MockERC20 token, uint256 amount, address to) internal {
        vm.prank(user);
        lending.withdraw(address(token), amount, to);
    }

    function _contains(address[] memory assets, address asset) internal pure returns (bool) {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return true;
        }

        return false;
    }

    function _expectUnauthorized(address caller, bytes memory data) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        (bool success,) = address(lending).call(data);
        success;
    }

    function _deployFeeToken() internal returns (LendingFeeOnTransferERC20 feeToken) {
        vm.startPrank(owner);
        feeToken = new LendingFeeOnTransferERC20("Fee", "FEE", 18, 100);
        lending.listReserve(address(feeToken), _defaultIrParams(), 7_000, 7_500, 500, 1_000, true, true);
        oracle.setPrice(address(feeToken), 1e8);
        feeToken.mint(alice, 1_000 ether);
        feeToken.mint(charlie, 1_000 ether);
        vm.stopPrank();

        vm.prank(alice);
        feeToken.approve(address(lending), type(uint256).max);
        vm.prank(charlie);
        feeToken.approve(address(lending), type(uint256).max);
    }

    function _seedBorrowableFeeToken(LendingFeeOnTransferERC20 feeToken, uint256 amount) internal {
        vm.prank(owner);
        feeToken.mint(address(lending), amount);
    }

    function _setupReentrantReserve() internal returns (LendingReentrantERC20 reToken) {
        vm.startPrank(owner);
        reToken = new LendingReentrantERC20("Reentrant", "RE", 18);
        lending.listReserve(address(reToken), _defaultIrParams(), 7_000, 7_500, 500, 1_000, true, true);
        oracle.setPrice(address(reToken), 1e8);
        reToken.mint(address(lending), 1_000 ether);
        reToken.mint(alice, 100 ether);
        reToken.mint(bob, 100 ether);
        reToken.mint(charlie, 100 ether);
        vm.stopPrank();

        vm.prank(alice);
        reToken.approve(address(lending), type(uint256).max);
        vm.prank(bob);
        reToken.approve(address(lending), type(uint256).max);
        vm.prank(charlie);
        reToken.approve(address(lending), type(uint256).max);
    }
}
