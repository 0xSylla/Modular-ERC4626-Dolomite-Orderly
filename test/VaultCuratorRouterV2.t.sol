// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {VaultCuratorRouterV2} from "../src/routers/VaultCuratorRouterV2.sol";
import {Data} from "../src/libraries/Data.sol";
import {Events} from "../src/libraries/Events.sol";

/// @title VaultCuratorRouterV2 — auto-rebalance additions test suite
/// @notice Covers the *delta* vs V1: setOperatorAutoRebalance + operatorRebalanceClose.
///         The rest of the router is identical to V1 and tested elsewhere.
///
///         Strategy: mock the factory + vault role checks + vault.executeBatch via
///         vm.mockCall so the tests stay self-contained and focus on the new logic.
contract VaultCuratorRouterV2Test is Test {
    VaultCuratorRouterV2 router;

    // Test addresses
    address factory = address(0xFAC70);
    address vault   = address(0xBA17);
    address curator = address(0xCA);
    address operator_ = address(0x09);
    address stranger = address(0x5);

    // Module type hashes — must match what the router validates against vault legs.
    bytes32 constant SWAP_TYPE    = keccak256("swap.uniswap");
    bytes32 constant LENDING_TYPE = keccak256("lending.morpho");
    bytes32 constant PERPS_TYPE   = keccak256("perps.hyperliquid");

    bytes32 constant CURATOR_ROLE  = keccak256("CURATOR_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 constant POSITION_ID = 0;

    function setUp() public {
        // Deploy router pointing at mock factory address. Factory calls are mocked below.
        router = new VaultCuratorRouterV2(factory);

        // Mock: factory.isVault(vault) → true
        vm.mockCall(
            factory,
            abi.encodeWithSignature("isVault(address)", vault),
            abi.encode(true)
        );

        // Mock: factory.isPerpsAssetAllowed(...) → true (needed for definePosition)
        vm.mockCall(
            factory,
            abi.encodeWithSignature("isPerpsAssetAllowed(address,string)", address(0xC0), "ETH"),
            abi.encode(true)
        );

        // Mock vault's role exposure
        vm.mockCall(
            vault,
            abi.encodeWithSignature("CURATOR_ROLE()"),
            abi.encode(CURATOR_ROLE)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("OPERATOR_ROLE()"),
            abi.encode(OPERATOR_ROLE)
        );

        // Mock role checks
        vm.mockCall(
            vault,
            abi.encodeWithSignature("hasRole(bytes32,address)", CURATOR_ROLE, curator),
            abi.encode(true)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("hasRole(bytes32,address)", OPERATOR_ROLE, operator_),
            abi.encode(true)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("hasRole(bytes32,address)", CURATOR_ROLE, operator_),
            abi.encode(false)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("hasRole(bytes32,address)", OPERATOR_ROLE, curator),
            abi.encode(false)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("hasRole(bytes32,address)", CURATOR_ROLE, stranger),
            abi.encode(false)
        );
        vm.mockCall(
            vault,
            abi.encodeWithSignature("hasRole(bytes32,address)", OPERATOR_ROLE, stranger),
            abi.encode(false)
        );

        // Vault whitelisted asset check (for definePosition)
        vm.mockCall(
            vault,
            abi.encodeWithSignature("isTargetAssetWhitelisted(address)", address(0xC0)),
            abi.encode(true)
        );

        // Curator sets legs
        vm.prank(curator);
        router.setVaultLegs(
            vault,
            Data.LegConfig({
                swapModuleType: SWAP_TYPE,
                lendingModuleType: LENDING_TYPE,
                perpsModuleType: PERPS_TYPE
            })
        );

        // Curator defines a position (status = IDLE)
        vm.prank(curator);
        router.definePosition(vault, address(0xC0), "ETH", 14_000_000);
    }

    // ============ Helpers ============

    /// Drive the position from IDLE → ACTIVE so we have a realistic starting state.
    function _bringToActive() internal {
        vm.prank(curator);
        router.requestOpeningPosition(vault, POSITION_ID);

        // executeOpeningRequest delegates to vault.executeBatch — mock it as a no-op.
        bytes[] memory empty = new bytes[](0);
        bytes32[] memory emptyT = new bytes32[](0);
        vm.mockCall(
            vault,
            abi.encodeWithSelector(
                bytes4(keccak256("executeBatch(bytes32[],bytes[])")),
                emptyT,
                empty
            ),
            abi.encode(empty)
        );

        vm.prank(operator_);
        router.executeOpeningRequest(vault, POSITION_ID, emptyT, empty);

        vm.prank(operator_);
        router.confirmOpen(vault, POSITION_ID);
    }

    // ============ setOperatorAutoRebalance ============

    function test_setOperatorAutoRebalance_curatorCanEnable() public {
        assertEq(router.allowOperatorAutoRebalance(vault), false, "default off");

        vm.expectEmit(true, false, false, true);
        emit Events.OperatorAutoRebalanceSet(vault, true);

        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        assertEq(router.allowOperatorAutoRebalance(vault), true, "should be enabled");
    }

    function test_setOperatorAutoRebalance_curatorCanRevoke() public {
        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);
        assertEq(router.allowOperatorAutoRebalance(vault), true);

        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, false);
        assertEq(router.allowOperatorAutoRebalance(vault), false, "should revoke");
    }

    function test_setOperatorAutoRebalance_revertsForOperator() public {
        vm.expectRevert(Events.Unauthorized.selector);
        vm.prank(operator_);
        router.setOperatorAutoRebalance(vault, true);
    }

    function test_setOperatorAutoRebalance_revertsForStranger() public {
        vm.expectRevert(Events.Unauthorized.selector);
        vm.prank(stranger);
        router.setOperatorAutoRebalance(vault, true);
    }

    function test_setOperatorAutoRebalance_revertsForNonFactoryVault() public {
        address fakeVault = address(0xDEAD);
        vm.mockCall(
            factory,
            abi.encodeWithSignature("isVault(address)", fakeVault),
            abi.encode(false)
        );
        vm.expectRevert(Events.NotFactoryVault.selector);
        vm.prank(curator);
        router.setOperatorAutoRebalance(fakeVault, true);
    }

    // ============ operatorRebalanceClose ============

    function test_operatorRebalanceClose_happyPath() public {
        _bringToActive();

        // Curator opts in
        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        // Build call data — the legs all match the registered types
        bytes32[] memory mods = new bytes32[](1);
        mods[0] = PERPS_TYPE;
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("recordReturn(uint256)", uint256(0));

        // Mock vault.executeBatch to return empty (we only care about the status transition)
        bytes[] memory empty = new bytes[](0);
        vm.mockCall(
            vault,
            abi.encodeWithSelector(
                bytes4(keccak256("executeBatch(bytes32[],bytes[])")),
                mods,
                datas
            ),
            abi.encode(empty)
        );

        vm.expectEmit(true, false, false, false);
        emit Events.PositionRebalancing(POSITION_ID);

        vm.prank(operator_);
        router.operatorRebalanceClose(vault, POSITION_ID, mods, datas);

        // Verify status transitioned ACTIVE → REBALANCING directly (skipped REBALANCE_REQUESTED)
        VaultCuratorRouterV2.PositionRecord memory p = router.getPosition(vault, POSITION_ID);
        assertEq(uint8(p.status), uint8(Data.PositionStatus.REBALANCING), "should be REBALANCING");
    }

    function test_operatorRebalanceClose_revertsWhenOptOut() public {
        _bringToActive();
        // No setOperatorAutoRebalance call → defaults to false

        bytes32[] memory mods = new bytes32[](0);
        bytes[] memory datas = new bytes[](0);

        vm.expectRevert(Events.OperatorAutoRebalanceDisabled.selector);
        vm.prank(operator_);
        router.operatorRebalanceClose(vault, POSITION_ID, mods, datas);
    }

    function test_operatorRebalanceClose_revertsWhenNotActive() public {
        // Position is still IDLE — bring to OPEN_REQUESTED but not further
        vm.prank(curator);
        router.requestOpeningPosition(vault, POSITION_ID);

        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        bytes32[] memory mods = new bytes32[](0);
        bytes[] memory datas = new bytes[](0);

        vm.expectRevert(Events.PositionNotActive.selector);
        vm.prank(operator_);
        router.operatorRebalanceClose(vault, POSITION_ID, mods, datas);
    }

    function test_operatorRebalanceClose_revertsForCurator() public {
        _bringToActive();
        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        bytes32[] memory mods = new bytes32[](0);
        bytes[] memory datas = new bytes[](0);

        // Even though the curator authorized auto-rebalance, the function is operator-only.
        // Curators wanting to rebalance manually still use requestRebalance.
        vm.expectRevert(Events.Unauthorized.selector);
        vm.prank(curator);
        router.operatorRebalanceClose(vault, POSITION_ID, mods, datas);
    }

    function test_operatorRebalanceClose_revertsForStranger() public {
        _bringToActive();
        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        bytes32[] memory mods = new bytes32[](0);
        bytes[] memory datas = new bytes[](0);

        vm.expectRevert(Events.Unauthorized.selector);
        vm.prank(stranger);
        router.operatorRebalanceClose(vault, POSITION_ID, mods, datas);
    }

    function test_operatorRebalanceClose_revertsForUnknownModuleType() public {
        _bringToActive();
        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        // Use a module type that wasn't registered in vault legs
        bytes32[] memory mods = new bytes32[](1);
        mods[0] = keccak256("perps.orderly");  // different perp module than what's set
        bytes[] memory datas = new bytes[](1);
        datas[0] = bytes("");

        vm.expectRevert(Events.ModuleNotWhitelisted.selector);
        vm.prank(operator_);
        router.operatorRebalanceClose(vault, POSITION_ID, mods, datas);
    }

    /// Verifies the operator can re-flip a position back via the existing executeRebalanceOpen
    /// after operatorRebalanceClose set status to REBALANCING. End-to-end auto-rebalance loop.
    function test_fullAutoRebalanceLoop_works() public {
        _bringToActive();

        vm.prank(curator);
        router.setOperatorAutoRebalance(vault, true);

        // operatorRebalanceClose: ACTIVE → REBALANCING
        bytes32[] memory closeMods = new bytes32[](0);
        bytes[] memory closeDatas = new bytes[](0);
        bytes[] memory emptyRet = new bytes[](0);
        vm.mockCall(
            vault,
            abi.encodeWithSelector(bytes4(keccak256("executeBatch(bytes32[],bytes[])")), closeMods, closeDatas),
            abi.encode(emptyRet)
        );
        vm.prank(operator_);
        router.operatorRebalanceClose(vault, POSITION_ID, closeMods, closeDatas);

        // executeRebalanceOpen: REBALANCING → ACTIVE
        bytes32[] memory openMods = new bytes32[](0);
        bytes[] memory openDatas = new bytes[](0);
        vm.prank(operator_);
        router.executeRebalanceOpen(vault, POSITION_ID, openMods, openDatas);

        VaultCuratorRouterV2.PositionRecord memory p = router.getPosition(vault, POSITION_ID);
        assertEq(uint8(p.status), uint8(Data.PositionStatus.ACTIVE), "should land back in ACTIVE");
    }
}
