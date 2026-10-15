# Gavel Protocol: a USDC-blocked lender position blocks repayment and forces the borrower into default

| | |
|---|---|
| **Target** | [The Gavel Protocol](https://github.com/JamieFrame/The-Gavel-Protocol) v1 on Arbitrum One |
| **Contracts** | `LoanProtocol` [`0xFCDd…1fEf2`](https://arbiscan.io/address/0xFCDd6Ef75638D8D19ad634004C234Ad18751fEf2), `NFTLoanProtocol` [`0x506e…147eb`](https://arbiscan.io/address/0x506e414c7D39639B2E9E318C46eD378AD51147eb) |
| **Source** | commit `457fea8`. The deployed implementations are an exact Sourcify match. |
| **Function** | `repayLoan` (`LoanProtocol.sol:1509`, `NFTLoanProtocol.sol:1475`) |
| **Class** | Push payment to an address the token can refuse → liveness failure → loss of collateral |
| **Severity** | **Medium**, as confirmed by the Gavel team |
| **Status** | Confirmed and published by the team as [KI-3](https://github.com/JamieFrame/The-Gavel-Protocol/blob/main/docs/known-issues.md#ki-3--repayment-reverts-if-the-loan-token-refuses-transfers-to-the-lender-position-holder). v1 is immutable, and the fix ships in v2. |

## Background

Gavel is an oracle-free lending protocol. A borrower auctions a loan request, lenders bid on the repayment amount, and the winning bid becomes a fixed-term loan. Both sides of the loan are ERC-721 position tokens, so the right to be repaid can be transferred or sold on the built-in marketplace.

At maturity the borrower has a grace period (1 day) to repay. After that, the holder of the lender position can call `claimCollateral` and take the whole collateral.

## Root cause

`repayLoan` looks up whoever currently holds the lender position and pushes the repayment to that address in the same transaction that returns the collateral:

```solidity
// LoanProtocol.sol, repayLoan()
address lender = positionNFT.ownerOf(lenderTokenId);   // current holder, not the original lender
...
IERC20(loanToken).safeTransferFrom(msg.sender, lender, repaymentAmount);   // :1509
IERC20(collateralToken).safeTransfer(msg.sender, collateralAmount);
```

There is no second path: no escrow, no partial repayment, no repay-into-the-contract. So repayment succeeds only if the loan token agrees to send funds **to the lender-position holder**.

USDC (`FiatTokenV2_2`) checks the recipient of every transfer against its blocklist. If the holder is blocked, the transfer reverts, and every repayment reverts with it.

The asymmetry is in `claimCollateral`. It moves only the collateral token (WBTC in every live loan), never the loan token, so the blocked holder can still claim once the grace period ends:

```
repayLoan       → moves USDC to the holder    → reverts while the holder is blocked
claimCollateral → moves WBTC to the holder    → works
```

The borrower cannot repay, and the lender-side holder still collects the collateral.

## How a holder ends up blocked

1. **The issuer blocks the holder during the loan.** Nobody acts in bad faith; Circle freezes an address.
2. **The holder transfers the lender position to an address that is already blocked.** The position is an unrestricted ERC-721.
3. **A blocked address buys the position on Gavel's marketplace.** It pays with a listing priced in a different token (for example USD₮0). *The Gavel team found this route during triage.*

Routes 2 and 3 need no action from the issuer. A lender who controls a blocked address can set them up on purpose.

## Impact

- From the moment the holder is blocked until the end of the grace period, every `repayLoan` call reverts.
- After maturity plus the grace period, `claimCollateral` succeeds and the holder receives the full collateral.
- The borrower keeps the loan principal but loses collateral worth more than the debt. Loans are over-collateralised, so that surplus is a direct loss to the borrower and a gain to the holder.
- `NFTLoanProtocol` has the same pattern; there the borrower loses the collateral NFT.

The protocol's own pause does not help. It freezes both functions and the deadlines, and the outcome is unchanged after unpause.

## Proof of concept

Foundry fork tests against the live contracts, pinned to Arbitrum One block `512620498`. See [`poc/`](poc/).

| Test | What it shows |
|---|---|
| `test_blacklistedLender_forcesDefault_loan4` | A live loan (0.02465373 WBTC against 814.42 USDC). Control: repayment works. After the USDC blacklister blocks the lender-position holder, `repayLoan` reverts, including at the last second of the grace period. After the grace period, the holder claims all the WBTC and the loan is `DEFAULTED`. |
| `test_blacklistedLender_locksAllActiveLoans` | One blocklist entry blocks all 19 active loans at the block, because one address held every lender position. |
| `test_control_repaySucceeds` (NFT) | `NFTLoanProtocol` had no loans yet, so a loan is created through the public auction flow and repaid normally. |
| `test_blacklistedLender_forcesDefault_nftLoan` | The same loan, with the holder blocked: repayment reverts, and the holder takes the NFT. |

```
active loans              19
repayments blocked        19
USDC owed (6 dp)          15957681315
WBTC collateral (8 dp)    44159213
WBTC seized by lender     44159213

4 tests passed, 0 failed
```

The tests block the holder by impersonating USDC's real `blacklister()`. That is route 1. Routes 2 and 3 end in the same state.

## Fix

Repayment should not depend on the lender being able to receive. The contract already has a pull pattern for auction refunds (`pendingRefunds` / `claimRefund`). Reusing it:

1. In `repayLoan`, transfer the repayment from the borrower to the protocol. Credit `pendingRefunds[lender][loanToken]`, return the collateral, and burn both positions as now.
2. The lender withdraws through `claimRefund(token)`. A blocked lender who is later unblocked can still collect.

The Gavel team confirmed that v2 will not push the repayment to the holder's wallet. v1 is immutable. The team documented the issue as KI-3 and published a borrower-side check: read `ownerOf(getLenderTokenId(loanId))` and USDC's `isBlacklisted` before repaying.

## What I got wrong, and what the team added

Triage corrected parts of my report, and I'm recording that here because it matters as much as the finding:

- **USD₮0 is not affected.** I assumed USD₮0 checks the recipient the way USDC does. It doesn't: it checks only the source and the caller. Only USDC loans are exposed. *Lesson: verify each token's blocklist semantics (sender, caller, recipient) instead of assuming they match.*
- **The Trust Assumptions already listed the USDC blocklist** as a dependency that "could prevent operations". What was missing was the consequence: forced default and loss of collateral.
- **There was no third-party exposure.** All 19 live loans were between team-operated addresses.
- **The team found the marketplace route** (route 3), plus two related cases: a USDC token-wide pause during the grace period has the same effect, and transferring the position to the loan token's own address makes any loan unrepayable.

## Timeline

| Date | Event |
|---|---|
| 2026-10-07 | Reviewed the deployed v1 and reported to `security@thegavel.io` with the fork PoC |
| 2026-10-08 | The team reproduced it on both contracts and confirmed it valid, Medium; KI-3 published |
| 2026-10-09 / 10 | Credit added to KI-3 |
| 2026-10-15 | This write-up published |

Thanks to Jamie Frame and the Gavel team for a fast, careful triage and an unusually transparent known-issues page.
