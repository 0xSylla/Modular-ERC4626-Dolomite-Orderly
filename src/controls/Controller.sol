// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "../data/Data.sol";
import  "../events/Events.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Controller is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    IERC20 public assetDeposit;
    address public ivault;
    mapping(address => bool) public whitelisted;
    uint256 public maxUserDeposit;
    mapping(address => uint256) public userDeposits;
    uint256 public totalUsers;
    mapping(uint256 => Data.TradeCycle) public tradeCycles;
    uint256 public currentTradeCycleId;
    uint256 public totalTVL;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(){
        _disableInitializers();
    }

    /**
    * @notice Pauses all contract operations.
     * @dev Callable only by the admin.
     */

    function __Controller_init(
        address _ivault,
        IERC20 _assetDeposit
    ) internal onlyInitializing {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();



        if (address(_assetDeposit) == address(0) || address(_ivault) == address(0)) {
            revert("Zero address provided");
        }

        totalTVL = 0;
        ivault = _ivault;
        assetDeposit = _assetDeposit;
    }

    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses contract operations.
     * @dev Callable only by the admin.
     */
    function emergencyUnpause() external onlyRole(DEFAULT_ADMIN_ROLE){
        _unpause();
    }


    /**
     * @notice Modifier to restrict function execution to the admin role.
     * @param status The required trade cycle status for the operation.
     */
    modifier onlyTradeCycle(Data.TradeCycleStatus status) {
        if (tradeCycles[currentTradeCycleId].status != status) {
            revert Events.OperationFailed();
        }
        _;
    }


    /**
     * @notice Modifier to restrict function execution when the trade cycle is closed.
     * @dev Ensures that the trade cycle is either in INIT or CLOSED status.
     */
    modifier whenTradeClosed() {
        Data.TradeCycle memory tradeCycle = tradeCycles[currentTradeCycleId];
        if (
            tradeCycle.status != Data.TradeCycleStatus.INIT &&
            tradeCycle.status != Data.TradeCycleStatus.CLOSED
        ) {
            revert Events.OperationFailed();
        }

        _;
    }


    /**
    * @notice Ends the current trade cycle.
     * @dev Marks the current cycle as ENDED, records the ending timestamp, increments the cycle ID, and emits a TradeCycleEnded event.
     */
    function initializeCycle() external onlyRole(DEFAULT_ADMIN_ROLE)  whenNotPaused
    {
        currentTradeCycleId = 0;
        Data.TradeCycle storage tradeCycle = tradeCycles[currentTradeCycleId];
        tradeCycle.status = Data.TradeCycleStatus.INIT;
        emit Events.TradeCycleInit(currentTradeCycleId);
    }

    /**
     * @notice Creates a new trade cycle.
     * @dev Callable only by the admin when the trade cycle is closed and the contract is not paused.
     * @param _duration The duration of the trade cycle in seconds.
     */
    function startTradeCycle(
        uint256 _duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenTradeClosed whenNotPaused {
        currentTradeCycleId = currentTradeCycleId + 1;
        Data.TradeCycle storage tradeCycle = tradeCycles[currentTradeCycleId];
        tradeCycle.AmountAvailable = assetDeposit.balanceOf(address(this));
        tradeCycle.status = Data.TradeCycleStatus.OPEN;
        tradeCycle.startedAt = uint40(block.timestamp);
        tradeCycle.endedAt = uint40(block.timestamp + _duration);

        emit Events.TradeCycleStarted(
            currentTradeCycleId,
            tradeCycle.AmountAvailable,
            tradeCycle.startedAt,
            tradeCycle.endedAt
        );
    }

    /**
    * @notice Updates the trade cycle duration.
     * @dev Callable only by the admin.
     * @param _newTradeCycleEndDate The new end date for the trade cycle.
     */
    function updateTradeCycleDuration(
        uint40 _newTradeCycleEndDate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Data.TradeCycle storage tradeCycle = tradeCycles[currentTradeCycleId];
        if (uint40(block.timestamp) > _newTradeCycleEndDate) {
            revert();
        }

        tradeCycle.endedAt = _newTradeCycleEndDate;
    }
    /**
     * @notice Updates the whitelist status of multiple users.
     * @dev Skips the zero address. Callable only by an operator.


    /**
     * @notice Requests to end the current trade cycle.
     * @dev Only callable by the admin when the trade cycle status is OPEN and the contract is not paused.
     */
    function requestToEndTradeCycle() external  onlyRole(DEFAULT_ADMIN_ROLE) onlyTradeCycle(Data.TradeCycleStatus.OPEN) whenNotPaused{
        Data.TradeCycle storage tradeCycle = tradeCycles[currentTradeCycleId];
        tradeCycle.status = Data.TradeCycleStatus.PENDING;

        emit Events.TradeCyclePendingEnd(currentTradeCycleId);
    }

    /**
     * @notice Ends the current trade cycle.
     * @dev Only callable by the admin when the trade cycle status is PENDING and the contract is not paused.
     */

    function endTradeCycle() external onlyRole(DEFAULT_ADMIN_ROLE) onlyTradeCycle(Data.TradeCycleStatus.PENDING) whenNotPaused {
        Data.TradeCycle storage tradeCycle = tradeCycles[currentTradeCycleId];
        tradeCycle.status = Data.TradeCycleStatus.CLOSED;
        tradeCycle.endedAt = uint40(block.timestamp);
        emit Events.TradeCycleEnded(currentTradeCycleId, tradeCycle.endedAt);
    }


}
