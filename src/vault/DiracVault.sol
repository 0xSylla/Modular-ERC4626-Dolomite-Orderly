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
import {IDiracVault} from "../interfaces/IDiracVault.sol";

/// @title DiracVault
/// @notice ERC4626 vault with windowed trade cycles, multi-strategy support, and delegatecall-based module execution
/// @dev No proxy — standalone immutable contract. Strategy logic lives in modules executed via delegatecall.
contract DiracVault is ERC4626, AccessControl, ReentrancyGuard, Pausable, IDiracVault {
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
        Data.CuratorFeeConfig memory _curatorFee,
        Data.ProtocolFees memory _protocolFees,
        address[] memory _modules
    ) ERC4626(IERC20(_depositToken)) ERC20(_name, _symbol) {
        if (_factory == address(0)) revert Events.ZeroAddress();
        factory = _factory;
        templateId = _templateId;

        _grantRole(OWNER_ROLE, _factory);
        _grantRole(CURATOR_ROLE, _curator);
        _grantRole(OPERATOR_ROLE, _operator);

        // Only factory (OWNER_ROLE) can grant/revoke OPERATOR_ROLE and CURATOR_ROLE
        _setRoleAdmin(OPERATOR_ROLE, OWNER_ROLE);
        _setRoleAdmin(CURATOR_ROLE, OWNER_ROLE);

        VaultStorage.Layout storage vs = VaultStorage.layout();
        vs.maxDeposit = _maxDeposit;
        vs.curatorFee = _curatorFee;
        vs.protocolFees = _protocolFees;

        for (uint256 i = 0; i < _modules.length; i++) {
            vs.whitelistedModules[_modules[i]] = true;
        }
    }

    // ============ Inflation Attack Protection ============
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
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
        _requireWithdrawOpen(vs);
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
        _requireWithdrawOpen(vs);

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
        address module,
        bytes calldata data
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant returns (bytes memory) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (!vs.whitelistedModules[module]) revert Events.ModuleNotWhitelisted();
        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) revert Events.ModuleExecutionFailed();
        emit Events.ModuleExecuted(module, false);
        return result;
    }

    function executeModule(
        address module,
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
        if (!vs.whitelistedModules[module]) revert Events.ModuleNotWhitelisted();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();

        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) revert Events.ModuleExecutionFailed();
        emit Events.ModuleExecuted(module, true);
        return result;
    }

    function executeBatch(
        address[] calldata modules,
        bytes[] calldata datas
    )
        external
        payable
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes[] memory results)
    {
        if (modules.length != datas.length) revert Events.ArrayLengthMismatch();

        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();

        results = new bytes[](modules.length);
        for (uint256 i = 0; i < modules.length; i++) {
            if (!vs.whitelistedModules[modules[i]])
                revert Events.ModuleNotWhitelisted();
            (bool ok, bytes memory result) = modules[i].delegatecall(datas[i]);
            if (!ok) revert Events.ModuleExecutionFailed();
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
        vs.currentCycle.status = Data.TradeCycleStatus.TRADING;
        // Snapshot assets for P&L calculation
        vs.currentCycle.assetsAtCycleStart = totalAssets();
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.TRADING);
    }

    function openWithdrawals() external onlyRole(CURATOR_ROLE) whenNotPaused {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.TRADING)
            revert Events.NotInTradingPeriod();
        vs.currentCycle.status = Data.TradeCycleStatus.WITHDRAW_OPEN;
        _collectFees(vs);
        emit Events.CycleStatusChanged(Data.TradeCycleStatus.WITHDRAW_OPEN);
    }

    function closeCycle() external onlyRole(CURATOR_ROLE) whenNotPaused {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (vs.currentCycle.status != Data.TradeCycleStatus.WITHDRAW_OPEN)
            revert Events.OperationFailed();
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
        address module,
        bytes calldata data
    ) external payable onlyRole(OWNER_ROLE) nonReentrant returns (bytes memory) {
        VaultStorage.Layout storage vs = VaultStorage.layout();
        if (!vs.whitelistedModules[module]) revert Events.ModuleNotWhitelisted();
        (bool ok, bytes memory result) = module.delegatecall(data);
        if (!ok) revert Events.ModuleExecutionFailed();
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

    // ============ Internal ============

    function _requireDepositOpen(
        VaultStorage.Layout storage vs
    ) internal view {
        if (vs.currentCycle.status != Data.TradeCycleStatus.DEPOSIT_OPEN)
            revert Events.NotInDepositWindow();
    }

    function _requireWithdrawOpen(
        VaultStorage.Layout storage vs
    ) internal view {
        if (vs.currentCycle.status != Data.TradeCycleStatus.WITHDRAW_OPEN)
            revert Events.NotInWithdrawWindow();
    }

    function _collectFees(VaultStorage.Layout storage vs) internal {
        uint256 currentAssets = totalAssets();
        uint256 startAssets = vs.currentCycle.assetsAtCycleStart;
        if (currentAssets <= startAssets) return; // no profit, no fees

        uint256 profit = currentAssets - startAssets;

        uint256 totalFeeBps = vs.protocolFees.protocolFeeBps
            + vs.protocolFees.daoFeeBps
            + vs.curatorFee.curatorFeeBps;
        if (totalFeeBps > 5_000) revert Events.TotalFeesExceedCap(); // max 50%

        uint256 protocolCut = (profit * vs.protocolFees.protocolFeeBps) / 10_000;
        uint256 daoCut = (profit * vs.protocolFees.daoFeeBps) / 10_000;
        uint256 curatorCut = (profit * vs.curatorFee.curatorFeeBps) / 10_000;
        uint256 totalFees = protocolCut + daoCut + curatorCut;

        IERC20 depositToken = IERC20(asset());

        if (protocolCut > 0) {
            depositToken.safeTransfer(
                vs.protocolFees.protocolFeeRecipient,
                protocolCut
            );
        }
        if (daoCut > 0) {
            depositToken.safeTransfer(
                vs.protocolFees.daoFeeRecipient,
                daoCut
            );
        }
        if (curatorCut > 0) {
            depositToken.safeTransfer(
                vs.curatorFee.curatorFeeRecipient,
                curatorCut
            );
        }

        // Adjust totalTVL to reflect fees leaving the vault
        if (vs.totalTVL > totalFees) {
            vs.totalTVL -= totalFees;
        } else {
            vs.totalTVL = 0;
        }

        emit Events.FeesCollected(protocolCut, daoCut, curatorCut);
    }

    /// @notice Receive ETH (gas refunds)
    receive() external payable {}
    fallback() external payable {}
}
