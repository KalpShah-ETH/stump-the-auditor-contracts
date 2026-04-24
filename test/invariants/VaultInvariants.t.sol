// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVault} from "src/interfaces/IVault.sol";
import {Vault} from "src/Vault/Vault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract VaultHandler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    // Slack for handler-vs-vault rounding drift across deposit/request/cancel cycles mixed
    // with reportYield and mgmt fee accrual. 1e15 = 0.001 WAD; negligible vs realistic yield,
    // generous vs worst-case virtual-offset + share-math drift over invariant depth × runs.
    uint256 internal constant YIELD_SLACK_WAD = 1e15;

    Vault internal immutable vault;
    MockERC20 internal immutable usdc;
    MockERC20 internal immutable dai;
    address internal immutable owner;
    address[] internal actors;

    mapping(address => uint256) internal depositedWad;
    mapping(address => uint256) internal claimedWad;
    mapping(address => uint256) internal yieldCreditWad;
    uint256 internal totalReportedYieldWad;

    uint256 internal lastTotalManagedWad;
    uint256 internal lastHighWaterMarkPPS;
    bool internal totalManagedMonotonic = true;
    bool internal highWaterMarkMonotonic = true;

    constructor(Vault vault_, MockERC20 usdc_, MockERC20 dai_, address owner_, address[] memory actors_) {
        vault = vault_;
        usdc = usdc_;
        dai = dai_;
        owner = owner_;
        actors = actors_;

        lastTotalManagedWad = vault_.totalAssets();
        lastHighWaterMarkPPS = vault_.highWaterMarkPPS();
    }

    function deposit(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        MockERC20 asset = _asset(assetSeed);
        uint256 balance = asset.balanceOf(actor);
        if (balance == 0) {
            _recordState(false);
            return;
        }

        uint256 minAmount = _isUsdc(asset) ? 1e6 : 1 ether;
        uint256 amount = bound(amountSeed, minAmount, balance);

        vm.prank(actor);
        try vault.deposit(address(asset), amount, actor) {
            depositedWad[actor] += _toWad(amount, asset.decimals());
        } catch {}

        _recordState(false);
    }

    function requestWithdraw(uint256 actorSeed, uint256 assetSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);
        uint256 availableShares = vault.userShares(actor);
        if (availableShares == 0) {
            _recordState(false);
            return;
        }

        uint256 shares = bound(sharesSeed, 1, availableShares);
        address asset = address(_asset(assetSeed));

        vm.prank(actor);
        try vault.requestWithdraw(shares, asset) {} catch {}

        _recordState(false);
    }

    function claimWithdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        IVault.WithdrawRequest memory request = vault.getPendingWithdraw(actor);
        if (request.shares == 0) {
            _recordState(false);
            return;
        }

        bool allowDecrease = false;

        vm.prank(actor);
        try vault.claimWithdraw() returns (uint256 amountOut) {
            claimedWad[actor] += _toWad(amountOut, _assetDecimals(request.asset));
            allowDecrease = true;
        } catch {}

        _recordState(allowDecrease);
    }

    function cancelWithdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (vault.getPendingWithdraw(actor).shares == 0) {
            _recordState(false);
            return;
        }

        vm.prank(actor);
        try vault.cancelWithdraw() {} catch {}

        _recordState(false);
    }

    function reportYield(uint256 assetSeed, uint256 amountSeed) external {
        if (vault.totalShares() == 0) {
            _recordState(false);
            return;
        }

        try vault.accrueFees() {} catch {}

        MockERC20 asset = _asset(assetSeed);
        uint256 nativeAmount =
            _isUsdc(asset) ? bound(amountSeed, 1e6, 500_000e6) : bound(amountSeed, 1 ether, 500_000 ether);
        uint256 profitWad = _toWad(nativeAmount, asset.decimals());
        uint256 totalSharesBefore = vault.totalShares();

        if (totalSharesBefore == 0) {
            _recordState(false);
            return;
        }

        uint256 totalClaimShares = totalSharesBefore;
        uint256 actorLength = actors.length;
        for (uint256 i; i < actorLength; ++i) {
            totalClaimShares += vault.getPendingWithdraw(actors[i]).shares;
        }

        uint256 allocated;
        uint256 firstHolderIndex = type(uint256).max;
        for (uint256 i; i < actorLength; ++i) {
            uint256 actorShares = vault.userShares(actors[i]) + vault.getPendingWithdraw(actors[i]).shares;
            if (actorShares == 0) continue;
            if (firstHolderIndex == type(uint256).max) firstHolderIndex = i;

            uint256 credit = Math.mulDiv(profitWad, actorShares, totalClaimShares, Math.Rounding.Floor);
            yieldCreditWad[actors[i]] += credit;
            allocated += credit;
        }

        if (firstHolderIndex != type(uint256).max && allocated < profitWad) {
            yieldCreditWad[actors[firstHolderIndex]] += profitWad - allocated;
        }

        vm.startPrank(owner);
        asset.mint(owner, nativeAmount);
        asset.approve(address(vault), nativeAmount);
        try vault.reportYield(address(asset), nativeAmount) {
            totalReportedYieldWad += profitWad;
        } catch {}
        vm.stopPrank();

        _recordState(false);
    }

    function accrueFees() external {
        try vault.accrueFees() {} catch {}
        _recordState(false);
    }

    function advanceTime(uint256 secondsSeed) external {
        uint256 jump = bound(secondsSeed, 1, 30 days);
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + ((jump + 11) / 12));
        _recordState(false);
    }

    function pause() external {
        if (vault.paused()) {
            _recordState(false);
            return;
        }

        vm.prank(owner);
        try vault.pause() {} catch {}
        _recordState(false);
    }

    function unpause() external {
        if (!vault.paused()) {
            _recordState(false);
            return;
        }

        vm.prank(owner);
        try vault.unpause() {} catch {}
        _recordState(false);
    }

    function totalManagedMonotonicOk() external view returns (bool) {
        return totalManagedMonotonic;
    }

    function highWaterMarkMonotonicOk() external view returns (bool) {
        return highWaterMarkMonotonic;
    }

    function depositedWadOf(address actor) external view returns (uint256) {
        return depositedWad[actor];
    }

    function claimedWadOf(address actor) external view returns (uint256) {
        return claimedWad[actor];
    }

    function yieldCreditWadOf(address actor) external view returns (uint256) {
        return yieldCreditWad[actor];
    }

    function entitlementBoundHolds(address actor) external view returns (bool) {
        uint256 entitlement = claimedWad[actor] + vault.previewWithdraw(vault.userShares(actor))
            + vault.getPendingWithdraw(actor).wadOwed;
        return entitlement <= depositedWad[actor] + totalReportedYieldWad + YIELD_SLACK_WAD;
    }

    function _recordState(bool allowManagedDecrease) internal {
        uint256 currentManagedWad = vault.totalAssets();
        if (currentManagedWad < lastTotalManagedWad && !allowManagedDecrease) {
            totalManagedMonotonic = false;
        }
        lastTotalManagedWad = currentManagedWad;

        uint256 currentHighWaterMarkPPS = vault.highWaterMarkPPS();
        if (currentHighWaterMarkPPS < lastHighWaterMarkPPS) {
            highWaterMarkMonotonic = false;
        }
        lastHighWaterMarkPPS = currentHighWaterMarkPPS;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _asset(uint256 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? usdc : dai;
    }

    function _assetDecimals(address asset) internal view returns (uint8) {
        if (asset == address(usdc)) return usdc.decimals();
        return dai.decimals();
    }

    function _isUsdc(MockERC20 asset) internal view returns (bool) {
        return address(asset) == address(usdc);
    }

    function _toWad(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) return amount;
        if (decimals_ < 18) return amount * 10 ** (18 - decimals_);
        return amount / 10 ** (decimals_ - 18);
    }
}

