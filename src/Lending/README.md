# Lending — Multi-Asset Lending Pool with Collateral and Liquidation

An Aave v2–lite lending pool. Users supply assets to earn interest and borrow other assets against supplied collateral. Supports multiple listed reserves, each with independent collateral factor, liquidation threshold, liquidation bonus, reserve factor, and utilization-based interest curve. Positions are liquidatable when health factor drops below 1.

## Conceptual Model

- **Supplied assets** tracked as *scaled balances*: `scaledSupply = actualSupply / supplyIndex`. As interest accrues, `supplyIndex` grows; suppliers' claims grow proportionally.
- **Borrowed assets** use `borrowIndex` the same way. Both indices start at `RAY` and only increase over time.
- **Health factor** = `Σ(collateralValueUSD × liquidationThreshold) / Σ(debtValueUSD)`. HF ≥ 1e18 (WAD) means healthy.
- **Liquidation.** Anyone can repay up to `closeFactor × debt` on behalf of an unhealthy borrower and receive the borrower's collateral at a discount (liquidation bonus).
- **Interest rate model.** Kinked curve. Below optimal utilization, borrow rate rises with `slope1`. Above, with `slope2` (steeper).

## Scale Conventions

| Unit | Value | Used for |
|---|---|---|
| **RAY** | 1e27 | indices (`supplyIndex`, `borrowIndex`), interest rates per-year and per-second |
| **WAD** | 1e18 | USD values, health factor, price normalization |
| **BPS** | 10_000 | config params (collateral factor, LTV, bonus, reserve factor, close factor) |
| Oracle | 1e8 | raw Chainlink-style oracle prices, normalized to WAD internally |

Scaled-balance invariant: `user_underlying = user_scaled × index / RAY`, floor-rounded.

## External Surface

User:
- `supply(asset, amount, onBehalfOf)`
- `withdraw(asset, amount, to) → withdrawn` (callable while paused; uses `type(uint256).max` for full)
- `borrow(asset, amount, to)`
- `repay(asset, amount, onBehalfOf) → repaid` (callable while paused)
- `liquidate(borrower, collateralAsset, debtAsset, debtToCover) → (debtRepaid, collateralSeized)`

Views: `getUserAccountData`, `getUserReserveData`, `getReserveData`, `getReserveList`, `utilizationRateRay`, `currentBorrowRateRay`, `currentSupplyRateRay`. All views simulate interest accrual to `block.timestamp`.

Admin (owner):
- `listReserve`, `setReserveParams`, `setInterestRateParams`
- `setBorrowEnabled`, `setCollateralEnabled`
- `setOracle`, `setCloseFactor`
- `withdrawReserves` (up to `accruedReserves`)
- `pause`, `unpause`

All admin setters call `_accrueInterest(asset)` first so new params apply forward only.

## Constants

| Name | Value |
|---|---|
| `MIN_HEALTH_FACTOR` | 1e18 |
| `MAX_CLOSE_FACTOR_BPS` | 10_000 (100%) |
| `MAX_LIQ_BONUS_BPS` | 2_000 (20%) |
| `MAX_COLLATERAL_FACTOR_BPS` | 9_000 (90%) |
| `MAX_RESERVE_FACTOR_BPS` | 5_000 (50%) |
| `MAX_ORACLE_STALENESS` | 1 hour |
| `ORACLE_DECIMALS` | 8 |

## Key Design Choices

- **Liquidator receives collateral as an internal supply position, not a direct transfer.** Mirrors Aave v2 "receiveAToken = true". Keeps reserve-balance math simple and eliminates one reentrancy surface.
- **`collateralAsset != debtAsset`** is required in `liquidate`. Simplifies the case where seized collateral is also the debt being repaid.
- **Liquidations are blocked while paused.** Emergency pause stops debt repricing from taking place mid-inspection.
- **Debt-free withdraws skip oracle reads.** If a user has no debt, there's nothing to check HF against, so no price is fetched. Stale-oracle reverts don't affect uncollateralized exits.
- **Oracle staleness lives in `Lending.sol`, not in the oracle itself.** The oracle returns `(price, updatedAt)`; Lending enforces the freshness gate.

## Interest Math Contract

```
supplyRate = borrowRate × utilization × (1 − reserveFactor)
```

This guarantees reserves are funded from interest, not from supplier principal. Index update is per-second linear (Aave v2 approximation):

```
newBorrowIndex = borrowIndex × (RAY + borrowRatePerSecond × dt) / RAY
newSupplyIndex = supplyIndex × (RAY + supplyRatePerSecond × dt) / RAY
reserveDelta   = totalBorrowActual × (newBorrowIndex − borrowIndex) / borrowIndex × reserveFactorBps / BPS
```

All multiplications through indices use `Math.mulDiv` to avoid 256-bit overflow on multi-year accruals.

## Key Invariants

1. `supplyIndex` and `borrowIndex` are monotonically non-decreasing per reserve.
2. `supplyIndex × totalScaledSupply / RAY >= borrowIndex × totalScaledBorrow / RAY` (per asset, always).
3. `IERC20(asset).balanceOf(this) >= netSupply + accruedReserves` where `netSupply = totalSupplyActual − totalBorrowActual`.
4. At end of every user-facing mutating call, HF ≥ 1e18 if the user has debt. HF may drop < 1e18 only between oracle updates and the next liquidation.
5. `lastUpdateTimestamp <= block.timestamp` per reserve.
6. Entry in `userCollateralAssets[user]` ↔ `userScaledSupply[user][asset] > 0`. Same for borrows.
7. `accruedReserves` monotonically non-decreasing except on `withdrawReserves`.
8. Sum across users of `userScaledSupply[*][asset]` == `totalScaledSupply`. Same for borrows.

## Trust / Scope Notes

- Fee-on-transfer / rebasing tokens rejected via pre/post balance deltas.
- Oracle-depeg exploits the attacker can't cause are out of scope.
- Admin is assumed honest; admin-only exploits are out of scope.

## Hotspots for Auditors

- **Interest accrual vs liquidation.** `_accrueInterest` must run on both the collateral and debt assets at the start of `liquidate`, or HF is computed against stale indices.
- **Oracle staleness × health factor.** Does every path that computes HF check freshness? Does a debt-free path correctly skip it?
- **Index rounding direction.** Scaled supply rounds DOWN on mint, UP on burn (protocol-favoring). Flipping any of these leaks value.
- **Close-factor clamp.** `debtToCover` must be clamped, and a clamped debt should not be allowed to overshoot collateral seizure.
- **Reserve-balance accounting during liquidation.** Liquidator's collateral is credited to their supply scaled balance; `totalScaledSupply` is unchanged (same asset, transferred between users). Any path that mutates `totalScaledSupply` during liquidation is suspect.
- **Dust positions.** Tiny scaled amounts can round to zero on read but survive on write — any comparison that treats `0` differently from the raw scaled storage is a candidate.
