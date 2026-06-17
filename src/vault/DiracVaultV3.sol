// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";
import {VaultStorage} from "../libraries/VaultStorage.sol";
// IDiracVault intentionally NOT implemented: that interface declares
// `openWithdrawals()` which V3 doesn't have. V3's ABI is consumed via its
// concrete type by VaultCuratorRouterV6 (no interface coupling).
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";

/// @title DiracVaultV3
/// @notice V3 of the Dirac vault. Two changes vs V2:
///         1. Module-execution failures bubble the inner revert data instead of
///            wrapping it as the opaque ModuleExecutionFailed(). Lets off-chain
///            tooling (and humans reading reverts) see exactly which module
///            reverted and why. Falls back to ModuleExecutionFailed only when
///            the inner call returned with empty revert data (rare).
///         2. The cycle state machine drops WITHDRAW_OPEN. Withdrawals were
///            already allowed in every non-TRADING state in V2 (CLOSED was
///            equivalent to WITHDRAW_OPEN as far as exit was concerned), so the
///            intermediate state was dead weight. closeCycle() now transitions
///            TRADING → CLOSED directly, and fees that were previously collected
///            in openWithdrawals() are collected in closeCycle() instead.
///         Otherwise identical to V2: same factory shape, same ABI surface, same
///         role model, same fee math, same module-delegatecall architecture,
///         same totalAssets() override semantics, same _decimalsOffset = 6.
///         The cycle enum (Data.TradeCycleStatus) is left at 4 values for source
///         compatibility with V1/V2; V3 simply never writes WITHDRAW_OPEN (3).
contract DiracVaultV3 is ERC4626, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Role Constants ============
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============ Immutables ============
    address public immutable factory;
    bytes32 public immutable templateId;

    constructor(
        address _curator,
        address _factory,
        address _operator,
        address _depositToken,
        string memory _name,
        string memory _symbol,
        uint256 _maxDeposit,
        bytes32 _templateId,
        Data.VaultFees memory _vaultFees,
        uint256 _rebalanceThresholdBps,
        uint256 _fundingRateThresholdBps,
        bytes32[] memory _moduleTypes
    ) ERC4626(IERC20(_depositToken)) ERC20(_name, _symbol) {
        if (_factory == address(0)) revert Events.ZeroAddress();
        factory = _factory;
        templateId = _templateId;

        _grantRole(OWNER_ROLE, _factory);
        _grantRole(CURATOR_ROLE, _curator);
        _grantRole(OPERATOR_ROLE, _operator);

        _setRoleAdmin(OPERATOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(CURATOR_ROLE, OWNER_ROLE);

        VaultStorage.Layout storage vs = VaultStorage.layout();
        vs.maxDeposit = _maxDeposit;
        vs.vaultFees = _vaultFees;
        vs.rebalanceThresholdBps = _rebalanceThresholdBps;
        vs.fundingRateThresholdBps = _fundingRateThresholdBps;

        for (uint256 i = 0; i < _moduleTypes.length; i++) {
            vs.whitelistedModuleTypes[_moduleTypes[i]] = true;
        }
    }

    // ============ Inflation Attack Protection ============
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ============ totalAssets() override ============
    //
    // Same as V2: cycle-start snapshot during TRADING, live asset.balanceOf
    // otherwise. See V2 source for the full rationale.
    function totalAssets() public view override returns (uint256) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status == Data.TradeCycleStatus.TRADING) {
            return vs.currentCycle.assetsAtCycleStart;
        }
        return super.totalAssets();
    }

    // ============ Internal: Resolve Module ============

    /// @dev Resolves a module type hash to its current implementation address from the factory registry.
    ///      Reverts if the module type is not whitelisted on this vault or not registered on the factory.
    function _resolveModule(bytes32 moduleType) internal view returns (address module) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (!vs.whitelistedModuleTypes[moduleType]) revert Events.ModuleNotWhitelisted();
        module = IDiracVaultFactory(factory).getModule(moduleType);
        if (module == address(0)) revert Events.ModuleNotWhitelisted();
    }

    /// @dev V3 change: when a delegatecall to a module fails, bubble the inner
    ///      revert data instead of wrapping it as opaque ModuleExecutionFailed().
    ///      Falls back to ModuleExecutionFailed only when revert data is empty
    ///      (happens for raw `revert()` with no message — very rare in our
    ///      modules).
    function _bubbleModuleRevert(bytes memory result) internal pure {
        if (result.length > 0) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        revert Events.ModuleExecutionFailed();
    }

    // ============ ERC4626 Overrides ============

    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        _requireDepositOpen(vs);
        if (assets == 0) revert Events.ZeroAmount();
        if (receiver == address(0)) revert Events.ZeroAddress();
        if (totalAssets() + assets > vs.maxDeposit)
            revert Events.MaxDepositExceeded();

        if (vs.userDeposits[receiver] == 0) {
            vs.totalUsers++;
        }
        vs.userDeposits[receiver] += assets;
        vs.totalTVL += assets;

        shares = super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        _requireDepositOpen(vs);

        assets = previewMint(shares);
        if (assets == 0) revert Events.ZeroAmount();
        if (totalAssets() + assets > vs.maxDeposit)
            revert Events.MaxDepositExceeded();

        if (vs.userDeposits[receiver] == 0) {
            vs.totalUsers++;
        }
        vs.userDeposits[receiver] += assets;
        vs.totalTVL += assets;

        assets = super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        _requireWithdrawAllowed(vs);
        if (assets == 0) revert Events.ZeroAmount();

        if (vs.userDeposits[owner] > assets) {
            vs.userDeposits[owner] -= assets;
        } else {
            delete vs.userDeposits[owner];
            if (vs.totalUsers > 0) vs.totalUsers--;
        }
        if (vs.totalTVL > assets) {
            vs.totalTVL -= assets;
        } else {
            vs.totalTVL = 0;
        }

        shares = super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        _requireWithdrawAllowed(vs);

        assets = super.redeem(shares, receiver, owner);
        if (assets == 0) revert Events.ZeroAmount();

        if (vs.userDeposits[owner] > assets) {
            vs.userDeposits[owner] -= assets;
        } else {
            delete vs.userDeposits[owner];
            if (vs.totalUsers > 0) vs.totalUsers--;
        }
        if (vs.totalTVL > assets) {
            vs.totalTVL -= assets;
        } else {
            vs.totalTVL = 0;
        }
    }

    // ============ Module Execution ============

    /// @notice One-time module setup — callable by operator at any cycle state.
    ///         Used to initialize module storage (e.g. set Orderly vault address) before trading starts.
    function setupModule(
        bytes32 moduleType,
        bytes calldata data
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant returns (bytes memory) {
        address module = _resolveModule(moduleType);
        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) _bubbleModuleRevert(result);
        emit Events.ModuleExecuted(module, false);
        return result;
    }

    function executeModule(
        bytes32 moduleType,
        bytes calldata data
    )
        external
        payable
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes memory)
    {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();

        address module = _resolveModule(moduleType);
        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) _bubbleModuleRevert(result);
        emit Events.ModuleExecuted(module, true);
        return result;
    }

    function executeBatch(
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    )
        external
        payable
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes[] memory results)
    {
        if (moduleTypes.length != datas.length) revert Events.ArrayLengthMismatch();

        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();

        results = new bytes[](moduleTypes.length);
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            address module = _resolveModule(moduleTypes[i]);
            (bool ok, bytes memory result) = module.delegatecall(datas[i]);
            if (!ok) _bubbleModuleRevert(result);
            results[i] = result;
        }
    }

    // ============ Curator: Vault Configuration ============

    function whitelistTargetAsset(
        address asset
    ) external onlyRole(CURATOR_ROLE) {
        VaultStorage.layout().vaultTargetAssets[asset] = true;
        emit Events.TargetAssetWhitelisted(asset);
    }

    function removeTargetAsset(
        address asset
    ) external onlyRole(CURATOR_ROLE) {
        delete VaultStorage.layout().vaultTargetAssets[asset];
        emit Events.TargetAssetRemoved(asset);
    }


    function setMaxDeposit(
        uint256 amount
    ) external onlyRole(CURATOR_ROLE) {
        VaultStorage.layout().maxDeposit = amount;
        emit Events.MaxDepositUpdated(amount);
    }

    // ============ Curator: Cycle Management ============
    //
    // V3 cycle ring (3 states, down from V2's 4):
    //   CLOSED ── openDeposits()   ──▶ DEPOSIT_OPEN
    //   DEPOSIT_OPEN ── startTrading() ──▶ TRADING
    //   TRADING ── closeCycle()    ──▶ CLOSED        (was: TRADING → WITHDRAW_OPEN → CLOSED in V2)
    // Withdrawals are allowed in CLOSED and DEPOSIT_OPEN, blocked only in
    // TRADING. The WITHDRAW_OPEN state is unused — it was identical to CLOSED
    // for exit purposes in V2.

    function openDeposits() external onlyRole(CURATOR_ROLE) whenNotPaused {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.CLOSED)
            revert Events.OperationFailed();
        vs.currentCycle.status = Data.TradeCycleStatus.DEPOSIT_OPEN;
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.DEPOSIT_OPEN);
    }

    function startTrading() external onlyRole(CURATOR_ROLE) whenNotPaused {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.DEPOSIT_OPEN)
            revert Events.OperationFailed();
        // Snapshot the LIVE idle USDC BEFORE flipping status. Once status is
        // TRADING, the overridden totalAssets() returns assetsAtCycleStart
        // (which is what we're trying to set) so reading it here would store 0.
        // super.totalAssets() bypasses the override and reads asset.balanceOf.
        vs.currentCycle.assetsAtCycleStart = super.totalAssets();
        vs.currentCycle.status = Data.TradeCycleStatus.TRADING;
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.TRADING);
    }

    /// @notice Close the trading cycle. V3 transitions TRADING → CLOSED directly;
    ///         the V2 openWithdrawals → closeCycle two-step is collapsed since
    ///         WITHDRAW_OPEN and CLOSED were equivalent for depositor exit.
    ///         Fees collected here (previously in openWithdrawals).
    function closeCycle() external onlyRole(CURATOR_ROLE) whenNotPaused {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();
        _collectFees(vs);
        vs.currentCycle.status = Data.TradeCycleStatus.CLOSED;
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.CLOSED);
    }

    // ============ Emergency (OWNER_ROLE) ============

    function pause() external {
        if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(CURATOR_ROLE, msg.sender))
            revert Events.Unauthorized();
        _pause();
    }

    function unpause() external {
        if (!hasRole(OWNER_ROLE, msg.sender) && !hasRole(CURATOR_ROLE, msg.sender))
            revert Events.Unauthorized();
        _unpause();
    }

    function emergencyEndCycle() external onlyRole(OWNER_ROLE) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        vs.currentCycle.status = Data.TradeCycleStatus.CLOSED;
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.CLOSED);
    }

    function emergencyExecuteModule(
        bytes32 moduleType,
        bytes calldata data
    ) external payable onlyRole(OWNER_ROLE) nonReentrant returns (bytes memory) {
        address module = _resolveModule(moduleType);
        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) _bubbleModuleRevert(result);
        return result;
    }

    // ============ View Functions ============

    function getCurrentCycle()
        external
        view
        returns (Data.TradeCycle memory)
    {
        return VaultStorage.layout().currentCycle;
    }

    function isTargetAssetWhitelisted(
        address asset
    ) external view returns (bool) {
        return VaultStorage.layout().vaultTargetAssets[asset];
    }

    function isModuleTypeWhitelisted(
        bytes32 moduleType
    ) external view returns (bool) {
        return VaultStorage.layout().whitelistedModuleTypes[moduleType];
    }

    function getMaxDeposit() external view returns (uint256) {
        return VaultStorage.layout().maxDeposit;
    }

    function getTotalTVL() external view returns (uint256) {
        return VaultStorage.layout().totalTVL;
    }

    function getTotalUsers() external view returns (uint256) {
        return VaultStorage.layout().totalUsers;
    }

    function getUserDeposit(address user) external view returns (uint256) {
        return VaultStorage.layout().userDeposits[user];
    }

    function getVaultFees() external view returns (Data.VaultFees memory) {
        return VaultStorage.layout().vaultFees;
    }

    function getRebalanceThresholdBps() external view returns (uint256) {
        return VaultStorage.layout().rebalanceThresholdBps;
    }

    function getFundingRateThresholdBps() external view returns (uint256) {
        return VaultStorage.layout().fundingRateThresholdBps;
    }

    // ============ Internal ============

    function _requireDepositOpen(
        VaultStorage.Layout storage vs
    ) internal view {
        if (vs.currentCycle.status != Data.TradeCycleStatus.DEPOSIT_OPEN)
            revert Events.NotInDepositWindow();
    }

    /// @dev Withdrawals are allowed in every cycle state EXCEPT TRADING.
    ///        - CLOSED       — wind-down state; depositors can exit any time.
    ///        - DEPOSIT_OPEN — co-exists with deposits; users may rebalance their
    ///                         position either way without waiting for the curator
    ///                         to flip cycles.
    ///        - TRADING      — REJECTED. Idle USDC ≠ real NAV during trading, so a
    ///                         withdrawal here would short-change the caller
    ///                         (they'd get only the idle slice, not the deployed
    ///                         Morpho + perps share).
    function _requireWithdrawAllowed(
        VaultStorage.Layout storage vs
    ) internal view {
        if (vs.currentCycle.status == Data.TradeCycleStatus.TRADING)
            revert Events.NotInWithdrawWindow();
    }

    function _collectFees(VaultStorage.Layout storage vs) internal {
        uint256 currentAssets = totalAssets();
        uint256 startAssets = vs.currentCycle.assetsAtCycleStart;
        if (currentAssets <= startAssets) return; // no profit, no fees

        uint256 profit = currentAssets - startAssets;

        // Performance fee on profit
        uint256 perfFee = (profit * vs.vaultFees.performanceFeeBps) / 10_000;

        // Management fee on total assets (annualized, applied per cycle)
        // Simplified: charge full mgmt fee per cycle close
        uint256 mgmtFee = (currentAssets * vs.vaultFees.managementFeeBps) / 10_000;

        uint256 totalFees = perfFee + mgmtFee;
        if (totalFees > profit) totalFees = profit; // never take more than profit

        IERC20 depositToken = IERC20(asset());

        if (totalFees > 0 && vs.vaultFees.feeRecipient != address(0)) {
            depositToken.safeTransfer(vs.vaultFees.feeRecipient, totalFees);
        }

        // Adjust totalTVL to reflect fees leaving the vault
        if (vs.totalTVL > totalFees) {
            vs.totalTVL -= totalFees;
        } else {
            vs.totalTVL = 0;
        }

        emit Events.FeesCollected(perfFee, mgmtFee, totalFees);
    }

    /// @notice Receive ETH (gas refunds)
    receive() external payable {}
    fallback() external payable {}
}
