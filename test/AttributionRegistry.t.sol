// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TDIRAC} from "../src/token/TDIRAC.sol";
import {SoulboundReceiptToken} from "../src/token/SoulboundReceiptToken.sol";
import {SoulboundReceiptPool} from "../src/token/SoulboundReceiptPool.sol";
import {AttributionRegistry} from "../src/registry/AttributionRegistry.sol";
import {Data} from "../src/libraries/Data.sol";

/// @dev Minimal stand-in for the live V4 factory — only the surface the
///      registry reads: `isVault` + `vaultInfo`.
contract MockFactory {
    mapping(address => bool) public isVault;
    mapping(address => Data.VaultInfo) internal _info;

    function setVault(address vault, address creator, bytes32 templateId) external {
        isVault[vault] = true;
        _info[vault] = Data.VaultInfo({
            vault: vault,
            creator: creator,
            templateId: templateId,
            deployedAt: 1
        });
    }

    function vaultInfo(address vault) external view returns (Data.VaultInfo memory) {
        return _info[vault];
    }
}

contract AttributionRegistryTest is Test {
    TDIRAC internal dirac;
    SoulboundReceiptToken internal sbt;
    SoulboundReceiptPool internal pool;
    AttributionRegistry internal reg;
    MockFactory internal factory;

    address internal treasury = address(0xCAFE);
    address internal admin = address(0xAD);
    address internal attester = address(0xA77E);
    address internal strategistAttester = address(0x57A7);

    address internal vault = address(0x7A017);
    address internal curator = address(0xC0A70);
    bytes32 internal constant TEMPLATE = keccak256("delta-neutral-v1");
    address internal strategist = address(0x57BA);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA701);

    uint256 internal constant USDC = 1e6;

    function setUp() public {
        dirac = new TDIRAC(treasury);

        // Two-step deploy with precomputed pool address (mirrors prod script).
        uint256 n = vm.getNonce(address(this));
        address futurePool = vm.computeCreateAddress(address(this), n + 1);
        sbt = new SoulboundReceiptToken(futurePool);
        // Pool starts with `admin` as attributor; we rotate to the registry below.
        pool = new SoulboundReceiptPool(address(dirac), address(sbt), address(dirac), admin, admin);
        assertEq(address(pool), futurePool, "futurePool prediction broke");

        factory = new MockFactory();
        factory.setVault(vault, curator, TEMPLATE);

        reg = new AttributionRegistry(
            address(pool), address(factory), admin, attester, strategistAttester
        );

        // Route minting through the registry + seed the burn reserve.
        vm.prank(admin);
        pool.setAttributor(address(reg));
        vm.prank(treasury);
        dirac.transfer(address(pool), 100_000_000 * 1e18);
    }

    // ============ Construction ============

    function test_constructor_wiring() public view {
        assertEq(address(reg.pool()), address(pool));
        assertEq(address(reg.factory()), address(factory));
        assertEq(reg.admin(), admin);
        assertEq(reg.attester(), attester);
        assertEq(reg.strategistAttester(), strategistAttester);
        assertEq(pool.attributor(), address(reg));
        // defaults
        assertEq(reg.minLpDeposit(), 100 * USDC);
        assertEq(reg.lpWeightPerDeposit(), 1e18);
        assertEq(reg.minTvlForCurator(), 10_000 * USDC);
        assertEq(reg.minUniqueLps(), 10);
        assertEq(reg.curatorBaseSbt(), 1000 * 1e18);
        assertEq(reg.strategistBaseSbt(), 2000 * 1e18);
        assertEq(reg.maxStrategistVaultsCounted(), 5);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(AttributionRegistry.AR__ZeroAddress.selector);
        new AttributionRegistry(address(0), address(factory), admin, attester, strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__ZeroAddress.selector);
        new AttributionRegistry(address(pool), address(0), admin, attester, strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__ZeroAddress.selector);
        new AttributionRegistry(address(pool), address(factory), address(0), attester, strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__ZeroAddress.selector);
        new AttributionRegistry(address(pool), address(factory), admin, address(0), strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__ZeroAddress.selector);
        new AttributionRegistry(address(pool), address(factory), admin, attester, address(0));
    }

    // ============ LP attribution ============

    function test_lp_mintsByDepositWeight() public {
        address[] memory lps = new address[](2);
        uint256[] memory deps = new uint256[](2);
        lps[0] = alice; deps[0] = 500 * USDC;
        lps[1] = bob;   deps[1] = 1000 * USDC;

        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);

        // sbt = deposit * 1e18 / 1e6 => deposit (USDC units) * 1e12
        assertEq(sbt.balanceOf(alice), 500 * USDC * 1e12);
        assertEq(sbt.balanceOf(bob), 1000 * USDC * 1e12);
    }

    function test_lp_skipsBelowFloor() public {
        address[] memory lps = new address[](2);
        uint256[] memory deps = new uint256[](2);
        lps[0] = alice; deps[0] = 99 * USDC;   // below 100 floor
        lps[1] = bob;   deps[1] = 100 * USDC;  // exactly floor

        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);

        assertEq(sbt.balanceOf(alice), 0);
        assertEq(sbt.balanceOf(bob), 100 * USDC * 1e12);
    }

    function test_lp_skipsZeroAddress() public {
        address[] memory lps = new address[](2);
        uint256[] memory deps = new uint256[](2);
        lps[0] = address(0); deps[0] = 500 * USDC;
        lps[1] = alice;      deps[1] = 500 * USDC;

        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);
        assertEq(sbt.balanceOf(alice), 500 * USDC * 1e12);
    }

    function test_lp_dedupWithinCycle() public {
        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;

        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);
        // re-attest same cycle — no double mint
        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);

        assertEq(sbt.balanceOf(alice), 500 * USDC * 1e12);
        assertTrue(reg.lpAttributedInCycle(vault, 1, alice));
    }

    function test_lp_differentCyclesStack() public {
        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;

        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);
        vm.prank(attester);
        reg.attestLpsForCycle(vault, 2, lps, deps);

        assertEq(sbt.balanceOf(alice), 2 * 500 * USDC * 1e12);
    }

    function test_lp_onlyAttester() public {
        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;

        vm.expectRevert(AttributionRegistry.AR__OnlyAttester.selector);
        reg.attestLpsForCycle(vault, 1, lps, deps);
    }

    function test_lp_rejectsNonFactoryVault() public {
        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;

        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__NotFactoryVault.selector);
        reg.attestLpsForCycle(address(0xDEAD), 1, lps, deps);
    }

    function test_lp_rejectsLengthMismatch() public {
        address[] memory lps = new address[](2);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; lps[1] = bob; deps[0] = 500 * USDC;

        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__LengthMismatch.selector);
        reg.attestLpsForCycle(vault, 1, lps, deps);
    }

    // ============ Curator attribution ============

    function test_curator_mintsOnGate() public {
        vm.prank(attester);
        reg.attestCuratorGate(vault, 10_000 * USDC, 10);
        assertEq(sbt.balanceOf(curator), 1000 * 1e18);
        assertTrue(reg.curatorAttributed(vault));
    }

    function test_curator_oneTimeLatch() public {
        vm.prank(attester);
        reg.attestCuratorGate(vault, 10_000 * USDC, 10);
        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__CuratorAlreadyAttributed.selector);
        reg.attestCuratorGate(vault, 50_000 * USDC, 20);
        assertEq(sbt.balanceOf(curator), 1000 * 1e18);
    }

    function test_curator_rejectsBelowTvl() public {
        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__CuratorGateNotMet.selector);
        reg.attestCuratorGate(vault, 9_999 * USDC, 10);
    }

    function test_curator_rejectsBelowUniqueLps() public {
        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__CuratorGateNotMet.selector);
        reg.attestCuratorGate(vault, 10_000 * USDC, 9);
    }

    function test_curator_onlyAttester() public {
        vm.expectRevert(AttributionRegistry.AR__OnlyAttester.selector);
        reg.attestCuratorGate(vault, 10_000 * USDC, 10);
    }

    function test_curator_rejectsNonFactoryVault() public {
        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__NotFactoryVault.selector);
        reg.attestCuratorGate(address(0xDEAD), 10_000 * USDC, 10);
    }

    // ============ Strategist attribution ============

    function test_strategist_mintsToAuthorWithCap() public {
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, strategist);

        vm.prank(strategistAttester);
        reg.attestStrategistPerformance(TEMPLATE, vault, 3);
        // 2000 base * 3 vaults
        assertEq(sbt.balanceOf(strategist), 2000 * 1e18 * 3);
    }

    function test_strategist_capsVaultsCounted() public {
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, strategist);

        vm.prank(strategistAttester);
        reg.attestStrategistPerformance(TEMPLATE, vault, 100); // cap 5
        assertEq(sbt.balanceOf(strategist), 2000 * 1e18 * 5);
    }

    function test_strategist_zeroCountTreatedAsOne() public {
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, strategist);

        vm.prank(strategistAttester);
        reg.attestStrategistPerformance(TEMPLATE, vault, 0);
        assertEq(sbt.balanceOf(strategist), 2000 * 1e18);
    }

    function test_strategist_revertsWithoutAuthor() public {
        vm.prank(strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__NoAuthor.selector);
        reg.attestStrategistPerformance(TEMPLATE, vault, 1);
    }

    function test_strategist_revertsTemplateMismatch() public {
        bytes32 other = keccak256("other");
        vm.prank(admin);
        reg.setTemplateAuthor(other, strategist);

        vm.prank(strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__TemplateMismatch.selector);
        reg.attestStrategistPerformance(other, vault, 1);
    }

    function test_strategist_alreadyAttested() public {
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, strategist);

        vm.prank(strategistAttester);
        reg.attestStrategistPerformance(TEMPLATE, vault, 1);
        vm.prank(strategistAttester);
        vm.expectRevert(AttributionRegistry.AR__StrategistAlreadyAttested.selector);
        reg.attestStrategistPerformance(TEMPLATE, vault, 1);
    }

    function test_strategist_onlyStrategistAttester() public {
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, strategist);
        // even the LP/curator attester can't call this
        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__OnlyStrategistAttester.selector);
        reg.attestStrategistPerformance(TEMPLATE, vault, 1);
    }

    function test_strategist_authorRepointable() public {
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, strategist);
        assertEq(reg.templateAuthor(TEMPLATE), strategist);
        vm.prank(admin);
        reg.setTemplateAuthor(TEMPLATE, bob);
        assertEq(reg.templateAuthor(TEMPLATE), bob);

        vm.prank(strategistAttester);
        reg.attestStrategistPerformance(TEMPLATE, vault, 1);
        assertEq(sbt.balanceOf(bob), 2000 * 1e18);
        assertEq(sbt.balanceOf(strategist), 0);
    }

    function test_setTemplateAuthor_onlyAdmin() public {
        vm.expectRevert(AttributionRegistry.AR__OnlyAdmin.selector);
        reg.setTemplateAuthor(TEMPLATE, strategist);
    }

    // ============ Admin / role rotation ============

    function test_setAttester() public {
        vm.prank(admin);
        reg.setAttester(bob);
        assertEq(reg.attester(), bob);

        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;
        vm.prank(bob);
        reg.attestLpsForCycle(vault, 1, lps, deps);
        assertEq(sbt.balanceOf(alice), 500 * USDC * 1e12);
    }

    function test_setStrategistAttester() public {
        vm.prank(admin);
        reg.setStrategistAttester(bob);
        assertEq(reg.strategistAttester(), bob);
    }

    function test_setAdmin() public {
        vm.prank(admin);
        reg.setAdmin(bob);
        assertEq(reg.admin(), bob);
        vm.prank(admin);
        vm.expectRevert(AttributionRegistry.AR__OnlyAdmin.selector);
        reg.setMinLpDeposit(1);
    }

    function test_setFactory_repoints() public {
        MockFactory f2 = new MockFactory();
        address vault2 = address(0xBEEF);
        f2.setVault(vault2, curator, TEMPLATE);

        vm.prank(admin);
        reg.setFactory(address(f2));
        assertEq(address(reg.factory()), address(f2));

        // attestation now validates against the new factory: vault2 works,
        // the old vault (not in f2) is rejected.
        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;
        vm.prank(attester);
        reg.attestLpsForCycle(vault2, 1, lps, deps);
        assertEq(sbt.balanceOf(alice), 500 * USDC * 1e12);

        vm.prank(attester);
        vm.expectRevert(AttributionRegistry.AR__NotFactoryVault.selector);
        reg.attestLpsForCycle(vault, 1, lps, deps);
    }

    function test_setFactory_onlyAdminAndNonZero() public {
        vm.expectRevert(AttributionRegistry.AR__OnlyAdmin.selector);
        reg.setFactory(address(0xBEEF));
        vm.prank(admin);
        vm.expectRevert(AttributionRegistry.AR__ZeroAddress.selector);
        reg.setFactory(address(0));
    }

    function test_adminSetters_onlyAdmin() public {
        vm.expectRevert(AttributionRegistry.AR__OnlyAdmin.selector);
        reg.setMinLpDeposit(1);
        vm.expectRevert(AttributionRegistry.AR__OnlyAdmin.selector);
        reg.setAttester(bob);
    }

    function test_adminSetters_updateValues() public {
        vm.startPrank(admin);
        reg.setMinLpDeposit(50 * USDC);
        reg.setLpWeightPerDeposit(2e18);
        reg.setMinTvlForCurator(5_000 * USDC);
        reg.setMinUniqueLps(5);
        reg.setCuratorBaseSbt(500 * 1e18);
        reg.setStrategistBaseSbt(1000 * 1e18);
        reg.setMaxStrategistVaultsCounted(3);
        vm.stopPrank();

        assertEq(reg.minLpDeposit(), 50 * USDC);
        assertEq(reg.lpWeightPerDeposit(), 2e18);
        assertEq(reg.minTvlForCurator(), 5_000 * USDC);
        assertEq(reg.minUniqueLps(), 5);
        assertEq(reg.curatorBaseSbt(), 500 * 1e18);
        assertEq(reg.strategistBaseSbt(), 1000 * 1e18);
        assertEq(reg.maxStrategistVaultsCounted(), 3);
    }

    function test_tunedLpWeightAppliesOnNextAttest() public {
        vm.prank(admin);
        reg.setLpWeightPerDeposit(2e18); // double

        address[] memory lps = new address[](1);
        uint256[] memory deps = new uint256[](1);
        lps[0] = alice; deps[0] = 500 * USDC;
        vm.prank(attester);
        reg.attestLpsForCycle(vault, 1, lps, deps);
        assertEq(sbt.balanceOf(alice), 2 * 500 * USDC * 1e12);
    }
}
