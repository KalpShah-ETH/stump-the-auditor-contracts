# Vault — Multi-Asset Vault with Fees and Timelocks

An ERC-4626-inspired vault that accepts multiple whitelisted, stable-denominated ERC-20s, issues shares proportional to deposits, accrues management and performance fees, and enforces a block-based withdrawal timelock.

## Conceptual Model

- Holds multiple stablecoins (USDC, USDT, DAI, etc.), all assumed 1:1 in value. No oracle required.
- Internal accounting in **WAD** (1e18). Token decimals normalized at entry/exit.
- Deposit asset X → receive shares. Shares claim `totalManagedWad / totalShares` pro-rata.
- Yield enters via admin `reportYield(asset, amount)`. Performance fee taken on yield above a per-share high-water mark.
- Management fee accrues linearly with time, minted as shares to the fee recipient.
- Withdrawals are two-step: `requestWithdraw` burns shares and freezes a WAD-claim, `claimWithdraw` releases the asset after `timelockBlocks`.

## Fee Mental Model

- **PPS** (price-per-share) = `totalManagedWad / (totalShares + VIRTUAL_SHARES_OFFSET)` in WAD.
- Deposits and withdrawals preserve PPS (round-to-protocol rules with virtual offset). Only `reportYield` lifts it.
- `_accrueFees()` runs at the start of every state-mutating path:
  1. Management fee (time-based, dilution-only) → shares minted to recipient.
  2. If `currentPPS > highWaterMarkPPS`: performance fee shares minted against the full claim base. HWM updated.
- Pending withdrawals share proportionally in reported yield and pay their performance-fee share at request time; the request's claim value is frozen at `requestWithdraw`.

## External Surface

User:
- `deposit(asset, amount, receiver) → shares`
- `requestWithdraw(shares, asset) → unlockBlock`
- `claimWithdraw() → amountOut` (callable while paused)
- `cancelWithdraw()` (only before `unlockBlock`; returns original shares)

Views: `totalAssets`, `convertToShares`, `convertToAssets`, `previewDeposit`, `previewWithdraw`, `getAssetList`, `getPendingWithdraw`. All preview views simulate a fee accrual.

Admin (owner, `Ownable2Step`):
- `addAsset`, `removeAsset` (requires `totalHeld == 0`)
- `setPerformanceFee`, `setManagementFee`, `setTimelockBlocks`, `setFeeRecipient`
- `reportYield(asset, amount)` — pulls whitelisted profit, normalizes, lifts PPS
- `accrueFees`, `pause`, `unpause`

All admin setters call `_accrueFees()` first so param changes apply forward-only.

## Constants

| Name | Value | Purpose |
|---|---|---|
| `WAD` | 1e18 | internal accounting scale |
| `BPS` | 10_000 | config param scale |
| `MAX_MANAGEMENT_FEE_BPS` | 500 | 5% annualized cap |
| `MAX_PERFORMANCE_FEE_BPS` | 3_000 | 30% cap |
| `MAX_TIMELOCK_BLOCKS` | ~7 days of blocks | timelock upper bound |
| `MIN_INITIAL_DEPOSIT` | 1e6 | first-depositor protection |
| `VIRTUAL_SHARES_OFFSET` | 1e3 | first-depositor inflation mitigation |

## Key Invariants

1. `totalShares == sum(userShares[*])` across every holder including fee recipient.
2. For every whitelisted asset: `IERC20(asset).balanceOf(vault) >= assetConfig[asset].totalHeld`.
3. `totalManagedWad` is monotonically non-decreasing except on `claimWithdraw`.
4. `highWaterMarkPPS` is monotonically non-decreasing.
5. No user can claim more WAD than deposit + pro-rata yield share.
6. `lastFeeAccrual <= block.timestamp`.
7. At most one outstanding `pendingWithdraw` per user.

## Trust / Scope Notes

- Fee-on-transfer and rebasing tokens are rejected via pre/post balance deltas.
- Only the owner can whitelist assets or report yield. Owner is assumed honest.
- `reportYield` does not accept negative yield; loss handling is explicitly out of scope.
- `cancelWithdraw` is disallowed after unlock to close the management-fee-avoidance loop from request→wait→cancel cycles.

## Hotspots for Auditors

Bugs tend to live where **two features interact**:

- Fee accrual × pending withdrawals — does a request-side perf-fee charge reconcile with what the active side later sees?
- `reportYield` × skewed active/pending ratios — does HWM lift credit the right base?
- Deposit ordering × fee accrual — is `_accrueFees` called before shares are computed?
- Rounding direction in `_computeShares` / `_computeAssets` — floor everywhere, or does one path ceil?
