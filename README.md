# Gavel Protocol: a USDC-blocked lender position forces borrower default

A confirmed Medium-severity finding in Gavel's v1 lending contracts on Arbitrum One, with a Foundry fork PoC that runs against the live deployment.

| | |
|---|---|
| **Target** | [The Gavel Protocol](https://github.com/JamieFrame/The-Gavel-Protocol) v1, `LoanProtocol` + `NFTLoanProtocol` (Arbitrum One) |
| **Commit** | `457fea8`, an exact Sourcify match to the deployed implementations |
| **Class** | Push payment to a recipient the token can refuse → liveness failure → loss of collateral |
| **Severity** | Medium (confirmed by the team) |
| **Status** | Published by the team as [**KI-3**](https://github.com/JamieFrame/The-Gavel-Protocol/blob/main/docs/known-issues.md#ki-3--repayment-reverts-if-the-loan-token-refuses-transfers-to-the-lender-position-holder), credited to me. The fix ships in v2. |

## The bug

`repayLoan` pushes the repayment straight to whoever currently holds the lender position NFT, in the same transaction that returns the collateral. It is the only way to repay.

USDC refuses transfers **to** a blocklisted address. If the lender-position holder is blocked, every repayment reverts. `claimCollateral` moves only the collateral (WBTC), so the blocked holder can still take it once the grace period ends. The borrower cannot repay, and loses collateral worth more than the debt.

The holder can be blocked by the issuer, or deliberately: the position is a transferable ERC-721, and it can be sent to, or bought on Gavel's marketplace by, an address that is already blocked.

Full write-up: **[finding.md](finding.md)**. It covers the root cause, the three trigger routes, impact, the fix, and what triage corrected in my original report.

## Contents

| Path | What it is |
|---|---|
| [`finding.md`](finding.md) | The finding |
| [`poc/test/GavelBlacklistRepayDoS.t.sol`](poc/test/GavelBlacklistRepayDoS.t.sol) | `LoanProtocol`: a live loan forced into default, then all 19 active loans blocked by one blocklist entry |
| [`poc/test/GavelNFTBlacklistRepayDoS.t.sol`](poc/test/GavelNFTBlacklistRepayDoS.t.sol) | `NFTLoanProtocol`: control plus attack on a loan created through the public auction flow |

## Running the PoC

Requires [Foundry](https://book.getfoundry.sh/). The tests fork Arbitrum One at block `512620498`; the public RPC serves that block.

```bash
git clone --recursive https://github.com/Arashrahmaniii/gavel-repay-blocklist-dos
cd gavel-repay-blocklist-dos/poc
ARB_RPC_URL=https://arb1.arbitrum.io/rpc forge test -vv
```

Expected: `4 tests passed, 0 failed`. Each test runs a control first (repayment succeeds) and only then applies the blocklist, so every revert is attributable to the blocked recipient.

## Disclosure

Reported privately to `security@thegavel.io` on 2026-10-07. The team reproduced the issue on both contracts, confirmed it as Medium on 2026-10-08, and published KI-3. This repository was published after KI-3, as agreed with the team.

Gavel has no bug bounty program. Nothing here was tested against live state; all testing ran on a local fork.

## Author

Arash Rahmani · [GitHub](https://github.com/Arashrahmaniii) · [LinkedIn](https://www.linkedin.com/in/arash-rahmani-223235440)
