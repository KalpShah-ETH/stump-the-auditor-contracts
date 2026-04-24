# Stump the AI Auditor — Base Contracts

Three production-style DeFi contracts. Modify one (≤50 lines) to plant a fund-draining vulnerability, then try to slip it past CertiK's AI Auditor Lite. If the scan misses it, submit. Top three stumps win.

## Challenge Window

**2026-04-28, 9:00 AM ET → 2026-05-12, 23:59 ET.** Rolling submissions. Deadline is firm.

- Apply: https://docs.google.com/forms/d/1dPBQaHMjTGleUUfIo0CJtqygHTSuFULY_l-pQX6kQ-4
- Submission form: sent in your approval email.
- Results: Wed 2026-05-20.

## Prizes

| Place | Prize |
|---|---|
| 1st | $1,000 AI Auditor credits + interview fast-track |
| 2nd | $500 AI Auditor credits + interview fast-track |
| 3rd | $250 AI Auditor credits + interview fast-track |

Every valid stump gets public recognition (opt-in). Interview fast-track = profile handed directly to CertiK's auditor hiring team with challenge context.

## Rules

- **≤50 lines modified** (added + changed; comments count, whitespace does not)
- **4 AI Auditor Lite scans** per person, flexible across the three contracts
- **Up to 3 submissions** per person, one per contract
- **Must compile** under this repo's Foundry config
- **No new imports**; no removed or renamed external/public functions
- **Severity bar: Critical or High only**
- **No trivial backdoors** — your diff has to read like a real developer mistake

### Severity Bar

**Critical** — direct theft of user funds, permanent freezing of user funds, protocol insolvency.
**High** — theft or permanent freezing of unclaimed yield, temporary freezing of user funds.

Rejected: Medium and below; exploits requiring admin action or external conditions (oracle depegs, MEV on pools outside scope).

### Auto-Disqualified

- Unrestricted `drain()` / `rescue()` / `emergencyWithdraw()`
- Hardcoded attacker address
- Removed `onlyOwner` / `whenNotPaused` / `nonReentrant` with no replacement
- Inverted access control

## Trust Model

The owner (`Ownable2Step`) is assumed honest — admin-only exploits are out of scope. Bugs must be exploitable by an unprivileged attacker, or require only normal admin actions (config changes, reward issuance).

External conditions the attacker doesn't control (unrelated oracle depegs, MEV on out-of-scope pools) are also out of scope.

Contracts use `Ownable2Step`, `ReentrancyGuard`, `Pausable`, and `SafeERC20`. Fee-on-transfer and rebasing tokens are explicitly rejected via pre/post balance deltas.

## The Three Contracts

### `src/Vault/Vault.sol` — Multi-Asset Vault

ERC-4626-inspired vault over multiple whitelisted stablecoins. Shares claim pro-rata on WAD-normalized assets. Management fee (time-based) + performance fee (on per-share HWM lift). Block-based withdrawal timelock with proportional pending-side yield share. Virtual-share offset blocks first-depositor inflation attacks. Full mechanics: [`src/Vault/README.md`](./src/Vault/README.md).

### `src/Staking/Staking.sol` — Lock-Tiered Staking

Synthetix `StakingRewards` × MasterChef × veToken-lite. Users stake into tiered locks with boost multipliers, accrue rewards in multiple tokens, and early-unstake penalties redistribute to remaining stakers. `primaryRewardToken == stakingToken` is a load-bearing invariant. Full mechanics: [`src/Staking/README.md`](./src/Staking/README.md).

### `src/Lending/Lending.sol` — Lending Pool

Aave v2-lite. Scaled-balance supply/borrow, kinked interest curve, oracle-priced collateral, health-factor liquidation. Scales: **RAY** (1e27) for indices and rates, **WAD** (1e18) for USD and HF, **BPS** (10_000) for config params, **1e8** for raw Chainlink-style oracle prices. Full mechanics: [`src/Lending/README.md`](./src/Lending/README.md).

## Where to Look

Good stumps live where **two features interact**:

- **Vault** — fee accrual × pending withdrawals, reportYield × active/pending skew
- **Staking** — reward accumulator × compound/emergency ordering, penalty flush × rate recalc
- **Lending** — interest accrual × liquidation, oracle staleness × health factor, index rounding × long-horizon drift

Single-line rounding flips often beat multi-line reworks. Diff size isn't judged — severity, subtlety, realism, and novelty are.

## Two Paths to Win

### Path A — Plant a vulnerability and slip it past Lite

1. **Apply.** Submit the application form. Decisions within 48 hours.
2. **Get whitelisted on AI Auditor.** Approved applicants are whitelisted on https://aiauditor.certik.com. Sign up (Google or magic link) — your account comes pre-loaded with **4 Lite scan credits**.
3. **Read the contracts.** Fork this repo. Pick one of `Vault`, `Staking`, or `Lending`. Study the per-contract README and the source.
4. **Plant a vulnerability.** Modify the contract you picked, ≤50 lines. The bug must be:
   - Critical or High severity (real fund-drain — see severity bar above)
   - Subtle enough to slip past AI Auditor Lite
   - Realistic enough that a senior engineer could plausibly ship it as a mistake
5. **Scan with Lite mode only.** Run AI Auditor against your modified contract.
   - **⚠️ Lite mode only. Do NOT use Max mode.** Max is disabled for the challenge — any Max-mode scan is invalid, and Max would burn through your credits faster.
   - Each scan costs one credit. You get 4 total, flexible across the three contracts.
6. **Iterate.** If Lite flags your bug, the scan is consumed and you have 3 left. Tweak and rescan. If Lite misses your bug, you've stumped it.
7. **Submit.** One valid stump = one Lite-mode scan that missed a real Critical/High vulnerability you planted. Submit via the form linked in your approval email.

### Path B — Find a real vulnerability already in the base contracts

The base contracts may contain real, intentional vulnerabilities. Finding one is the other way to win. Same severity bar, same prizes, same judging.

1. **Apply** (same as Path A).
2. **Read the unmodified contracts** in this repo carefully.
3. **Find a real bug.** It has to be Critical or High — same definitions. Write a Foundry PoC that proves the exploit against the unmodified base.
4. **Submit** via the same form. Pick the contract, link your PoC repo, write up the bug. No scan URL needed for Path B (you didn't plant anything; nothing to scan against).

Path B is not easier than Path A. The contracts have been written carefully and the bugs (if any exist) are not labeled. Looking only at the diff between the base and your fork tells you nothing on Path B — there is no diff.

You can submit on either path. **Up to 3 submissions per person total**, across both paths combined, max one per contract.

## Getting Started

```bash
git clone --recurse-submodules https://github.com/CertiKProject/stump-the-auditor-contracts
cd stump-the-auditor-contracts
forge build
forge test
```

Invariant + fuzz coverage:

```bash
forge test --match-path "test/invariants/*"
forge test --fuzz-runs 1000
```

**PoC template:** copy `test/PlantPoC.t.sol.example` → `test/PlantPoC.t.sol`, plant your bug, and prove the exploit with a Foundry test before submitting.

## Requirements

- [Foundry](https://book.getfoundry.sh/) — install via `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- Solidity `^0.8.24`, EVM version `cancun`
- OpenZeppelin Contracts v5.1 (pinned submodule)

If `forge build` fails on a fresh clone of the unmodified base, email us and we'll patch.

## Submission Contents (Recap)

Submit via the form linked in your approval email. Provide:

- Which contract you targeted (Vault / Staking / Lending)
- Path: A (planted) or B (existing in base)
- AI Auditor Lite scan URL — **Path A only** (proof Lite missed your planted bug)
- GitHub repo URL — your fork (Path A: contains your ≤50-line modification; Path B: contains your Foundry PoC against the unmodified base)
- Severity claim (Critical or High) with subclass + 1-paragraph justification
- Writeup: what the bug is, exploit steps, impact, why it's a realistic dev mistake

Up to 3 submissions per person, max one per contract, across both paths combined.

## Contact

**dickson.wu@certik.com** — rules questions, scan resets, base-contract bug reports.

## License

MIT. See [LICENSE](./LICENSE).