contract VaultInvariants is StdInvariant, BaseTest {
    uint256 internal constant PERF_FEE_BPS = 2_000;
    uint256 internal constant MGMT_FEE_BPS = 100;
    uint256 internal constant TIMELOCK_BLOCKS = 3;
    uint256 internal constant INITIAL_USDC = 5_000_000e6;
    uint256 internal constant INITIAL_DAI = 5_000_000 ether;

    MockERC20 internal usdc;
    MockERC20 internal dai;
    Vault internal vault;
    VaultHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();

        usdc = deployMockToken("USDC", 6);
        dai = deployMockToken("DAI", 18);

        vm.prank(owner);
        vault = new Vault(feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, TIMELOCK_BLOCKS);

        vm.prank(owner);
        vault.addAsset(address(usdc));
        vm.prank(owner);
        vault.addAsset(address(dai));

        actors.push(alice);
        actors.push(bob);
        actors.push(charlie);

        for (uint256 i; i < actors.length; ++i) {
            mintAndApprove(usdc, actors[i], address(vault), INITIAL_USDC);
            mintAndApprove(dai, actors[i], address(vault), INITIAL_DAI);
        }

        handler = new VaultHandler(vault, usdc, dai, owner, actors);
        targetContract(address(handler));
    }

    function invariant_vaultAccountingAndMonotonicityHold() public view {
        uint256 summedShares = vault.userShares(feeRecipient);
        for (uint256 i; i < actors.length; ++i) {
            summedShares += vault.userShares(actors[i]);
        }
        assertEq(vault.totalShares(), summedShares);

        address[] memory assets = vault.getAssetList();
        for (uint256 i; i < assets.length; ++i) {
            (,, uint256 totalHeld) = vault.assetConfig(assets[i]);
            assertGe(IERC20(assets[i]).balanceOf(address(vault)), totalHeld);
        }

        assertTrue(handler.totalManagedMonotonicOk());
        assertTrue(handler.highWaterMarkMonotonicOk());
        assertLe(vault.lastFeeAccrual(), block.timestamp);
    }

    function invariant_userEntitlementsStayBoundedAndPendingRequestsStayConsistent() public view {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertTrue(handler.entitlementBoundHolds(actor));

            IVault.WithdrawRequest memory request = vault.getPendingWithdraw(actor);
            if (request.shares == 0) {
                assertEq(request.wadOwed, 0);
                assertEq(request.asset, address(0));
                assertEq(request.unlockBlock, 0);
                assertFalse(request.claimed);
            } else {
                assertTrue(request.asset == address(usdc) || request.asset == address(dai));
                assertGt(request.unlockBlock, 0);
                assertFalse(request.claimed);
            }
        }
    }
}
