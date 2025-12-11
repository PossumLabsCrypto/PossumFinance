# Security review report

This report was created by [Mario Poneder](https://x.com/MarioPoneder), Security Researcher @spearbit, @zenith256, @SecurityOak & http://trust-security.xyz | Judge @code4rena & @cantinaxyz.

Verify the correctness of the report on Mario's gist:
[https://gist.github.com/MarioPoneder/6ffb8cfc301811bf09fe49db460b357d](https://gist.github.com/MarioPoneder/6ffb8cfc301811bf09fe49db460b357d)


**Project:** [`PossumLabsCrypto/PossumFinance`](https://github.com/PossumLabsCrypto/PossumFinance)   
**Commit:** [83d9dcefe626dbe585c880cbd4cdc6a734acb549](https://github.com/PossumLabsCrypto/PossumFinance/commit/83d9dcefe626dbe585c880cbd4cdc6a734acb549)   
**Start Date:** 2025-12-03

**Scope:**
* `src/AssetVault.sol` (nSLOC: 98, coverage: 100% lines / 100% statements / 100% branches / 100% functions)
* `src/SignalVault.sol` (nSLOC: 329, coverage: 100% lines / 100% statements / 100% branches / 100% functions)

**Overview**
* **[L-01]**  Centralized privileged withdrawal in `withdrawTokens` function
* **[L-02]**  Sybil attacks can disproportionately steer vault direction
* **[I-01]**  Implicit epoch‑0 bootstrap causes off‑by‑one behavior and non‑paying first epoch
* **[I-02]**  Summary of known issues in deployed contracts

---

## **[L-01]**  Centralized privileged withdrawal in `AssetVault` contract

### Description

The `withdrawTokens` function grants a single hard‑coded `owner` unrestricted authority to withdraw the entire balance of any ERC20 token held by `AssetVault`:

```solidity
function withdrawTokens(address _token) external {
    if (msg.sender != owner) revert NotOwner();

    uint256 amount = IERC20(_token).balanceOf(address(this));

    ///@dev Send the tokens to the owner
    IERC20(_token).safeTransfer(owner, amount);
}
```

Because `owner` is initialized to a fixed address and cannot be changed or renounced, this effectively creates a centralized entry point that can drain all vault assets (including `UP_TOKEN`, `DOWN_TOKEN`, and any other ERC20).  

> [!NOTE]
> This only affects the `AssetVault`, the `owner` access is not present in the `SignalVault`, avoiding unilateral access to tokens staked by users.

### Recommendation

It is recommended to minimize or remove centralized control while preserving emergency capabilities. 


**Status:**  
🆗 Acknowledged

> - This version of the protocol is an MVP with an expected lifetime of 3-6 months which serves a specific purpose: to collect data on the underlying business logic and offer a usable proof of concept. The current version is not expected to scale, hence access controls are of lesser concern. An upcoming "full release" version with the purpose to scale will have additional features and no privileged access control.
> - The Possum treasury has provided 100% of the trading capital in the Asset Vault with no external flows intended. For understandable reasons, we maintain control over our own working capital.

## **[L-02]**  Sybil attacks can disproportionately steer vault direction

### Description

The protocol’s votepower model gives every address with at least `MIN_STAKE_FOR_VOTEPOWER` the same baseline `UNIFORM_VOTEPOWER`, regardless of how much more PSM it holds. An attacker can split a large PSM position across many addresses, each just over the minimum threshold, and obtain a total votepower roughly proportional to the number of addresses rather than the total PSM.  

Because `vaultDirection` is determined by the aggregate `upVotes` vs `downVotes`, this Sybil strategy allows a single economic actor to disproportionately influence the vault’s trading direction (whether `AssetVault` buys UP and sells DOWN, or the reverse) compared to an honest participant with the same total stake but only one address. Over time, this can let the attacker steer the vault into positions that favor their external trades or PSM exposure, at the expense of less sophisticated users who assume a more “one person, one vote” dynamic.

### Recommendation

It is recommended to consider reducing Sybil advantages by making votepower scale more smoothly with stake size.  

**Status:**  
🆗 Acknowledged

> Intended mechanic of the MVP and partially mitigated by the 1% deposit fee.
>
> Smooth scaling of voting power according to the amount staked was our original design. However, it doesn't make sense from a signal logic perspective.
>
> Staking more PSM doesn't mean the prediction of the user is any more useful than the prediction of other users.
>
> The cost of this sybil attack is linearly proportional to:
> 1. deposit fee %
> 2. MIN_STAKE_FOR_VOTEPOWER 
> 3. price of PSM
> 
> We can use this fact to construct a quadratic or even cubic cost increase to sybils in a later version. 

## **[I-01]**  Implicit epoch‑0 bootstrap causes off‑by‑one behavior and non‑paying first epoch

### Description

In `SignalVault`, `activeEpochID` is never explicitly initialized and therefore starts at `0`. However, all prediction and accounting logic is written around epoch IDs 1 and 2, which are toggled every settlement:
- `castPrediction` writes to `predictions[1]` / `predictions[2]` only.
- `getPendingRewards` and `_claim` compute `claimEpochID = (activeEpochID == 1) ? 2 : 1`, i.e. they assume the two valid epochs are `1` and `2`.
- `stakedUp`, `stakedDown`, `upVotes`, `downVotes` are used with epoch IDs `1` and `2` for user participation.

On the first `settleEpoch` call:
- `activeEpochID` is still `0`, so:
  - `last_result` is computed for epoch `0` based on `last_settlementPrice` (which starts at 0) and the first oracle price, effectively marking a “phantom” epoch‐0 as up.
  - `last_winnerStakeTotal` is derived from `stakedUp[0]` / `stakedDown[0]`, which are 0 (no predictions ever stored for epoch 0).
  - `vaultDirection` is computed from `upVotes[0]` / `downVotes[0]` (both 0), defaulting to the `down` path.
- `activeEpochID` is then set to `1`, and `nextSettlement` is moved forward by one `EPOCH_DURATION`.

Consequences:
- The first settlement after deployment does not pay any rewards, even if users had staked PSM before it. There is no way for users to have a prediction recorded for epoch 0 because `castPrediction` writes only to epochs `1` and `2`.
- The “first epoch” visible to users (with real predictions) is actually the second on‑chain settlement, which is unintuitive and can cause off‑by‑one confusion:
- Reward and direction events for the first settlement (`EpochSettled`) refer to an epoch with no user participation and no possibility of rewards, which can mislead indexers and users monitoring event logs.

### Recommendation

It is recommended to explicitly handle the epoch-0 boostrap in the constructor. Alternatively, clearly document this behavior in comments and documentation so that users and integrators understand that the first settlement is a non‑paying initialization step.

**Status:**  
🆗 Acknowledged

> Note taken to create additional documentation for integrators when it becomes relevant.

## **[I-02]**  Summary of known issues in deployed contracts

### Description

There are three issues that exist in the fist deployed version (MVP) of [`AssetVault`](https://arbiscan.io/address/0xc7a22081662faeedc27993cb72cba6141e15ba48) and [`SignalVault`](https://arbiscan.io/address/0xb800B8dbCF9A78b16F5C1135Cd1A39384ABf1fbc) which have been addressed in the current codebase. They are included here for transparency and for auditors/users reviewing historical behavior.

1. **PSM redeemable for PSM**  
   - *Problem*: The original `redeemPSM` logic allowed users to redeem PSM for PSM held by `AssetVault`, which is economically pointless and could create confusing or circular flows.  
   - *Mitigation*: A dedicated `sweepPsmToSignalVault` function was added so that any PSM in `AssetVault` is instead swept back to `SignalVault` for use as staking rewards, avoiding PSM↔PSM redemption.

2. **Division by zero in reward calculation edge case**  
   - *Problem*: In `SignalVault.getPendingRewards`, the line `pendingRewards = (epochReward * userStake.stakeBalance) / last_winnerStakeTotal;` could divide by zero if all winners fully unstaked before claiming, leaving `last_winnerStakeTotal == 0` for a winning epoch.  
   - *Mitigation*: A guard `if (last_winnerStakeTotal > 0)` was added before the division, ensuring that in such edge cases `pendingRewards` is simply 0 and the function never reverts.

3. **Potential overflow in exponential vote power calculation**  
   - *Problem*: Vote power was computed as `UNIFORM_VOTEPOWER * (VOTE_INCREASE_BASE ** userStake.winStreak)`
    which could theoretically overflow if `winStreak` became very large (e.g. > 247), even though this is extremely unlikely in practice. 
   - *Mitigation*: The code now caps the streak for exponentiation with the check `if (userStake.winStreak > 50)`, and also caps the result at `VOTE_POWER_CAP`, preventing any overflow while preserving the intended behavior.

### Recommendation

It is recommeded to include these mitigation measures when deploying the next version of the protocol.

**Status:**  
✅ Already resolved at the review commit