// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDiamondMin {
    struct Pool {
        uint256 initialReward;
        uint256 rewardDecrease;
        uint128 payoutStart;
        uint128 decreaseInterval;
    }
    struct Facet {
        address facetAddress;
        uint8 action;
        bytes4[] functionSelectors;
    }

    function __SessionRouter_init(address fundingAccount_, uint128 maxSessionDuration_, Pool[] calldata pools_) external;
    function __Marketplace_init(address token_, uint256 bidMinPricePerSecond_, uint256 bidMaxPricePerSecond_) external;
    function __ProviderRegistry_init() external;
    function __ModelRegistry_init() external;
    function __Delegation_init(address registry_) external;
    function __LumerinDiamond_init() external;
    function diamondCut(Facet[] memory facets_, address init_, bytes memory initData_) external;
    function transferOwnership(address newOwner_) external;
    function getToken() external view returns (address);
    function getFundingAccount() external view returns (address);
    function getPools() external view returns (Pool[] memory);
    function getProviderMinimumStake() external view returns (uint256);
    function getModelMinimumStake() external view returns (uint256);
    function getRegistry() external view returns (address);
    function DELEGATION_RULES_SESSION() external view returns (bytes32);
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
    function owner() external view returns (address);
}

interface IDelegateRegistryMin {
    function delegateContract(address to, address contract_, bytes32 rights, bool enable) external payable returns (bytes32);
}

/// @notice Negative / coverage checks for Lane C on the same pinned Base fork
/// (block 57723502). No privileged accounts. These tests assert the diamond
/// core access control HOLDS: re-initialization and diamondCut by a stranger
/// must fail, and delegation through the live registry must follow the
/// documented (to, from, contract, rights) semantics.
contract DiamondAccessControlTest is Test {
    error OwnableUnauthorizedAccount(address account);
    error InsufficientRightsForOperation(address delegator, address delegatee);

    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 57723502;

    address stranger = vm.addr(0x9999);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        deal(MOR, stranger, 100 ether);
    }

    function testStrangerCannotReinitializeOrCut() public {
        // Snapshot critical config.
        address tokenBefore = IDiamondMin(DIAMOND).getToken();
        address fundingBefore = IDiamondMin(DIAMOND).getFundingAccount();
        uint256 poolsBefore = IDiamondMin(DIAMOND).getPools().length;
        uint256 provStakeBefore = IDiamondMin(DIAMOND).getProviderMinimumStake();
        uint256 modelStakeBefore = IDiamondMin(DIAMOND).getModelMinimumStake();
        address registryBefore = IDiamondMin(DIAMOND).getRegistry();
        address ownerBefore = IDiamondMin(DIAMOND).owner();

        assertGt(poolsBefore, 3, "pools must be initialized");
        assertTrue(tokenBefore != address(0), "token must be set");

        // Every initializer reachable via the diamond: a stranger's call must
        // either revert or leave state untouched. (Provider/Model inits have
        // empty bodies, so a call may succeed while changing nothing.)
        vm.startPrank(stranger);
        IDiamondMin.Pool[] memory pools = new IDiamondMin.Pool[](0);
        try IDiamondMin(DIAMOND).__SessionRouter_init(stranger, 600, pools) {} catch {}
        try IDiamondMin(DIAMOND).__Marketplace_init(stranger, 1, 2) {} catch {}
        try IDiamondMin(DIAMOND).__ProviderRegistry_init() {} catch {}
        try IDiamondMin(DIAMOND).__ModelRegistry_init() {} catch {}
        try IDiamondMin(DIAMOND).__Delegation_init(stranger) {} catch {}
        try IDiamondMin(DIAMOND).__LumerinDiamond_init() {} catch {}

        // diamondCut and transferOwnership must revert for a stranger.
        IDiamondMin.Facet[] memory facets = new IDiamondMin.Facet[](0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, stranger));
        IDiamondMin(DIAMOND).diamondCut(facets, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, stranger));
        IDiamondMin(DIAMOND).transferOwnership(stranger);
        vm.stopPrank();

        // Config unchanged.
        assertEq(IDiamondMin(DIAMOND).getToken(), tokenBefore);
        assertEq(IDiamondMin(DIAMOND).getFundingAccount(), fundingBefore);
        assertEq(IDiamondMin(DIAMOND).getPools().length, poolsBefore);
        assertEq(IDiamondMin(DIAMOND).getProviderMinimumStake(), provStakeBefore);
        assertEq(IDiamondMin(DIAMOND).getModelMinimumStake(), modelStakeBefore);
        assertEq(IDiamondMin(DIAMOND).getRegistry(), registryBefore);
        assertEq(IDiamondMin(DIAMOND).owner(), ownerBefore);

        // Diamond still functional for a fresh unprivileged user.
        vm.startPrank(stranger);
        IERC20Min(MOR).approve(DIAMOND, type(uint256).max);
        IDiamondMin(DIAMOND).providerRegister(stranger, 1 ether, "x.example:1");
        vm.stopPrank();
    }

    function _ethSign(uint256 key, bytes memory payload) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(payload);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _setupProviderBid(address provider) internal returns (bytes32) {
        vm.startPrank(provider);
        IERC20Min(MOR).approve(DIAMOND, type(uint256).max);
        IDiamondMin(DIAMOND).providerRegister(provider, 10_000 ether, "p.example:1");
        bytes32 baseModelId = keccak256("delegation-test-model");
        string[] memory tags = new string[](0);
        IDiamondMin(DIAMOND).modelRegister(provider, baseModelId, bytes32(uint256(1)), 0, 1 ether, "m", tags);
        bytes32 modelId = IDiamondMin(DIAMOND).getModelId(provider, baseModelId);
        IDiamondMin(DIAMOND).postModelBid(provider, modelId, 1e12);
        vm.stopPrank();
        return keccak256(abi.encodePacked(provider, modelId, uint256(0)));
    }

    function testDelegationThroughLiveRegistry() public {
        address provider = vm.addr(0x4444);
        address user = vm.addr(0x5555);
        address delegate = vm.addr(0x6666);
        deal(MOR, provider, 20_000 ether);
        deal(MOR, user, 200_000 ether);

        bytes32 bidId = _setupProviderBid(provider);

        bytes memory approval = abi.encode(bidId, uint256(block.chainid), user, uint128(block.timestamp));
        bytes memory sig = _ethSign(0x4444, approval);

        // Without delegation, a third party cannot open a session for the user.
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientRightsForOperation.selector, user, delegate)
        );
        IDiamondMin(DIAMOND).openSession(user, 10_000 ether, false, approval, sig);

        // User grants SESSION rights to the delegate via the live registry.
        bytes32 rights = IDiamondMin(DIAMOND).DELEGATION_RULES_SESSION();
        address registry = IDiamondMin(DIAMOND).getRegistry();
        vm.prank(user);
        IDelegateRegistryMin(registry).delegateContract(delegate, DIAMOND, rights, true);

        // Now the delegate can open the session for the user (user funds it).
        vm.prank(user);
        IERC20Min(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(delegate);
        bytes32 sessionId = IDiamondMin(DIAMOND).openSession(user, 10_000 ether, false, approval, sig);
        assertTrue(sessionId != bytes32(0), "delegated openSession must succeed");
    }
}
