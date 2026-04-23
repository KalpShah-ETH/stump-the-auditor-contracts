// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVault} from "src/interfaces/IVault.sol";
import {Vault} from "src/Vault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract FeeOnTransferVaultToken is ERC20, Ownable {
    uint256 internal constant BPS = 10_000;

    uint8 private immutable _decimals;
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _feeTransfer(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _feeTransfer(from, to, amount);
        return true;
    }

    function _feeTransfer(address from, address to, uint256 amount) internal {
        uint256 fee = amount * feeBps / BPS;
        uint256 received = amount - fee;
        _transfer(from, to, received);
        if (fee != 0) _transfer(from, address(this), fee);
    }
}

contract ReentrantVaultToken is ERC20, Ownable {
    enum HookType {
        None,
        Transfer,
        TransferFrom
    }

    uint8 private immutable _decimals;
    HookType public hookType;
    address public target;
    bytes public payload;
    bool private entered;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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

contract VaultTest is BaseTest {
    event AssetAdded(address indexed asset, uint8 decimals);
    event AssetRemoved(address indexed asset);
    event Deposited(
        address indexed user, address indexed asset, uint256 amount, uint256 sharesMinted, address indexed receiver
    );
    event WithdrawRequested(
        address indexed user, uint256 sharesBurned, uint256 wadOwed, address indexed asset, uint64 unlockBlock
    );
    event WithdrawClaimed(address indexed user, address indexed asset, uint256 amountOut);
    event WithdrawCancelled(address indexed user, uint256 sharesReturned);
    event FeesAccrued(uint256 mgmtFeeShares, uint256 perfFeeShares, uint256 newHighWaterMarkPPS);
    event YieldReported(address indexed asset, uint256 amount, uint256 newTotalManagedWad);
    event FeeParamsUpdated(uint256 perfBps, uint256 mgmtBps);
    event TimelockUpdated(uint256 blocks);
    event FeeRecipientUpdated(address recipient);
    event Paused(address account);
    event Unpaused(address account);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant VSO = 1e3;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant DEFAULT_PERF_FEE_BPS = 2_000;
    uint256 internal constant DEFAULT_MGMT_FEE_BPS = 100;
    uint256 internal constant DEFAULT_TIMELOCK = 3;

    MockERC20 internal usdc;
    MockERC20 internal dai;
    Vault internal vault;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);
        dai = deployMockToken("DAI", 18);

        vault = _deployFreshVault(DEFAULT_PERF_FEE_BPS, DEFAULT_MGMT_FEE_BPS, DEFAULT_TIMELOCK);
        _whitelistAsset(vault, address(usdc));
        _whitelistAsset(vault, address(dai));

        mintAndApprove(usdc, alice, address(vault), 5_000_000e6);
        mintAndApprove(usdc, bob, address(vault), 5_000_000e6);
        mintAndApprove(usdc, charlie, address(vault), 5_000_000e6);

        mintAndApprove(dai, alice, address(vault), 5_000_000 ether);
        mintAndApprove(dai, bob, address(vault), 5_000_000 ether);
        mintAndApprove(dai, charlie, address(vault), 5_000_000 ether);
    }

    function testSingleUserHappyPathDepositYieldRequestClaim() public {
        Vault fresh = _deployDefaultVault(2_000, 0, DEFAULT_TIMELOCK);

        uint256 depositAmount = 100e6;
        uint256 depositWad = _toWad(depositAmount, 6);
        uint256 yieldAmount = 10e6;

        _depositUsdc(fresh, alice, depositAmount);

        vm.startPrank(owner);
        usdc.mint(owner, yieldAmount);
        usdc.approve(address(fresh), yieldAmount);
        vm.expectEmit(false, false, true, true);
        emit YieldReported(address(usdc), yieldAmount, depositWad + _toWad(yieldAmount, 6));
        fresh.reportYield(address(usdc), yieldAmount);
        vm.stopPrank();

        vm.prank(charlie);
        fresh.accrueFees();

        uint256 aliceShares = fresh.userShares(alice);
        uint256 expectedAmountOut = _fromWad(fresh.previewWithdraw(aliceShares), 6);
        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(usdc));

        advanceBlocks(DEFAULT_TIMELOCK);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 amountOut = fresh.claimWithdraw();
        uint256 balanceAfter = usdc.balanceOf(alice);
        uint256 feeRecipientAssets = fresh.convertToAssets(fresh.userShares(feeRecipient));

        assertEq(balanceAfter - balanceBefore, amountOut);
        assertEq(amountOut, expectedAmountOut);
        assertGt(amountOut, depositAmount);
        assertApproxEqAbs(fresh.totalAssets(), feeRecipientAssets, 1);
        assertGt(fresh.userShares(feeRecipient), 0);
    }

    function testTwoUsersTwoAssetsShareYieldProRata() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        _depositUsdc(fresh, alice, 100e6);
        _depositDai(fresh, bob, 50 ether);

        _reportYield(fresh, usdc, 20e6);
        _reportYield(fresh, dai, 10 ether);

        uint256 aliceShares = fresh.userShares(alice);
        uint256 bobShares = fresh.userShares(bob);

        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(usdc));

        vm.prank(bob);
        fresh.requestWithdraw(bobShares, address(dai));

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        uint256 aliceOut = fresh.claimWithdraw();

        vm.prank(bob);
        uint256 bobOut = fresh.claimWithdraw();

        assertApproxEqAbs(aliceOut, 120e6, 1);
        assertEq(bobOut, 60 ether);
        assertLe(fresh.totalAssets(), 1);
    }

    function testFeeRecipientReceivesSharesAfterYieldAndTime() public {
        Vault fresh = _deployDefaultVault(2_000, 200, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        warp(180 days);

        _reportYield(fresh, dai, 20 ether);

        vm.prank(charlie);
        fresh.accrueFees();

        assertGt(fresh.userShares(feeRecipient), 0);
        assertEq(fresh.feeRecipient(), feeRecipient);
    }

    function test_reportYield_chargesPerfFeeOnlyOnActiveShares() public {
        Vault fresh = _deployDefaultVault(3_000, 0, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 1_000 ether);
        _depositDai(fresh, bob, 1_000 ether);

        uint256 aliceShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(dai));
        IVault.WithdrawRequest memory requestBefore = fresh.getPendingWithdraw(alice);

        _reportYield(fresh, dai, 200 ether);
        IVault.WithdrawRequest memory requestAfter = fresh.getPendingWithdraw(alice);

        assertEq(requestAfter.wadOwed, requestBefore.wadOwed);
        assertEq(requestAfter.reservedAmount, requestBefore.reservedAmount);

        vm.prank(charlie);
        fresh.accrueFees();

        uint256 bobAssets = fresh.convertToAssets(fresh.userShares(bob));
        advanceBlocks(DEFAULT_TIMELOCK);

        uint256 aliceBalanceBefore = dai.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceOut = fresh.claimWithdraw();

        uint256 feeRecipientAssets = fresh.convertToAssets(fresh.userShares(feeRecipient));

        assertEq(dai.balanceOf(alice) - aliceBalanceBefore, aliceOut);
        assertEq(aliceOut, 1_000 ether);
        assertGt(bobAssets, 1_130 ether);
        assertLt(bobAssets, 1_145 ether);
        assertGt(feeRecipientAssets, 55 ether);
        assertLt(feeRecipientAssets, 60 ether);
    }

    function test_reportYield_skewedPendingStateDoesNotIteratePendingYield() public {
        Vault fresh = _deployDefaultVault(3_000, 0, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 200 ether);
        _depositDai(fresh, bob, 1 ether);

        uint256 aliceShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(dai));
        IVault.WithdrawRequest memory requestBefore = fresh.getPendingWithdraw(alice);

        _reportYield(fresh, dai, 100 ether);
        IVault.WithdrawRequest memory requestAfter = fresh.getPendingWithdraw(alice);

        assertEq(requestAfter.wadOwed, requestBefore.wadOwed);
        assertEq(requestAfter.reservedAmount, requestBefore.reservedAmount);

        vm.prank(charlie);
        fresh.accrueFees();

        uint256 feeRecipientAssets = fresh.convertToAssets(fresh.userShares(feeRecipient));
        uint256 bobAssets = fresh.convertToAssets(fresh.userShares(bob));

        assertGt(feeRecipientAssets, 20 ether);
        assertLt(feeRecipientAssets, 25 ether);
        assertGt(bobAssets, 75 ether);
        assertLt(bobAssets, 80 ether);

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        uint256 aliceOut = fresh.claimWithdraw();

        assertEq(aliceOut, 200 ether);
    }

    function testReportYieldRevertsWhenAllSharesArePending() public {
        Vault fresh = _deployDefaultVault(3_000, 0, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        uint256 aliceShares = fresh.userShares(alice);

        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(dai));

        vm.startPrank(owner);
        dai.mint(owner, 1 ether);
        dai.approve(address(fresh), 1 ether);
        vm.expectRevert(IVault.NoActiveShares.selector);
        fresh.reportYield(address(dai), 1 ether);
        vm.stopPrank();
    }

    function testDepositPreservesHighWaterMark() public {
        Vault fresh = _deployDefaultVault(2_000, 0, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        _reportYield(fresh, dai, 20 ether);

        vm.prank(charlie);
        fresh.accrueFees();

        uint256 hwmBefore = fresh.highWaterMarkPPS();
        uint256 ppsBefore = _activePps(fresh);

        _depositDai(fresh, bob, 1_000 ether);

        assertEq(fresh.highWaterMarkPPS(), hwmBefore);
        assertLe(_activePps(fresh), ppsBefore);
    }

    function testWithdrawPreservesHighWaterMark() public {
        Vault fresh = _deployDefaultVault(2_000, 0, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        _reportYield(fresh, dai, 20 ether);

        vm.prank(charlie);
        fresh.accrueFees();

        uint256 hwmBefore = fresh.highWaterMarkPPS();
        uint256 aliceHalfShares = fresh.userShares(alice) / 2;

        vm.prank(alice);
        fresh.requestWithdraw(aliceHalfShares, address(dai));

        assertEq(fresh.highWaterMarkPPS(), hwmBefore);

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        fresh.claimWithdraw();

        assertEq(fresh.highWaterMarkPPS(), hwmBefore);
    }

    function testYieldLiftsHighWaterMarkAndChargesPerformanceFee() public {
        Vault fresh = _deployDefaultVault(2_000, 0, DEFAULT_TIMELOCK);

        uint256 depositAmount = 100 ether;
        uint256 profit = 20 ether;

        _depositDai(fresh, alice, depositAmount);

        uint256 expectedPps = _currentPps(depositAmount + profit, fresh.totalShares());

        vm.startPrank(owner);
        dai.mint(owner, profit);
        dai.approve(address(fresh), profit);
        vm.expectEmit(false, false, true, true);
        emit YieldReported(address(dai), profit, depositAmount + profit);
        fresh.reportYield(address(dai), profit);
        vm.stopPrank();

        vm.prank(charlie);
        fresh.accrueFees();

        assertEq(fresh.highWaterMarkPPS(), _currentPps(depositAmount + profit, fresh.totalShares()));
        assertLt(fresh.highWaterMarkPPS(), expectedPps);
        assertGt(fresh.userShares(feeRecipient), 0);
    }

    function testYieldBelowHighWaterMarkAfterWithdrawalChargesNothing() public {
        Vault fresh = _deployDefaultVault(2_000, 0, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);

        _reportYield(fresh, dai, 20 ether);

        vm.prank(charlie);
        fresh.accrueFees();

        uint256 feeSharesBefore = fresh.userShares(feeRecipient);
        uint256 hwmBefore = fresh.highWaterMarkPPS();

        uint256 halfShares = fresh.userShares(alice) / 2;
        vm.prank(alice);
        fresh.requestWithdraw(halfShares, address(dai));
        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        fresh.claimWithdraw();

        uint256 managedBefore = fresh.totalAssets();
        uint256 supplyBefore = fresh.totalShares();
        uint256 requiredProfit = _profitNeededToReachPps(hwmBefore, managedBefore, supplyBefore);
        if (requiredProfit <= 1) {
            assertEq(fresh.userShares(feeRecipient), feeSharesBefore);
            assertEq(fresh.highWaterMarkPPS(), hwmBefore);
            return;
        }
        uint256 smallProfit = requiredProfit > 1 ? requiredProfit - 1 : 0;
        assertGt(smallProfit, 0);

        _reportYield(fresh, dai, smallProfit);

        vm.prank(charlie);
        fresh.accrueFees();

        assertEq(fresh.userShares(feeRecipient), feeSharesBefore);
        assertEq(fresh.highWaterMarkPPS(), hwmBefore);
    }

    function testManagementFeeDoesNotTriggerPerformanceFee() public {
        Vault fresh = _deployDefaultVault(2_000, 200, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        uint256 expectedMgmtShares = _mgmtFeeShares(fresh.totalShares(), fresh.managementFeeBps(), 365 days);

        warp(365 days);

        vm.expectEmit(false, false, false, true);
        emit FeesAccrued(expectedMgmtShares, 0, fresh.highWaterMarkPPS());

        vm.prank(charlie);
        fresh.accrueFees();

        assertEq(fresh.userShares(feeRecipient), expectedMgmtShares);
        assertEq(fresh.highWaterMarkPPS(), WAD);
        assertLt(_activePps(fresh), WAD);
    }

    function testFirstDepositorProtectionBlocksDustSeedAndDonationAttack() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        vm.expectRevert(abi.encodeWithSelector(IVault.InitialDepositTooSmall.selector, 999_999, 1e6));
        vm.prank(alice);
        fresh.deposit(address(usdc), 999_999, alice);

        _depositUsdc(fresh, alice, 1e6);
        _mintAssetToVault(usdc, address(fresh), 1_000_000e6);

        vm.prank(bob);
        uint256 minted = fresh.deposit(address(usdc), 1e6, bob);

        assertGt(minted, 0);
        assertEq(fresh.highWaterMarkPPS(), WAD);
    }

    function testDecimalsNormalizeOneUsdcToOneWad() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        _depositUsdc(fresh, alice, 1e6);

        assertEq(fresh.convertToAssets(fresh.userShares(alice)), 1e18);
    }

    function testTwentyDecimalAssetRoundTripsThroughNormalization() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        MockERC20 highDecimals = deployMockToken("HDEC", 20);

        vm.prank(owner);
        fresh.addAsset(address(highDecimals));

        mintAndApprove(highDecimals, alice, address(fresh), 1_000 ether * 100);

        vm.prank(alice);
        fresh.deposit(address(highDecimals), 100 ether * 100, alice);

        uint256 fullShares = fresh.userShares(alice);
        assertEq(fresh.convertToAssets(fullShares), 100 ether);

        vm.prank(alice);
        fresh.requestWithdraw(fullShares, address(highDecimals));

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        uint256 amountOut = fresh.claimWithdraw();

        assertEq(amountOut, 100 ether * 100);
    }

    function testDepositSubWadHighDecimalAmountRevertsZeroAmount() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        MockERC20 highDecimals = deployMockToken("HDEC", 20);

        vm.prank(owner);
        fresh.addAsset(address(highDecimals));

        mintAndApprove(highDecimals, bob, address(fresh), 100 ether * 100);
        mintAndApprove(highDecimals, alice, address(fresh), 50);

        vm.prank(bob);
        fresh.deposit(address(highDecimals), 100 ether * 100, bob);

        vm.expectRevert(IVault.ZeroAmount.selector);
        vm.prank(alice);
        fresh.deposit(address(highDecimals), 50, alice);
    }

    function testRequestWithdrawRejectsDifferentShareAssetBeforeRounding() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        MockERC20 highDecimals = deployMockToken("HDEC", 20);

        vm.prank(owner);
        fresh.addAsset(address(usdc));
        vm.prank(owner);
        fresh.addAsset(address(highDecimals));

        mintAndApprove(highDecimals, alice, address(fresh), 1_000_000);

        vm.prank(alice);
        fresh.deposit(address(highDecimals), 1_000_000, alice);

        vm.prank(bob);
        fresh.deposit(address(usdc), 1e6, bob);

        uint256 aliceShares = fresh.userShares(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.ShareAssetMismatch.selector, alice, address(highDecimals), address(usdc))
        );
        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(usdc));
    }

    function testDepositRejectsDifferentAssetForExistingShares() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        _depositUsdc(fresh, alice, 100e6);

        vm.expectRevert(abi.encodeWithSelector(IVault.ShareAssetMismatch.selector, alice, address(usdc), address(dai)));
        vm.prank(alice);
        fresh.deposit(address(dai), 1 ether, alice);
    }

    function testFeeOnTransferDepositRevertsUnsupportedToken() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);
        FeeOnTransferVaultToken feeToken;
        vm.prank(owner);
        feeToken = new FeeOnTransferVaultToken("FEE", "FEE", 6, 100);

        vm.prank(owner);
        fresh.addAsset(address(feeToken));

        vm.prank(owner);
        feeToken.mint(alice, 100e6);

        vm.prank(alice);
        feeToken.approve(address(fresh), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IVault.UnsupportedToken.selector, address(feeToken)));
        vm.prank(alice);
        fresh.deposit(address(feeToken), 100e6, alice);
    }

    function testAdminSetterAccruesFeesForwardOnly() public {
        Vault fresh = _deployDefaultVault(2_000, 100, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        warp(180 days);

        uint256 expectedMgmtShares = _mgmtFeeShares(fresh.totalShares(), 100, 180 days);

        vm.prank(owner);
        fresh.setManagementFee(500);

        assertEq(fresh.userShares(feeRecipient), expectedMgmtShares);
        assertEq(fresh.managementFeeBps(), 500);
    }

    function testPreviewHelpersSimulatePendingFeeAccrual() public {
        Vault fresh = _deployDefaultVault(0, 100, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        warp(180 days);

        uint256 previewShares = fresh.previewDeposit(address(dai), 10 ether);
        uint256 previewWad = fresh.previewWithdraw(fresh.userShares(alice) / 4);

        vm.prank(bob);
        uint256 actualShares = fresh.deposit(address(dai), 10 ether, bob);

        assertEq(actualShares, previewShares);

        uint256 quarterShares = fresh.userShares(alice) / 4;
        vm.prank(alice);
        fresh.requestWithdraw(quarterShares, address(dai));

        assertEq(fresh.getPendingWithdraw(alice).wadOwed, previewWad);
    }

    function testPauseMatrixBlocksEntryButAllowsClaimAndCancel() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        _depositUsdc(fresh, alice, 100e6);

        vm.expectEmit(false, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        fresh.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        fresh.deposit(address(usdc), 10e6, bob);

        uint256 fullShares = fresh.userShares(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        fresh.requestWithdraw(fullShares, address(usdc));

        vm.prank(owner);
        fresh.unpause();

        uint256 halfShares = fresh.userShares(alice) / 2;
        vm.prank(alice);
        fresh.requestWithdraw(halfShares, address(usdc));

        vm.prank(owner);
        fresh.pause();

        vm.prank(alice);
        fresh.cancelWithdraw();

        vm.prank(owner);
        fresh.unpause();

        uint256 remainingShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(remainingShares, address(usdc));
        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(owner);
        fresh.pause();

        vm.prank(alice);
        fresh.claimWithdraw();
    }

    function testAdminFunctionsRejectUnauthorizedCaller() public {
        Vault fresh = _deployDefaultVault(2_000, 100, DEFAULT_TIMELOCK);

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.addAsset(address(this));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.removeAsset(address(usdc));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setPerformanceFee(100);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setManagementFee(100);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setTimelockBlocks(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setFeeRecipient(charlie);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.reportYield(address(dai), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.unpause();

        vm.stopPrank();
    }

    function testAssetAddedEvent() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        MockERC20 extra = deployMockToken("USDX", 6);

        vm.expectEmit(true, false, false, true);
        emit AssetAdded(address(extra), 6);

        vm.prank(owner);
        fresh.addAsset(address(extra));
    }

    function testAssetRemovedEvent() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        MockERC20 extra = deployMockToken("USDX", 6);

        _whitelistAsset(fresh, address(extra));

        vm.expectEmit(true, false, false, true);
        emit AssetRemoved(address(extra));

        vm.prank(owner);
        fresh.removeAsset(address(extra));
    }

    function testDepositEmitsEvent() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);
        uint256 amount = 100e6;
        uint256 shares = _computeShares(_toWad(amount, 6), 0, 0);

        vm.expectEmit(true, true, false, true);
        emit Deposited(alice, address(usdc), amount, shares, alice);

        vm.prank(alice);
        fresh.deposit(address(usdc), amount, alice);
    }

    function testWithdrawRequestedEmitsEvent() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);
        _depositUsdc(fresh, alice, 100e6);

        uint256 shares = fresh.userShares(alice) / 2;
        uint256 wadOwed = _computeAssets(shares, fresh.totalShares(), fresh.totalAssets());
        uint64 unlockBlock = uint64(block.number + fresh.timelockBlocks());

        vm.expectEmit(true, false, true, true);
        emit WithdrawRequested(alice, shares, wadOwed, address(usdc), unlockBlock);

        vm.prank(alice);
        fresh.requestWithdraw(shares, address(usdc));
    }

    function testWithdrawClaimedEmitsEvent() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);
        _depositUsdc(fresh, alice, 100e6);

        uint256 fullShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(fullShares, address(usdc));

        uint256 amountOut = 100e6;
        advanceBlocks(DEFAULT_TIMELOCK);

        vm.expectEmit(true, true, false, true);
        emit WithdrawClaimed(alice, address(usdc), amountOut);

        vm.prank(alice);
        fresh.claimWithdraw();
    }

    function testWithdrawCancelledEmitsEvent() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);
        _depositUsdc(fresh, alice, 100e6);

        uint256 shares = fresh.userShares(alice) / 2;

        vm.prank(alice);
        fresh.requestWithdraw(shares, address(usdc));

        vm.expectEmit(true, false, false, true);
        emit WithdrawCancelled(alice, shares);

        vm.prank(alice);
        fresh.cancelWithdraw();
    }

    function testFeeParamsUpdatedEventForPerformanceFee() public {
        Vault fresh = _deployDefaultVault(2_000, 100, DEFAULT_TIMELOCK);

        vm.expectEmit(false, false, false, true);
        emit FeeParamsUpdated(1_500, 100);

        vm.prank(owner);
        fresh.setPerformanceFee(1_500);
    }

    function testFeeParamsUpdatedEventForManagementFee() public {
        Vault fresh = _deployDefaultVault(2_000, 100, DEFAULT_TIMELOCK);

        vm.expectEmit(false, false, false, true);
        emit FeeParamsUpdated(2_000, 200);

        vm.prank(owner);
        fresh.setManagementFee(200);
    }

    function testTimelockUpdatedEvent() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        vm.expectEmit(false, false, false, true);
        emit TimelockUpdated(5);

        vm.prank(owner);
        fresh.setTimelockBlocks(5);
    }

    function testFeeRecipientUpdatedEvent() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        vm.expectEmit(false, false, false, true);
        emit FeeRecipientUpdated(charlie);

        vm.prank(owner);
        fresh.setFeeRecipient(charlie);
    }

    function testPauseAndUnpauseEmitEvents() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        vm.expectEmit(false, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        fresh.pause();

        vm.expectEmit(false, false, false, true);
        emit Unpaused(owner);

        vm.prank(owner);
        fresh.unpause();
    }

    function testDepositWrongAssetReverts() public {
        MockERC20 extra = deployMockToken("USDX", 6);

        mintAndApprove(extra, alice, address(vault), 100e6);

        vm.expectRevert(abi.encodeWithSelector(IVault.AssetNotWhitelisted.selector, address(extra)));
        vm.prank(alice);
        vault.deposit(address(extra), 100e6, alice);
    }

    function testRequestMoreSharesThanOwnedReverts() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 availableShares = vault.userShares(alice);
        uint256 sharesToRequest = availableShares + 1;
        vm.expectRevert(abi.encodeWithSelector(IVault.InsufficientShares.selector, sharesToRequest, availableShares));
        vm.prank(alice);
        vault.requestWithdraw(sharesToRequest, address(usdc));
    }

    function testClaimBeforeUnlockReverts() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 fullShares = vault.userShares(alice);
        vm.prank(alice);
        vault.requestWithdraw(fullShares, address(usdc));

        uint64 unlockBlock = vault.getPendingWithdraw(alice).unlockBlock;

        vm.expectRevert(abi.encodeWithSelector(IVault.TimelockActive.selector, unlockBlock, uint64(block.number)));
        vm.prank(alice);
        vault.claimWithdraw();
    }

    function testSecondPendingWithdrawReverts() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 halfShares = vault.userShares(alice) / 2;
        vm.prank(alice);
        vault.requestWithdraw(halfShares, address(usdc));

        vm.expectRevert(abi.encodeWithSelector(IVault.PendingWithdrawExists.selector, alice));
        vm.prank(alice);
        vault.requestWithdraw(1, address(usdc));
    }

    function testNoPendingWithdrawReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVault.NoPendingWithdraw.selector, alice));
        vm.prank(alice);
        vault.claimWithdraw();
    }

    function testCancelAfterUnlockReverts() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 halfShares = vault.userShares(alice) / 2;
        vm.prank(alice);
        vault.requestWithdraw(halfShares, address(usdc));

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.TimelockActive.selector, vault.getPendingWithdraw(alice).unlockBlock, uint64(block.number)
            )
        );
        vm.prank(alice);
        vault.cancelWithdraw();
    }

    function test_cancelWithdraw_returnsOriginalShares() public {
        Vault fresh = _deployDefaultVault(0, 500, DEFAULT_TIMELOCK);

        _depositDai(fresh, alice, 100 ether);
        _depositDai(fresh, bob, 100 ether);

        uint256 aliceSharesBefore = fresh.userShares(alice);
        uint256 bobSharesBefore = fresh.userShares(bob);

        vm.prank(alice);
        fresh.requestWithdraw(aliceSharesBefore, address(dai));

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        fresh.cancelWithdraw();

        assertEq(fresh.userShares(alice), aliceSharesBefore);
        assertEq(fresh.userShares(bob), bobSharesBefore);
        assertGt(fresh.totalShares(), aliceSharesBefore + bobSharesBefore);
        assertApproxEqAbs(
            fresh.convertToAssets(fresh.userShares(alice)), fresh.convertToAssets(fresh.userShares(bob)), 1
        );
        assertLt(fresh.convertToAssets(fresh.userShares(alice)), 100 ether);
    }

    function testAddAssetAlreadyWhitelistedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVault.AssetAlreadyWhitelisted.selector, address(usdc)));
        vm.prank(owner);
        vault.addAsset(address(usdc));
    }

    function testAddAssetRejectsDecimalsAbove36() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        MockERC20 unsupported = deployMockToken("BAD", 37);

        vm.expectRevert(abi.encodeWithSelector(IVault.UnsupportedToken.selector, address(unsupported)));
        vm.prank(owner);
        fresh.addAsset(address(unsupported));
    }

    function testRemoveAssetWithHoldingsReverts() public {
        _depositUsdc(vault, alice, 100e6);

        vm.expectRevert(abi.encodeWithSelector(IVault.AssetStillHeld.selector, address(usdc), 100e6));
        vm.prank(owner);
        vault.removeAsset(address(usdc));
    }

    function testZeroAmountReverts() public {
        vm.expectRevert(IVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(address(usdc), 0, alice);
    }

    function testEmptyVaultAccrueUpdatesTimestampAndZeroValueViewsReturnZero() public {
        Vault fresh = _deployDefaultVault(0, 100, DEFAULT_TIMELOCK);
        uint256 previousAccrual = fresh.lastFeeAccrual();

        warp(1 days);

        vm.prank(charlie);
        fresh.accrueFees();

        assertGt(fresh.lastFeeAccrual(), previousAccrual);
        assertEq(fresh.convertToShares(0), 0);
        assertEq(fresh.convertToAssets(0), 0);
        assertEq(fresh.previewDeposit(address(usdc), 0), 0);
        assertEq(fresh.previewWithdraw(0), 0);
    }

    function testZeroAddressReverts() public {
        vm.expectRevert(IVault.ZeroAddress.selector);
        vm.prank(alice);
        vault.deposit(address(usdc), 1e6, address(0));
    }

    function testAdminZeroAddressAndZeroYieldValidation() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);

        vm.expectRevert(IVault.ZeroAddress.selector);
        vm.prank(owner);
        fresh.addAsset(address(0));

        vm.expectRevert(IVault.ZeroAddress.selector);
        vm.prank(owner);
        fresh.setFeeRecipient(address(0));

        vm.expectRevert(IVault.ZeroAmount.selector);
        vm.prank(owner);
        fresh.reportYield(address(usdc), 0);
    }

    function testSetPerformanceFeeTooHighReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVault.FeeTooHigh.selector, 3_001, 3_000));
        vm.prank(owner);
        vault.setPerformanceFee(3_001);
    }

    function testSetManagementFeeTooHighReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVault.FeeTooHigh.selector, 501, 500));
        vm.prank(owner);
        vault.setManagementFee(501);
    }

    function testSetTimelockTooLongReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVault.TimelockTooLong.selector, 50_401, 50_400));
        vm.prank(owner);
        vault.setTimelockBlocks(50_401);
    }

    function testRequestWithdrawRejectsDifferentSettlementAsset() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 fullShares = vault.userShares(alice);
        vm.expectRevert(abi.encodeWithSelector(IVault.ShareAssetMismatch.selector, alice, address(usdc), address(dai)));
        vm.prank(alice);
        vault.requestWithdraw(fullShares, address(dai));
    }

    function testRequestWithdrawReservesPerAssetLiquidity() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        _depositUsdc(fresh, alice, 100e6);
        _depositUsdc(fresh, bob, 100e6);
        _reportYield(fresh, dai, 100 ether);

        uint256 aliceShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(usdc));

        assertGt(fresh.reservedForWithdraw(address(usdc)), 100e6);

        uint256 bobShares = fresh.userShares(bob);
        uint256 needed = _fromWad(fresh.previewWithdraw(bobShares), 6);
        uint256 available = usdc.balanceOf(address(fresh)) - fresh.reservedForWithdraw(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(IVault.InsufficientAssetLiquidity.selector, address(usdc), needed, available)
        );
        vm.prank(bob);
        fresh.requestWithdraw(bobShares, address(usdc));
    }

    function testReportYieldIgnoresPendingRequestAssetLiquidity() public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        _depositUsdc(fresh, alice, 100e6);
        _depositDai(fresh, bob, 100 ether);

        uint256 aliceShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(aliceShares, address(usdc));

        IVault.WithdrawRequest memory requestBefore = fresh.getPendingWithdraw(alice);
        assertEq(fresh.reservedForWithdraw(address(usdc)), usdc.balanceOf(address(fresh)));

        _reportYield(fresh, dai, 10 ether);

        IVault.WithdrawRequest memory requestAfter = fresh.getPendingWithdraw(alice);
        assertEq(requestAfter.wadOwed, requestBefore.wadOwed);
        assertEq(requestAfter.reservedAmount, requestBefore.reservedAmount);
        assertEq(fresh.reservedForWithdraw(address(usdc)), requestBefore.reservedAmount);
    }

    function testClaimWithdrawRevertsWhenLiquidityWasLost() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 fullShares = vault.userShares(alice);
        vm.prank(alice);
        vault.requestWithdraw(fullShares, address(usdc));

        vm.prank(owner);
        usdc.burn(address(vault), 100e6);

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.expectRevert(abi.encodeWithSelector(IVault.InsufficientAssetLiquidity.selector, address(usdc), 100e6, 0));
        vm.prank(alice);
        vault.claimWithdraw();
    }

    function testConstructorValidatesZeroFeeRecipient() public {
        vm.expectRevert(IVault.ZeroAddress.selector);
        vm.prank(owner);
        new Vault(address(0), 0, 0, 0);
    }

    function testConstructorValidatesFeeCapsAndTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(IVault.FeeTooHigh.selector, 3_001, 3_000));
        vm.prank(owner);
        new Vault(feeRecipient, 3_001, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IVault.FeeTooHigh.selector, 501, 500));
        vm.prank(owner);
        new Vault(feeRecipient, 0, 501, 0);

        vm.expectRevert(abi.encodeWithSelector(IVault.TimelockTooLong.selector, 50_401, 50_400));
        vm.prank(owner);
        new Vault(feeRecipient, 0, 0, 50_401);
    }

    function testReentrancyGuardBlocksReentrantDeposit() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        ReentrantVaultToken token;
        vm.prank(owner);
        token = new ReentrantVaultToken("RVT", "RVT", 6);

        vm.prank(owner);
        fresh.addAsset(address(token));

        vm.prank(owner);
        token.mint(alice, 10_000e6);

        vm.prank(alice);
        token.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        fresh.deposit(address(token), 1_000e6, alice);

        bytes memory payload = abi.encodeCall(fresh.deposit, (address(token), 1_000e6, alice));
        vm.prank(owner);
        token.setHook(ReentrantVaultToken.HookType.TransferFrom, address(fresh), payload);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        fresh.deposit(address(token), 1_000e6, alice);
    }

    function testReentrancyGuardBlocksReentrantRequestWithdraw() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        ReentrantVaultToken token;
        vm.prank(owner);
        token = new ReentrantVaultToken("RVT", "RVT", 6);

        vm.prank(owner);
        fresh.addAsset(address(token));

        vm.prank(owner);
        token.mint(alice, 10_000e6);

        vm.prank(alice);
        token.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        fresh.deposit(address(token), 1_000e6, alice);

        bytes memory payload = abi.encodeCall(fresh.requestWithdraw, (fresh.userShares(alice), address(token)));
        vm.prank(owner);
        token.setHook(ReentrantVaultToken.HookType.TransferFrom, address(fresh), payload);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        fresh.deposit(address(token), 1_000e6, alice);
    }

    function testReentrancyGuardBlocksReentrantClaimWithdraw() public {
        Vault fresh = _deployFreshVault(0, 0, DEFAULT_TIMELOCK);
        ReentrantVaultToken token;
        vm.prank(owner);
        token = new ReentrantVaultToken("RVT", "RVT", 6);

        vm.prank(owner);
        fresh.addAsset(address(token));

        vm.prank(owner);
        token.mint(alice, 10_000e6);

        vm.prank(alice);
        token.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        fresh.deposit(address(token), 1_000e6, alice);

        uint256 fullShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(fullShares, address(token));

        advanceBlocks(DEFAULT_TIMELOCK);

        bytes memory payload = abi.encodeCall(fresh.claimWithdraw, ());
        vm.prank(owner);
        token.setHook(ReentrantVaultToken.HookType.Transfer, address(fresh), payload);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        fresh.claimWithdraw();
    }

    function testViewHelpersReturnCurrentState() public {
        _depositUsdc(vault, alice, 100e6);

        uint256 halfShares = vault.userShares(alice) / 2;
        vm.prank(alice);
        vault.requestWithdraw(halfShares, address(usdc));

        address[] memory assets = vault.getAssetList();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(dai));

        IVault.WithdrawRequest memory request = vault.getPendingWithdraw(alice);
        assertEq(request.asset, address(usdc));
        assertGt(request.shares, 0);
        assertGt(request.unlockBlock, block.number);
        assertFalse(request.claimed);
    }

    function testFuzzSingleUserRoundTripUsdc(uint96 amountSeed) public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        uint256 amount = bound(uint256(amountSeed), 1e6, 1_000_000e6);

        vm.prank(alice);
        fresh.deposit(address(usdc), amount, alice);

        uint256 fullShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(fullShares, address(usdc));

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        uint256 amountOut = fresh.claimWithdraw();

        assertEq(amountOut, amount);
    }

    function testFuzzSingleUserRoundTripDai(uint96 amountSeed) public {
        Vault fresh = _deployDefaultVault(0, 0, DEFAULT_TIMELOCK);

        uint256 amount = bound(uint256(amountSeed), 1 ether, 1_000_000 ether);

        vm.prank(alice);
        fresh.deposit(address(dai), amount, alice);

        uint256 fullShares = fresh.userShares(alice);
        vm.prank(alice);
        fresh.requestWithdraw(fullShares, address(dai));

        advanceBlocks(DEFAULT_TIMELOCK);

        vm.prank(alice);
        uint256 amountOut = fresh.claimWithdraw();

        assertEq(amountOut, amount);
    }

    function _deployDefaultVault(uint256 perfFeeBps, uint256 mgmtFeeBps, uint256 timelockBlocks_)
        internal
        returns (Vault fresh)
    {
        fresh = _deployFreshVault(perfFeeBps, mgmtFeeBps, timelockBlocks_);
        _whitelistAsset(fresh, address(usdc));
        _whitelistAsset(fresh, address(dai));
    }

    function _deployFreshVault(uint256 perfFeeBps, uint256 mgmtFeeBps, uint256 timelockBlocks_)
        internal
        returns (Vault fresh)
    {
        vm.prank(owner);
        fresh = new Vault(feeRecipient, perfFeeBps, mgmtFeeBps, timelockBlocks_);

        _approveUsersForVault(address(fresh));
    }

    function _whitelistAsset(Vault target, address asset) internal {
        vm.prank(owner);
        target.addAsset(asset);
    }

    function _depositUsdc(Vault target, address user, uint256 amount) internal returns (uint256 sharesMinted) {
        vm.prank(user);
        sharesMinted = target.deposit(address(usdc), amount, user);
    }

    function _depositDai(Vault target, address user, uint256 amount) internal returns (uint256 sharesMinted) {
        vm.prank(user);
        sharesMinted = target.deposit(address(dai), amount, user);
    }

    function _mintAssetToVault(MockERC20 token, address target, uint256 amount) internal {
        vm.prank(owner);
        token.mint(target, amount);
    }

    function _reportYield(Vault target, MockERC20 token, uint256 amount) internal {
        vm.startPrank(owner);
        token.mint(owner, amount);
        token.approve(address(target), amount);
        target.reportYield(address(token), amount);
        vm.stopPrank();
    }

    function _approveUsersForVault(address spender) internal {
        vm.prank(alice);
        usdc.approve(spender, type(uint256).max);
        vm.prank(bob);
        usdc.approve(spender, type(uint256).max);
        vm.prank(charlie);
        usdc.approve(spender, type(uint256).max);

        vm.prank(alice);
        dai.approve(spender, type(uint256).max);
        vm.prank(bob);
        dai.approve(spender, type(uint256).max);
        vm.prank(charlie);
        dai.approve(spender, type(uint256).max);
    }

    function _activePps(Vault target) internal view returns (uint256) {
        return target.convertToAssets(target.VIRTUAL_SHARES_OFFSET());
    }

    function _mgmtFeeShares(uint256 shareSupply, uint256 feeBps, uint256 dt) internal pure returns (uint256) {
        return Math.mulDiv(shareSupply, feeBps * dt, BPS * YEAR, Math.Rounding.Floor);
    }

    function _profitNeededToReachPps(uint256 targetPps, uint256 managedWad, uint256 shareSupply)
        internal
        pure
        returns (uint256)
    {
        uint256 targetManagedPlusOne = Math.mulDiv(targetPps, shareSupply + VSO, WAD * VSO, Math.Rounding.Ceil);
        if (targetManagedPlusOne == 0) return 0;

        uint256 targetManaged = targetManagedPlusOne - 1;
        if (targetManaged <= managedWad) return 0;
        return targetManaged - managedWad;
    }

    function _toWad(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) return amount;
        if (decimals_ < 18) return amount * 10 ** (18 - decimals_);
        return amount / 10 ** (decimals_ - 18);
    }

    function _fromWad(uint256 wadAmount, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) return wadAmount;
        if (decimals_ < 18) return wadAmount / 10 ** (18 - decimals_);
        return wadAmount * 10 ** (decimals_ - 18);
    }

    function _computeShares(uint256 amountWad, uint256 shareSupply, uint256 managedWad)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amountWad, shareSupply + VSO, managedWad + 1, Math.Rounding.Floor);
    }

    function _computeAssets(uint256 shares, uint256 shareSupply, uint256 managedWad) internal pure returns (uint256) {
        return Math.mulDiv(shares, managedWad + 1, shareSupply + VSO, Math.Rounding.Floor);
    }

    function _currentPps(uint256 managedWad, uint256 shareSupply) internal pure returns (uint256) {
        return Math.mulDiv(managedWad + 1, WAD * VSO, shareSupply + VSO, Math.Rounding.Floor);
    }
}
