// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";
import {VaultStorage} from "../libraries/VaultStorage.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";
import {IAttributionRegistry} from "../interfaces/IAttributionRegistry.sol";

/// @title DiracVaultV5
/// @notice V4 + Phase 3 attribution hooks. Adds 4 lightweight pieces of state
///         and 3 call-outs to the `AttributionRegistry`. Everything else is
///         byte-identical to V4 (same revert-wrapping semantics, same cycle
///         state machine, same _decimalsOffset, same module-delegatecall
///         architecture).
///
///         New state:
///           - `attributionRegistry`         immutable, set at construction
///           - `hasEverDeposited[user]`      monotonic (never decremented)
///           - `uniqueDepositorCount`        monotonic counter
///           - `curatorAttributed`           one-time latch
///           - `cycleNumber`                 incremented at each closeCycle
///           - `depositors[]`                push-only list, registry iterates at close
///
///         New hooks:
///           - In `deposit` / `mint` AFTER super: track unique depositors +
///             check curator gate (one-time mint).
///           - In `closeCycle` AFTER status flip: increment cycleNumber +
///             notify registry of cycle close (registry iterates depositors).
///
///         All registry calls are wrapped in try/catch so a malfunctioning
///         registry can't brick the core vault. Attribution failure is
///         silent (logs an event, nothing else).
contract DiracVaultV5 is ERC4626, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Role Constants ============
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============ Immutables ============
    address public immutable factory;
    bytes32 public immutable templateId;
    /// @notice Phase 3 attribution engine. May be `address(0)` for vaults
    ///         deployed by an old factory before the registry was wired up;
    ///         hook calls short-circuit when zero.
    address public immutable attributionRegistry;

    // ============ Attribution state (V5 NEW) ============
    /// @notice Monotonic — true after a user's first deposit, never reset.
    mapping(address => bool) public hasEverDeposited;
    /// @notice Monotonic count of distinct depositor addresses (never decremented).
    ///         Distinct from `VaultStorage.totalUsers` which is bidirectional.
    uint256 public uniqueDepositorCount;
    /// @notice One-time latch — flipped when `(TVL × uniqueLPs)` crosses the
    ///         registry's `(minTvlForCurator, minUniqueLps)` gate.
    bool public curatorAttributed;
    /// @notice Incremented on every `closeCycle`. Stable identifier the registry
    ///         uses for per-cycle LP attribution de-dup.
    uint256 public cycleNumber;
    /// @notice Push-only list of depositor addresses. Registry reads at cycle
    ///         close to iterate eligible LPs. Bounded in practice by the
    ///         per-vault LP cap most strategies impose; if a vault attracts
    ///         many thousands of LPs, the registry would need to switch to a
    ///         pull-based attribution flow (TODO for v2).
    address[] private _depositorsList;

    // ============ Events (V5-specific) ============
    event AttributionRegistryCallFailed(string hook);

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
        bytes32[] memory _moduleTypes,
        address _attributionRegistry
    ) ERC4626(IERC20(_depositToken)) ERC20(_name, _symbol) {
        if (_factory == address(0)) revert Events.ZeroAddress();
        factory = _factory;
        templateId = _templateId;
        attributionRegistry = _attributionRegistry; // may be zero — hooks no-op

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
    function totalAssets() public view override returns (uint256) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status == Data.TradeCycleStatus.TRADING) {
            return vs.currentCycle.assetsAtCycleStart;
        }
        return super.totalAssets();
    }

    // ============ Internal: Resolve Module ============
    function _resolveModule(bytes32 moduleType) internal view returns (address module) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (!vs.whitelistedModuleTypes[moduleType]) revert Events.ModuleNotWhitelisted();
        module = IDiracVaultFactory(factory).getModule(moduleType);
        if (module == address(0)) revert Events.ModuleNotWhitelisted();
    }

    // ============ Attribution: depositors list view ============
    /// @notice Used by `AttributionRegistry.onCycleClose` to iterate eligible LPs.
    function depositors() external view returns (address[] memory) {
        return _depositorsList;
    }

    function depositorsLength() external view returns (uint256) {
        return _depositorsList.length;
    }

    function getUserDeposit(address user) external view returns (uint256) {
        return VaultStorage.layout().userDeposits[user];
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

        _trackDepositorAndMaybeAttributeCurator(receiver);
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

        _trackDepositorAndMaybeAttributeCurator(receiver);
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

    // ============ Module Execution (identical to V4) ============

    function setupModule(
        bytes32 moduleType,
        bytes calldata data
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant returns (bytes memory) {
        address module = _resolveModule(moduleType);
        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) revert Events.ModuleExecutionFailed();
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
        if (!ok) revert Events.ModuleExecutionFailed();
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
            if (!ok) revert Events.ModuleExecutionFailed();
            results[i] = result;
        }
    }

    // ============ Curator: Vault Configuration (identical to V4) ============

    function whitelistTargetAsset(address asset) external onlyRole(CURATOR_ROLE) {
        VaultStorage.layout().vaultTargetAssets[asset] = true;
        emit Events.TargetAssetWhitelisted(asset);
    }

    function removeTargetAsset(address asset) external onlyRole(CURATOR_ROLE) {
        delete VaultStorage.layout().vaultTargetAssets[asset];
        emit Events.TargetAssetRemoved(asset);
    }

    function setMaxDeposit(uint256 amount) external onlyRole(CURATOR_ROLE) {
        VaultStorage.layout().maxDeposit = amount;
        emit Events.MaxDepositUpdated(amount);
    }

    // ============ Curator: Cycle Management (V5 + attribution hook) ============

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
        vs.currentCycle.assetsAtCycleStart = super.totalAssets();
        vs.currentCycle.status = Data.TradeCycleStatus.TRADING;
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.TRADING);
    }

    function closeCycle() external onlyRole(CURATOR_ROLE) whenNotPaused {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();
        _collectFees(vs);
        vs.currentCycle.status = Data.TradeCycleStatus.CLOSED;

        // ===== Attribution Hook C: cycle close =====
        cycleNumber++;
        if (attributionRegistry != address(0)) {
            try IAttributionRegistry(attributionRegistry).onCycleClose(cycleNumber) {
                // ok
            } catch {
                emit AttributionRegistryCallFailed("onCycleClose");
            }
        }

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
        if (!ok) revert Events.ModuleExecutionFailed();
        return result;
    }

    // ============ View Functions ============
    function getCurrentCycle() external view returns (Data.TradeCycle memory) { return VaultStorage.layout().currentCycle; }
    function isTargetAssetWhitelisted(address asset) external view returns (bool) { return VaultStorage.layout().vaultTargetAssets[asset]; }
    function isModuleTypeWhitelisted(bytes32 moduleType) external view returns (bool) { return VaultStorage.layout().whitelistedModuleTypes[moduleType]; }
    function getMaxDeposit() external view returns (uint256) { return VaultStorage.layout().maxDeposit; }
    function getTotalTVL() external view returns (uint256) { return VaultStorage.layout().totalTVL; }
    function getTotalUsers() external view returns (uint256) { return VaultStorage.layout().totalUsers; }
    function getVaultFees() external view returns (Data.VaultFees memory) { return VaultStorage.layout().vaultFees; }
    function getRebalanceThresholdBps() external view returns (uint256) { return VaultStorage.layout().rebalanceThresholdBps; }
    function getFundingRateThresholdBps() external view returns (uint256) { return VaultStorage.layout().fundingRateThresholdBps; }

    // ============ Internal ============

    function _requireDepositOpen(VaultStorage.Layout storage vs) internal view {
        if (vs.currentCycle.status != Data.TradeCycleStatus.DEPOSIT_OPEN)
            revert Events.NotInDepositWindow();
    }

    function _requireWithdrawAllowed(VaultStorage.Layout storage vs) internal view {
        if (vs.currentCycle.status == Data.TradeCycleStatus.TRADING)
            revert Events.NotInWithdrawWindow();
    }

    function _collectFees(VaultStorage.Layout storage vs) internal {
        uint256 currentAssets = totalAssets();
        uint256 startAssets = vs.currentCycle.assetsAtCycleStart;
        if (currentAssets <= startAssets) return;

        uint256 profit = currentAssets - startAssets;
        uint256 perfFee = (profit * vs.vaultFees.performanceFeeBps) / 10_000;
        uint256 mgmtFee = (currentAssets * vs.vaultFees.managementFeeBps) / 10_000;

        uint256 totalFees = perfFee + mgmtFee;
        if (totalFees > profit) totalFees = profit;

        IERC20 depositToken = IERC20(asset());
        if (totalFees > 0 && vs.vaultFees.feeRecipient != address(0)) {
            depositToken.safeTransfer(vs.vaultFees.feeRecipient, totalFees);
        }
        if (vs.totalTVL > totalFees) {
            vs.totalTVL -= totalFees;
        } else {
            vs.totalTVL = 0;
        }

        emit Events.FeesCollected(perfFee, mgmtFee, totalFees);
    }

    /// @dev Attribution Hooks A + B — called from `deposit` and `mint` after
    ///      the ERC4626 effects have settled. Hook A is the unique-LP counter
    ///      bookkeeping. Hook B is the one-time curator gate check. Both are
    ///      idempotent; the registry call is wrapped in try/catch so vault
    ///      behavior is robust to registry misbehavior.
    function _trackDepositorAndMaybeAttributeCurator(address receiver) internal {
        // Hook A: unique depositor tracking
        if (!hasEverDeposited[receiver]) {
            hasEverDeposited[receiver] = true;
            _depositorsList.push(receiver);
            uniqueDepositorCount++;
        }

        // Hook B: curator gate (one-time)
        if (!curatorAttributed && attributionRegistry != address(0)) {
            IAttributionRegistry reg = IAttributionRegistry(attributionRegistry);
            uint256 tvlGate = reg.minTvlForCurator();
            uint256 lpsGate = reg.minUniqueLps();
            if (totalAssets() >= tvlGate && uniqueDepositorCount >= lpsGate) {
                curatorAttributed = true;
                try reg.onCuratorGateHit() {
                    // ok
                } catch {
                    // Re-open the latch so it can retry on the next deposit
                    // if the registry was temporarily broken. The state IS
                    // monotonic at the gate (TVL × LPs is increasing in this
                    // window), so a future deposit triggers re-evaluation.
                    curatorAttributed = false;
                    emit AttributionRegistryCallFailed("onCuratorGateHit");
                }
            }
        }
    }

    /// @notice Receive ETH (gas refunds)
    receive() external payable {}
    fallback() external payable {}
}
